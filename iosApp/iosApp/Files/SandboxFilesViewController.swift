import UIKit
import UniformTypeIdentifiers

@MainActor
final class SandboxFilesViewController: UITableViewController, UISearchResultsUpdating, UIDocumentPickerDelegate {
    private let store: SandboxFileStore
    private let directory: URL
    private let clipboard: SandboxFileClipboard
    private var entries: [SandboxFileEntry] = []
    private var visibleEntries: [SandboxFileEntry] = []
    private var operation: Task<Void, Never>?
    private var refreshID = UUID()
    private var loadTask: Task<Void, Never>?
    private var picker: UIDocumentPickerViewController?
    private var directoryImporter: LocalBookDirectoryImportCoordinator?
    private var isVisible = false
    private let search = UISearchController(searchResultsController: nil)

    init(directory: URL? = nil, store: SandboxFileStore = .shared, clipboard: SandboxFileClipboard? = nil) {
        self.store = store
        self.directory = directory ?? store.root
        self.clipboard = clipboard ?? SandboxFileClipboard()
        super.init(style: .plain)
        title = directory?.lastPathComponent ?? "文件管理"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { loadTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "files.list"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "筛选文件"
        navigationItem.searchController = search
        definesPresentationContext = true
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        refreshControl = refresh
        updateActions()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        applyPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        refreshID = UUID()
        loadTask?.cancel()
        loadTask = nil
        refreshControl?.endRefreshing()
    }

    @objc private func applyPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.reloadData()
    }

    @objc private func reload() {
        guard operation == nil else { refreshControl?.endRefreshing(); return }
        let id = UUID()
        refreshID = id
        loadTask?.cancel()
        loadTask = Task { [weak self, store, directory] in
            do {
                let entries = try await store.list(directory)
                guard let self, self.isVisible, self.refreshID == id, !Task.isCancelled else { return }
                self.entries = entries
                self.updateSearchResults(for: self.search)
                self.navigationItem.prompt = nil
                self.loadTask = nil
                self.refreshControl?.endRefreshing()
                self.updateActions()
            } catch {
                guard let self, self.isVisible, self.refreshID == id, !Task.isCancelled else { return }
                self.navigationItem.prompt = error.userFacingMessage
                self.loadTask = nil
                self.refreshControl?.endRefreshing()
            }
        }
    }

