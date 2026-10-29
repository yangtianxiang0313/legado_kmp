import UIKit
import shared

/// Owns file access, export, and restore presentation independently of the settings table.
@MainActor
final class SettingsBackupCoordinator: NSObject {
    private weak var owner: UIViewController?
    private let screen: SettingsScreenAdapter
    private let onError: (Error) -> Void
    private let onRestored: () -> Void
    private var isProcessing = false
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

    private func present(_ controller: UIViewController, animated: Bool) {
        owner?.present(controller, animated: animated)
    }

    private func presentError(_ error: Error) { onError(error) }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
        present(alert, animated: true)
    }

    // MARK: - F59/F60 Backup & Restore

    func executeBackup() { chooseDestination(restoring: false) }

    private func chooseDestination(restoring: Bool) {
        guard !isProcessing, !restoration.isProcessing, let owner, owner.canPerformNavigationAction else { return }
        let sheet = UIAlertController(title: restoring ? "恢复备份" : "立即备份", message: nil, preferredStyle: .actionSheet)
        sheet.view.accessibilityIdentifier = "settings.backup.destination"
        sheet.addAction(
            UIAlertAction(title: restoring ? "从本地文件恢复" : "备份到本地", style: .default) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                self.afterDismissal(of: sheet) {
                    if restoring { self.presentRestoreFilePicker() } else { self.executeLocalBackup() }
                }
            })
        sheet.addAction(
            UIAlertAction(title: restoring ? "从 WebDAV 恢复" : "备份到 WebDAV", style: .default) { [weak self, weak sheet] _ in
                guard let self, let sheet else { return }
                self.afterDismissal(of: sheet) {
                    guard let owner = self.owner, owner.canPerformNavigationAction else { return }
                    let page = CloudBackupViewController()
                    page.onRestored = self.onRestored
                    owner.navigationController?.pushViewController(page.configuredForDrillDownPresentation(), animated: true)
                }
            })
        sheet.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        sheet.popoverPresentationController?.sourceView = owner.view
        sheet.popoverPresentationController?.sourceRect = CGRect(
            x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    func checkWebDavConnection() {
        guard !isProcessing, !restoration.isProcessing, owner?.canPerformNavigationAction == true else { return }
        let hud = UIAlertController(title: L10n.Settings.webDavChecking, message: nil, preferredStyle: .alert)
        present(hud, animated: true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let connected = try await screen.checkWebDavConnection()
                let initialized = connected ? try await screen.initWebDavDirs() : false
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        self.presentSimpleAlert(
                            title: L10n.Settings.webDavTitle,
                            message: connected && initialized
                                ? L10n.Settings.webDavCheckSuccess
                                : L10n.Settings.webDavCheckFailed
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        self.presentError(error)
                    }
                }
            }
        }
    }

    private func executeLocalBackup() {
        guard !isProcessing, !restoration.isProcessing, owner?.canPerformNavigationAction == true else { return }
        let prompt = UIAlertController(
            title: "备份密码", message: "用于保护服务器和 WebDAV 凭据。请保管密码，以便在其它设备恢复。", preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "settings.backup.password"
        for (index, placeholder) in ["备份密码", "再次输入密码"].enumerated() {
            prompt.addTextField {
                $0.placeholder = placeholder
                $0.isSecureTextEntry = true
                $0.autocorrectionType = .no
                $0.textContentType = .newPassword
                $0.accessibilityIdentifier = "settings.backup.password.\(index)"
            }
        }
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak prompt] _ in
                for field in prompt?.textFields ?? [] { field.text = nil }
            })
        let confirm = UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak prompt] _ in
            guard let self, let prompt, let password = prompt.textFields?.first?.text,
                !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                password == prompt.textFields?.last?.text
            else { return }
            self.afterDismissal(of: prompt) { [weak self] in self?.performBackup(password: password) }
        }
        confirm.isEnabled = false
        prompt.addAction(confirm)
        for field in prompt.textFields ?? [] {
            field.addAction(
                UIAction { [weak prompt, weak confirm] _ in
                    let password = prompt?.textFields?.first?.text ?? ""
                    confirm?.isEnabled =
                        !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && password == prompt?.textFields?.last?.text
                }, for: .editingChanged)
        }
        present(prompt, animated: true)
    }

    private func performBackup(password: String) {
        guard !isProcessing, !restoration.isProcessing, owner?.canPerformNavigationAction == true else { return }
        isProcessing = true
        let hud = UIAlertController(title: L10n.Settings.backupProcessing, message: nil, preferredStyle: .alert)
        present(hud, animated: true)
        Task { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            do {
                let configuration = self.screen.latestRuntimeConfig
                let archive = try await self.screen.createAndroidBackupArchive(password: password)
                let fileURL = try await LocalBackupStore.shared.save(
                    base64: archive.base64Zip, onlyLatest: configuration?.onlyLatestBackup ?? true,
                    configuredPath: configuration?.backupPath)
                var warnings = archive.warnings
                do { try await CloudBackupScreenAdapter().markLocalBackupCreated() } catch {
                    warnings.append("备份已保存，但最近备份时间未记录。")
                }
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        guard self.owner?.canPerformNavigationAction == true else { return }
                        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
                        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
                            guard !warnings.isEmpty else { return }
                            DispatchQueue.main.async {
                                self?.presentSimpleAlert(title: "备份已保存", message: warnings.joined(separator: "\n"))
                            }
                        }
                        activityVC.popoverPresentationController?.sourceView = self.owner?.view
                        activityVC.popoverPresentationController?.sourceRect = self.owner?.view.bounds ?? .zero
                        self.present(activityVC, animated: true)
                    }
                }
            } catch {
                await MainActor.run {
                    hud.dismiss(animated: true) {
                        if self.owner?.canPerformNavigationAction == true { self.presentError(error) }
                    }
                }
            }
        }
    }

    func showRestoreFilePicker() {
        chooseDestination(restoring: true)
    }

    private func presentRestoreFilePicker() { restoration.showFilePicker() }

    func restoreFile(_ url: URL) {
        guard !isProcessing else { return }
        restoration.restoreFile(url)
    }

    private func afterDismissal(of prompt: UIAlertController, action: @escaping () -> Void) {
        for field in prompt.textFields ?? [] { field.text = nil }
        let completion = { [weak self] in
            DispatchQueue.main.async {
                guard self?.owner?.canPerformNavigationAction == true else { return }
                action()
            }
        }
        if prompt.isBeingDismissed, let transition = prompt.transitionCoordinator {
            if !transition.animate(alongsideTransition: nil, completion: { _ in completion() }) { completion() }
        } else {
            prompt.dismiss(animated: true, completion: completion)
        }
    }

}
