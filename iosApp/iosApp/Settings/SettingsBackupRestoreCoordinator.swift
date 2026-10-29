import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class SettingsBackupRestoreCoordinator: NSObject, UIDocumentPickerDelegate {
    private typealias PreparedBackupFile = SettingsBackupFilePreparation.PreparedBackupFile
    private enum Phase { case idle, choosing, reading, confirming, converting, restoring }
    private weak var owner: UIViewController?
    private weak var window: UIWindow?
    private weak var picker: UIDocumentPickerViewController?
    private weak var presentation: UIViewController?
    private let screen: SettingsScreenAdapter
    private let onError: (Error) -> Void
    private let onRestored: () -> Void
    private var phase = Phase.idle
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    var isProcessing: Bool { phase != .idle }

    init(
        owner: UIViewController?, screen: SettingsScreenAdapter,
        onError: @escaping (Error) -> Void, onRestored: @escaping () -> Void
    ) {
        self.owner = owner
        self.screen = screen
        self.onError = onError
        self.onRestored = onRestored
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(resignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit {
        task?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func showFilePicker() {
        guard begin() else { return }
        phase = .choosing
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .zip])
        controller.delegate = self
        controller.allowsMultipleSelection = false
        picker = controller
        presentation = controller
        owner?.present(controller, animated: true)
    }

    func restoreFile(_ url: URL) {
        guard begin(), let id = requestID else { return }
        readFile(url, id: id)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard picker === controller, phase == .choosing, let id = requestID, let url = urls.first else { return }
        picker = nil
        // The delegate can arrive while the picker is still presented. Starting
        // through canPerformNavigationAction at that point silently drops the file.
        task = Task { [weak self] in
            guard let self else { return }
            await dismiss(controller)
            guard current(id), owner?.canPerformNavigationAction == true else { reset(id); return }
            task = nil
            readFile(url, id: id)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard picker === controller, let id = requestID else { return }
        picker = nil
        Task { [weak self] in
            guard let self else { return }
            await dismiss(controller)
            reset(id)
        }
    }

    private func begin() -> Bool {
        guard !isProcessing, owner?.canPerformNavigationAction == true else { return false }
        requestID = UUID()
        window = owner?.viewIfLoaded?.window
        cancellationRequested = false
        return true
    }

    private func readFile(_ url: URL, id: UUID) {
        phase = .reading
        let hud = progress(title: "正在读取备份…", id: id)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await SettingsBackupFilePreparation.prepare(url: url)
                try Task.checkCancellation()
                await dismiss(hud)
                guard current(id), owner?.canPerformNavigationAction == true else { reset(id); return }
                task = nil
                phase = .confirming
                confirm(file, id: id)
            } catch {
                await finish(error: error, id: id, hud: hud, mayHaveCommitted: false)
            }
        }
    }

    private func confirm(_ file: PreparedBackupFile, id: UUID) {
        let alert = UIAlertController(
            title: L10n.Settings.restoreConfirmTitle, message: L10n.Settings.restoreConfirmMessage, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "settings.backup.restore.confirm"
        if file.needsPassword {
            alert.addTextField { field in
                field.placeholder = file.isZip ? "Android 备份密码（未设置可留空）" : "备份密码"
                field.isSecureTextEntry = true
                field.autocorrectionType = .no
                field.textContentType = .password
                field.accessibilityIdentifier = "settings.backup.restore.password"
            }
        }
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                self?.clearPassword(alert)
                self?.reset(id)
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, self.current(id) else { return }
                let password = alert.textFields?.first?.text ?? ""
                self.clearPassword(alert)
                self.task = Task { [weak self] in
                    guard let self else { return }
                    await dismiss(alert)
                    guard current(id), owner?.canPerformNavigationAction == true else { reset(id); return }
                    task = nil
                    restore(file, password: password, id: id)
                }
            })
        presentation = alert
        owner?.present(alert, animated: true)
    }

    private func restore(_ file: PreparedBackupFile, password: String, id: UUID) {
        phase = .converting
        let hud = progress(title: L10n.Settings.restoreProcessing, id: id)
        task = Task { [weak self] in
            guard let self else { return }
            var mayHaveCommitted = false
            do {
                let payload: String
                let warnings: [String]
                if file.isZip {
                    let converted = try await SettingsBackupPreparationClient.prepare(data: file.data, password: password)
                    payload = converted.payload
                    warnings = converted.warnings
                } else {
                    guard let json = file.jsonPayload else {
                        throw NSError(
                            domain: "io.legado.backup", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "备份文件不是 UTF-8 JSON"])
                    }
                    payload = json
                    warnings = []
                }
                try Task.checkCancellation()
                guard current(id) else { throw CancellationError() }
                phase = .restoring
                mayHaveCommitted = true
                let result = try await screen.restoreFromBackup(payload: payload, password: password)
                onRestored()
                await dismiss(hud)
                guard current(id), owner?.canPerformNavigationAction == true else { reset(id); return }
                reset(id)
                let done = UIAlertController(
                    title: warnings.isEmpty ? L10n.Settings.restoreSuccess : "恢复完成，请查看说明",
                    message: Self.summary(result, warnings: warnings), preferredStyle: .alert)
                done.view.accessibilityIdentifier = "settings.backup.restore.completed"
                done.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                owner?.present(done, animated: true)
            } catch {
                await finish(error: error, id: id, hud: hud, mayHaveCommitted: mayHaveCommitted)
            }
        }
    }

    private func progress(title: String, id: UUID) -> UIAlertController {
        let hud = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        hud.view.accessibilityIdentifier = "settings.backup.restore.processing"
        hud.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in
                guard let self, self.requestID == id else { return }
                self.cancellationRequested = true
                self.task?.cancel()
            })
        presentation = hud
        owner?.present(hud, animated: true)
        return hud
    }

    private func finish(error: Error, id: UUID, hud: UIAlertController, mayHaveCommitted: Bool) async {
        if mayHaveCommitted { onRestored() }
        await dismiss(hud)
        guard requestID == id else { return }
        let canPresent = isAttached && owner?.canPerformNavigationAction == true
        reset(id)
        guard canPresent else { return }
        if error is CancellationError {
            let alert = UIAlertController(
                title: mayHaveCommitted ? "恢复请求已停止" : "备份准备已停止",
                message: mayHaveCommitted ? "提交阶段可能已经完成，请核对当前书架和设置。" : "未恢复任何数据。",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            owner?.present(alert, animated: true)
        } else {
            onError(error)
        }
    }

    private func current(_ id: UUID) -> Bool {
        requestID == id && !cancellationRequested && !Task.isCancelled && isAttached
    }

    private var isAttached: Bool {
        guard let owner, let window, owner.viewIfLoaded?.window === window,
            !owner.isBeingDismissed, !owner.isMovingFromParent, owner.isVisibleInNavigationStack,
            window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active, AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    private func reset(_ id: UUID) {
        guard requestID == id else { return }
        requestID = nil
        phase = .idle
        task = nil
        presentation = nil
        picker = nil
        window = nil
        cancellationRequested = false
    }

    @objc private func resignActive() {
        guard isProcessing else { return }
        cancellationRequested = true
        task?.cancel()
        if phase == .confirming || phase == .choosing, let id = requestID {
            let controller = presentation
            clearPassword(controller as? UIAlertController)
            Task { [weak self] in
                guard let self else { return }
                if let controller { await dismiss(controller) }
                reset(id)
            }
        }
    }

    private func clearPassword(_ alert: UIAlertController?) {
        for field in alert?.textFields ?? [] { field.text = nil }
    }

    private func dismiss(_ controller: UIViewController) async {
        guard controller.presentingViewController != nil || controller.isBeingDismissed else { return }
        await withCheckedContinuation { continuation in
            if controller.isBeingDismissed, let transition = controller.transitionCoordinator,
                transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() })
            {
                return
            }
            if controller.isBeingDismissed {
                DispatchQueue.main.async { continuation.resume() }
            } else {
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
        if presentation === controller { presentation = nil }
    }

    private static func summary(_ result: BackupRestoreResult, warnings: [String]) -> String {
        let counts: [(String, Int32)] = [
            ("书架", result.bookCount), ("书源", result.bookSourceCount), ("RSS 源", result.rssSourceCount),
            ("替换规则", result.replaceRuleCount), ("书籍分组", result.bookGroupCount), ("书签", result.bookmarkCount),
            ("TXT 目录规则", result.txtTocRuleCount), ("词典规则", result.dictRuleCount), ("搜索历史", result.searchHistoryCount),
            ("阅读记录", result.readRecordCount), ("RSS 收藏", result.rssStarCount), ("源订阅", result.sourceSubCount),
            ("HTTP 朗读配置", result.httpTTSCount), ("键盘辅助", result.keyboardAssistCount), ("服务器配置", result.serverCount),
        ]
        var text =
            (result.preferencesRestored ? "支持的设置已按恢复忽略项应用\n" : "")
            + counts.map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        if !warnings.isEmpty { text += "\n\n" + warnings.joined(separator: "\n") }
        return text
    }
}
