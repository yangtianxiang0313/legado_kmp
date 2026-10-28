import UIKit
import UniformTypeIdentifiers
import shared

/// Owns file access, export, and restore presentation independently of the settings table.
@MainActor
final class SettingsBackupCoordinator: NSObject, UIDocumentPickerDelegate {
    private weak var owner: UIViewController?
    private let screen: SettingsScreenAdapter
    private let onError: (Error) -> Void
    private let onRestored: () -> Void
    private var isProcessing = false
    private var restoreTask: Task<Void, Never>?

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
        guard !isProcessing, let owner, owner.canPerformNavigationAction else { return }
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
        guard !isProcessing, owner?.canPerformNavigationAction == true else { return }
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
        guard !isProcessing, owner?.canPerformNavigationAction == true else { return }
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

    private func presentRestoreFilePicker() {
        guard !isProcessing, owner?.canPerformNavigationAction == true else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .zip])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func handleRestoreFile(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard fileSize <= 128 * 1024 * 1024,
            let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= 128 * 1024 * 1024
        else {
            presentError(
                NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法读取备份文件，或文件超过 128 MB"]))
            return
        }
        let isZip = url.pathExtension.lowercased() == "zip" || data.starts(with: [0x50, 0x4b, 0x03, 0x04])
        let needsPassword: Bool
        do {
            if isZip {
                needsPassword = true
            } else {
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw NSError(
                        domain: "io.legado.backup", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "备份文件不是 UTF-8 JSON"])
                }
                needsPassword = try BackupCredentialCodec().requiresPassword(payload: payload)
            }
        } catch {
            presentError(error)
            return
        }
        let alert = UIAlertController(
            title: L10n.Settings.restoreConfirmTitle,
            message: L10n.Settings.restoreConfirmMessage,
            preferredStyle: .alert
        )
        alert.view.accessibilityIdentifier = "settings.backup.restore.confirm"
        if needsPassword {
            alert.addTextField { field in
                field.placeholder = isZip ? "Android 备份密码（未设置可留空）" : "备份密码"
                field.isSecureTextEntry = true
                field.autocorrectionType = .no
                field.textContentType = .password
                field.accessibilityIdentifier = "settings.backup.restore.password"
            }
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                let password = alert.textFields?.first?.text ?? ""
                self.afterDismissal(of: alert) { [weak self] in
                    self?.executeRestore(data: data, isZip: isZip, password: password)
                }
            })
        present(alert, animated: true)
    }

    func restoreFile(_ url: URL) {
        guard !isProcessing, owner?.canPerformNavigationAction == true else { return }
        handleRestoreFile(url: url)
    }

    private func executeRestore(data: Data, isZip: Bool, password: String) {
        guard !isProcessing, owner?.canPerformNavigationAction == true else { return }
        isProcessing = true
        let hud = UIAlertController(title: L10n.Settings.restoreProcessing, message: nil, preferredStyle: .alert)
        hud.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak hud] _ in
                self?.restoreTask?.cancel()
                hud?.message = "正在停止恢复…"
                hud?.actions.forEach { $0.isEnabled = false }
            })
        present(hud, animated: true)
        restoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isProcessing = false
                self.restoreTask = nil
            }
            do {
                let payload: String
                let warnings: [String]
                if isZip {
                    let converted = try await Task.detached(priority: .userInitiated) {
                        try AndroidBackupArchive().convert(base64Zip: data.base64EncodedString(), password: password)
                    }.value
                    payload = converted.payload
                    warnings = converted.warnings
                } else {
                    guard let json = String(data: data, encoding: .utf8) else {
                        throw NSError(
                            domain: "io.legado.kmp.ios", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "备份文件不是 UTF-8 JSON"])
                    }
                    payload = json
                    warnings = []
                }
                let result = try await self.screen.restoreFromBackup(payload: payload, password: password)
                let counts: [(String, Int32)] = [
                    ("书架", result.bookCount), ("书源", result.bookSourceCount),
                    ("RSS 源", result.rssSourceCount), ("替换规则", result.replaceRuleCount),
                    ("书籍分组", result.bookGroupCount), ("书签", result.bookmarkCount),
                    ("TXT 目录规则", result.txtTocRuleCount), ("词典规则", result.dictRuleCount),
                    ("搜索历史", result.searchHistoryCount), ("阅读记录", result.readRecordCount),
                    ("RSS 收藏", result.rssStarCount), ("源订阅", result.sourceSubCount),
                    ("HTTP 朗读配置", result.httpTTSCount), ("键盘辅助", result.keyboardAssistCount),
                    ("服务器配置", result.serverCount),
                ]
                var summary =
                    (result.preferencesRestored ? "支持的设置已按恢复忽略项应用\n" : "")
                    + counts.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
                if !warnings.isEmpty { summary += "\n\n" + warnings.joined(separator: "\n") }
                await MainActor.run {
                    self.onRestored()
                    hud.dismiss(animated: true) {
                        guard self.owner?.canPerformNavigationAction == true else { return }
                        let done = UIAlertController(
                            title: warnings.isEmpty ? L10n.Settings.restoreSuccess : "恢复完成，请查看说明", message: summary,
                            preferredStyle: .alert)
                        done.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                        self.present(done, animated: true)
                    }
                }
            } catch is CancellationError {
                self.onRestored()
                hud.dismiss(animated: true) {
                    guard self.owner?.canPerformNavigationAction == true else { return }
                    self.presentSimpleAlert(title: "恢复请求已停止", message: "提交阶段可能已经完成，请核对当前书架和设置。")
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

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        restoreFile(url)
    }
}