    private func updateActions() {
        var actions = [
            UIAction(title: "导入文件", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in self?.pickFile() },
            UIAction(title: "扫描此文件夹", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.scanBooks() },
            UIAction(title: "新建文件夹", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in self?.askName() },
        ]
        if let source = clipboard.source {
            actions.append(
                UIAction(title: "粘贴 \(source.lastPathComponent)", image: UIImage(systemName: "doc.on.clipboard")) {
                    [weak self] _ in self?.paste()
                })
        }
        actions.append(
            UIAction(title: "下载管理", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                self?.navigationController?.pushViewController(DownloadManagementViewController(), animated: true)
            })
        actions.append(
            UIAction(title: "远程书籍", image: UIImage(systemName: "network")) { [weak self] _ in
                guard let self, self.operation == nil else { return }
                let screen = BookshelfScreenAdapter()
                do {
                    try screen.bootstrap().get()
                    self.navigationController?.pushViewController(
                        RemoteBookViewController(screen: screen).configuredForDrillDownPresentation(), animated: true)
                } catch { self.showTransientMessage(error.userFacingMessage) }
            })
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis"), menu: UIMenu(children: actions))
        more.accessibilityLabel = "文件操作"
        more.accessibilityIdentifier = "files.actions"
        more.isEnabled = operation == nil
        let refresh = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload))
        refresh.isEnabled = operation == nil
        navigationItem.rightBarButtonItems = [more, refresh]
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleEntries =
            query.isEmpty ? entries : entries.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }
        let label = UILabel()
        label.text = entries.isEmpty ? "暂无文件" : "没有匹配的文件"
        label.textAlignment = .center
        label.textColor = AndroidReplicaTheme.secondaryText
        tableView.backgroundView = visibleEntries.isEmpty ? label : nil
        tableView.reloadData()
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { visibleEntries.count }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = visibleEntries[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.text = entry.url.lastPathComponent
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.textLabel?.numberOfLines = 2
        cell.imageView?.image = UIImage(systemName: entry.isDirectory ? "folder" : "doc")
        cell.imageView?.tintColor = AndroidReplicaTheme.accent
        cell.accessoryType = .disclosureIndicator
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        if !entry.isDirectory {
            cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        }
        cell.accessibilityIdentifier = "files.item.\(entry.url.lastPathComponent)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard operation == nil, visibleEntries.indices.contains(indexPath.row) else { return }
        let entry = visibleEntries[indexPath.row]
        search.searchBar.resignFirstResponder()
        let destination: UIViewController =
            entry.isDirectory
            ? SandboxFilesViewController(directory: entry.url, store: store, clipboard: clipboard)
            : FileDocumentViewController(url: entry.url)
        navigationController?.pushViewController(destination, animated: true)
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard operation == nil, visibleEntries.indices.contains(indexPath.row) else { return nil }
        let entry = visibleEntries[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "重命名", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.askName(for: entry.url) },
                UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.capture(entry.url, moving: false)
                },
                UIAction(title: "移动", image: UIImage(systemName: "folder")) { [weak self] _ in
                    self?.capture(entry.url, moving: true)
                },
                UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDelete(entry.url)
                },
            ])
        }
    }

    private func capture(_ url: URL, moving: Bool) {
        guard operation == nil else { return }
        clipboard.source = url
        clipboard.moving = moving
        updateActions()
    }

    private func paste() {
        guard let source = clipboard.source else { return }
        let moving = clipboard.moving
        perform { [store, directory, clipboard] in
            try await store.transfer(source, into: directory, moving: moving)
            if moving, clipboard.source == source { clipboard.source = nil }
        }
    }

    private func askName(for source: URL? = nil) {
        guard operation == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: source == nil ? "新建文件夹" : "重命名", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = source?.lastPathComponent; field.placeholder = "名称"; field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
                guard let self, let name = alert?.textFields?.first?.text else { return }
                self.perform { [store = self.store, directory = self.directory] in
                    if let source {
                        try await store.rename(source, to: name)
                    } else {
                        try await store.createFolder(named: name, in: directory)
                    }
                }
            })
        present(alert, animated: true)
    }

    private func confirmDelete(_ source: URL) {
        guard operation == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "删除文件", message: "确定删除“\(source.lastPathComponent)”？此操作不可撤销。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                self?.perform { [store = self?.store] in try await store?.remove(source) }
            })
        present(alert, animated: true)
    }

    private func pickFile() {
        guard operation == nil, picker == nil, presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.picker = picker
        present(picker, animated: true)
    }

    private func scanBooks() {
        guard operation == nil, directoryImporter == nil, picker == nil, isVisible,
            canPerformNavigationAction, presentedViewController == nil,
            UIApplication.shared.applicationState == .active,
            view.window.map({ AppLockManager.shared.isUnlocked(in: $0) }) == true
        else { return }
        search.isActive = false
        let importer = LocalBookDirectoryImportCoordinator(presenter: self)
        importer.onBatchCompleted = { [weak self] summary in
            guard let self else { return }
            LocalBookImportResultViewController(summary: summary).present(from: self)
        }
        importer.onFinished = { [weak self] in
            self?.directoryImporter = nil
            self?.updateActions()
        }
        directoryImporter = importer
        importer.start(root: directory)
        updateActions()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if picker === controller { picker = nil }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard picker === controller, let url = urls.first else { return }
        picker = nil
        perform { [store, directory] in _ = try await store.importFile(url, into: directory) }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        refreshID = UUID()
        loadTask?.cancel()
        loadTask = nil
        operation = Task { [weak self] in
            do { try await action() } catch { if self?.isVisible == true { self?.showTransientMessage(error.userFacingMessage) } }
            guard let self else { return }
            self.operation = nil
            self.updateActions()
            if self.isVisible { self.reload() }
        }
        updateActions()
    }
}
