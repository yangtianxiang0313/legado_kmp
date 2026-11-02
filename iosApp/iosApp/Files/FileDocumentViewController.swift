import QuickLook
import UIKit
import shared

@MainActor
final class FileDocumentViewController: UITableViewController, QLPreviewControllerDataSource,
    QLPreviewControllerDelegate, UIAdaptivePresentationControllerDelegate
{
    private let url: URL
    private var importer: LocalBookImportCoordinator?
    private var importID: UUID?
    private var ruleImport: ExternalRuleImportCoordinator?
    private var readerConfigImport: ExternalReaderConfigImportCoordinator?
    private var backupCoordinator: SettingsBackupCoordinator?
    private var backupScreen: SettingsScreenAdapter?
    private var backupFeedbackPage: UUID?
    private var shareTask: Task<Void, Never>?
    private var shareLoadID: UUID?
    private var shareCompletionConsumed = false
    private var presentation: UIViewController?
    private var presentationOwnership: LocalBookImportOwnership?
    private weak var closingPresentation: UIViewController?
    private var previewURL: URL?
    private var generation = UUID()
    private var isVisible = false
    private weak var pageWindow: UIWindow?
    private weak var pageRoot: UIViewController?

    private enum Action: String {
        case book, source, readerConfig, restore, preview, share

        var title: String {
            switch self {
            case .book: return FileDocumentPresentationText.importBook
            case .source: return FileDocumentPresentationText.importRules
            case .readerConfig: return FileDocumentPresentationText.importReaderConfig
            case .restore: return FileDocumentPresentationText.restoreBackup
            case .preview: return FileDocumentPresentationText.preview
            case .share: return FileDocumentPresentationText.shareExport
            }
        }

        var image: String {
            switch self {
            case .book: return "books.vertical"
            case .source: return "square.and.arrow.down"
            case .readerConfig: return "textformat.size"
            case .restore: return "arrow.counterclockwise"
            case .preview: return "doc.text.magnifyingglass"
            case .share: return "square.and.arrow.up"
            }
        }
    }

    init(url: URL) {
        self.url = url
        super.init(style: .insetGrouped)
        title = url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        shareTask?.cancel()
        backupScreen?.unbind()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "files.document"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 48
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeHiddenNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(invalidateActions(_:)), name: name, object: nil)
        }
        applyPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if let pageWindow, pageWindow !== view.window || pageRoot !== view.window?.rootViewController {
            generation = UUID()
        }
        pageWindow = view.window
        pageRoot = view.window?.rootViewController
        tableView.reloadData()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        let ownsPresentation =
            presentation != nil || importer != nil
            || ruleImport?.isPreparing == true || readerConfigImport?.isPreparing == true
        if isMovingFromParent || navigationController?.isBeingDismissed == true
            || navigationController?.topViewController !== self || !ownsPresentation
        {
            generation = UUID()
            shareTask?.cancel()
            ruleImport?.cancel()
            readerConfigImport?.cancel()
            importer?.cancel()
        }
    }

    @objc private func applyPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.reloadData()
    }

    @objc private func invalidateActions(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== pageWindow?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== pageWindow { return }
        generation = UUID()
        // Validation is read-only; delegated import/restore work retains its coordinator's terminal contract.
        shareTask?.cancel()
        ruleImport?.cancel()
        readerConfigImport?.cancel()
        // A share extension may already be writing. Its completion handler, not scene loss, releases that slot.
        if let preview = presentation as? QLPreviewController { closePresentation(preview) }
    }

    private var isBusy: Bool {
        consumerBusy
            || ruleImport?.isPreparing == true || readerConfigImport?.isPreparing == true
    }

    private var consumerBusy: Bool { shareTask != nil || presentation != nil || importer != nil }

    private var actions: [Action] {
        var items: [Action] = []
        let ext = url.pathExtension.lowercased()
        if LocalBookFormats.importExtensions.contains(ext) { items.append(.book) }
        if ["json", "txt"].contains(ext) { items.append(.source) }
        if ["zip", "json"].contains(ext) { items += [.readerConfig, .restore] }
        return items + [.preview, .share]
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { actions.count }

    override func tableView(_: UITableView, viewForHeaderInSection _: Int) -> UIView? {
        let header = UITableViewHeaderFooterView(reuseIdentifier: nil)
        let label = UILabel()
        label.text = url.lastPathComponent
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.textColor = AndroidReplicaTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        header.contentView.addSubview(label)
        let margins = header.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            label.topAnchor.constraint(equalTo: header.contentView.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: header.contentView.bottomAnchor, constant: -8),
        ])
        return header
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let action = actions[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = action.title
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.imageView?.image = UIImage(systemName: action.image)
        cell.imageView?.tintColor = AndroidReplicaTheme.accent
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.accessibilityIdentifier = "files.document.\(action.rawValue)"
        // Delegated preparation owns a modal; its private cancel path has no page-level terminal callback.
        cell.selectionStyle = consumerBusy ? .none : .default
        if consumerBusy { cell.accessibilityTraits.insert(.notEnabled) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard actions.indices.contains(indexPath.row), !isBusy, isVisible, canPerformNavigationAction,
            let ownership = LocalBookImportOwnership(owner: self)
        else { return }
        generation = UUID()
        let page = generation
        navigationItem.prompt = nil
        switch actions[indexPath.row] {
        case .book: importBook(page: page)
        case .source:
            let coordinator = ExternalRuleImportCoordinator(owner: self)
            coordinator.onImported = { [weak self] in
                self?.report(FileDocumentPresentationText.rulesImported, page: page)
            }
            ruleImport = coordinator
            coordinator.start(input: .file(url))
        case .readerConfig:
            let coordinator = ExternalReaderConfigImportCoordinator(owner: self)
            coordinator.onImported = { [weak self] in
                self?.report(FileDocumentPresentationText.readerConfigImported, page: page)
            }
            readerConfigImport = coordinator
            coordinator.start(input: .file(url))
        case .restore: restoreBackup(page: page)
        case .preview, .share:
            shareOrPreview(previewing: actions[indexPath.row] == .preview, page: page, ownership: ownership)
        }
        tableView.reloadData()
    }

    private func importBook(page: UUID) {
        let id = UUID()
        let coordinator = LocalBookImportCoordinator(presenter: self) { _ in }
        coordinator.onBatchCompleted = { [weak self] summary in
            guard let self, self.importID == id, self.generation == page, self.canPerformNavigationAction,
                AppLockManager.shared.isUnlocked(in: self.viewIfLoaded?.window)
            else { return }
            LocalBookImportResultViewController(summary: summary).present(from: self)
        }
        coordinator.onFinished = { [weak self] in
            guard let self, self.importID == id else { return }
            self.importID = nil
            self.importer = nil
            self.tableView.reloadData()
        }
        importID = id
        importer = coordinator
        coordinator.start(url: url)
    }

    private func restoreBackup(page: UUID) {
        if backupCoordinator == nil {
            let screen = SettingsScreenAdapter()
            do { try screen.bootstrap().get() } catch {
                showTransientMessage(FileDocumentPresentationText.message(for: error))
                return
            }
            backupScreen = screen
            backupCoordinator = SettingsBackupCoordinator(
                owner: self, screen: screen,
                onError: { [weak self] error in
                    guard let self, self.backupFeedbackPage == self.generation,
                        self.pageWindow?.rootViewController === self.pageRoot, self.canPerformNavigationAction,
                        AppLockManager.shared.isUnlocked(in: self.viewIfLoaded?.window)
                    else { return }
                    self.showTransientMessage(FileDocumentPresentationText.message(for: error))
                },
                onRestored: { [weak self] in
                    guard let self, self.backupFeedbackPage == self.generation,
                        self.pageWindow?.rootViewController === self.pageRoot
                    else { return }
                    self.tableView.reloadData()
                })
        }
        // Reuse the coordinator; replacing it could bypass an in-flight restore or unbind its screen.
        backupFeedbackPage = page
        backupCoordinator?.restoreFile(url)
    }

    private func report(_ message: String, page: UUID) {
        guard generation == page, let window = pageWindow, window.rootViewController === pageRoot,
            navigationController?.topViewController === self, !isMovingFromParent, !isBeingDismissed,
            window.windowScene?.activationState == .foregroundActive, AppLockManager.shared.isUnlocked(in: window)
        else { return }
        // Success can precede dismissal. Put it on the original page, not an unrelated modal.
        navigationItem.prompt = message
    }

    private func shareOrPreview(previewing: Bool, page: UUID, ownership: LocalBookImportOwnership) {
        guard shareTask == nil else { return }
        let id = UUID()
        shareLoadID = id
        ownership.observe { [weak self, weak ownership] in
            guard let self, let ownership,
                self.shareLoadID == id || self.presentationOwnership === ownership
            else { return }
            self.generation = UUID()
            self.shareTask?.cancel()
            if let preview = self.presentation as? QLPreviewController { self.closePresentation(preview) }
        }
        shareTask = Task { [weak self, url] in
            defer {
                if self?.presentationOwnership !== ownership { ownership.stopObserving() }
                if let self, self.shareLoadID == id {
                    self.shareTask = nil
                    self.shareLoadID = nil
                    self.tableView.reloadData()
                }
            }
            do {
                let file = try await SandboxFileStore.shared.validatedFile(url)
                try Task.checkCancellation()
                guard let self, self.generation == page, ownership.canPresent else { return }
                let controller: UIViewController
                if previewing {
                    guard QLPreviewController.canPreview(file as NSURL) else {
                        throw Self.readError(FileDocumentPresentationText.unsupportedPreview)
                    }
                    self.previewURL = file
                    let preview = QLPreviewController()
                    preview.dataSource = self
                    preview.delegate = self
                    controller = preview
                } else {
                    self.shareCompletionConsumed = false
                    let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.view
                    share.popoverPresentationController?.sourceRect = CGRect(
                        x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    share.completionWithItemsHandler = { [weak self, weak share] _, _, _, error in
                        Task { @MainActor [weak self, weak share] in
                            guard let self, let share, self.presentation === share, !self.shareCompletionConsumed else {
                                return
                            }
                            self.shareCompletionConsumed = true
                            await LocalBookImportOwnership.dismiss(share)
                            self.finishPresentation(share)
                            if let error, self.generation == page, ownership.canPresent {
                                self.showTransientMessage(FileDocumentPresentationText.message(for: error))
                            }
                        }
                    }
                    controller = share
                }
                self.presentation = controller
                self.presentationOwnership = ownership
                ownership.bind(controller)
                self.present(controller, animated: true) { [weak self, weak controller] in
                    guard let self, let controller, self.presentation === controller else { return }
                    guard self.generation == page else {
                        self.closePresentation(controller)
                        return
                    }
                    do { try ownership.acknowledgePresentation(controller) } catch {
                        self.closePresentation(controller)
                    }
                }
                controller.presentationController?.delegate = self
            } catch {
                guard !(error is CancellationError), let self, self.generation == page, ownership.canPresent else {
                    return
                }
                self.showTransientMessage(FileDocumentPresentationText.message(for: error))
            }
        }
    }

    private func closePresentation(_ controller: UIViewController) {
        guard presentation === controller, closingPresentation !== controller else { return }
        closingPresentation = controller
        Task { @MainActor [weak self] in
            await LocalBookImportOwnership.dismiss(controller)
            self?.finishPresentation(controller)
        }
    }

    private func finishPresentation(_ controller: UIViewController) {
        guard presentation === controller else { return }
        presentationOwnership?.stopObserving()
        presentationOwnership?.bind(nil)
        presentationOwnership = nil
        presentation = nil
        closingPresentation = nil
        previewURL = nil
        tableView.reloadData()
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) { finishPresentation(controller) }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let controller = presentationController.presentedViewController
        if !(controller is UIActivityViewController) { finishPresentation(controller) }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        presentation === controller && previewURL != nil ? 1 : 0
    }

    func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem {
        (previewURL ?? url) as NSURL
    }

    private nonisolated static func readError(_ text: String) -> NSError {
        NSError(domain: "io.legado.files", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

enum FileDocumentPresentationText {
    static let filterFiles = text("file.consumer.filter_files", "筛选文件")
    static let importFile = text("file.consumer.import_file", "导入文件")
    static let scanFolder = text("file.consumer.scan_folder", "扫描此文件夹")
    static let createFolder = text("file.consumer.create_folder", "新建文件夹")
    static let downloads = text("file.consumer.downloads", "下载管理")
    static let fileActions = text("file.consumer.actions", "文件操作")
    static let noFiles = text("file.consumer.no_files", "暂无文件")
    static let noMatches = text("file.consumer.no_matches", "没有匹配的文件")
    static let working = text("file.consumer.working", "正在处理文件…")
    static let openFolderHint = text("file.consumer.open_folder_hint", "打开文件夹")
    static let openFileHint = text("file.consumer.open_file_hint", "打开文件操作")
    static let rename = text("file.consumer.rename", "重命名")
    static let move = text("file.consumer.move", "移动")
    static let name = text("file.consumer.name", "名称")
    static let deleteFile = text("file.consumer.delete_file", "删除文件")
    static let importBook = text("file.consumer.import_book", "导入书籍")
    static let importRules = text("file.consumer.import_rules", "导入规则")
    static let importReaderConfig = text("file.consumer.import_reader_config", "导入阅读配置")
    static let restoreBackup = text("backup.local.restore.title", "恢复备份")
    static let preview = text("file.consumer.preview", "预览")
    static let shareExport = text("file.consumer.share_export", "分享 / 导出")
    static let rulesImported = text("file.consumer.rules_imported", "规则导入完成")
    static let readerConfigImported = text("file.consumer.reader_config_imported", "阅读配置导入完成")
    static let unsupportedPreview = text("file.consumer.preview_unsupported", "系统暂不支持预览此文件，可分享给其他应用打开")

    static func paste(_ name: String) -> String { format("file.consumer.paste", "粘贴 %@", name) }

    static func deleteMessage(_ name: String) -> String {
        format("file.consumer.delete_message", "确定删除“%@”？此操作不可撤销。", name)
    }

    static func message(for error: Error) -> String {
        let failure = error as NSError
        // Translate only exact, owned store diagnostics. Unknown/user text and original NSError codes are untouched.
        guard failure.domain == "io.legado.files", failure.code == 1,
            let diagnostic = failure.userInfo[NSLocalizedDescriptionKey] as? String
        else { return failure.localizedDescription }
        switch diagnostic {
        case "不能将文件夹放入自身": return text("file.consumer.error.folder_into_self", "不能将文件夹放入自身")
        case "请选择文件": return text("file.consumer.error.select_file", "请选择文件")
        case "无效的文件地址": return text("file.consumer.error.invalid_url", "无效的文件地址")
        case "已存在同名文件": return text("file.consumer.error.name_exists", "已存在同名文件")
        case "只能导入普通文件": return text("file.consumer.error.regular_file_only", "只能导入普通文件")
        case "无法读取文件": return text("file.consumer.error.unreadable", "无法读取文件")
        case "不能访问应用文件目录之外的内容": return text("file.consumer.error.outside_sandbox", "不能访问应用文件目录之外的内容")
        case "名称不能为空或包含路径、控制字符": return text("file.consumer.error.invalid_name", "名称不能为空或包含路径、控制字符")
        default: return failure.localizedDescription
        }
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: key, value: fallback, table: nil)
    }

    private static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback), locale: Locale.current, arguments: arguments)
    }
}
