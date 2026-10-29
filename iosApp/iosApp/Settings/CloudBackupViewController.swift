import UIKit
import shared

@MainActor
final class CloudBackupViewController: UITableViewController {
    private enum RestorePhase { case idle, password, preparing, confirming, committing, finishing }
    private let screen = CloudBackupScreenAdapter()
    private var files: [CloudBackupFile] = []
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var visible = false
    private var loading = false
    private var processing = false
    private var failure: String?
    private var pendingMessage: String?
    private var initialRestore: CloudBackupFile?
    private var previousInteractivePop: Bool?
    private weak var processingNavigationController: UINavigationController?
    private var restorePhase = RestorePhase.idle
    private weak var restoreWindow: UIWindow?
    private weak var restoreScene: UIWindowScene?
    private weak var restorePresentation: UIAlertController?
    private var preparedRestore: PreparedCloudBackup?
    private var restoreInvalidated = false
    private var preparationCancelledByUser = false
    var onRestored: (() -> Void)?
    var onReturn: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if parent == nil, let callback = onReturn {
            onReturn = nil
            callback()
        }
    }

    init(initialRestore: CloudBackupFile? = nil) {
        self.initialRestore = initialRestore
        super.init(style: .plain)
        title = "云端备份"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        task?.cancel()
        preparedRestore?.discard()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.accessibilityIdentifier = "backup.cloud.list"
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reloadBackups), for: .valueChanged)
        refreshControl = refresh
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        for name in [UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification, .appLockStatusDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(becameActive), name: name, object: nil)
        }
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(restoreContextChanged(_:)), name: name, object: nil)
        }
        applyPalette()
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canUseCloudScreen, !self.processing else { return }
            if let message = self.pendingMessage {
                self.pendingMessage = nil
                self.showResult(message)
            } else if self.task == nil {
                self.reloadBackups()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        if restorePhase != .idle {
            cancelRestore(requestID)
        } else if !processing {
            requestID = UUID()
            task?.cancel()
            task = nil
            loading = false
            refreshControl?.endRefreshing()
        }
    }

    @objc private func applyPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.reloadData()
    }

    @objc private func becameActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self, canUseCloudScreen, !processing, let message = pendingMessage else { return }
            pendingMessage = nil
            showResult(message)
        }
    }

    private func updateControls() {
        let upload = UIBarButtonItem(
            image: UIImage(systemName: "icloud.and.arrow.up"), style: .plain, target: self, action: #selector(uploadBackup))
        upload.accessibilityLabel = "备份到云端"
        upload.accessibilityIdentifier = "backup.cloud.upload"
        upload.isEnabled = !loading && !processing
        let refresh = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadBackups))
        refresh.accessibilityIdentifier = "backup.cloud.refresh"
        refresh.isEnabled = !loading && !processing
        navigationItem.rightBarButtonItems = [upload, refresh]
        navigationItem.hidesBackButton = processing
        if processing, previousInteractivePop == nil {
            processingNavigationController = navigationController
            previousInteractivePop = navigationController?.interactivePopGestureRecognizer?.isEnabled
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        } else if !processing, let previousInteractivePop {
            processingNavigationController?.interactivePopGestureRecognizer?.isEnabled = previousInteractivePop
            self.previousInteractivePop = nil
            processingNavigationController = nil
        }
        tableView.isUserInteractionEnabled = !processing
    }

    @objc private func reloadBackups() {
        guard visible, !processing else { refreshControl?.endRefreshing(); return }
        task?.cancel()
        let id = UUID()
        requestID = id
        loading = true
        failure = nil
        updateControls()
        tableView.reloadData()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await screen.list()
                guard visible, requestID == id, !Task.isCancelled else { return }
                files = loaded
            } catch is CancellationError {
                return
            } catch {
                guard visible, requestID == id else { return }
                failure = error.userFacingMessage
            }
            task = nil
            loading = false
            refreshControl?.endRefreshing()
            updateControls()
            tableView.reloadData()
            if let selected = initialRestore, failure == nil {
                initialRestore = nil
                if let file = files.first(where: { $0.name == selected.name && $0.lastModified == selected.lastModified }) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.requestID == id else { return }
                        self.confirmRestore(file)
                    }
                } else {
                    showResult("云端备份已变化，请重新选择")
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, files.count) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        files.isEmpty ? nil : failure.map { "刷新失败，当前保留上次列表。\n" + $0 }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        guard !files.isEmpty else {
            cell.textLabel?.text = loading ? "正在加载…" : (failure == nil ? "暂无云端备份" : "加载失败，点击重试")
            cell.detailTextLabel?.text = failure
            cell.accessibilityIdentifier = failure == nil ? "backup.cloud.empty" : "backup.cloud.retry"
            cell.selectionStyle = failure == nil ? .none : .default
            return cell
        }
        let file = files[indexPath.row]
        cell.textLabel?.text = file.name
        let date =
            file.lastModified > 0
            ? DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: Double(file.lastModified) / 1000), dateStyle: .medium, timeStyle: .short)
            : "时间未知"
        cell.detailTextLabel?.text = date + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "backup.cloud.file.\(file.name)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading, !processing else { return }
        guard !files.isEmpty else { if failure != nil { reloadBackups() }; return }
        confirmRestore(files[indexPath.row])
    }

    @objc private func uploadBackup() {
        guard canPerformNavigationAction, task == nil, !processing else { return }
        BackupPasswordPrompt.present(from: self, creating: true) { [weak self] password in
            self?.performUpload(password)
        }
    }

    func confirmRestore(_ file: CloudBackupFile) {
        guard canUseCloudScreen, task == nil, !loading, !processing else { return }
        let id = UUID()
        requestID = id
        restoreWindow = view.window
        restoreScene = view.window?.windowScene
        restoreInvalidated = false
        preparationCancelledByUser = false
        restorePhase = .password
        processing = true
        updateControls()
        let prompt = UIAlertController(
            title: "恢复云端备份", message: "先下载并预检所选备份，确认内容后才会恢复。\n\(file.name)", preferredStyle: .alert)
        prompt.view.accessibilityIdentifier = "backup.cloud.restore.confirm"
        prompt.addTextField {
            $0.placeholder = "备份密码（未设置可留空）"
            $0.isSecureTextEntry = true
            $0.autocorrectionType = .no
            $0.textContentType = .password
            $0.accessibilityIdentifier = "backup.cloud.password.0"
        }
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak prompt] _ in
                prompt?.textFields?.forEach { $0.text = nil }
                self?.cancelRestore(id)
            })
        prompt.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak prompt] _ in
                guard let self, let prompt, self.currentRestore(id, phase: .password) else { return }
                let password = prompt.textFields?.first?.text ?? ""
                prompt.textFields?.forEach { $0.text = nil }
                self.task = Task { [weak self] in
                    guard let self else { return }
                    await dismissRestorePresentation(prompt)
                    guard currentRestore(id, phase: .password), canPerformNavigationAction else {
                        await finishRestore(id)
                        return
                    }
                    prepareRestore(file, password: password, id: id)
                }
            })
        restorePresentation = prompt
        present(prompt, animated: true)
    }

    private func performUpload(_ password: String) {
        guard canPerformNavigationAction, task == nil, !processing else { return }
        processing = true
        updateControls()
        let hud = progressAlert("正在上传备份", cancellable: true)
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                let result = try await screen.upload(password: password)
                message = (["已备份到云端：\(result.file.name)"] + result.warnings).joined(separator: "\n")
            } catch is CancellationError {
                message = "已停止等待，请刷新确认云端状态"
            } catch {
                message = error.userFacingMessage
            }
            finish(hud: hud, message: message)
        }
    }

    private func prepareRestore(_ file: CloudBackupFile, password: String, id: UUID) {
        guard currentRestore(id, phase: .password) else { return }
        restorePhase = .preparing
        let hud = UIAlertController(
            title: "正在下载并预检备份", message: "此阶段未恢复任何数据，可以取消。", preferredStyle: .alert)
        hud.view.accessibilityIdentifier = "backup.cloud.preparing"
        hud.addAction(
            UIAlertAction(title: "取消预检", style: .cancel) { [weak self] _ in
                self?.cancelRestore(id, userInitiated: true)
            })
        restorePresentation = hud
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await screen.prepareRestore(file: file, password: password)
                guard currentRestore(id, phase: .preparing) else {
                    prepared.discard()
                    await finishPreparation(id)
                    return
                }
                preparedRestore = prepared
                await dismissRestorePresentation(hud)
                guard currentRestore(id, phase: .preparing), canPerformNavigationAction else {
                    await finishPreparation(id)
                    return
                }
                task = nil
                restorePhase = .confirming
                confirmPreparedRestore(prepared, id: id)
            } catch {
                let message = restoreInvalidated || error is CancellationError ? nil : error.userFacingMessage
                await finishPreparation(id, message: message)
            }
        }
    }

    private func confirmPreparedRestore(_ prepared: PreparedCloudBackup, id: UUID) {
        guard currentRestore(id, phase: .confirming), canPerformNavigationAction else {
            prepared.discard()
            cancelRestore(id)
            return
        }
        let alert = UIAlertController(
            title: "确认恢复备份", message: Self.preparedSummary(prepared), preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "backup.cloud.restore.prepared.confirm"
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.cancelRestore(id) })
        alert.addAction(
            UIAlertAction(title: "恢复", style: .destructive) { [weak self, weak alert] _ in
                guard let self, let alert, self.currentRestore(id, phase: .confirming),
                    self.preparedRestore === prepared
                else { return }
                self.task = Task { [weak self] in
                    guard let self else { return }
                    // UIAlertAction runs before its dismissal animation has completed.
                    await dismissRestorePresentation(alert)
                    guard currentRestore(id, phase: .confirming), canPerformNavigationAction,
                        preparedRestore === prepared
                    else {
                        await finishRestore(id)
                        return
                    }
                    commitRestore(prepared, id: id)
                }
            })
        restorePresentation = alert
        present(alert, animated: true)
    }

    private func commitRestore(_ prepared: PreparedCloudBackup, id: UUID) {
        guard currentRestore(id, phase: .confirming) else { return }
        restorePhase = .committing
        preparedRestore = nil
        let hud = progressAlert("正在恢复备份", cancellable: false)
        hud.message = "正在提交恢复，请等待完成。此阶段不能取消或回滚已恢复的数据。"
        restorePresentation = hud
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { prepared.discard(); return }
            defer { prepared.discard() }
            guard currentRestore(id, phase: .committing) else {
                await finishRestore(id)
                return
            }
            let message: String
            do {
                let restored = try await screen.restore(prepared: prepared)
                // Do not suppress success when the Swift task was cancelled after shared committed.
                onRestored?()
                message = (["恢复完成", Self.restoreSummary(restored.result)] + restored.warnings).joined(separator: "\n")
            } catch is CancellationError {
                message = "恢复请求已结束，请核对当前书架和设置；已提交的数据不会自动回滚。"
            } catch {
                message = error.userFacingMessage + "\n请核对当前书架和设置；已提交的数据不会自动回滚。"
            }
            await finishRestore(id, message: message, keepMessage: true)
        }
    }

    private func finishPreparation(_ id: UUID, message: String? = nil) async {
        guard requestID == id else { return }
        let result = preparationCancelledByUser ? "预检已取消，未恢复任何数据。" : message
        await finishRestore(id, message: result)
    }

    private func finishRestore(_ id: UUID, message: String? = nil, keepMessage: Bool = false) async {
        guard requestID == id, restorePhase != .idle, restorePhase != .finishing else { return }
        restorePhase = .finishing
        preparedRestore?.discard()
        preparedRestore = nil
        if let presentation = restorePresentation { await dismissRestorePresentation(presentation) }
        guard requestID == id else { return }
        let mayPresent = restoreIsAttached && canPerformNavigationAction
        requestID = UUID()
        restorePhase = .idle
        restoreWindow = nil
        restoreScene = nil
        restorePresentation = nil
        restoreInvalidated = false
        preparationCancelledByUser = false
        task = nil
        loading = false
        processing = false
        refreshControl?.endRefreshing()
        updateControls()
        guard let message else { return }
        if mayPresent { showResult(message) } else if keepMessage { pendingMessage = message }
    }

    private func cancelRestore(_ id: UUID, userInitiated: Bool = false) {
        guard requestID == id, restorePhase != .idle else { return }
        restoreInvalidated = true
        preparationCancelledByUser = preparationCancelledByUser || userInitiated
        task?.cancel()
        guard restorePhase != .committing, restorePhase != .finishing else { return }
        preparedRestore?.discard()
        preparedRestore = nil
        restorePresentation?.textFields?.forEach { $0.text = nil }
        if restorePhase == .preparing {
            restorePresentation?.dismiss(animated: false)
            return
        }
        Task { [weak self] in await self?.finishRestore(id) }
    }

    @objc private func restoreContextChanged(_ notification: Notification) {
        let contextWindow = restoreWindow ?? viewIfLoaded?.window
        let contextScene = restoreScene ?? contextWindow?.windowScene
        if let scene = notification.object as? UIScene, scene !== contextScene { return }
        if let window = notification.object as? UIWindow, window !== contextWindow { return }
        if notification.name == .appLockStatusDidChange, AppLockManager.shared.isUnlocked(in: contextWindow) { return }
        guard restorePhase != .idle else {
            if !processing {
                requestID = UUID()
                task?.cancel()
                task = nil
                loading = false
                refreshControl?.endRefreshing()
                updateControls()
            }
            return
        }
        cancelRestore(requestID)
    }

    private func currentRestore(_ id: UUID, phase: RestorePhase) -> Bool {
        requestID == id && restorePhase == phase && !restoreInvalidated && !Task.isCancelled && restoreIsAttached
    }

    private var restoreIsAttached: Bool {
        guard let window = restoreWindow, let scene = restoreScene,
            viewIfLoaded?.window === window, window.windowScene === scene,
            visible, isVisibleInNavigationStack, !isBeingDismissed, !isMovingFromParent,
            window.isKeyWindow, !window.isHidden, window.alpha > 0,
            scene.activationState == .foregroundActive, UIApplication.shared.applicationState == .active,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    private var canUseCloudScreen: Bool {
        visible && canPerformNavigationAction && AppLockManager.shared.isUnlocked(in: viewIfLoaded?.window)
    }

    private func dismissRestorePresentation(_ controller: UIViewController) async {
        while controller.isBeingPresented { await waitForPresentationTransition() }
        if controller.presentingViewController != nil, !controller.isBeingDismissed {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
        // A cancellation must not let an action escape an in-flight UIKit dismissal.
        while controller.isBeingDismissed || controller.presentingViewController != nil {
            await waitForPresentationTransition()
        }
        if restorePresentation === controller { restorePresentation = nil }
    }

    private func waitForPresentationTransition() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { continuation.resume() }
        }
    }

    private static func preparedSummary(_ prepared: PreparedCloudBackup) -> String {
        let file = prepared.file
        let date =
            file.lastModified > 0
            ? DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: Double(file.lastModified) / 1000), dateStyle: .medium, timeStyle: .short)
            : "时间未知"
        var sections = [
            file.name + "\n" + date + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
            "预检完成，尚未恢复任何数据。\n" + restoreSummary(prepared.summary),
        ]
        if !prepared.warnings.isEmpty { sections.append("说明：\n" + prepared.warnings.joined(separator: "\n")) }
        sections.append("将合并恢复并覆盖同身份的数据，设置按恢复忽略项处理。数据库和设置分开保存，不保证跨存储同时成功；已提交的数据不会自动回滚。")
        return sections.joined(separator: "\n\n")
    }

    private static func restoreSummary(_ result: BackupRestoreResult) -> String {
        let counts: [(String, Int32)] = [
            ("书架", result.bookCount), ("书源", result.bookSourceCount), ("RSS 源", result.rssSourceCount),
            ("替换规则", result.replaceRuleCount), ("书籍分组", result.bookGroupCount), ("书签", result.bookmarkCount),
            ("TXT 目录规则", result.txtTocRuleCount), ("词典规则", result.dictRuleCount), ("搜索历史", result.searchHistoryCount),
            ("阅读记录", result.readRecordCount), ("RSS 收藏", result.rssStarCount), ("源订阅", result.sourceSubCount),
            ("HTTP 朗读配置", result.httpTTSCount), ("键盘辅助", result.keyboardAssistCount), ("服务器配置", result.serverCount),
        ]
        let nonzero = counts.filter { $0.1 > 0 }.map { "\($0.0)：\($0.1)" }
        return (nonzero.isEmpty ? ["15 类数据均为空"] : nonzero)
            .joined(separator: "\n") + "\n偏好设置：" + (result.preferencesRestored ? "包含（按恢复忽略项处理）" : "不包含")
    }

    private func progressAlert(_ title: String, cancellable: Bool) -> UIAlertController {
        let hud = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        hud.view.accessibilityIdentifier = "backup.cloud.processing"
        if cancellable {
            hud.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.task?.cancel() })
        }
        return hud
    }

    private func finish(hud: UIAlertController, message: String) {
        task = nil
        processing = false
        updateControls()
        let completion = { [weak self] in
            guard let self else { return }
            if visible, canPerformNavigationAction, UIApplication.shared.applicationState == .active {
                showResult(message)
            } else {
                pendingMessage = message
            }
        }
        if hud.presentingViewController != nil { hud.dismiss(animated: true, completion: completion) } else { completion() }
    }

    private func showResult(_ message: String) {
        guard canUseCloudScreen else { pendingMessage = message; return }
        let alert = UIAlertController(title: "云端备份", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "backup.cloud.result"
        alert.addAction(
            UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self] _ in
                DispatchQueue.main.async { self?.reloadBackups() }
            })
        present(alert, animated: true)
    }
}
