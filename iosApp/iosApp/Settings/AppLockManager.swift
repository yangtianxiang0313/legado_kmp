import UIKit

extension Notification.Name {
    static let appLockStatusDidChange = Notification.Name("io.legado.app-lock.status-changed")
    static let appLockWillCover = Notification.Name("io.legado.app-lock.will-cover")
}

@MainActor
final class AppLockManager {
    static let shared = AppLockManager()

    private let credentials = AppLockCredentialStore()
    private var scenes: [ObjectIdentifier: AppLockSceneSession] = [:]
    private var refreshTask: Task<Void, Never>?
    private var operationID: UUID?
    private var credentialRevision = 0
    private(set) var status: AppLockStatus = .checking

    /// Unknown/unavailable storage is protected, never interpreted as "no password".
    var hasPassword: Bool { status != .disabled }

    private init() {}

    /// Attach before exposing the content window. The callback runs after each successful re-entry.
    func attach(window: UIWindow, onUnlocked: (() -> Void)? = nil) {
        guard let scene = window.windowScene else {
            window.isHidden = true
            return
        }
        let id = ObjectIdentifier(scene)
        if let existing = scenes[id] {
            existing.replaceContentWindow(window)
            if let onUnlocked {
                existing.onUnlocked = onUnlocked
                // Bootstrap may replace StartupVC after generation zero was already uncovered.
                existing.deliveredGeneration = -1
                if existing.active { reconcile(existing) }
            }
            return
        }
        let session = AppLockSceneSession(window: window, scene: scene)
        session.onUnlocked = onUnlocked
        scenes[id] = session
        session.showPrivacy()
        if session.active { reconcile(session) }
        refreshStatus()
    }

    func sceneDidBecomeActive(_ window: UIWindow?) {
        guard let window else { return }
        attach(window: window)
        guard let session = session(for: window) else { return }
        session.active = true
        reconcile(session)
        refreshStatus()
    }

    /// Call synchronously from sceneWillResignActive, before the system takes its snapshot.
    func sceneWillResignActive(_ window: UIWindow?) {
        guard let window, let session = session(for: window) else { return }
        session.active = false
        session.generation += 1
        session.requiresUnlock = true
        session.showPrivacy()
        NotificationCenter.default.post(name: .appLockWillCover, object: window)
    }

    func sceneDidEnterBackground(_ window: UIWindow?) {
        guard let window, let session = session(for: window) else { return }
        if session.active {
            sceneWillResignActive(window)
        } else {
            session.showPrivacy()
        }
    }

    func sceneDidDisconnect(_ window: UIWindow?) {
        guard let window, let scene = window.windowScene,
            let session = scenes.removeValue(forKey: ObjectIdentifier(scene))
        else { return }
        session.active = false
        session.generation += 1
        session.pendingUnlock.removeAll()
        session.disconnect()
    }

    /// Previous startup API; lifecycle calls above remain required for subsequent re-entry.
    func presentLockScreenIfNeeded(on window: UIWindow?, onUnlocked: @escaping () -> Void = {}) {
        guard let window else { return }
        attach(window: window)
        guard let session = session(for: window) else { return }
        session.pendingUnlock.append(onUnlocked)
        if session.active { reconcile(session) }
    }

