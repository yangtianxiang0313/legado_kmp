import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class SettingsBackupRestoreCoordinator: NSObject, UIDocumentPickerDelegate {
    private typealias PreparedBackupFile = SettingsBackupFilePreparation.PreparedBackupFile
    private enum Phase { case idle, choosing, reading, confirming, converting, restoring }
    private weak var owner: UIViewController?
    private weak var window: UIWindow?
    private weak var root: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var navigationTop: UIViewController?
    private weak var picker: UIDocumentPickerViewController?
    private weak var presentation: UIViewController?
    private let screen: SettingsScreenAdapter
    private let onError: (Error) -> Void
    private let onRestored: () -> Void
    private var phase = Phase.idle
    private var requestID: UUID?
    private var task: Task<Void, Never>?
    private var cancellationRequested = false
    private var deliveryInvalidated = false

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
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
            .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidateDelivery(_:)), name: name, object: nil)
        }
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
        guard picker === controller, phase == .choosing, let id = requestID else { return }
        guard let url = urls.first else {
            documentPickerWasCancelled(controller)
            return
        }
        picker = nil
        // The delegate can arrive while the picker is still presented. Starting
        // through canPerformNavigationAction at that point silently drops the file.
        task = Task { [weak self] in
            guard let self else { return }
            await dismiss(controller)
            guard current(id), owner?.canPerformNavigationAction == true else {
                reset(id)
                return
            }
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
        guard !isProcessing, let owner, owner.canPerformNavigationAction,
            let window = owner.viewIfLoaded?.window, AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        requestID = UUID()
        self.window = window
        root = window.rootViewController
        navigation = owner.navigationController
        navigationTop = owner.navigationController?.topViewController
        cancellationRequested = false
        deliveryInvalidated = false
        return true
    }

    private func readFile(_ url: URL, id: UUID) {
        phase = .reading
        let hud = progress(title: Self.text("backup.restore.reading", "正在读取备份…"), id: id)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let file = try await SettingsBackupFilePreparation.prepare(url: url)
                try Task.checkCancellation()
                await dismiss(hud)
                guard current(id), owner?.canPerformNavigationAction == true else {
                    reset(id)
                    return
                }
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
                field.placeholder =
                    file.isZip
                    ? Self.text("backup.restore.android_password", "Android 备份密码（未设置可留空）")
                    : Self.text("backup.restore.password", "备份密码")
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
                guard let self, let alert, self.current(id), self.isCurrentPresentation(alert) else { return }
                let password = alert.textFields?.first?.text ?? ""
                self.clearPassword(alert)
                self.task = Task { [weak self] in
                    guard let self else { return }
                    await dismiss(alert)
                    guard current(id), owner?.canPerformNavigationAction == true else {
                        reset(id)
                        return
                    }
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
                    warnings = SettingsBackupPreparationClient.localizedWarnings(converted.warnings)
                } else {
                    guard let json = file.jsonPayload else {
                        throw NSError(
                            domain: "io.legado.backup", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: Self.text("backup.file.invalid_utf8", "备份文件不是 UTF-8 JSON")])
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
                // A successful terminal result proves the commit, even if Cancel arrived during it.
                guard canPresentResult(id) else {
                    reset(id)
                    return
                }
                reset(id)
                let done = UIAlertController(
                    title: warnings.isEmpty ? L10n.Settings.restoreSuccess : Self.text("backup.restore.completed_with_notes", "恢复完成，请查看说明"),
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
        let canPresent = canPresentResult(id)
        reset(id)
        guard canPresent else { return }
        if error is CancellationError {
            let alert = UIAlertController(
                title: mayHaveCommitted
                    ? Self.text("backup.restore.request_stopped", "恢复请求已停止")
                    : Self.text("backup.restore.preparation_stopped", "备份准备已停止"),
                message: mayHaveCommitted
                    ? Self.text("backup.restore.commit_uncertain", "提交阶段可能已经完成，请核对当前书架和设置。")
                    : Self.text("backup.restore.nothing_restored", "未恢复任何数据。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            owner?.present(alert, animated: true)
        } else {
            onError(error)
        }
    }

    private func current(_ id: UUID) -> Bool {
        requestID == id && !cancellationRequested && !deliveryInvalidated && !Task.isCancelled && isAttached
    }

    private func canPresentResult(_ id: UUID) -> Bool {
        requestID == id && !deliveryInvalidated && isAttached && owner?.canPerformNavigationAction == true
    }

    private func isCurrentPresentation(_ controller: UIViewController) -> Bool {
        presentation === controller && controller.viewIfLoaded?.window === window
            && controller.presentingViewController != nil && controller.presentedViewController == nil
            && !controller.isBeingPresented && !controller.isBeingDismissed
    }

    private var isAttached: Bool {
        guard let owner, let window, let root, let navigation, let navigationTop,
            window.rootViewController === root, owner.navigationController === navigation,
            navigation.topViewController === navigationTop, navigation.viewIfLoaded?.window === window,
            owner.viewIfLoaded?.window === window,
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
        deliveryInvalidated = false
        root = nil
        navigation = nil
        navigationTop = nil
    }

    @objc private func invalidateDelivery(_ notification: Notification) {
        guard isProcessing, let window else { return }
        switch notification.name {
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification:
            guard notification.object as? UIScene === window.windowScene else { return }
        case UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover:
            guard notification.object as? UIWindow === window else { return }
        default: break
        }
        deliveryInvalidated = true
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
        // A cancelled Task must still wait for UIKit to finish the owned dismissal.
        while controller.isBeingPresented || controller.isBeingDismissed {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
        if controller.presentingViewController != nil {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
        if presentation === controller { presentation = nil }
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "Local backup restoration")
    }

    private static func summary(_ result: BackupRestoreResult, warnings: [String]) -> String {
        let counts: [(String, Int32)] = [
            (text("backup.restore.bookshelf", "书架"), result.bookCount),
            (text("backup.restore.book_sources", "书源"), result.bookSourceCount),
            (text("backup.restore.rss_sources", "RSS 源"), result.rssSourceCount),
            (text("backup.restore.replace_rules", "替换规则"), result.replaceRuleCount),
            (text("backup.restore.book_groups", "书籍分组"), result.bookGroupCount),
            (text("backup.restore.bookmarks", "书签"), result.bookmarkCount),
            (text("backup.restore.txt_toc_rules", "TXT 目录规则"), result.txtTocRuleCount),
            (text("backup.restore.dictionary_rules", "词典规则"), result.dictRuleCount),
            (text("backup.restore.search_history", "搜索历史"), result.searchHistoryCount),
            (text("backup.restore.read_records", "阅读记录"), result.readRecordCount),
            (text("backup.restore.rss_favorites", "RSS 收藏"), result.rssStarCount),
            (text("backup.restore.source_subscriptions", "源订阅"), result.sourceSubCount),
            (text("backup.restore.http_tts", "HTTP 朗读配置"), result.httpTTSCount),
            (text("backup.restore.keyboard_assists", "键盘辅助"), result.keyboardAssistCount),
            (text("backup.restore.servers", "服务器配置"), result.serverCount),
        ]
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        var sections: [String] = []
        if result.preferencesRestored {
            sections.append(text("backup.restore.preferences_applied", "支持的设置已按恢复忽略项应用"))
        }
        let format = text("backup.restore.count_row", "%@：%@")
        sections.append(
            counts.map { label, count in
                String(format: format, label, formatter.string(from: NSNumber(value: count)) ?? String(count))
            }.joined(separator: "\n"))
        if !warnings.isEmpty { sections.append(warnings.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }
}
