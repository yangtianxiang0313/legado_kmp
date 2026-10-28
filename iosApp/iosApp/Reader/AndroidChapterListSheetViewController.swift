import UIKit
import shared

class AndroidChapterListSheetViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UITextFieldDelegate, UIGestureRecognizerDelegate, BookmarkListDelegate
{
    private static let cellIdentifier = "ReaderTocChapterCell"
    private static let reverseLoadingMessage = "正在反转目录"

    private var items: [ReaderChapterListItem]
    private var pendingTitleItems: [ReaderChapterListItem]?
    private var needsWordCountReload = false
    private var filteredIndices: [Int] = []
    private var itemsRevision = UUID()
    private struct ChapterTitleRequest {
        weak var cell: ReaderTocChapterCell?
        let item: ReaderChapterListItem
        let revision: UUID
    }
    private var pendingChapterTitle: ChapterTitleRequest?
    private lazy var chapterLongPress = UILongPressGestureRecognizer(
        target: self, action: #selector(showLongPressedChapterTitle(_:)))
    private var operationTask: Task<Void, Never>?
    private var operationRequestID: UUID?
    private var isReversing = false
    private var isFastScrolling = false
    private var canEditSearch: Bool { !isClosing && !isReversing && !isFastScrolling }
    private var canUseControls: Bool { canEditSearch && !tabPager.isTransitioning }
    private var canApplyChapterUpdates: Bool {
        canUseControls && canUpdateChapterList && !tableView.isDragging && !tableView.isDecelerating
    }
    private var isClosing = false
    private var selectedTab: ReaderTocTabPagerViewController.Tab { tabPager.selectedTab }
    private var isSearchExpanded = false
    private var chapterSearchQuery = ""
    private var didLocateInitialChapter = false
    private var needsLocateAfterReversal = false
    private var bookmarkController: BookmarkListViewController?
    private weak var readerContainer: ReaderContainerViewController?
    private let standaloneBook: Book?
    private let standaloneBookURL: String?
    private weak var bookmarkProvider: ReaderBookmarkListProviding?
    private let menuCoordinator: ReaderChapterListMenuCoordinator
    private lazy var liveState: ReaderTocLiveStateCoordinator? = makeLiveState()
    private var liveSnapshot: ReaderTocLiveStateCoordinator.Snapshot?
    private var chapterState: ReaderTocChapterState
    private let bookmarkExportCoordinator = ReaderTocBookmarkExportCoordinator()
    private let onSelect: (Int) -> Void
    private let onSelectPosition: ((Int, Int) -> Void)?
    private let onReverse: (() async throws -> [ReaderChapterListItem])?

    private let titleBackground = UIView()
    private lazy var toolbar = ReaderTocToolbarView(tabsView: tabPager.tabsView)
    private var moreButton: UIButton { toolbar.moreButton }
    private var searchField: UITextField { toolbar.searchField }
    private let chapterPage = ReaderTocChapterPageViewController()
    private lazy var tabPager = ReaderTocTabPagerViewController(chapters: chapterPage)
    private var tableView: UITableView { chapterPage.tableView }
    private var emptyLabel: UILabel { chapterPage.emptyLabel }
    private var palette: ReaderTocPalette { ReaderTocPalette(traits: traitCollection) }

    init(
        items: [ReaderChapterListItem],
        readerContainer: ReaderContainerViewController? = nil,
        book: Book? = nil,
        bookURL: String? = nil,
        bookmarkProvider: ReaderBookmarkListProviding? = nil,
        onSelect: @escaping (Int) -> Void,
        onSelectPosition: ((Int, Int) -> Void)? = nil,
        onRefresh _: (() async throws -> [ReaderChapterListItem])?,
        onReverse: (() async throws -> [ReaderChapterListItem])? = nil,
        onReloadTitles: (() async throws -> [ReaderChapterListItem])? = nil,
        onShowLogs: ((UIViewController) -> Void)? = nil
    ) {
        self.items = items
        self.readerContainer = readerContainer
        standaloneBook = book
        standaloneBookURL = bookURL
        self.bookmarkProvider = bookmarkProvider
        chapterState = ReaderTocChapterState(items: items, book: readerContainer?.book ?? book)
        filteredIndices = Array(items.indices)
        self.onSelect = onSelect
        self.onSelectPosition = onSelectPosition
        self.onReverse = onReverse
        menuCoordinator = ReaderChapterListMenuCoordinator(
            initialRuntimeConfig: readerContainer?.runtimeConfig,
            onReloadTitles: onReloadTitles,
            onShowLogs: onShowLogs)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        operationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Reader.chapterListTitle
        menuCoordinator.canUpdate = { [weak self] in
            guard let self else { return false }
            return self.canUpdateChapterList && !self.isReversing
        }
        menuCoordinator.onTitlesReloaded = { [weak self] items in
            guard let self else { return }
            if let liveState = self.liveState {
                liveState.reload()
                return
            }
            if !self.canApplyChapterUpdates {
                self.pendingTitleItems = items
            } else {
                self.applyReloadedTitles(items)
            }
        }
        menuCoordinator.onWordCountChanged = { [weak self] in
            guard let self else { return }
            guard self.canApplyChapterUpdates else {
                self.needsWordCountReload = true
                return
            }
            self.needsWordCountReload = false
            self.preservingVisibleChapter { self.tableView.reloadData() }
        }
        menuCoordinator.onMessage = { [weak self] message in self?.showTransientMessage(message) }
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeSceneUpdates(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteDidChange), name: .androidReplicaThemeDidChange, object: nil)
        applyPalette()
        applyFilter()
        updateSelectedTab()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(palette.titleBackground) ? .darkContent : .lightContent
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        toolbar.updateLayout(availableSize: view.bounds.size)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isClosing = false
        preservePanelTitle()
        updateOperationControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        liveState?.deactivate()
        menuCoordinator.deactivate()
        cancelChapterListOperationForDeparture()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        menuCoordinator.activate()
        liveState?.activate()
        resumeChapterUpdates()
        if !didLocateInitialChapter {
            didLocateInitialChapter = true
            scrollAfterFilter(animated: false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else { return }
        themePaletteDidChange()
    }

    func updateItems(_ items: [ReaderChapterListItem]) {
        guard isViewLoaded else { self.items = items; return }
        if canApplyChapterUpdates {
            applyReloadedTitles(items)
        } else {
            pendingTitleItems = items
        }
    }

    private func configureViews() {
        tabPager.makeBookmarks = { [weak self] in self?.makeBookmarkPanel() }
        tabPager.onBookmarksUnavailable = { [weak self] in
            self?.showTransientMessage(L10n.Reader.chapterBookmarkUnavailable)
        }
        tabPager.onTransitionBegan = { [weak self] in
            self?.pendingChapterTitle = nil
            self?.needsLocateAfterReversal = false
            self?.menuCoordinator.dismissMenu()
        }
        tabPager.onTransitionStateChanged = { [weak self] in
            guard let self else { return }
            self.updateOperationControls()
            if !self.tabPager.isTransitioning {
                self.collapseUnfocusedEmptySearch()
                self.resumeChapterUpdates()
            }
        }
        tabPager.onSelectionChanged = { [weak self] in self?.updateSelectedTab() }
        chapterPage.onLocateCurrent = { [weak self] in self?.locateCurrentChapter() }
        chapterPage.onScrollToTop = { [weak self] in self?.scrollToTop() }
        chapterPage.onScrollToBottom = { [weak self] in self?.scrollToBottom() }
        chapterPage.onFastScrollStateChange = { [weak self] in self?.setFastScrolling($0) }
        for item in [titleBackground, toolbar] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        configureToolbar()
        configureTableView()
        addChild(tabPager)
        tabPager.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabPager.view)
        NSLayoutConstraint.activate([
            titleBackground.topAnchor.constraint(equalTo: view.topAnchor),
            titleBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tabPager.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tabPager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabPager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabPager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tabPager.didMove(toParent: self)
    }

    private func configureToolbar() {
        toolbar.onBack = { [weak self] in self?.handleBack() }
        toolbar.onSearch = { [weak self] in self?.toggleSearch() }
        toolbar.onMore = { [weak self] in self?.showMoreMenu() }
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
    }

    private func configureTableView() {
        tableView.register(ReaderTocChapterCell.self, forCellReuseIdentifier: Self.cellIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 48
        tableView.bounces = false
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .onDrag
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.insetsContentViewsToSafeArea = false
        tableView.accessibilityIdentifier = UIIdentifiers.ReaderChapterList.table
        chapterLongPress.delegate = self
        tableView.addGestureRecognizer(chapterLongPress)
    }

    private func applyPalette() {
        let colors = palette
        view.backgroundColor = colors.background
        titleBackground.backgroundColor = colors.titleBackground
        toolbar.applyPalette(colors)
        for case let cell as ReaderTocChapterCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell) else { continue }
            configure(cell, at: indexPath)
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func themePaletteDidChange() {
        guard isViewLoaded else { return }
        applyPalette()
    }

    private func applyFilter() {
        itemsRevision = UUID()
        pendingChapterTitle = nil
        chapterState = ReaderTocChapterState(items: items, book: bookmarkBookURL.flatMap { bookContext(for: $0) })
        filteredIndices = chapterState.visibleIndices(in: items, query: chapterSearchQuery)
        updateCurrentChapterInfo()
        // ChapterListFragment leaves the RecyclerView blank for empty data or an unmatched query.
        emptyLabel.text = nil
        emptyLabel.isHidden = true
        tabPager.setBookmarksAvailable(bookmarkBookURL != nil || bookmarkProvider != nil)
        tableView.reloadData()
        chapterPage.reloadFastScroll()
    }

    private func setFastScrolling(_ active: Bool) {
        guard isFastScrolling != active else { return }
        isFastScrolling = active
        tabPager.setFastScrollActive(active)
        if active {
            pendingChapterTitle = nil
            needsLocateAfterReversal = false
            menuCoordinator.dismissMenu()
            view.endEditing(true)
        }
        updateOperationControls()
        if !active { resumeChapterUpdates() }
    }

    private func resumeChapterUpdates() {
        guard canApplyChapterUpdates else { return }
        liveState?.resumeUpdates()
        if let items = pendingTitleItems {
            pendingTitleItems = nil
            applyReloadedTitles(items)
        }
        menuCoordinator.resumeUpdates()
        if needsWordCountReload {
            needsWordCountReload = false
            preservingVisibleChapter { tableView.reloadData() }
            chapterPage.reloadFastScroll()
        }
    }

    private func preservingVisibleChapter(_ updates: () -> Void) {
        let row = tableView.indexPathsForVisibleRows?.min()
        let url = row.flatMap {
            filteredIndices.indices.contains($0.row) ? items[filteredIndices[$0.row]].chapter.url : nil
        }
        let offset = row.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        updates()
        tableView.layoutIfNeeded()
        guard let url, let offset,
            let row = filteredIndices.firstIndex(where: { items[$0].chapter.url == url })
        else { return }
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
            minY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
        let y = tableView.rectForRow(at: IndexPath(row: row, section: 0)).minY - offset
        tableView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
    }

    private func applyReloadedTitles(_ items: [ReaderChapterListItem]) {
        preservingVisibleChapter {
            self.items = items
            applyFilter()
        }
    }

    private func updateCurrentChapterInfo() {
        chapterPage.setCurrentChapterInfo(
            chapterState.currentChapterInfo, canLocate: chapterState.locateRow(visibleCount: filteredIndices.count) != nil,
            hasVisibleChapters: !filteredIndices.isEmpty)
    }

    private func bookContext(for bookURL: String) -> Book? {
        if let liveSnapshot {
            return liveSnapshot.book?.bookUrl == bookURL ? liveSnapshot.book : nil
        }
        if let readerContainer, readerContainer.bookURL == bookURL,
            let book = readerContainer.book, book.bookUrl == bookURL
        {
            return book
        }
        return standaloneBook?.bookUrl == bookURL ? standaloneBook : nil
    }

    private func scrollToCurrentChapter() {
        guard let row = chapterState.locateRow(visibleCount: filteredIndices.count) else {
            showTransientMessage(L10n.Reader.chapterCurrentNotFound)
            return
        }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
    }

    @objc private func toggleSearch() {
        guard canUseControls else { return }
        menuCoordinator.dismissMenu()
        if isSearchExpanded {
            if !(searchField.text ?? "").isEmpty {
                searchField.text = nil
                searchTextChanged()
                searchField.becomeFirstResponder()
            } else {
                collapseSearch()
            }
        } else {
            isSearchExpanded = true
            updateSearchVisibility()
            searchField.becomeFirstResponder()
        }
    }

    private func collapseSearch(restoringChapter: Bool = true) {
        let hadQuery = !(searchField.text ?? "").isEmpty
        isSearchExpanded = false
        searchField.resignFirstResponder()
        searchField.text = nil
        updateSearchVisibility()
        if hadQuery {
            if selectedTab == .bookmarks {
                bookmarkController?.setChapterPanelSearchQuery("")
            } else {
                chapterSearchQuery = ""
                preservingVisibleChapter { applyFilter() }
                if restoringChapter { scrollAfterFilter(animated: false) }
            }
        }
    }

    private func updateSearchVisibility() {
        toolbar.setSearchExpanded(isSearchExpanded)
        toolbar.setSearchHasQuery(!(searchField.text ?? "").isEmpty)
    }

    @objc private func searchTextChanged() {
        guard canEditSearch else { return }
        toolbar.setSearchHasQuery(!(searchField.text ?? "").isEmpty)
        guard searchField.markedTextRange == nil else { return }
        needsLocateAfterReversal = false
        if selectedTab == .bookmarks {
            bookmarkController?.setChapterPanelSearchQuery(searchField.text ?? "")
        } else {
            chapterSearchQuery = searchField.text ?? ""
            applyFilter()
            scrollAfterFilter(animated: false)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_: UITextField) {
        collapseUnfocusedEmptySearch()
    }

    private func collapseUnfocusedEmptySearch() {
        guard isSearchExpanded, canUseControls, !searchField.isFirstResponder,
            (searchField.text ?? "").isEmpty
        else { return }
        // UIKit IME dismissal ends editing; keep nonempty submitted/drag-dismissed queries.
        collapseSearch(restoringChapter: false)
    }

    @objc private func handleBack() {
        guard canUseControls else { return }
        // book_toc uses a regular actionView: toolbar home finishes even while SearchView is expanded.
        closePanel()
    }

    private func closePanel(completion: @escaping () -> Void = {}) {
        view.endEditing(true)
        cancelChapterListOperationForDeparture()
        ChapterListNavigation.close(self, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        if isReversing {
            showTransientMessage(Self.reverseLoadingMessage)
            return true
        }
        if menuCoordinator.hasPresentedMenu { menuCoordinator.dismissMenu() } else { handleBack() }
        return true
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        filteredIndices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath) as! ReaderTocChapterCell
        configure(cell, at: indexPath)
        return cell
    }

    private func configure(_ cell: ReaderTocChapterCell, at indexPath: IndexPath) {
        guard filteredIndices.indices.contains(indexPath.row) else { return }
        let item = items[filteredIndices[indexPath.row]]
        let request = ChapterTitleRequest(cell: cell, item: item, revision: itemsRevision)
        cell.configure(
            item: item, palette: palette, showWordCount: menuCoordinator.showWordCount,
            onShowFullTitle: { [weak self] in self?.showFullChapterTitle(request) ?? false })
        cell.accessibilityIdentifier = UIIdentifiers.ReaderChapterList.cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canUseControls, filteredIndices.indices.contains(indexPath.row) else { return }
        let item = items[filteredIndices[indexPath.row]]
        selectChapter(item)
    }

    private func selectChapter(_ item: ReaderChapterListItem) {
        guard canUseControls else { return }
        // Keep the current chapter callback so the presenter can preserve its reading position.
        closePanel { [onSelect] in onSelect(Int(item.chapter.index)) }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === chapterLongPress else { return true }
        pendingChapterTitle = nil
        guard canUseControls, selectedTab == .chapters,
            let row = tableView.indexPathForRow(at: touch.location(in: tableView)),
            filteredIndices.indices.contains(row.row),
            let cell = tableView.cellForRow(at: row) as? ReaderTocChapterCell
        else { return false }
        pendingChapterTitle = ChapterTitleRequest(
            cell: cell, item: items[filteredIndices[row.row]], revision: itemsRevision)
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === chapterLongPress else { return true }
        return pendingChapterTitle.map(isCurrentChapterTitleRequest) ?? false
    }

    private func isCurrentChapterTitleRequest(_ request: ChapterTitleRequest) -> Bool {
        guard canUseControls, canUpdateChapterList, !isBeingPresented,
            presentedViewController == nil, !menuCoordinator.hasPresentedMenu,
            selectedTab == .chapters, itemsRevision == request.revision,
            let cell = request.cell, let row = tableView.indexPath(for: cell),
            filteredIndices.indices.contains(row.row)
        else { return false }
        return items[filteredIndices[row.row]] === request.item
    }

    @discardableResult
    private func showFullChapterTitle(_ request: ChapterTitleRequest) -> Bool {
        guard isCurrentChapterTitleRequest(request) else { return false }
        showTransientMessage(request.item.displayTitle, duration: 3.5)
        UIAccessibility.post(notification: .announcement, argument: request.item.displayTitle)
        return true
    }

    @objc private func showLongPressedChapterTitle(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began, let request = pendingChapterTitle {
            showFullChapterTitle(request)
        }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
            pendingChapterTitle = nil
        }
    }

    @objc private func scrollToTop() {
        guard canUseControls, !filteredIndices.isEmpty else { return }
        needsLocateAfterReversal = false
        searchField.resignFirstResponder()
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        resumeChapterUpdates()
    }

    @objc private func scrollToBottom() {
        guard canUseControls, !filteredIndices.isEmpty else { return }
        needsLocateAfterReversal = false
        searchField.resignFirstResponder()
        tableView.scrollToRow(at: IndexPath(row: filteredIndices.count - 1, section: 0), at: .top, animated: false)
        resumeChapterUpdates()
    }

    @objc private func locateCurrentChapter() {
        guard canUseControls else { return }
        needsLocateAfterReversal = false
        searchField.resignFirstResponder()
        scrollToCurrentChapter()
        resumeChapterUpdates()
    }

    @objc private func showMoreMenu() {
        guard canUseControls else { return }
        view.endEditing(true)
        menuCoordinator.presentMenu(
            in: self, anchorView: moreButton, showingChapters: selectedTab == .chapters,
            canReverse: onReverse != nil && !items.isEmpty && !isReversing,
            onExportBookmarks: { [weak self] markdown in self?.exportBookmarks(markdown: markdown) },
            onReverse: { [weak self] in self?.reverseOrder() })
    }

    private func exportBookmarks(markdown: Bool) {
        guard canUseControls,
            let bookURL = bookmarkBookURL,
            let book = bookContext(for: bookURL)
        else { return }
        bookmarkExportCoordinator.presentExport(
            markdown: markdown, screen: StandaloneReaderBookmarkListAdapter(bookURL: book.bookUrl),
            bookName: book.name, bookAuthor: book.author, in: self, anchor: moreButton)
    }

    private func reverseOrder() {
        guard canUseControls, canUpdateChapterList, selectedTab == .chapters, !items.isEmpty,
            !isReversing, !menuCoordinator.isUpdating, let onReverse
        else { return }
        let requestID = UUID()
        operationRequestID = requestID
        isReversing = true
        menuCoordinator.dismissMenu()
        view.endEditing(true)
        updateOperationControls()
        showTransientMessage(Self.reverseLoadingMessage)
        operationTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.operationRequestID == requestID {
                    self.operationTask = nil
                    self.operationRequestID = nil
                    self.isReversing = false
                    self.updateOperationControls()
                    self.resumeChapterUpdates()
                }
            }
            do {
                try Task.checkCancellation()
                // A committed reversal must rebind the reader inside onReverse, even after cancellation.
                let updated = try await onReverse()
                guard !Task.isCancelled, let self, self.operationRequestID == requestID,
                    self.canUpdateChapterList
                else { return }
                self.items = updated
                self.chapterSearchQuery = self.searchField.text ?? ""
                self.applyFilter()
                if let liveState = self.liveState {
                    self.needsLocateAfterReversal = true
                    liveState.reload()
                } else {
                    self.scrollAfterFilter(animated: false)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                    let self, self.operationRequestID == requestID, self.canUpdateChapterList
                else { return }
                self.showTransientMessage("反转目录失败: \(error.userFacingMessage)")
            }
        }
    }

    private var canUpdateChapterList: Bool {
        !isClosing && !isBeingDismissed && !isMovingFromParent
            && navigationController?.isBeingDismissed != true && viewIfLoaded?.window != nil
    }

    private func makeLiveState() -> ReaderTocLiveStateCoordinator? {
        guard let bookURL = bookmarkBookURL ?? standaloneBook?.bookUrl ?? readerContainer?.bookURL else { return nil }
        let state = ReaderTocLiveStateCoordinator.forBook(bookURL)
        state.canApply = { [weak self] in
            guard let self else { return false }
            return self.canApplyChapterUpdates && self.presentedViewController == nil
                && UIApplication.shared.applicationState == .active
                && self.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        }
        state.onSnapshot = { [weak self] in self?.applyLiveSnapshot($0) }
        state.onError = { error in SharedRuntime.log("TOC state reload failed: \(error.userFacingMessage)") }
        return state
    }

    private func applyLiveSnapshot(_ snapshot: ReaderTocLiveStateCoordinator.Snapshot) {
        liveSnapshot = snapshot
        defer {
            if needsLocateAfterReversal {
                needsLocateAfterReversal = false
                scrollAfterFilter(animated: false)
            }
        }
        let updated = snapshot.items
        let updatedState = ReaderTocChapterState(items: updated, book: snapshot.book)
        guard
            updatedState != chapterState || updated.count != items.count
                || !zip(items, updated).allSatisfy({ ReaderTocChapterPolicy.samePresentation($0, $1) })
        else { return }
        let onlyFlagsChanged =
            updatedState == chapterState && updated.count == items.count
            && zip(items, updated).allSatisfy {
                ReaderTocChapterPolicy.sameRow($0, $1)
            }
        if onlyFlagsChanged {
            items = zip(items, updated).map { ReaderTocChapterPolicy.samePresentation($0, $1) ? $0 : $1 }
            pendingChapterTitle = nil
            // Cache/check icons do not change row geometry or replace a live scroll view.
            for row in tableView.indexPathsForVisibleRows ?? [] {
                guard let cell = tableView.cellForRow(at: row) as? ReaderTocChapterCell else { continue }
                configure(cell, at: row)
            }
            updateCurrentChapterInfo()
        } else {
            applyReloadedTitles(updated)
        }
        bookmarkController?.chapterPanelCurrentChapterIndex = chapterState.currentChapterIndex ?? 0
    }

    func scrollViewWillBeginDragging(_: UIScrollView) { needsLocateAfterReversal = false }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resumeChapterUpdates() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { resumeChapterUpdates() }

    @objc private func resumeSceneUpdates(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        liveState?.reload()
        resumeChapterUpdates()
    }

    private func updateOperationControls() {
        if !canUseControls { pendingChapterTitle = nil }
        let canFastScroll = !isClosing && !isReversing && !tabPager.isTransitioning
        tabPager.setControlsEnabled(!isClosing && !isReversing && !isFastScrolling)
        toolbar.setControlsEnabled(canUseControls, searchEnabled: canEditSearch)
        chapterPage.setControlsEnabled(canUseControls)
        chapterPage.setFastScrollEnabled(canFastScroll)
        bookmarkController?.chapterPanelActionsEnabled = canUseControls
        bookmarkController?.chapterPanelFastScrollEnabled = canFastScroll
        isModalInPresentation = isReversing || isFastScrolling || tabPager.isTransitioning
    }

    private func cancelChapterListOperationForDeparture() {
        isClosing = true
        liveState?.deactivate()
        chapterPage.cancelFastScrolling()
        bookmarkController?.cancelFastScrolling()
        pendingTitleItems = nil
        bookmarkExportCoordinator.cancel()
        // A shared reversal can still commit after cancellation; keep its flight until it settles.
        operationTask?.cancel()
        updateOperationControls()
    }

    private func scrollAfterFilter(animated: Bool) {
        let currentIndex = chapterState.currentChapterIndex ?? 0
        guard
            let row = ReaderTocChapterPolicy.initialScrollRow(
                in: items, visibleIndices: filteredIndices, currentChapterIndex: currentIndex)
        else { return }
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: animated)
    }

    @objc private func showChapters() {
        guard canUseControls else { return }
        tabPager.select(.chapters)
    }

    private func updateSelectedTab() {
        menuCoordinator.dismissMenu()
        // TocActivity only routes query changes to the selected fragment; swiping keeps both snapshots.
        preservePanelTitle()
        updateOperationControls()
    }

    private func preservePanelTitle() {
        title = L10n.Reader.chapterListTitle
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
    }

    private var bookmarkBookURL: String? {
        items.lazy.map { $0.chapter.bookUrl }
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            ?? [standaloneBook?.bookUrl, standaloneBookURL, readerContainer?.bookURL].compactMap { $0 }
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private func makeBookmarkPanel() -> BookmarkListViewController? {
        if let bookmarkController { return bookmarkController }
        guard canUseControls else { return nil }
        let screen: ReaderBookmarkListProviding
        if let bookmarkProvider {
            screen = bookmarkProvider
        } else if let bookURL = bookmarkBookURL {
            screen = StandaloneReaderBookmarkListAdapter(bookURL: bookURL)
        } else {
            return nil
        }
        let controller = BookmarkListViewController(screen: screen)
        controller.delegate = self
        controller.isEmbeddedInChapterPanel = true
        controller.onFastScrollStateChange = { [weak self] in self?.setFastScrolling($0) }
        controller.chapterPanelCurrentChapterIndex = chapterState.currentChapterIndex ?? 0
        controller.onBackOverride = { [weak self] in self?.showChapters() }
        bookmarkController = controller
        return controller
    }

    func bookmarkList(_: BookmarkListViewController, didSelectChapterIndex index: Int, position: Int) {
        guard canUseControls else { return }
        closePanel { [weak readerContainer, onSelect, onSelectPosition] in
            if let readerContainer {
                readerContainer.loadChapter(index: index, restorePosition: max(position, 0))
            } else if let onSelectPosition {
                onSelectPosition(index, position)
            } else {
                onSelect(index)
            }
        }
    }
}
