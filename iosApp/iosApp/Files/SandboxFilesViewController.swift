import UIKit
import UniformTypeIdentifiers

@MainActor
final class SandboxFilesViewController: UITableViewController, UISearchResultsUpdating, UISearchControllerDelegate,
    UIDocumentPickerDelegate
{
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
    private var directoryImportID: UUID?
    private var pickerOwnership: LocalBookImportOwnership?
    private weak var nameAlert: UIAlertController?
    private weak var pageWindow: UIWindow?
    private weak var pageRoot: UIViewController?
    private var generation = UUID()
    private var isVisible = false
    private let search = UISearchController(searchResultsController: nil)

    init(directory: URL? = nil, store: SandboxFileStore = .shared, clipboard: SandboxFileClipboard? = nil) {
        self.store = store
        self.directory = directory ?? store.root
        self.clipboard = clipboard ?? SandboxFileClipboard()
        super.init(style: .plain)
        title = directory?.lastPathComponent ?? L10n.Settings.fileManageTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "files.list"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = FileDocumentPresentationText.filterFiles
        search.searchBar.accessibilityLabel = FileDocumentPresentationText.filterFiles
        navigationItem.searchController = search
        definesPresentationContext = true
        let refresh = UIRefreshControl()
        refresh.accessibilityLabel = L10n.Common.refresh
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        refreshControl = refresh
        updateActions()
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
        for name in [
            UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification,
            UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(resumePage(_:)), name: name, object: nil)
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
        updateActions()
        let appearance = generation
        Task { @MainActor [weak self] in
            // Navigation can still own its transition during the child's viewDidAppear.
            await Task.yield()
            guard let self, self.isVisible, self.generation == appearance else { return }
            if let transition = self.navigationController?.transitionCoordinator ?? self.transitionCoordinator {
                await withCheckedContinuation { continuation in
                    if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                        continuation.resume()
                    }
                }
                await Task.yield()
            }
            guard self.isVisible, self.generation == appearance,
                self.viewIfLoaded?.window === self.pageWindow,
                self.pageWindow?.rootViewController === self.pageRoot
            else { return }
            self.updateActions()
            self.reload()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        // An owned full-screen picker/scan is not navigation away from this directory.
        if isMovingFromParent || navigationController?.isBeingDismissed == true
            || (picker == nil && directoryImporter == nil)
        {
            generation = UUID()
        }
        if isMovingFromParent || navigationController?.isBeingDismissed == true
            || navigationController?.topViewController !== self
        {
            directoryImporter?.cancel()
            pickerOwnership?.invalidate()
        }
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
        guard !isBusy, isVisible, canPerformNavigationAction,
            let ownership = LocalBookImportOwnership(owner: self)
        else {
            refreshControl?.endRefreshing()
            return
        }
        generation = UUID()
        let id = UUID()
        refreshID = id
        loadTask?.cancel()
        if entries.isEmpty { showEmptyState(L10n.Common.loadingTitle) }
        loadTask = Task { [weak self, store, directory] in
            do {
                let entries = try await store.list(directory)
                guard let self, self.refreshID == id, !Task.isCancelled else { return }
                self.loadTask = nil
                self.refreshControl?.endRefreshing()
                guard self.isVisible, ownership.canPresent else {
                    self.updateActions()
                    return
                }
                self.entries = entries
                self.updateSearchResults(for: self.search)
                self.navigationItem.prompt = nil
                self.updateActions()
            } catch {
                guard let self, self.refreshID == id, !Task.isCancelled else { return }
                self.loadTask = nil
                self.refreshControl?.endRefreshing()
                if self.isVisible, ownership.canPresent {
                    let message = FileDocumentPresentationText.message(for: error)
                    self.navigationItem.prompt = message
                    if self.visibleEntries.isEmpty { self.showEmptyState(message) }
                }
                self.updateActions()
            }
        }
        updateActions()
    }

    private var isBusy: Bool {
        operation != nil || loadTask != nil || picker != nil || directoryImporter != nil
    }

    private func take(_ id: UUID, ownership: LocalBookImportOwnership) -> Bool {
        guard generation == id, !isBusy, isVisible, ownership.canPresent else { return false }
        generation = UUID()
        updateActions()
        return true
    }

    private var canCloseSearch: Bool {
        search.isActive && search.presentedViewController == nil && isVisibleInNavigationStack
            && (presentedViewController == nil || presentedViewController === search)
            && (navigationController?.presentedViewController == nil
                || navigationController?.presentedViewController === search)
            && pageWindow?.rootViewController === pageRoot && pageWindow?.isKeyWindow == true
            && pageWindow?.windowScene?.activationState == .foregroundActive
            && AppLockManager.shared.isUnlocked(in: pageWindow)
    }

    private func run(
        _ id: UUID, ownership: LocalBookImportOwnership?,
        _ body: @escaping @MainActor (SandboxFilesViewController) -> Void
    ) {
        guard generation == id, !isBusy else { return }
        if !search.isActive {
            guard pageWindow?.rootViewController === pageRoot, viewIfLoaded?.window === pageWindow,
                let current = ownership ?? LocalBookImportOwnership(owner: self), take(id, ownership: current)
            else { return }
            body(self)
            return
        }
        guard canCloseSearch, let window = pageWindow, let root = pageRoot else { return }
        generation = UUID()
        let page = generation
        operation = Task { [self] in
            search.isActive = false
            await LocalBookImportOwnership.dismiss(search)
            operation = nil
            guard generation == page, window.rootViewController === root, viewIfLoaded?.window === window,
                let current = LocalBookImportOwnership(owner: self), take(page, ownership: current)
            else {
                updateActions()
                return
            }
            body(self)
        }
        updateActions()
    }

    func didDismissSearchController(_: UISearchController) { updateActions() }

    @objc private func invalidateActions(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== pageWindow?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== pageWindow { return }
        generation = UUID()
        refreshID = UUID()
        loadTask?.cancel()
        loadTask = nil
        refreshControl?.endRefreshing()
        nameAlert?.textFields?.forEach {
            $0.text = nil
            $0.resignFirstResponder()
        }
        nameAlert?.dismiss(animated: false)
        nameAlert = nil
        // Picker ownership intentionally survives ordinary provider/scene suspension.
    }

    @objc private func resumePage(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== pageWindow?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== pageWindow { return }
        guard isVisible, canPerformNavigationAction else { return }
        updateActions()
        reload()
    }

    private func updateActions() {
        let id = generation
        let ownership = LocalBookImportOwnership(owner: self)
        func action(
            _ title: String, _ image: String, _ body: @escaping @MainActor (SandboxFilesViewController) -> Void
        ) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: image)) { [weak self] _ in
                self?.run(id, ownership: ownership, body)
            }
        }
        var actions = [
            action(FileDocumentPresentationText.importFile, "square.and.arrow.down") { $0.pickFile() },
            action(FileDocumentPresentationText.scanFolder, "folder.badge.plus") { $0.scanBooks() },
            action(FileDocumentPresentationText.createFolder, "folder.badge.plus") { $0.askName() },
        ]
        if let source = clipboard.source {
            let moving = clipboard.moving
            actions.append(
                action(FileDocumentPresentationText.paste(source.lastPathComponent), "doc.on.clipboard") {
                    $0.paste(source, moving: moving)
                })
        }
        actions.append(
            action(FileDocumentPresentationText.downloads, "arrow.down.circle") {
                $0.navigationController?.pushViewController(DownloadManagementViewController(), animated: true)
            })
        actions.append(
            action(L10n.Bookshelf.remoteTitle, "network") { owner in
                let screen = BookshelfScreenAdapter()
                do {
                    try screen.bootstrap().get()
                    owner.navigationController?.pushViewController(
                        RemoteBookViewController(screen: screen).configuredForDrillDownPresentation(), animated: true)
                } catch { owner.showTransientMessage(FileDocumentPresentationText.message(for: error)) }
            })
        let more = toolButton("ellipsis", label: FileDocumentPresentationText.fileActions, identifier: "files.actions")
        more.menu = UIMenu(children: actions)
        more.showsMenuAsPrimaryAction = true
        let refresh = toolButton("arrow.clockwise", label: L10n.Common.refresh, identifier: "files.refresh")
        refresh.addAction(
            UIAction { [weak self] _ in
                self?.run(id, ownership: ownership) { $0.reload() }
            }, for: .touchUpInside)
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: more), UIBarButtonItem(customView: refresh)]
    }

    private func toolButton(_ image: String, label: String, identifier: String) -> UIButton {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        button.setImage(UIImage(systemName: image), for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.isEnabled = !isBusy
        return button
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleEntries =
            query.isEmpty
            ? entries : entries.filter { $0.url.lastPathComponent.localizedCaseInsensitiveContains(query) }
        if visibleEntries.isEmpty {
            showEmptyState(
                entries.isEmpty ? FileDocumentPresentationText.noFiles : FileDocumentPresentationText.noMatches)
        } else {
            tableView.backgroundView = nil
        }
        tableView.reloadData()
    }

    private func showEmptyState(_ message: String) {
        let container = UIView()
        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = AndroidReplicaTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        tableView.backgroundView = container
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { visibleEntries.count }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = visibleEntries[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.text = entry.url.lastPathComponent
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.lineBreakMode = .byCharWrapping
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.imageView?.image = UIImage(systemName: entry.isDirectory ? "folder" : "doc")
        cell.imageView?.tintColor = AndroidReplicaTheme.accent
        cell.accessoryType = .disclosureIndicator
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessibilityHint =
            entry.isDirectory
            ? FileDocumentPresentationText.openFolderHint : FileDocumentPresentationText.openFileHint
        if !entry.isDirectory {
            cell.detailTextLabel?.text = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        }
        cell.accessibilityIdentifier = "files.item.\(entry.url.lastPathComponent)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard visibleEntries.indices.contains(indexPath.row) else { return }
        let entry = visibleEntries[indexPath.row]
        run(generation, ownership: LocalBookImportOwnership(owner: self)) { owner in
            owner.search.searchBar.resignFirstResponder()
            let destination: UIViewController =
                entry.isDirectory
                ? SandboxFilesViewController(directory: entry.url, store: owner.store, clipboard: owner.clipboard)
                : FileDocumentViewController(url: entry.url)
            owner.navigationController?.pushViewController(destination, animated: true)
        }
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard !isBusy, visibleEntries.indices.contains(indexPath.row), canPerformNavigationAction || canCloseSearch
        else { return nil }
        let ownership = LocalBookImportOwnership(owner: self)
        let entry = visibleEntries[indexPath.row]
        let id = generation
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, self.generation == id, self.canPerformNavigationAction || self.canCloseSearch else {
                return nil
            }
            return UIMenu(children: [
                UIAction(title: FileDocumentPresentationText.rename, image: UIImage(systemName: "pencil")) {
                    [weak self] _ in
                    self?.run(id, ownership: ownership) { $0.askName(for: entry.url) }
                },
                UIAction(title: L10n.Reader.selectionCopy, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                    self?.run(id, ownership: ownership) { $0.capture(entry.url, moving: false) }
                },
                UIAction(title: FileDocumentPresentationText.move, image: UIImage(systemName: "folder")) {
                    [weak self] _ in
                    self?.run(id, ownership: ownership) { $0.capture(entry.url, moving: true) }
                },
                UIAction(title: L10n.Common.delete, image: UIImage(systemName: "trash"), attributes: .destructive) {
                    [weak self] _ in
                    self?.run(id, ownership: ownership) { $0.confirmDelete(entry.url) }
                },
            ])
        }
    }

    private func capture(_ url: URL, moving: Bool) {
        clipboard.source = url
        clipboard.moving = moving
        updateActions()
    }

    private func paste(_ source: URL, moving: Bool) {
        guard clipboard.source == source, clipboard.moving == moving else {
            updateActions()
            return
        }
        perform { [store, directory, clipboard] in
            try await store.transfer(source, into: directory, moving: moving)
            if moving, clipboard.source == source, clipboard.moving == moving { clipboard.source = nil }
        }
    }

    private func askName(for source: URL? = nil) {
        guard !isBusy, let ownership = LocalBookImportOwnership(owner: self) else { return }
        let id = generation
        let alert = UIAlertController(
            title: source == nil ? FileDocumentPresentationText.createFolder : FileDocumentPresentationText.rename,
            message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = source?.lastPathComponent
            field.placeholder = FileDocumentPresentationText.name
            field.accessibilityLabel = FileDocumentPresentationText.name
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocorrectionType = .no
        }
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let alert else { return }
                self?.cancelAlert(alert, page: id, ownership: ownership)
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.save, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, self.generation == id, !self.isBusy,
                    ownership.canUse(alert, allowingDismissal: true), alert.presentedViewController == nil,
                    let name = alert.textFields?.first?.text
                else { return }
                ownership.stopObserving()
                self.generation = UUID()
                self.perform(ownership: ownership, dismissing: alert) {
                    [store = self.store, directory = self.directory] in
                    if let source {
                        try await store.rename(source, to: name)
                    } else {
                        try await store.createFolder(named: name, in: directory)
                    }
                }
            })
        presentAlert(alert, ownership: ownership)
    }

    private func confirmDelete(_ source: URL) {
        guard !isBusy, let ownership = LocalBookImportOwnership(owner: self) else { return }
        let id = generation
        let alert = UIAlertController(
            title: FileDocumentPresentationText.deleteFile,
            message: FileDocumentPresentationText.deleteMessage(source.lastPathComponent), preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let alert else { return }
                self?.cancelAlert(alert, page: id, ownership: ownership)
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.delete, style: .destructive) { [weak self, weak alert] _ in
                guard let self, let alert, self.generation == id, !self.isBusy,
                    ownership.canUse(alert, allowingDismissal: true), alert.presentedViewController == nil
                else { return }
                ownership.stopObserving()
                self.generation = UUID()
                self.perform(ownership: ownership, dismissing: alert) { [store = self.store] in
                    try await store.remove(source)
                }
            })
        presentAlert(alert, ownership: ownership)
    }

    private func presentAlert(_ alert: UIAlertController, ownership: LocalBookImportOwnership) {
        ownership.bind(alert)
        ownership.onCheck = { [weak alert, weak ownership] in
            if alert?.presentedViewController != nil { ownership?.invalidate() }
        }
        ownership.observe { [weak self, weak alert] in
            guard let self, self.nameAlert === alert else { return }
            self.generation = UUID()
            alert?.textFields?.forEach {
                $0.text = nil
                $0.resignFirstResponder()
            }
            alert?.dismiss(animated: false)
            self.nameAlert = nil
        }
        nameAlert = alert
        present(alert, animated: true)
    }

    private func cancelAlert(_ alert: UIAlertController, page: UUID, ownership: LocalBookImportOwnership) {
        guard generation == page, nameAlert === alert, operation == nil else { return }
        generation = UUID()
        ownership.stopObserving()
        nameAlert = nil
        operation = Task { [self] in
            await LocalBookImportOwnership.dismiss(alert)
            operation = nil
            updateActions()
            reload()
        }
        updateActions()
    }

    private func pickFile() {
        guard !isBusy, let ownership = LocalBookImportOwnership(owner: self) else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.picker = picker
        pickerOwnership = ownership
        ownership.bind(picker)
        ownership.observe { [weak self, weak picker] in
            guard let self, let picker, self.picker === picker else { return }
            self.finishPicker(picker, url: nil)
        }
        present(picker, animated: true) { [weak self, weak picker] in
            guard let self, let picker, self.picker === picker else { return }
            do { try ownership.acknowledgePresentation(picker) } catch { self.finishPicker(picker, url: nil) }
        }
        updateActions()
    }

    private func scanBooks() {
        guard !isBusy, isVisible,
            canPerformNavigationAction, presentedViewController == nil,
            UIApplication.shared.applicationState == .active,
            view.window.map({ AppLockManager.shared.isUnlocked(in: $0) }) == true
        else { return }
        search.isActive = false
        let id = UUID()
        let page = generation
        let importer = LocalBookDirectoryImportCoordinator(presenter: self)
        importer.onBatchCompleted = { [weak self] summary in
            guard let self, self.directoryImportID == id, self.generation == page,
                self.canPerformNavigationAction, AppLockManager.shared.isUnlocked(in: self.viewIfLoaded?.window)
            else { return }
            LocalBookImportResultViewController(summary: summary).present(from: self)
        }
        importer.onFinished = { [weak self] in
            guard let self, self.directoryImportID == id else { return }
            self.directoryImportID = nil
            self.directoryImporter = nil
            self.updateActions()
            self.reload()
        }
        directoryImportID = id
        directoryImporter = importer
        importer.start(root: directory)
        updateActions()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicker(controller, url: nil)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicker(controller, url: urls.first)
    }

    private func finishPicker(_ controller: UIDocumentPickerViewController, url: URL?) {
        guard picker === controller, let ownership = pickerOwnership, operation == nil else { return }
        // Acquire the incoming scope synchronously, before the provider delegate returns.
        let lease = url.map(SandboxFileReadLease.init)
        picker = nil
        pickerOwnership = nil
        operation = Task { [self, store, directory] in
            defer {
                lease?.cancel()
                ownership.stopObserving()
                operation = nil
                updateActions()
                reload()
            }
            await LocalBookImportOwnership.dismiss(controller)
            ownership.bind(nil)
            guard let lease else { return }
            do {
                try await ownership.waitUntilReady()
                guard ownership.canPresent else { return }
                // Do not cancel/release this slot until the store acknowledges the actual copy result.
                _ = try await store.importFile(lease, into: directory)
            } catch {
                if !(error is CancellationError), ownership.canPresent {
                    showTransientMessage(FileDocumentPresentationText.message(for: error))
                }
            }
        }
        navigationItem.prompt = FileDocumentPresentationText.working
        updateActions()
    }

    private func perform(
        ownership suppliedOwnership: LocalBookImportOwnership? = nil, dismissing alert: UIAlertController? = nil,
        _ action: @escaping @MainActor () async throws -> Void
    ) {
        guard !isBusy, let ownership = suppliedOwnership ?? LocalBookImportOwnership(owner: self) else { return }
        let page = generation
        refreshID = UUID()
        loadTask?.cancel()
        loadTask = nil
        operation = Task { [self] in
            defer {
                operation = nil
                updateActions()
                reload()
            }
            if let alert {
                await LocalBookImportOwnership.dismiss(alert)
                ownership.bind(nil)
            }
            guard generation == page, ownership.canPresent else { return }
            do { try await action() } catch {
                if generation == page, ownership.canPresent {
                    showTransientMessage(FileDocumentPresentationText.message(for: error))
                }
            }
        }
        navigationItem.prompt = FileDocumentPresentationText.working
        updateActions()
    }
}
