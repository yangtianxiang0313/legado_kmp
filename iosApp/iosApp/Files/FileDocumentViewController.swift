import QuickLook
import UIKit
import shared

@MainActor
final class FileDocumentViewController: UITableViewController, QLPreviewControllerDataSource {
    private let url: URL
    private var importer: LocalBookImportCoordinator?
    private var ruleImport: ExternalRuleImportCoordinator?
    private var shareTask: Task<Void, Never>?
    private var previewURL: URL?
    private var backupCoordinator: SettingsBackupCoordinator?
    private var backupScreen: SettingsScreenAdapter?
    private var readerConfigImport: ExternalReaderConfigImportCoordinator?

    init(url: URL) {
        self.url = url
        super.init(style: .insetGrouped)
        title = url.lastPathComponent
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { backupScreen?.unbind() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "files.document"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.backgroundColor = AndroidReplicaTheme.background
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    private var actions: [(String, String, String)] {
        var items: [(String, String, String)] = []
        if LocalBookFormats.importExtensions.contains(url.pathExtension.lowercased()) {
            items.append(("导入书籍", "books.vertical", "book"))
        }
        if ["json", "txt"].contains(url.pathExtension.lowercased()) {
            items.append(("导入规则", "square.and.arrow.down", "source"))
        }
        if ["zip", "json"].contains(url.pathExtension.lowercased()) {
            items.append(("导入阅读配置", "textformat.size", "readerConfig"))
            items.append(("恢复备份", "arrow.counterclockwise", "restore"))
        }
        items.append(("预览", "doc.text.magnifyingglass", "preview"))
        items.append(("分享 / 导出", "square.and.arrow.up", "share"))
        return items
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { actions.count }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let action = actions[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = action.0
        cell.textLabel?.numberOfLines = 0
        cell.imageView?.image = UIImage(systemName: action.1)
        cell.imageView?.tintColor = AndroidReplicaTheme.accent
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.accessibilityIdentifier = "files.document.\(action.2)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canPerformNavigationAction else { return }
        switch actions[indexPath.row].2 {
        case "book":
            guard importer == nil else { return }
            let coordinator = LocalBookImportCoordinator(presenter: self) { _ in }
            coordinator.onBatchCompleted = { [weak self] summary in
                guard let self else { return }
                LocalBookImportResultViewController(summary: summary).present(from: self)
            }
            coordinator.onFinished = { [weak self] in self?.importer = nil }
            importer = coordinator
            coordinator.start(url: url)
        case "source": showSourcePreview()
        case "readerConfig":
            let coordinator = ExternalReaderConfigImportCoordinator(owner: self)
            coordinator.onImported = { [weak self] in self?.showTransientMessage("阅读配置导入完成") }
            readerConfigImport = coordinator
            coordinator.start(input: .file(url))
        case "restore":
            backupScreen?.unbind()
            let screen = SettingsScreenAdapter()
            do { try screen.bootstrap().get() } catch { showTransientMessage(error.userFacingMessage); return }
            backupScreen = screen
            let coordinator = SettingsBackupCoordinator(
                owner: self, screen: screen,
                onError: { [weak self] in self?.showTransientMessage($0.userFacingMessage) },
                onRestored: { [weak self] in self?.tableView.reloadData() })
            backupCoordinator = coordinator
            coordinator.restoreFile(url)
        case "preview": shareOrPreview(previewing: true)
        default: shareOrPreview(previewing: false)
        }
    }

    private func showSourcePreview() {
        guard presentedViewController == nil else { return }
        let coordinator = ExternalRuleImportCoordinator(owner: self)
        coordinator.onImported = { [weak self] in self?.showTransientMessage("规则导入完成") }
        ruleImport = coordinator
        coordinator.start(input: .file(url))
    }

    private func shareOrPreview(previewing: Bool) {
        guard shareTask == nil else { return }
        shareTask = Task { [weak self, url] in
            defer { self?.shareTask = nil }
            do {
                let file = try await SandboxFileStore.shared.validatedFile(url)
                guard let self, self.canPerformNavigationAction else { return }
                self.previewURL = file
                if previewing {
                    guard QLPreviewController.canPreview(file as NSURL) else { throw Self.readError("系统暂不支持预览此文件，可分享给其他应用打开") }
                    let preview = QLPreviewController()
                    preview.dataSource = self
                    self.present(preview, animated: true)
                } else {
                    let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.view
                    share.popoverPresentationController?.sourceRect = CGRect(
                        x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    self.present(share, animated: true)
                }
            } catch { self?.showTransientMessage(error.userFacingMessage) }
        }
    }

    func numberOfPreviewItems(in _: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_: QLPreviewController, previewItemAt _: Int) -> QLPreviewItem { (previewURL ?? url) as NSURL }

    private nonisolated static func readError(_ text: String) -> NSError {
        NSError(domain: "io.legado.files", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
