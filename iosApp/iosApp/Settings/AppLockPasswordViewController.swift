import UIKit

@MainActor
final class AppLockPasswordViewController: UIViewController, UITextFieldDelegate {
    enum Mode { case enable, change, disable }

    private let mode: Mode
    private let form = AppLockFormView()
    private let manager = AppLockManager.shared
    private var current: UITextField?
    private var replacement: UITextField?
    private var confirmation: UITextField?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var visible = false
    private var previousPopEnabled: Bool?

    init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
        switch mode {
        case .enable: title = "设置应用密码"
        case .change: title = "修改应用密码"
        case .disable: title = "关闭应用锁"
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { task?.cancel() }

    override func loadView() { view = form }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "app-lock.password-management"
        form.heading.text = title
        if mode != .enable {
            current = form.addPasswordField(title: "当前密码", identifier: "app-lock.current-password")
        }
        if mode != .disable {
            replacement = form.addPasswordField(
                title: "新密码", identifier: "app-lock.new-password", newPassword: true)
            confirmation = form.addPasswordField(
                title: "再次输入新密码", identifier: "app-lock.confirm-password", newPassword: true)
        }
        switch mode {
        case .enable:
            form.message.text = "设置后，离开前台需重新解锁。此密码无法通过书籍备份找回。"
            form.submit.configuration?.title = "设置密码"
        case .change:
            form.message.text = "请输入当前密码和两次新密码"
            form.submit.configuration?.title = "保存新密码"
        case .disable:
            form.message.text = "输入当前应用密码，确认关闭应用锁"
            form.submit.configuration?.title = "确认关闭应用锁"
            form.submit.configuration?.baseBackgroundColor = .systemRed
        }
        for (index, field) in form.fields.enumerated() {
            field.delegate = self
            field.returnKeyType = index == form.fields.count - 1 ? .done : .next
        }
        form.submit.addTarget(self, action: #selector(save), for: .touchUpInside)
        NotificationCenter.default.addObserver(
            self, selector: #selector(willCover(_:)), name: .appLockWillCover, object: nil)
        // Clear inputs even if an embedding caller has not yet wired every SceneDelegate hook.
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        invalidateInput()
        super.viewWillDisappear(animated)
    }

    @objc private func willCover(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === viewIfLoaded?.window else { return }
        invalidateInput()
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene,
            scene === viewIfLoaded?.window?.windowScene
        else { return }
        invalidateInput()
    }

    private func invalidateInput() {
        requestID = UUID()
        task?.cancel()
        task = nil
        form.clearSensitiveInput()
        form.showError(nil)
        setProcessing(false)
    }

    private func setProcessing(_ processing: Bool) {
        form.setProcessing(processing)
        navigationItem.hidesBackButton = processing
        if processing, previousPopEnabled == nil {
            previousPopEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        } else if !processing, let previousPopEnabled {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = previousPopEnabled
            self.previousPopEnabled = nil
        }
    }

    @objc private func save() {
        guard visible, canPerformNavigationAction, task == nil, let window = view.window else { return }
        let oldPassword = current?.text ?? ""
        let newPassword = replacement?.text ?? ""
        let repeatedPassword = confirmation?.text ?? ""
        do {
            if mode != .disable {
                try AppLockCredentialCrypto.validateNewPassword(newPassword, confirmation: repeatedPassword)
            }
        } catch {
            form.showError(error)
            return
        }
        let id = UUID()
        requestID = id
        form.clearSensitiveInput()
        form.showError(nil)
        setProcessing(true)
        task = Task { [weak self, weak window] in
            guard let self, let window else { return }
            do {
                switch mode {
                case .enable:
                    try await manager.setPassword(newPassword, confirmation: repeatedPassword, in: window)
                case .change:
                    try await manager.changePassword(
                        oldPassword: oldPassword, newPassword: newPassword, confirmation: repeatedPassword, in: window)
                case .disable:
                    try await manager.disablePassword(oldPassword, in: window)
                }
                guard requestID == id, visible, window.isKeyWindow,
                    window.windowScene?.activationState == .foregroundActive
                else { return }
                task = nil
                setProcessing(false)
                navigationController?.popViewController(animated: true)
            } catch {
                guard requestID == id, visible else { return }
                task = nil
                setProcessing(false)
                if !(error is CancellationError) { form.showError(error) }
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let index = form.fields.firstIndex(where: { $0 === textField }), index + 1 < form.fields.count {
            form.fields[index + 1].becomeFirstResponder()
        } else {
            save()
        }
        return false
    }
}
