import UIKit
import shared

/// One startup sync per configuration; reader entry waits for the shared worker to really stop.
@MainActor
final class BookshelfProgressSyncCoordinator {
    static let shared = BookshelfProgressSyncCoordinator()

    private struct Configuration: Hashable {
        let enabled: Bool
        let url: String?
        let account: String?
        let password: String?
        let directory: String

        init(_ config: AppRuntimeConfig) {
            enabled = config.syncBookProgress
            url = config.webDavUrl
            account = config.webDavAccount
            password = config.webDavPassword
            directory = config.webDavDir
        }

        var canStart: Bool {
            enabled && account?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                && password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }

    @MainActor
    private final class Request {
        let id = UUID()
        let configuration: Configuration
        var subscription: FlowSubscription?
        var cancellationRequested = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        init(configuration: Configuration) { self.configuration = configuration }

        func cancel() {
            guard !cancellationRequested else { return }
            cancellationRequested = true
            subscription?.cancel()
        }
    }

    private enum LifecycleEvent {
        case resume, suspend, disconnect
    }

    private weak var home: MainTabBarController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var navigation: UINavigationController?
    private var ownerGeneration = UUID()
    private var readingSuspended = false
    private var wasSafelyActive = false
    private var activation: UInt64 = 0
    private var configuration: Configuration?
    private var completedConfigurations = Set<Configuration>()
    private var attemptedActivation: [Configuration: UInt64] = [:]
    private var client: BookshelfProgressSyncClient?
    private var runtimeSubscription: FlowSubscription?
    private var runtimeObservation = UUID()
    private var request: Request?
    private var observers: [NSObjectProtocol] = []

    private init() {
        observe(UIScene.didActivateNotification, event: .resume)
        observe(UIApplication.didBecomeActiveNotification, event: .resume)
        observe(UIWindow.didBecomeKeyNotification, event: .resume)
        observe(.appLockStatusDidChange, event: .resume)
        observe(UIApplication.protectedDataDidBecomeAvailableNotification, event: .resume)
        observe(UIScene.willDeactivateNotification, event: .suspend)
        observe(UIScene.didEnterBackgroundNotification, event: .suspend)
        observe(UIApplication.willResignActiveNotification, event: .suspend)
        observe(UIApplication.didEnterBackgroundNotification, event: .suspend)
        observe(UIWindow.didResignKeyNotification, event: .suspend)
        observe(.appLockWillCover, event: .suspend)
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification, event: .suspend)
        observe(UIScene.didDisconnectNotification, event: .disconnect)
    }

    deinit {
        runtimeSubscription?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Only MainTab appearance can release a reader-entry barrier, not a settings/key callback.
    func resume(from home: MainTabBarController) {
        guard home.isVisibleForBookshelfProgressSync,
            let window = home.viewIfLoaded?.window, let scene = window.windowScene,
            let navigation = home.navigationController,
            window.rootViewController === navigation, navigation.viewControllers.first === home
        else { return }
        if self.home !== home || self.window !== window || self.scene !== scene || self.navigation !== navigation {
            invalidateActivation()
            self.home = home
            self.window = window
            self.scene = scene
            self.navigation = navigation
        }
        readingSuspended = false
        observeSettingsIfReady()
        scheduleEvaluation()
    }

    func suspend(from home: MainTabBarController) {
        guard self.home === home else { return }
        invalidateActivation()
    }

    /// Swift task cancellation intentionally cannot release this wait before the native terminal.
    func suspendAndWait() async {
        readingSuspended = true
        invalidateActivation()
        guard let request else { return }
        await withCheckedContinuation { continuation in
            request.waiters.append(continuation)
        }
    }

    private func observeSettingsIfReady() {
        guard runtimeSubscription == nil, SharedRuntime.startupState == .ready else { return }
        do {
            let settings = try SharedRuntime.settingsFacade().get()
            client = BookshelfProgressSyncClient(settings: settings)
            let observation = UUID()
            runtimeObservation = observation
            runtimeSubscription = settings.watchRuntimeConfig { [weak self] config in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.runtimeObservation == observation else { return }
                    let next = Configuration(config)
                    guard self.configuration != next else { return }
                    self.configuration = next
                    if let request = self.request, request.configuration != next { request.cancel() }
                    self.scheduleEvaluation()
                }
            }
        } catch {
            // Shared errors may include connection details; never interpolate them here.
            SharedRuntime.log("书架启动进度同步暂不可用，等待下次安全激活")
        }
    }