    func refreshStatus() {
        guard refreshTask == nil else { return }
        let revision = credentialRevision
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let loaded: AppLockStatus
            do { loaded = try await credentials.status() } catch { loaded = .unavailable }
            refreshTask = nil
            guard revision == credentialRevision else { refreshStatus(); return }
            applyStatus(loaded)
        }
    }

    func setPassword(_ password: String, confirmation: String, in window: UIWindow?) async throws {
        try AppLockCredentialCrypto.validateNewPassword(password, confirmation: confirmation)
        try await mutate(in: window) { try await self.credentials.prepareEnable(password) }
    }

    func changePassword(
        oldPassword: String, newPassword: String, confirmation: String, in window: UIWindow?
    ) async throws {
        try AppLockCredentialCrypto.validateNewPassword(newPassword, confirmation: confirmation)
        try await mutate(in: window) {
            try await self.credentials.prepareChange(oldPassword: oldPassword, newPassword: newPassword)
        }
    }

    func disablePassword(_ password: String, in window: UIWindow?) async throws {
        try await mutate(in: window) { try await self.credentials.prepareDisable(password) }
    }

    func isUnlocked(in window: UIWindow?) -> Bool {
        guard let window, let session = session(for: window) else { return false }
        return canManage(session)
    }

    private func mutate(
        in window: UIWindow?, prepare: () async throws -> AppLockCredentialStore.Mutation
    ) async throws {
        guard let window, let session = session(for: window), canManage(session) else { throw AppLockFailure.inactive }
        guard operationID == nil else { throw AppLockFailure.busy }
        let id = UUID()
        let generation = session.generation
        operationID = id
        credentialRevision += 1
        defer {
            if operationID == id { operationID = nil }
            refreshStatus()
        }
        do {
            let mutation = try await prepare()
            try Task.checkCancellation()
            guard session.generation == generation, canManage(session) else { throw AppLockFailure.inactive }
            let result = try await credentials.commit(mutation)
            credentialRevision += 1
            // A commit may finish while resigning. Its completion must not uncover an inactive scene.
            for candidate in scenes.values {
                if candidate !== session || candidate.generation != generation || !candidate.active {
                    candidate.requiresUnlock = true
                }
            }
            applyStatus(result)
            guard session.generation == generation, session.active else { throw AppLockFailure.inactive }
        } catch {
            switch error {
            case AppLockFailure.storageUnavailable, AppLockFailure.damagedCredential,
                AppLockFailure.credentialChanged:
                applyStatus(.unavailable)
            default: break
            }
            throw error
        }
    }

    private func canManage(_ session: AppLockSceneSession) -> Bool {
        session.active && !session.requiresUnlock && session.isContentVisible
            && session.contentWindow?.windowScene?.activationState == .foregroundActive
            && (status == .enabled || status == .disabled)
    }

    private func session(for window: UIWindow) -> AppLockSceneSession? {
        guard let scene = window.windowScene, let session = scenes[ObjectIdentifier(scene)],
            session.contentWindow === window
        else { return nil }
        return session
    }

    private func applyStatus(_ newStatus: AppLockStatus) {
        let changed = status != newStatus
        status = newStatus
        for session in scenes.values { reconcile(session) }
        if changed { NotificationCenter.default.post(name: .appLockStatusDidChange, object: self) }
    }

    private func reconcile(_ session: AppLockSceneSession) {
        guard session.active else { session.showPrivacy(); return }
        if status == .disabled, operationID != nil, session.requiresUnlock {
            // An enable commit may be completing on the worker while this scene re-enters.
            session.showBlocked(unavailable: false)
            return
        }
        switch status {
        case .disabled:
            session.requiresUnlock = false
            uncover(session)
        case .enabled where !session.requiresUnlock:
            uncover(session)
        case .enabled:
            session.showLock()
            session.controller.onSubmit = { [weak self, weak session] password in
                guard let self, let session else { return }
                self.unlock(password, session: session)
            }
        case .checking, .unavailable:
            session.requiresUnlock = true
            session.showBlocked(unavailable: status == .unavailable)
            session.controller.onRetry = { [weak self] in self?.refreshStatus() }
        }
    }

    private func uncover(_ session: AppLockSceneSession) {
        session.uncover()
        let generation = session.generation
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session, session.active, !session.requiresUnlock,
                session.generation == generation, session.isContentVisible,
                status == .disabled || status == .enabled
            else { return }
            let callbacks = session.pendingUnlock
            session.pendingUnlock.removeAll()
            if session.deliveredGeneration != generation {
                session.deliveredGeneration = generation
                session.onUnlocked?()
            }
            callbacks.forEach { $0() }
        }
    }

    private func unlock(_ password: String, session: AppLockSceneSession) {
        guard session.active, session.requiresUnlock, status == .enabled else { return }
        guard operationID == nil else { session.controller.showError(AppLockFailure.busy); return }
        let id = UUID()
        let generation = session.generation
        let revision = credentialRevision
        operationID = id
        session.controller.setProcessing(true)
        Task { [weak self] in
            guard let self else { return }
            defer {
                if operationID == id { operationID = nil }
                session.controller.setProcessing(false)
            }
            do {
                try await credentials.verify(password)
                guard session.active, session.generation == generation, credentialRevision == revision,
                    status == .enabled, session.contentWindow?.windowScene?.activationState == .foregroundActive
                else { return }
                session.requiresUnlock = false
                session.controller.clearSensitiveInput()
                uncover(session)
            } catch {
                guard session.active, session.generation == generation else { return }
                session.controller.showError(error)
                switch error {
                case AppLockFailure.storageUnavailable, AppLockFailure.damagedCredential,
                    AppLockFailure.credentialChanged, AppLockFailure.notEnabled:
                    applyStatus(.unavailable)
                default: break
                }
            }
        }
    }
}
