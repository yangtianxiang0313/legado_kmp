import UIKit

@MainActor
final class AppLockViewController: UIViewController, UITextFieldDelegate {
    enum Mode { case loading, password, unavailable }

    var onSubmit: ((String) -> Void)?
    var onRetry: (() -> Void)?
    private let form = AppLockFormView()
    private var field: UITextField!
    private var mode: Mode = .loading
    private var processing = false

    override func loadView() { view = form }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "app-lock.authentication"
        form.heading.text = "应用已锁定"
        field = form.addPasswordField(title: "应用密码", identifier: "app-lock.password")
        field.delegate = self
        form.submit.addTarget(self, action: #selector(submit), for: .touchUpInside)
        updateMode()
    }

    func setMode(_ mode: Mode) {
        loadViewIfNeeded()
        if self.mode == mode { return }
        self.mode = mode
        form.showError(nil)
        updateMode()
    }

    func setProcessing(_ processing: Bool) {
        self.processing = processing
        loadViewIfNeeded()
        form.setProcessing(processing || mode == .loading)
    }

    func showError(_ error: Error) {
        loadViewIfNeeded()
        clearSensitiveInput()
        form.showError(error)
    }

    func clearSensitiveInput() {
        guard isViewLoaded else { return }
        form.clearSensitiveInput()
        form.showError(nil)
    }

    private func updateMode() {
        switch mode {
        case .loading:
            form.message.text = "正在读取安全凭据"
            form.submit.configuration?.title = "请稍候"
        case .password:
            form.message.text = "请输入应用密码以继续"
            form.submit.configuration?.title = "解锁"
        case .unavailable:
            form.message.text = "暂时无法读取应用锁凭据。请确认设备已解锁后重试；不会自动关闭应用锁。"
            form.submit.configuration?.title = "重试"
        }
        form.showFields(mode == .password)
        form.setProcessing(processing || mode == .loading)
    }

    @objc private func submit() {
        guard !processing, view.window?.isKeyWindow == true,
            view.window?.windowScene?.activationState == .foregroundActive
        else { return }
        if mode == .unavailable { onRetry?(); return }
        guard mode == .password else { return }
        let password = field.text ?? ""
        form.clearSensitiveInput()
        form.showError(nil)
        onSubmit?(password)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }
}
