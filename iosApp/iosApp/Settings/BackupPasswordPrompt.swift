import UIKit

@MainActor
enum BackupPasswordPrompt {
    @discardableResult
    static func present(
        from owner: UIViewController, creating: Bool, fileName: String? = nil,
        onCancel: (() -> Void)? = nil,
        onConfirm: @escaping (String) -> Void
    ) -> Handle? {
        guard owner.canPerformNavigationAction,
            let window = owner.viewIfLoaded?.window, let scene = window.windowScene,
            let root = window.rootViewController, let navigation = owner.navigationController,
            let top = navigation.topViewController, AppLockManager.shared.isUnlocked(in: window)
        else { return nil }
        let handle = Handle(
            owner: owner, window: window, scene: scene, root: root, navigation: navigation, top: top,
            onCancel: onCancel, onConfirm: onConfirm)
        handle.present(creating: creating, fileName: fileName)
        return handle
    }

    @MainActor
    final class Handle: NSObject {
        private enum Phase { case prompting, dismissing, finished }
        private final class AttachmentProbe: UIView {
            var onWindowChanged: (() -> Void)?
            private var wasAttached = false
            override func didMoveToWindow() {
                super.didMoveToWindow()
                if window != nil { wasAttached = true }
                if wasAttached { onWindowChanged?() }
            }
        }

        private weak var owner: UIViewController?
        private weak var window: UIWindow?
        private weak var scene: UIWindowScene?
        private weak var root: UIViewController?
        private weak var navigation: UINavigationController?
        private weak var top: UIViewController?
        private weak var presenter: UIViewController?
        private var presentation: UIAlertController?
        private var phase = Phase.prompting
        private var onConfirm: ((String) -> Void)?
        private var onCancel: (() -> Void)?
        private var pendingPassword: String?
        private var ownerProbe: AttachmentProbe?
        private var promptProbe: AttachmentProbe?
        private var monitor: Task<Void, Never>?

        var controller: UIAlertController? { presentation }
        var isConsuming: Bool { phase == .dismissing }

        fileprivate init(
            owner: UIViewController, window: UIWindow, scene: UIWindowScene, root: UIViewController,
            navigation: UINavigationController, top: UIViewController,
            onCancel: (() -> Void)?, onConfirm: @escaping (String) -> Void
        ) {
            self.owner = owner
            self.window = window
            self.scene = scene
            self.root = root
            self.navigation = navigation
            self.top = top
            self.onConfirm = onConfirm
            self.onCancel = onCancel
        }