    private func observe(_ name: Notification.Name, event: LifecycleEvent) {
        let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] notification in
            // UIKit and app-lock notifications can originate outside a Swift actor context.
            MainActor.assumeIsolated { self?.handle(notification, event: event) }
        }
        observers.append(observer)
    }

    private func handle(_ notification: Notification, event: LifecycleEvent) {
        guard home != nil else { return }
        if let source = notification.object as? UIWindow, source !== window { return }
        if let source = notification.object as? UIScene, source !== scene { return }
        switch event {
        case .resume:
            observeSettingsIfReady()
            scheduleEvaluation()
        case .suspend:
            invalidateActivation()
        case .disconnect:
            invalidateActivation()
            home = nil
            window = nil
            scene = nil
            navigation = nil
        }
    }

    private func invalidateActivation() {
        ownerGeneration = UUID()
        wasSafelyActive = false
        // Keep the request and its single-flight slot until syncRequest delivers its terminal.
        request?.cancel()
    }

    private func scheduleEvaluation() {
        let generation = ownerGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ownerGeneration == generation else { return }
            self.evaluate()
        }
    }

    private var canRun: Bool {
        guard !readingSuspended, SharedRuntime.startupState == .ready,
            UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
            let home, let window, let scene, let navigation,
            home.isVisibleForBookshelfProgressSync, home.isReadyForStartupNavigation,
            home.viewIfLoaded?.window === window, home.navigationController === navigation,
            window.windowScene === scene, window.rootViewController === navigation,
            navigation.viewControllers.count == 1, navigation.topViewController === home,
            scene.activationState == .foregroundActive, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    private func evaluate() {
        guard canRun else {
            if wasSafelyActive || request?.cancellationRequested == false { invalidateActivation() }
            return
        }
        if !wasSafelyActive {
            wasSafelyActive = true
            activation &+= 1
        }
        guard request == nil, let configuration, configuration.canStart, let client,
            !completedConfigurations.contains(configuration), attemptedActivation[configuration] != activation
        else { return }

        let next = Request(configuration: configuration)
        request = next
        attemptedActivation[configuration] = activation
        let id = next.id
        // Register before starting: even an immediate native callback must share this one slot.
        next.subscription = client.syncRequest { [weak self] response in
            DispatchQueue.main.async { [weak self] in self?.finish(id, response: response) }
        }
    }

    private func finish(_ id: UUID, response: BookshelfProgressSyncResponse) {
        guard let request, request.id == id else { return }
        request.subscription = nil
        self.request = nil
        if response.isCancelled {
            SharedRuntime.log("书架启动进度同步已取消")
        } else if response.errorCode == nil, response.errorMessage == nil, let result = response.result {
            if result.disabled || result.failedCount == 0 {
                completedConfigurations.insert(request.configuration)
            }
            SharedRuntime.log(
                "书架启动进度同步结束: 更新 \(result.updatedCount)，跳过 \(result.skippedCount)，失败 \(result.failedCount)，停用 \(result.disabled)")
        } else {
            SharedRuntime.log("书架启动进度同步失败，等待下次安全激活")
        }

        let waiters = request.waiters
        request.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
        // Only a changed configuration or a newer safe activation can run another request.
        // A reader barrier remains latched even when this callback or a config update arrives.
        scheduleEvaluation()
    }
}
