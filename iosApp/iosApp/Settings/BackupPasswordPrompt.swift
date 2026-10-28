import UIKit

@MainActor
enum BackupPasswordPrompt {
    static func present(
        from owner: UIViewController, creating: Bool, fileName: String? = nil,
        onConfirm: @escaping (String) -> Void
    ) {
        guard owner.canPerformNavigationAction else { return }
        let message = creating ? "备份密码用于保护服务器和 WebDAV 凭据，请保管密码。" : "将合并恢复所选备份，覆盖同身份的数据。\n\(fileName ?? "")"
        let prompt = UIAlertController(title: creating ? "备份密码" : "恢复云端备份", message: message, preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = creating ? "backup.cloud.password" : "backup.cloud.restore.confirm"
        for index in 0..<(creating ? 2 : 1) {
            prompt.addTextField {
                $0.placeholder = index == 0 ? (creating ? "备份密码" : "备份密码（未设置可留空）") : "再次输入密码"
                $0.isSecureTextEntry = true
                $0.autocorrectionType = .no
                $0.textContentType = creating ? .newPassword : .password
                $0.accessibilityIdentifier = "backup.cloud.password.\(index)"
            }
        }
        let clear = { [weak prompt] in for field in prompt?.textFields ?? [] { field.text = nil } }
        prompt.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { _ in clear() })
        let action = UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak owner, weak prompt] _ in
            guard let owner, let prompt else { return }
            let password = prompt.textFields?.first?.text ?? ""
            guard
                !creating
                    || (!password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && password == prompt.textFields?.last?.text)
            else { return }
            clear()
            let completion = { [weak owner] in
                DispatchQueue.main.async {
                    guard owner?.canPerformNavigationAction == true else { return }
                    onConfirm(password)
                }
            }
            if prompt.isBeingDismissed, let transition = prompt.transitionCoordinator {
                if !transition.animate(alongsideTransition: nil, completion: { _ in completion() }) { completion() }
            } else {
                prompt.dismiss(animated: true, completion: completion)
            }
        }
        action.isEnabled = !creating
        prompt.addAction(action)
        for field in prompt.textFields ?? [] {
            field.addAction(
                UIAction { [weak prompt, weak action] _ in
                    let password = prompt?.textFields?.first?.text ?? ""
                    action?.isEnabled =
                        !creating
                        || (!password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && password == prompt?.textFields?.last?.text)
                }, for: .editingChanged)
        }
        owner.present(prompt, animated: true)
    }
}