        deinit {
            monitor?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func cancel() {
            guard phase != .finished else { return }
            let prompt = presentation
            let completion = onCancel
            finish()
            completion?()
            if let prompt { Task { await Self.dismiss(prompt) } }
        }

        fileprivate func present(creating: Bool, fileName: String?) {
            guard let owner, isAttached(), owner.canPerformNavigationAction else {
                cancel()
                return
            }
            let passwordTitle = NSLocalizedString(
                "backup.local.password.title", value: "备份密码", comment: "Backup password title")
            let message =
                creating
                ? NSLocalizedString(
                    "backup.local.password.message", value: "用于保护服务器和 WebDAV 凭据。请保管密码，以便在其它设备恢复。",
                    comment: "Backup password purpose")
                : String(
                    format: NSLocalizedString(
                        "backup.cloud.restore.password_message", value: "将合并恢复所选备份，覆盖同身份的数据。\n%@",
                        comment: "Cloud restore confirmation with backup filename"), fileName ?? "")
            let prompt = UIAlertController(
                title: creating
                    ? passwordTitle
                    : NSLocalizedString(
                        "backup.cloud.restore.title", value: "恢复云端备份", comment: "Cloud restore title"),
                message: message, preferredStyle: .alert)
            presentation = prompt
            prompt.view.accessibilityIdentifier = creating ? "backup.cloud.password" : "backup.cloud.restore.confirm"
            for index in 0..<(creating ? 2 : 1) {
                prompt.addTextField {
                    $0.placeholder =
                        index == 0
                        ? (creating
                            ? passwordTitle
                            : NSLocalizedString(
                                "backup.cloud.password.optional", value: "备份密码（未设置可留空）", comment: "Optional restore password"))
                        : NSLocalizedString("backup.local.password.repeat", value: "再次输入密码", comment: "Repeat backup password")
                    $0.isSecureTextEntry = true
                    $0.autocorrectionType = .no
                    $0.autocapitalizationType = .none
                    $0.textContentType = creating ? .newPassword : .password
                    $0.accessibilityIdentifier = "backup.cloud.password.\(index)"
                }
            }
            // The owned alert retains its handle until consumption or invalidation breaks the cycle.
            prompt.addAction(
                UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [self] _ in
                    guard phase == .prompting else { return }
                    cancel()
                })
            let action = UIAlertAction(title: L10n.Common.confirm, style: .default) { [self, weak prompt] _ in
                guard let prompt else {
                    cancel()
                    return
                }
                guard phase == .prompting, presentation === prompt else { return }
                let password = prompt.textFields?.first?.text ?? ""
                let repeated = prompt.textFields?.last?.text
                clearFields(prompt)
                guard phase == .prompting, presentation === prompt,
                    isAttached(), owns(prompt, allowingDismissal: true),
                    !creating || (!password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password == repeated)
                else {
                    cancel()
                    return
                }
                phase = .dismissing
                pendingPassword = password
                Task { [self] in
                    await Self.dismiss(prompt)
                    guard phase == .dismissing, presentation === prompt,
                        isAttached(), self.owner?.canPerformNavigationAction == true,
                        prompt.presentingViewController == nil,
                        let password = pendingPassword, let completion = onConfirm
                    else {
                        cancel()
                        return
                    }
                    finish()
                    completion(password)
                }
            }
            action.isEnabled = !creating
            prompt.addAction(action)
            for field in prompt.textFields ?? [] {
                field.addAction(
                    UIAction { [weak self, weak prompt, weak action] _ in
                        guard let self, let prompt, self.phase == .prompting,
                            self.isAttached(), self.owns(prompt, allowingDismissal: false)
                        else {
                            for field in prompt?.textFields ?? [] { field.text = nil }
                            self?.cancel()
                            action?.isEnabled = false
                            return
                        }
                        let password = prompt.textFields?.first?.text ?? ""
                        action?.isEnabled =
                            !creating
                            || (!password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && password == prompt.textFields?.last?.text)
                    }, for: .editingChanged)
            }
            observeOwnership()
            let probe = AttachmentProbe(frame: .zero)
            probe.isHidden = true
            probe.isUserInteractionEnabled = false
            probe.onWindowChanged = { [weak self] in
                guard let self, self.phase != .finished, !self.isAttached() else { return }
                self.cancel()
            }
            ownerProbe = probe
            owner.view.addSubview(probe)
            let alertProbe = AttachmentProbe(frame: .zero)
            alertProbe.isHidden = true
            alertProbe.isUserInteractionEnabled = false
            alertProbe.onWindowChanged = { [weak self, weak prompt] in
                guard let self, let prompt, self.phase == .prompting,
                    prompt.viewIfLoaded?.window !== self.window
                else { return }
                self.cancel()
            }
            promptProbe = alertProbe
            prompt.view.addSubview(alertProbe)
            owner.present(prompt, animated: true) { [weak self, weak prompt] in
                guard let self, self.phase == .prompting, let prompt else { return }
                self.presenter = prompt.presentingViewController
                if !self.isAttached() || !self.owns(prompt, allowingDismissal: false) { self.cancel() }
            }
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard let self, self.phase != .finished else { return }
                    guard self.isAttached(), let prompt = self.presentation else {
                        self.cancel()
                        return
                    }
                    if self.phase == .prompting, !prompt.isBeingPresented,
                        !self.owns(prompt, allowingDismissal: false)
                    {
                        self.cancel()
                        return
                    }
                }
            }
        }

        private func observeOwnership() {
            guard let scene, let window else { return }
            for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: name, object: scene)
            }
            for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover] {
                NotificationCenter.default.addObserver(self, selector: #selector(invalidate), name: name, object: window)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(lockChanged), name: .appLockStatusDidChange, object: AppLockManager.shared)
        }

        @objc private func invalidate() { cancel() }

        @objc private func lockChanged() {
            if !AppLockManager.shared.isUnlocked(in: window) { cancel() }
        }

        private func isAttached() -> Bool {
            guard phase != .finished, let owner, let window, let scene, let root, let navigation, let top,
                owner.viewIfLoaded?.window === window, owner.navigationController === navigation,
                window.windowScene === scene, window.rootViewController === root, navigation.topViewController === top,
                owner.isVisibleInNavigationStack, UIApplication.shared.applicationState == .active,
                scene.activationState == .foregroundActive, window.isKeyWindow, !window.isHidden, window.alpha > 0,
                window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
                AppLockManager.shared.isUnlocked(in: window), !root.isBeingDismissed, !root.isMovingFromParent,
                presentation?.presentedViewController == nil
            else { return false }
            var candidate: UIViewController? = owner
            while let controller = candidate {
                guard controller.viewIfLoaded?.window === window, controller.viewIfLoaded?.isHidden == false,
                    (controller.viewIfLoaded?.alpha ?? 0) > 0, !controller.isBeingDismissed, !controller.isBeingPresented,
                    !controller.isMovingFromParent, !controller.isMovingToParent,
                    controller.presentedViewController == nil || controller.presentedViewController === presentation
                else { return false }
                if let transition = controller.transitionCoordinator,
                    transition.viewController(forKey: .from) !== presentation,
                    transition.viewController(forKey: .to) !== presentation
                {
                    return false
                }
                candidate = controller.parent
            }
            return true
        }

        private func owns(_ prompt: UIAlertController, allowingDismissal: Bool) -> Bool {
            guard presentation === prompt, let presenter, prompt.presentingViewController === presenter,
                presenter.presentedViewController === prompt, prompt.viewIfLoaded?.window === window,
                prompt.presentedViewController == nil, !prompt.isBeingPresented,
                allowingDismissal || !prompt.isBeingDismissed
            else { return false }
            return true
        }

        private func clearFields(_ prompt: UIAlertController? = nil) {
            for field in (prompt ?? presentation)?.textFields ?? [] { field.text = nil }
        }

        private func finish() {
            phase = .finished
            pendingPassword = nil
            clearFields()
            for field in presentation?.textFields ?? [] {
                field.isEnabled = false
                field.resignFirstResponder()
            }
            for action in presentation?.actions ?? [] { action.isEnabled = false }
            onConfirm = nil
            onCancel = nil
            monitor?.cancel()
            monitor = nil
            NotificationCenter.default.removeObserver(self)
            for probe in [ownerProbe, promptProbe] {
                probe?.onWindowChanged = nil
                probe?.removeFromSuperview()
            }
            ownerProbe = nil
            promptProbe = nil
            presentation = nil
            presenter = nil
        }

        private static func dismiss(_ prompt: UIAlertController) async {
            while prompt.isBeingPresented || prompt.isBeingDismissed {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
                }
            }
            if let presenter = prompt.presentingViewController, presenter.presentedViewController === prompt,
                prompt.presentedViewController == nil
            {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    prompt.dismiss(animated: prompt.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive) {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
