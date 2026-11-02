import UIKit
import shared

/// Owns file access, export, and restore presentation independently of the settings table.
@MainActor
final class SettingsBackupCoordinator: NSObject {
    private enum Phase { case idle, choosing, password, transitioning, working, sharing, result }
    private final class AttachmentProbe: UIView {
        var onWindowChanged: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?()
        }
    }

    private weak var owner: UIViewController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var navigationTop: UIViewController?
    private let screen: SettingsScreenAdapter
    private let onError: (Error) -> Void
    private let onRestored: () -> Void
    private var phase = Phase.idle
    private var requestID: UUID?
    private var deliveryInvalidated = false
    private var workInFlight = false
    private var pendingPassword: String?
    private var presentation: UIViewController?
    private var attachmentProbe: AttachmentProbe?
    private var monitor: Task<Void, Never>?
    private var isProcessing: Bool { phase != .idle }
    private lazy var restoration = SettingsBackupRestoreCoordinator(
        owner: owner, screen: screen, onError: onError, onRestored: onRestored)

    init(
        owner: UIViewController, screen: SettingsScreenAdapter,
        onError: @escaping (Error) -> Void, onRestored: @escaping () -> Void
    ) {
        self.owner = owner
        self.screen = screen
        self.onError = onError
        self.onRestored = onRestored
    }

    deinit {
        monitor?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func presentSimpleAlert(title: String, message: String, id: UUID) {
        guard ready(id) else {
            finish(id)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                self.afterDismissal(of: alert, id: id, from: .result) { [weak self] in self?.finish(id) }
            })
        phase = .result
        present(alert, id: id)
    }

    // MARK: - F59/F60 Backup & Restore

    func executeBackup() { chooseDestination(restoring: false) }

    private func chooseDestination(restoring: Bool) {
        guard let id = begin(phase: .choosing), let owner else { return }
        let sheet = UIAlertController(
            title: restoring
                ? NSLocalizedString("backup.local.restore.title", value: "恢复备份", comment: "Local restore destination title")
                : NSLocalizedString("backup.local.export.title", value: "立即备份", comment: "Local backup destination title"),
            message: nil, preferredStyle: .actionSheet)
        sheet.view.accessibilityIdentifier = "settings.backup.destination"
        sheet.addAction(
            UIAlertAction(
                title: restoring
                    ? NSLocalizedString("backup.local.restore.file", value: "从本地文件恢复", comment: "Restore from local file")
                    : NSLocalizedString("backup.local.export.file", value: "备份到本地", comment: "Back up to local storage"),
                style: .default
            ) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                self.afterDismissal(of: sheet, id: id, from: .choosing) { [weak self] in
                    guard let self else { return }
                    if restoring {
                        self.finish(id)
                        self.restoration.showFilePicker()
                    } else {
                        self.executeLocalBackup(id: id)
                    }
                }
            })
        sheet.addAction(
            UIAlertAction(
                title: restoring
                    ? NSLocalizedString("backup.local.restore.webdav", value: "从 WebDAV 恢复", comment: "Restore from WebDAV")
                    : NSLocalizedString("backup.local.export.webdav", value: "备份到 WebDAV", comment: "Back up to WebDAV"),
                style: .default
            ) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                self.afterDismissal(of: sheet, id: id, from: .choosing) { [weak self] in
                    guard let self, let owner = self.owner, let navigation = self.navigation else { return }
                    let page = CloudBackupViewController()
                    page.onRestored = self.onRestored
                    self.finish(id)
                    guard owner.canPerformNavigationAction else { return }
                    navigation.pushViewController(page.configuredForDrillDownPresentation(), animated: true)
                }
            })
        sheet.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                self.afterDismissal(of: sheet, id: id, from: .choosing) { [weak self] in self?.finish(id) }
            })
        sheet.popoverPresentationController?.sourceView = owner.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
        present(sheet, id: id)
    }

    func checkWebDavConnection() {
        guard let id = begin(phase: .working) else { return }
        let hud = UIAlertController(title: L10n.Settings.webDavChecking, message: nil, preferredStyle: .alert)
        present(hud, id: id)
        guard current(id) else {
            finish(id)
            return
        }
        workInFlight = true
        Task { [self] in
            do {
                let connected = try await screen.checkWebDavConnection()
                // Never cancel/release a shared request before its real terminal callback.
                let initialized = connected && current(id) ? try await screen.initWebDavDirs() : false
                await dismiss(hud)
                workInFlight = false
                guard ready(id) else {
                    finish(id)
                    return
                }
                presentSimpleAlert(
                    title: L10n.Settings.webDavTitle,
                    message: connected && initialized ? L10n.Settings.webDavCheckSuccess : L10n.Settings.webDavCheckFailed,
                    id: id)
            } catch {
                await dismiss(hud)
                workInFlight = false
                let mayReport = ready(id)
                finish(id)
                // Preserve the adapter's existing error path, including missing configuration.
                if mayReport { onError(error) }
            }
        }
    }

    private func executeLocalBackup(id: UUID) {
        guard ready(id) else {
            finish(id)
            return
        }
        phase = .password
        let passwordTitle = NSLocalizedString("backup.local.password.title", value: "备份密码", comment: "Backup password title")
        let prompt = UIAlertController(
            title: passwordTitle,
            message: NSLocalizedString(
                "backup.local.password.message", value: "用于保护服务器和 WebDAV 凭据。请保管密码，以便在其它设备恢复。",
                comment: "Backup password purpose"), preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "settings.backup.password"
        for (index, placeholder) in [
            passwordTitle,
            NSLocalizedString("backup.local.password.repeat", value: "再次输入密码", comment: "Repeat backup password"),
        ].enumerated() {
            prompt.addTextField {
                $0.placeholder = placeholder
                $0.isSecureTextEntry = true
                $0.autocorrectionType = .no
                $0.textContentType = .newPassword
                $0.accessibilityIdentifier = "settings.backup.password.\(index)"
            }
        }
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak prompt] _ in
                self?.clearPassword(prompt)
                guard let self, let prompt else { return }
                self.afterDismissal(of: prompt, id: id, from: .password) { [weak self] in self?.finish(id) }
            })
        let confirm = UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak prompt] _ in
            guard let self, let prompt else { return }
            let password = prompt.textFields?.first?.text ?? ""
            let repeated = prompt.textFields?.last?.text
            self.clearPassword(prompt)
            guard self.current(id), self.phase == .password, self.presentation === prompt else { return }
            guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                password == repeated
            else {
                self.invalidate(id)
                return
            }
            self.pendingPassword = password
            self.afterDismissal(of: prompt, id: id, from: .password) { [weak self] in
                guard let self, let password = self.pendingPassword else { return }
                self.pendingPassword = nil
                self.performBackup(password: password, id: id)
            }
        }
        confirm.isEnabled = false
        prompt.addAction(confirm)
        for field in prompt.textFields ?? [] {
            field.addAction(
                UIAction { [weak self, weak prompt, weak confirm] _ in
                    guard let self, self.current(id), self.phase == .password else {
                        self?.clearPassword(prompt)
                        confirm?.isEnabled = false
                        return
                    }
                    let password = prompt?.textFields?.first?.text ?? ""
                    confirm?.isEnabled =
                        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && password == prompt?.textFields?.last?.text
                }, for: .editingChanged)
        }
        present(prompt, id: id)
    }

    private func performBackup(password: String, id: UUID) {
        guard ready(id) else {
            finish(id)
            return
        }
        phase = .working
        let hud = UIAlertController(title: L10n.Settings.backupProcessing, message: nil, preferredStyle: .alert)
        present(hud, id: id)
        guard current(id) else {
            finish(id)
            return
        }
        workInFlight = true
        Task { [self] in
            do {
                let configuration = screen.latestRuntimeConfig
                let archive = try await screen.createAndroidBackupArchive(password: password)
                guard current(id) else {
                    await dismiss(hud)
                    workInFlight = false
                    finish(id)
                    return
                }
                // Once saving starts, UI invalidation suppresses delivery, not the atomic write.
                let fileURL = try await LocalBackupStore.shared.save(
                    base64: archive.base64Zip, onlyLatest: configuration?.onlyLatestBackup ?? true,
                    configuredPath: configuration?.backupPath)
                var warnings = SettingsBackupPreparationClient.localizedWarnings(archive.warnings)
                do { try await CloudBackupScreenAdapter().markLocalBackupCreated() } catch {
                    warnings.append(
                        NSLocalizedString(
                            "backup.local.saved.timestamp_warning", value: "备份已保存，但最近备份时间未记录。",
                            comment: "Saved backup timestamp warning"))
                }
                await dismiss(hud)
                workInFlight = false
                guard ready(id) else {
                    finish(id)
                    return
                }
                share(fileURL, warnings: warnings, id: id)
            } catch {
                await dismiss(hud)
                workInFlight = false
                let mayReport = ready(id)
                finish(id)
                if mayReport { onError(Self.localizedExportError(error)) }
            }
        }
    }

    private func share(_ file: URL, warnings: [String], id: UUID) {
        guard ready(id), let owner else {
            finish(id)
            return
        }
        phase = .sharing
        let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "settings.backup.share"
        controller.completionWithItemsHandler = { [weak self, weak controller] _, completed, _, error in
            let failed = error != nil
            Task { @MainActor [weak self, weak controller] in
                guard let self, let controller, self.current(id), self.phase == .sharing,
                    self.presentation === controller
                else { return }
                self.afterDismissal(of: controller, id: id, from: .sharing) { [weak self] in
                    guard let self else { return }
                    let status: String
                    if failed {
                        status = NSLocalizedString(
                            "backup.local.share.failed", value: "备份已保存，但分享未完成。可稍后从备份目录分享。",
                            comment: "Sharing failed after backup was saved")
                    } else if completed {
                        status = NSLocalizedString(
                            "backup.local.share.completed", value: "备份已保存，分享已完成。", comment: "Saved and shared backup")
                    } else {
                        status = NSLocalizedString(
                            "backup.local.share.cancelled", value: "备份已保存，已取消分享。", comment: "Sharing cancelled after backup was saved")
                    }
                    self.presentSimpleAlert(
                        title: NSLocalizedString("backup.local.saved.title", value: "备份已保存", comment: "Backup saved title"),
                        message: ([status] + warnings).joined(separator: "\n"), id: id)
                }
            }
        }
        controller.popoverPresentationController?.sourceView = owner.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
        present(controller, id: id)
    }

    func showRestoreFilePicker() { chooseDestination(restoring: true) }

    func restoreFile(_ url: URL) {
        guard !isProcessing, !restoration.isProcessing else { return }
        restoration.restoreFile(url)
    }

    private func begin(phase: Phase) -> UUID? {
        guard !isProcessing, !restoration.isProcessing, let owner, owner.canPerformNavigationAction,
            let window = owner.viewIfLoaded?.window, let scene = window.windowScene,
            let root = window.rootViewController, let navigation = owner.navigationController,
            AppLockManager.shared.isUnlocked(in: window)
        else { return nil }
        let id = UUID()
        requestID = id
        self.phase = phase
        self.window = window
        self.scene = scene
        self.root = root
        self.navigation = navigation
        navigationTop = navigation.topViewController
        deliveryInvalidated = false
        for name in [UIScene.willDeactivateNotification, UIScene.didDisconnectNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidatePresentation), name: name, object: scene)
        }
        for name in [UIWindow.didResignKeyNotification, .appLockWillCover] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidatePresentation), name: name, object: window)
        }
        let probe = AttachmentProbe(frame: .zero)
        probe.isHidden = true
        probe.isUserInteractionEnabled = false
        probe.onWindowChanged = { [weak self] in
            guard let self, self.requestID == id, !self.isAttached else { return }
            self.invalidate(id)
        }
        attachmentProbe = probe
        owner.view.addSubview(probe)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.requestID == id else { return }
                if !self.isAttached {
                    self.invalidate(id)
                    return
                }
                if self.phase == .choosing || self.phase == .password || self.phase == .result,
                    let presentation = self.presentation, presentation.presentingViewController == nil,
                    !presentation.isBeingPresented, !presentation.isBeingDismissed
                {
                    self.finish(id)
                    return
                }
            }
        }
        return id
    }

    private var isAttached: Bool {
        guard let owner, let window, let scene, let root, let navigation, let navigationTop,
            owner.viewIfLoaded?.window === window, owner.navigationController === navigation,
            window.windowScene === scene, window.rootViewController === root,
            navigation.topViewController === navigationTop, owner.isVisibleInNavigationStack,
            !owner.isBeingDismissed, !owner.isMovingFromParent, !navigation.isBeingDismissed, !root.isBeingDismissed,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            window.isKeyWindow, !window.isHidden, window.alpha > 0, window.isUserInteractionEnabled,
            !window.accessibilityElementsHidden, AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        var candidate: UIViewController? = owner
        while let controller = candidate {
            guard controller.viewIfLoaded?.window === window, controller.viewIfLoaded?.isHidden == false,
                (controller.viewIfLoaded?.alpha ?? 0) > 0,
                !controller.isBeingDismissed, !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if controller === navigation { return true }
            candidate = controller.parent
        }
        return false
    }

    private func current(_ id: UUID) -> Bool {
        guard requestID == id, !deliveryInvalidated else { return false }
        guard isAttached else {
            invalidate(id)
            return false
        }
        return true
    }

    private func ready(_ id: UUID) -> Bool {
        current(id) && owner?.canPerformNavigationAction == true
    }

    private func present(_ controller: UIViewController, id: UUID) {
        guard ready(id), let owner else {
            invalidate(id)
            return
        }
        presentation = controller
        owner.present(controller, animated: true) { [weak self, weak controller] in
            guard let self, self.requestID == id else { return }
            if !self.current(id) || controller?.presentingViewController == nil { self.invalidate(id) }
        }
    }

    private func afterDismissal(
        of controller: UIViewController, id: UUID, from expected: Phase, action: @escaping @MainActor () -> Void
    ) {
        clearPassword(controller as? UIAlertController)
        guard current(id), phase == expected, presentation === controller else { return }
        phase = .transitioning
        Task { [self] in
            await dismiss(controller)
            guard ready(id) else {
                finish(id)
                return
            }
            action()
        }
    }

    @objc private func invalidatePresentation() {
        if let id = requestID { invalidate(id) }
    }

    private func invalidate(_ id: UUID) {
        guard requestID == id, !deliveryInvalidated else { return }
        deliveryInvalidated = true
        pendingPassword = nil
        clearPassword(presentation as? UIAlertController)
        monitor?.cancel()
        let controller = presentation
        Task { [self] in
            if let controller { await dismiss(controller) }
            if !workInFlight { finish(id) }
        }
    }

    private func finish(_ id: UUID) {
        guard requestID == id, !workInFlight else { return }
        pendingPassword = nil
        clearPassword(presentation as? UIAlertController)
        attachmentProbe?.onWindowChanged = nil
        attachmentProbe?.removeFromSuperview()
        attachmentProbe = nil
        monitor?.cancel()
        monitor = nil
        NotificationCenter.default.removeObserver(self)
        presentation = nil
        requestID = nil
        phase = .idle
        window = nil
        scene = nil
        root = nil
        navigation = nil
        navigationTop = nil
    }

    private func clearPassword(_ alert: UIAlertController?) {
        for field in alert?.textFields ?? [] { field.text = nil }
    }

    private func dismiss(_ controller: UIViewController) async {
        // Action callbacks may precede UIKit's automatic dismissal. Wait without spinning or observing cancellation.
        while controller.isBeingPresented || controller.isBeingDismissed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
        if let presenter = controller.presentingViewController, presenter.presentedViewController === controller {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                controller.dismiss(animated: scene?.activationState == .foregroundActive) { continuation.resume() }
            }
        }
        if presentation === controller { presentation = nil }
    }

    private static func localizedExportError(_ error: Error) -> NSError {
        let source = error as NSError
        return NSError(
            domain: source.domain, code: source.code,
            userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString(
                    "backup.local.export.failed", value: "备份未保存。请检查备份数据、可用空间和备份路径后重试。",
                    comment: "Local backup export or save failure without sensitive details")
            ])
    }
}
