import UIKit
import shared

final class AndroidReplicaBookshelfViewController: UIViewController {
    let screen = BookshelfScreenAdapter()
    lazy var localBookImport = BookshelfLocalImport(presenter: self, screen: screen)
    lazy var bookshelfTransfer = BookshelfTransferCoordinator(presenter: self, screen: screen)
    private let header = AndroidBookshelfHeaderView()
    private let folderHeader = BookshelfFolderHeaderView()
    private let folderPage = BookshelfFolderViewController()
    private var usesFolders: Bool { preferences?.bookGroupStyle == 1 }
    var bookshelfMoreAnchor: UIView { usesFolders ? folderHeader.moreAnchor : header.moreAnchor }

    func refreshBookshelfPresentationForMenu() {
        folderPage.refreshPresentation()
        if bookshelfOverflowMenu?.superview != nil {
            groupPager.currentPage?.suspendPresentation()
        } else {
            groupPager.currentPage?.resumePresentation()
        }
    }
    weak var bookshelfOverflowMenu: ReaderOverflowMenuView?
    private let groupPager = BookshelfGroupPagerViewController()
    private var groups: [BookGroup] = []
    private var selectedGroupId = BookshelfScreenAdapter.allGroupId
    private var displayedFolderMode = false
    private var isFolderSnapshotReady = false
    private var updateObserver: UUID?
    private var lastUpdateRevision: UInt64 = 0
    private var updateReloadScheduled = false
    private var openTask: Task<Void, Never>?
    private var openGeneration = UUID()
    private var folderLoadTask: Task<Void, Never>?
    private var folderLoadID = UUID()
    private var refreshingBookURLs: Set<String> = []
    private lazy var groupEditing = BookshelfGroupEditingCoordinator(presenter: self, screen: screen) { [weak self] in
        self?.reloadGroupPages()
    }
    var books: [Book] = []
    var selectedBookshelfSort: Int32?
    var layoutMode: BookshelfLayoutMode = .list {
        didSet { updatePageAppearance() }
    }
    var preferences: AppUiPreferences? {
        didSet { updatePageAppearance() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        BookshelfRootView.statusBarStyle(for: traitCollection)
    }

    override func loadView() {
        view = BookshelfRootView(header: header, folderHeader: folderHeader)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        bindScreen()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshThemeColors), name: .androidReplicaThemeDidChange, object: nil)
        refreshThemeColors()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshThemeColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) ?? true {
            refreshThemeColors()
        }
    }

    @objc private func refreshThemeColors() {
        guard let root = viewIfLoaded as? BookshelfRootView else { return }
        root.refreshColors()
        // The navigation container owns status-bar style on the main screen.
        var owner: UIViewController? = self
        while let controller = owner {
            controller.setNeedsStatusBarAppearanceUpdate()
            owner = controller.parent
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let updateObserver {
            Task { @MainActor in BookshelfUpdateCoordinator.shared.removeObserver(updateObserver) }
        }
        openTask?.cancel()
        folderLoadTask?.cancel()
        screen.unbind()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        openGeneration = UUID()
        openTask?.cancel()
        openTask = nil
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        bookshelfOverflowMenu?.dismiss()
        header.resetTransition()
        groupEditing.cancelPreparation()
    }

    private func configureViews() {
        header.onSearch = { [weak self] in self?.openSearch() }
        header.onMore = { [weak self] in self?.showBookshelfMoreMenu() }
        header.onSelectGroup = { [weak self] id in
            guard let self, !self.usesFolders else { return }
            self.groupPager.selectGroup(id)
        }
        header.onEditGroup = { [weak self] id in self?.groupEditing.edit(groupID: id) }
        folderHeader.onBack = { [weak self] in self?.returnToFolderRoot() }
        folderHeader.onSearch = { [weak self] in self?.openSearch() }
        folderHeader.onMore = { [weak self] in self?.showBookshelfMoreMenu() }
        folderPage.onOpen = { [weak self] book in self?.openBookFromBookshelf(book) }
        folderPage.onDetails = { [weak self] book in self?.showBookDetails(book) }
        folderPage.onOpenGroup = { [weak self] id in
            guard let self, self.usesFolders, self.isVisibleInNavigationStack else { return }
            self.screen.selectGroup(id)
        }
        folderPage.onEditGroup = { [weak self] id in self?.groupEditing.edit(groupID: id) }
        folderPage.onRefresh = { [weak self] in self?.refreshBooks() }
        folderPage.onRetry = { [weak self] in self?.reloadFolderBooks() }
        header.onReselectGroup = { [weak self] id in
            guard let self else { return }
            let name =
                self.groups.first(where: { $0.groupId == id || ($0.groupId == 0 && id == -1) })?.groupName
                ?? L10n.Bookshelf.groupFallback
            self.showMessage("\(name)(\(self.books.count))")
        }
        groupPager.loadBooks = { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.screen.loadBooks(groupId: id)
        }
        groupPager.onSelectGroup = { [weak self] id in
            guard let self, !self.usesFolders else { return }
            self.selectedGroupId = id
            self.books = self.groupPager.currentPage?.books ?? []
            self.renderHeader()
            self.screen.selectGroup(id)
        }
        groupPager.onOpen = { [weak self] book in self?.openBookFromBookshelf(book) }
        groupPager.onTransitionProgress = { [weak self] from, to, fraction, animated in
            self?.header.setTransition(from: from, to: to, fraction: fraction, animated: animated)
        }
        groupPager.onTransitionSettled = { [weak self] in self?.header.resetTransition() }
        groupPager.onDetails = { [weak self] book in self?.showBookDetails(book) }
        groupPager.onRefresh = { [weak self] id in
            guard let self, !self.usesFolders, self.screen.currentSelectedGroupId == id else { return }
            self.refreshBooks()
        }

        let container = (view as! BookshelfRootView).contentContainer
        for child in [groupPager, folderPage] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(child.view)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: container.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            child.didMove(toParent: self)
        }
        updatePageAppearance()
        renderHeader()
        updateObserver = BookshelfUpdateCoordinator.shared.observe { [weak self] snapshot in
            self?.applyUpdateSnapshot(snapshot)
        }
    }

    private func bindScreen() {
        screen.onGroupsChange = { [weak self] groups, selectedGroupId in
            guard let self else { return }
            let selectionChanged = self.selectedGroupId != selectedGroupId
            let modeChanged = self.displayedFolderMode != self.usesFolders
            self.displayedFolderMode = self.usesFolders
            self.groups = groups.filter { $0.show }
            self.selectedGroupId = selectedGroupId
            if self.usesFolders {
                if selectionChanged {
                    self.books = []
                    self.isFolderSnapshotReady = false
                }
                self.renderFolder()
                if selectionChanged { self.reloadFolderBooks() }
            } else {
                self.groupPager.configure(groups: self.groups, selectedGroupId: selectedGroupId)
                if modeChanged, !selectionChanged {
                    self.groupPager.render(books: self.books, groupId: selectedGroupId)
                } else {
                    self.books = self.groupPager.currentPage?.books ?? []
                }
            }
            self.renderHeader()
        }
        screen.onBooksChange = { [weak self] books in
            guard let self else { return }
            self.folderLoadID = UUID()
            self.folderLoadTask?.cancel()
            self.folderLoadTask = nil
            self.books = books
            self.isFolderSnapshotReady = true
            self.updateEmptyState()
        }
        screen.onLayoutModeChange = { [weak self] mode in self?.layoutMode = mode }
        screen.onPreferencesChange = { [weak self] preferences in self?.preferences = preferences }
        if case .failure(let error) = screen.bootstrap() { showMessage(error.message) }
    }

    private func renderHeader() {
        folderHeader.configure(
            groupName: selectedGroupId == BookshelfScreenAdapter.rootGroupId
                ? nil : groups.first(where: { $0.groupId == selectedGroupId })?.groupName)
        header.configure(
            groups: groups.map {
                AndroidBookshelfHeaderGroup(
                    id: $0.groupId == 0 ? BookshelfScreenAdapter.allGroupId : $0.groupId, title: $0.groupName)
            }, selectedGroupId: selectedGroupId)
    }

    private func updatePageAppearance() {
        guard isViewLoaded else { return }
        (view as? BookshelfRootView)?.setFolderMode(usesFolders)
        groupPager.view.isHidden = usesFolders
        groupPager.view.accessibilityElementsHidden = usesFolders
        folderPage.view.isHidden = !usesFolders
        folderPage.view.accessibilityElementsHidden = !usesFolders
        folderPage.configure(
            layoutMode: layoutMode, preferences: preferences, canRefresh: screen.canRefreshSelectedGroup)
        groupPager.configureAppearance(layoutMode: layoutMode, preferences: preferences)
    }

    func updateEmptyState() {
        if usesFolders {
            renderFolder()
        } else {
            groupPager.render(books: books, groupId: screen.currentSelectedGroupId)
        }
    }

    func reloadGroupPages() {
        if usesFolders { reloadFolderBooks() } else { groupPager.reloadCachedPages() }
    }

    private func renderFolder() {
        folderPage.configure(
            layoutMode: layoutMode, preferences: preferences, canRefresh: screen.canRefreshSelectedGroup)
        if isFolderSnapshotReady {
            folderPage.render(groups: groups, books: books, groupID: selectedGroupId)
        } else {
            folderPage.prepare(groups: groups, groupID: selectedGroupId)
        }
        folderPage.setRefreshing(bookURLs: refreshingBookURLs, isRefreshing: false)
    }

    private func reloadFolderBooks() {
        guard usesFolders else { return }
        folderLoadTask?.cancel()
        let id = UUID()
        let groupID = screen.currentSelectedGroupId
        folderLoadID = id
        folderPage.showLoading()
        folderLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let books = try await self.screen.loadBooks(groupId: groupID)
                try Task.checkCancellation()
                guard self.folderLoadID == id, self.usesFolders,
                    self.screen.currentSelectedGroupId == groupID
                else { return }
                self.books = books
                self.isFolderSnapshotReady = true
                self.renderFolder()
            } catch {
                guard !Task.isCancelled, self.folderLoadID == id, self.usesFolders else { return }
                self.folderPage.showFailure(error.userFacingMessage)
            }
            if self.folderLoadID == id { self.folderLoadTask = nil }
        }
    }

    @discardableResult
    private func returnToFolderRoot() -> Bool {
        guard usesFolders, selectedGroupId != BookshelfScreenAdapter.rootGroupId,
            isVisibleInNavigationStack, presentedViewController == nil
        else { return false }
        screen.selectGroup(BookshelfScreenAdapter.rootGroupId)
        return true
    }

    override func accessibilityPerformEscape() -> Bool { returnToFolderRoot() }

    override var keyCommands: [UIKeyCommand]? {
        guard usesFolders, selectedGroupId != BookshelfScreenAdapter.rootGroupId else {
            return super.keyCommands
        }
        let back = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleFolderBack))
        back.discoverabilityTitle = L10n.Reader.backAction
        back.wantsPriorityOverSystemBehavior = true
        return [back]
    }

    @objc private func handleFolderBack() { returnToFolderRoot() }

    func applyLocalBookImport(_ book: Book, refreshedBooks: [Book]) {
        books = refreshedBooks
        updateEmptyState()
        if !books.contains(where: { $0.bookUrl == book.bookUrl }),
            selectedGroupId != BookshelfScreenAdapter.allGroupId
        {
            screen.selectGroup(BookshelfScreenAdapter.allGroupId)
        }
        reloadGroupPages()
    }

    @objc func refreshBooks() {
        guard isVisibleInNavigationStack else { return }
        do {
            try BookshelfUpdateCoordinator.shared.enqueue(books: books)
        } catch {
            showMessage(error.userFacingMessage)
        }
        applyUpdateSnapshot(BookshelfUpdateCoordinator.shared.snapshot)
    }

    private func applyUpdateSnapshot(_ snapshot: BookshelfUpdateCoordinator.Snapshot) {
        refreshingBookURLs = snapshot.activeURLs
        groupPager.setRefreshing(groupId: nil, bookURLs: snapshot.activeURLs)
        folderPage.setRefreshing(bookURLs: snapshot.activeURLs, isRefreshing: false)
        guard lastUpdateRevision != snapshot.completionRevision else { return }
        lastUpdateRevision = snapshot.completionRevision
        guard !updateReloadScheduled else { return }
        updateReloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateReloadScheduled = false
            self.reloadGroupPages()
        }
    }

    private func showBookDetails(_ book: Book) {
        guard canPerformNavigationAction else { return }
        navigationController?.pushViewController(
            AndroidReplicaBookDetailViewController(bookURL: book.bookUrl), animated: true)
    }

    private func openSearch() {
        guard canPerformNavigationAction else { return }
        navigationController?.pushViewController(AndroidReplicaSearchViewController(), animated: true)
    }

    func showMessage(_ message: String) { showTransientMessage(message) }

    private func openBookFromBookshelf(_ book: Book) {
        guard openTask == nil, canPerformNavigationAction else { return }
        let generation = UUID()
        openGeneration = generation
        let groupId = screen.currentSelectedGroupId
        // An inactive page can retain old metadata. Resume from storage, not that page's snapshot.
        openTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.openGeneration == generation { self.openTask = nil }
            }
            do {
                await BookshelfProgressSyncCoordinator.shared.suspendAndWait()
                try Task.checkCancellation()
                let latestBooks = try await self.screen.loadBooks(groupId: groupId)
                try Task.checkCancellation()
                guard self.openGeneration == generation, self.screen.currentSelectedGroupId == groupId,
                    self.canPerformNavigationAction, self.view.window != nil
                else { return }
                self.books = latestBooks
                self.updateEmptyState()
                guard let latest = latestBooks.first(where: { $0.bookUrl == book.bookUrl }) else {
                    self.showMessage("书籍已不在当前分组")
                    return
                }
                self.presentBook(latest)
            } catch is CancellationError {
            } catch {
                guard self.openGeneration == generation, self.canPerformNavigationAction else {
                    return
                }
                self.showMessage(error.userFacingMessage)
            }
        }
    }

    private func presentBook(_ book: Book) {
        BookReadingDestination.open(book, from: self)
    }
}
