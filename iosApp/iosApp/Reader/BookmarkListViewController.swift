import UIKit
import shared

final class BookmarkListViewController: UIViewController, UITextFieldDelegate {
    private static let sortModeDefaultsKey = "reader.bookmark.sortMode"

    private var bookmarks: [Bookmark] = []
    private var filteredIndices: [Int] = []
    private var loadErrorMessage: String?
    private lazy var bookmarkObservation: ReaderBookmarkObservationCoordinator = {
        let coordinator = ReaderBookmarkObservationCoordinator(screen: screen)
        coordinator.window = { [weak self] in self?.viewIfLoaded?.window }
        coordinator.canApplySnapshot = { [weak self] in self?.canApplyBookmarkSnapshot == true }
        coordinator.onSnapshot = { [weak self] in self?.receiveBookmarks($0) }
        coordinator.onLoadError = { [weak self] in self?.receiveBookmarkLoadError($0) }
        coordinator.onLoadingChanged = { [weak self] in self?.setLoadingBookmarks($0) }
        return coordinator
    }()
    private var chapterPanelSearchQuery = ""
    private var chapterPanelPendingScrollRow: Int?
    private var chapterPanelNeedsInitialScroll = true
    private var chapterPanelNeedsFilterUpdate = false
    private var sortMode =
        ReaderBookmarkListSortMode(
            rawValue: UserDefaults.standard.integer(forKey: BookmarkListViewController.sortModeDefaultsKey)) ?? .latest
    private lazy var topBar = AndroidReplicaDetailBar(
        title: L10n.Reader.bookmarkListTitle, target: self, backAction: #selector(handleBack))
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var fastScroller: ReaderListFastScroller?
    private lazy var tableAdapter = ReaderBookmarkListTableAdapter(
        bookmarkCount: { [weak self] in self?.filteredIndices.count ?? 0 },
        bookmarkAtRow: { [weak self] in self?.visibleBookmark(at: $0) },
        isEmbedded: { [weak self] in self?.isEmbeddedInChapterPanel ?? false },
        canPerformEmbeddedActions: { [weak self] in self?.canPerformEmbeddedBookmarkActions == true },
        palette: { [weak self] in ReaderTocPalette(traits: self?.traitCollection ?? UITraitCollection()) },
        onSelect: { [weak self] in self?.openBookmark($0) },
        onLegacyAction: { [weak self] action, bookmark in self?.handleBookmarkAction(action, bookmark: bookmark) },
        onStaleBookmark: { [weak self] in self?.showTransientMessage(L10n.Reader.bookmarkStale) },
        onScrollInteractionChanged: { [weak self] in self?.bookmarkScrollInteractionChanged($0) }
    )
    private let emptyView = AndroidBookmarkEmptyView()
    private let searchField = UITextField()
    private let headerSummaryLabel = UILabel()
    private let sortButton = UIButton(type: .system)
    private let exportButton = UIButton(type: .system)
    private let refreshControl = UIRefreshControl()
    weak var delegate: BookmarkListDelegate?
    var onBackOverride: (() -> Void)?
    var onFastScrollStateChange: ((Bool) -> Void)?
    var isEmbeddedInChapterPanel = false
    var chapterPanelActionsEnabled = true {
        didSet {
            tableView.allowsSelection = chapterPanelActionsEnabled
            resumeBookmarkUpdates()
        }
    }
    var chapterPanelFastScrollEnabled = true {
        didSet {
            updateFastScrollAvailability()
            resumeBookmarkUpdates()
        }
    }
    var chapterPanelCurrentChapterIndex = 0
    private let screen: ReaderBookmarkListProviding

    init(screen: ReaderBookmarkListProviding) {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(bookURL: String) {
        self.init(screen: StandaloneReaderBookmarkListAdapter(bookURL: bookURL))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Reader.bookmarkListTitle
        view.backgroundColor = ReaderTocPalette(traits: traitCollection).background
        if !isEmbeddedInChapterPanel {
            navigationController?.setNavigationBarHidden(true, animated: false)
        }
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        refreshPalette()
        if !isEmbeddedInChapterPanel { observeKeyboard() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !isEmbeddedInChapterPanel {
            navigationController?.setNavigationBarHidden(true, animated: animated)
        }
        bookmarkObservation.activate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        bookmarkObservation.activate()
        resumeBookmarkUpdates()
    }

    override func viewWillDisappear(_ animated: Bool) {
        bookmarkObservation.deactivate()
        cancelFastScrolling()
        super.viewWillDisappear(animated)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil, isViewLoaded { bookmarkObservation.deactivate() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isEmbeddedInChapterPanel, canApplyBookmarkSnapshot, tableView.bounds.height > 0,
            let row = chapterPanelPendingScrollRow, filteredIndices.indices.contains(row)
        else { return }
        chapterPanelPendingScrollRow = nil
        tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .top, animated: false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else { return }
        refreshPalette()
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        let palette = ReaderTocPalette(traits: traitCollection)
        view.backgroundColor = palette.background
        tableView.backgroundColor = view.backgroundColor
        fastScroller?.apply(accent: palette.accent)
        tableAdapter.refreshPalette()
    }

    func cancelFastScrolling() {
        fastScroller?.cancelScrubbing()
    }

    func setChapterPanelSearchQuery(_ query: String) {
        guard chapterPanelSearchQuery != query else { return }
        chapterPanelSearchQuery = query
        if isEmbeddedInChapterPanel, isViewLoaded { applyFilter() }
    }

    private func configureViews() {
        if isEmbeddedInChapterPanel == false {
            configureTopBar()
            configureSearchField()
            configureSummaryLabel()
        }
        configureTableView()
        configureEmptyView()

        ReaderBookmarkListLayout.install(
            in: view, tableView: tableView, emptyView: emptyView,
            header: isEmbeddedInChapterPanel ? nil : (bar: topBar, search: searchField, summary: headerSummaryLabel))
        configureFastScroller()
    }

    private func configureTopBar() {
        sortButton.setImage(UIImage(systemName: "arrow.up.arrow.down"), for: .normal)
        sortButton.accessibilityLabel = L10n.Reader.bookmarkSortTitle
        sortButton.addTarget(self, action: #selector(handleSort), for: .touchUpInside)
        topBar.addAction(sortButton)
        exportButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        exportButton.accessibilityLabel = L10n.Reader.bookmarkExportTitle
        exportButton.addTarget(self, action: #selector(handleExport), for: .touchUpInside)
        topBar.addAction(exportButton)
    }

    private func configureSearchField() {
        searchField.placeholder = L10n.Reader.bookmarkSearchPlaceholder
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.backgroundColor = AndroidReplicaTheme.menuBackground
        searchField.layer.cornerRadius = 18
        searchField.font = .preferredFont(forTextStyle: .body)
        searchField.adjustsFontForContentSizeCategory = true
        searchField.textColor = AndroidReplicaTheme.primaryText
        searchField.tintColor = AndroidReplicaTheme.accent
        searchField.leftView = paddedIconView(name: "magnifyingglass")
        searchField.leftViewMode = .always
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
    }

    private func configureSummaryLabel() {
        headerSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        headerSummaryLabel.adjustsFontForContentSizeCategory = true
        headerSummaryLabel.textColor = AndroidReplicaTheme.secondaryText
        headerSummaryLabel.numberOfLines = 2
    }

    private func configureTableView() {
        tableView.backgroundColor = view.backgroundColor
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.sectionHeaderTopPadding = 0
        // fragment_bookmark.xml disables overscroll; keep standalone pull-to-refresh.
        tableView.bounces = !isEmbeddedInChapterPanel
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableAdapter.install(on: tableView)
        tableView.accessibilityIdentifier = UIIdentifiers.ReaderBookmarkList.table
        if !isEmbeddedInChapterPanel {
            refreshControl.tintColor = AndroidReplicaTheme.secondaryText
            refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
            tableView.refreshControl = refreshControl
        }
    }

    private func configureEmptyView() {
        emptyView.accessibilityIdentifier = UIIdentifiers.ReaderBookmarkList.emptyLabel
        emptyView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleEmptyViewTap)))
        emptyView.isHidden = true
    }

    private func configureFastScroller() {
        guard isEmbeddedInChapterPanel, let container = tableView.superview else { return }
        let scroller = ReaderListFastScroller(tableView: tableView)
        fastScroller = scroller
        scroller.accessibilityIdentifier = "reader.bookmarks.fastScroll"
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.apply(accent: ReaderTocPalette(traits: traitCollection).accent)
        scroller.onScrubbingChanged = { [weak self] active in
            self?.onFastScrollStateChange?(active)
            self?.bookmarkScrollInteractionChanged(active)
        }
        container.addSubview(scroller)
        NSLayoutConstraint.activate([
            scroller.widthAnchor.constraint(equalToConstant: 24),
            scroller.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            scroller.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 8),
            scroller.bottomAnchor.constraint(equalTo: tableView.bottomAnchor, constant: -8),
        ])
        tableView.showsVerticalScrollIndicator = false
        updateFastScrollAvailability()
    }

    private func updateFastScrollAvailability() {
        guard let fastScroller else { return }
        let enabled =
            isEmbeddedInChapterPanel && chapterPanelFastScrollEnabled && loadErrorMessage == nil
            && !filteredIndices.isEmpty
        if !enabled { fastScroller.cancelScrubbing() }
        fastScroller.isEnabled = enabled
    }

    private func reloadTableData() {
        tableAdapter.reloadData()
        updateEmptyState()
        fastScroller?.reload()
    }

    private func observeKeyboard() {
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleKeyboardFrameChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    private func paddedIconView(name: String) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 38, height: 36))
        let imageView = UIImageView(image: UIImage(systemName: name))
        imageView.tintColor = AndroidReplicaTheme.secondaryText
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(x: 14, y: 9, width: 16, height: 18)
        container.addSubview(imageView)
        return container
    }

    @objc private func handleBack() {
        if let onBackOverride {
            onBackOverride()
            return
        }
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func searchTextChanged() {
        applyFilter()
    }

    @objc private func handleEmptyViewTap() {
        if loadErrorMessage != nil {
            loadErrorMessage = nil
            updateEmptyState()
            reloadBookmarks()
            return
        }
        let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard keyword.isEmpty == false else {
            showTransientMessage(bookmarks.isEmpty ? L10n.Reader.bookmarkEmptyMessage : L10n.Reader.noSearchResults)
            return
        }
        searchField.text = nil
        applyFilter()
        searchField.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func applyFilter(repositionEmbedded: Bool = true) {
        if isEmbeddedInChapterPanel {
            chapterPanelNeedsFilterUpdate = true
            chapterPanelNeedsInitialScroll = chapterPanelNeedsInitialScroll || repositionEmbedded
            guard bookmarkObservation.isActive, canApplyBookmarkSnapshot else { return }
            chapterPanelNeedsFilterUpdate = false
            filteredIndices = ReaderTocBookmarkPolicy.visibleIndices(in: bookmarks, query: chapterPanelSearchQuery)
            if chapterPanelNeedsInitialScroll || chapterPanelPendingScrollRow != nil {
                chapterPanelPendingScrollRow = ReaderTocBookmarkPolicy.initialScrollRow(
                    in: bookmarks, visibleIndices: filteredIndices, currentChapterIndex: chapterPanelCurrentChapterIndex
                )
                chapterPanelNeedsInitialScroll = chapterPanelPendingScrollRow == nil
                view.setNeedsLayout()
            }
        } else {
            let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if keyword.isEmpty {
                filteredIndices = Array(bookmarks.indices)
            } else {
                filteredIndices = bookmarks.indices.filter { index in
                    let bookmark = bookmarks[index]
                    return bookmark.chapterName.localizedCaseInsensitiveContains(keyword)
                        || bookmark.bookText.localizedCaseInsensitiveContains(keyword)
                        || bookmark.content.localizedCaseInsensitiveContains(keyword)
                }
            }
            filteredIndices.sort { lhs, rhs in
                sortMode.precedes(bookmarks[lhs], bookmarks[rhs])
            }
            headerSummaryLabel.text = summaryText()
        }
        reloadTableData()
    }

    private func summaryText() -> String? {
        guard bookmarks.isEmpty == false else { return nil }
        let countText = L10n.Reader.bookmarkCountText(filteredIndices.count)
        let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sortText = sortMode.title
        guard keyword.isEmpty == false else { return "\(countText)  ·  \(sortText)" }
        return "\(countText)  ·  \(sortText)  ·  \(keyword)"
    }

    @objc private func handleSort() {
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.Reader.bookmarkSortTitle,
            options: ReaderBookmarkListSortMode.allCases.map { mode in
                .init(
                    title: mode.title, systemImage: mode == sortMode ? "checkmark.circle.fill" : "arrow.up.arrow.down",
                    isSelected: mode == sortMode,
                    isDestructive: false
                ) { [weak self] in
                    self?.selectSortMode(mode)
                }
            }
        )
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(
                    optionCount: ReaderBookmarkListSortMode.allCases.count)),
            animated: true)
    }

    private func selectSortMode(_ mode: ReaderBookmarkListSortMode) {
        sortMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.sortModeDefaultsKey)
        applyFilter()
        if filteredIndices.isEmpty == false {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: true)
        }
    }

    @objc private func handleExport() {
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        let exportBookmarks = currentVisibleBookmarks()
        guard exportBookmarks.isEmpty == false else {
            showTransientMessage(bookmarks.isEmpty ? L10n.Reader.bookmarkEmptyMessage : L10n.Reader.noSearchResults)
            return
        }
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.Reader.bookmarkExportTitle,
            options: [
                .init(
                    title: L10n.Reader.bookmarkExportJson, systemImage: "curlybraces", isSelected: false,
                    isDestructive: false
                ) { [weak self] in
                    self?.exportAsJSON()
                },
                .init(
                    title: L10n.Reader.bookmarkExportMarkdown, systemImage: "doc.plaintext", isSelected: false,
                    isDestructive: false
                ) { [weak self] in
                    self?.exportAsMarkdown()
                },
                .init(
                    title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false,
                    isDestructive: false
                ) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 3)), animated: true)
    }

    private func exportAsJSON() {
        guard let jsonString = ReaderBookmarkExport.json(currentVisibleBookmarks()) else {
            showTransientMessage(L10n.AllBookmark.exportFailed)
            return
        }

        UIPasteboard.general.string = jsonString
        shareExportText(jsonString, fileName: "reader-bookmarks.json")
    }

    private func exportAsMarkdown() {
        let md = ReaderBookmarkExport.markdown(currentVisibleBookmarks())
        UIPasteboard.general.string = md
        shareExportText(md, fileName: "reader-bookmarks.md")
    }

    @MainActor
    private func shareExportText(_ text: String, fileName: String) {
        let tempURL: URL
        do {
            tempURL = try ReaderBookmarkExport.fileURL(text: text, fileName: fileName)
        } catch {
            showTransientMessage(L10n.AllBookmark.exportFailed)
            return
        }
        let controller = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        let anchor = exportButton
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        present(controller, animated: true) { [weak self] in
            self?.showTransientMessage(L10n.Reader.bookmarkExportReady)
        }
    }

    private func currentVisibleBookmarks() -> [Bookmark] {
        filteredIndices.compactMap { bookmarks[safe: $0] }
    }

    private func visibleBookmark(at row: Int) -> Bookmark? {
        guard let originalIndex = filteredIndices[safe: row] else { return nil }
        return bookmarks[safe: originalIndex]
    }

    // MARK: - Data

    func reloadBookmarks() {
        bookmarkObservation.reload()
    }

    private func receiveBookmarks(_ result: [Bookmark]) {
        tableAdapter.preservingScrollAnchor {
            loadErrorMessage = nil
            bookmarks = result
            applyFilter(repositionEmbedded: false)
        }
    }

    private func receiveBookmarkLoadError(_ error: Error) {
        loadErrorMessage = error.userFacingMessage
        bookmarks = []
        filteredIndices = []
        chapterPanelPendingScrollRow = nil
        headerSummaryLabel.text = nil
        reloadTableData()
        if presentedViewController == nil { presentLoadError(error) }
    }

    private var canApplyBookmarkSnapshot: Bool {
        isViewLoaded && bookmarkObservation.isActive && view.window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
            && !tableView.isTracking && !tableView.isDragging && !tableView.isDecelerating
            && !tableView.hasUncommittedUpdates && fastScroller?.isScrubbing != true
            && (!isEmbeddedInChapterPanel || (chapterPanelActionsEnabled && chapterPanelFastScrollEnabled))
    }

    private var canPerformEmbeddedBookmarkActions: Bool {
        guard canApplyBookmarkSnapshot, bookmarkObservation.isActive, bookmarkObservation.hasSnapshot,
            !bookmarkObservation.hasPendingSnapshot, !chapterPanelNeedsFilterUpdate
        else { return false }
        var host: UIViewController? = self
        while let controller = host {
            if controller.isBeingPresented || controller.isBeingDismissed || controller.isMovingFromParent
                || controller.presentedViewController != nil
            {
                return false
            }
            host = controller.parent
        }
        return true
    }

    private func bookmarkScrollInteractionChanged(_ interacting: Bool) {
        if interacting {
            chapterPanelPendingScrollRow = nil
            chapterPanelNeedsInitialScroll = false
        } else {
            resumeBookmarkUpdates()
        }
    }

    private func resumeBookmarkUpdates() {
        guard isViewLoaded, bookmarkObservation.isActive, canApplyBookmarkSnapshot else { return }
        bookmarkObservation.resumeUpdates()
        if chapterPanelNeedsFilterUpdate, bookmarkObservation.hasSnapshot, !bookmarkObservation.hasPendingSnapshot {
            applyFilter(repositionEmbedded: false)
        }
    }

    private func setLoadingBookmarks(_ loading: Bool) {
        guard !isEmbeddedInChapterPanel else { return }
        if loading { refreshControl.beginRefreshing() } else { refreshControl.endRefreshing() }
        for button in [sortButton, exportButton] { button.isEnabled = !loading }
    }

    @objc private func handleRefresh() {
        loadErrorMessage = nil
        reloadBookmarks()
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        let endFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
        let keyboardFrame = view.convert(endFrame, from: nil)
        let overlap = max(view.bounds.maxY - keyboardFrame.minY - view.safeAreaInsets.bottom, 0)
        let bottomInset = notification.name == UIResponder.keyboardWillHideNotification ? 0 : overlap
        tableView.contentInset.bottom = bottomInset
        tableView.verticalScrollIndicatorInsets.bottom = bottomInset
        let duration =
            (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.18
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }

    private func deleteBookmark(at originalIndex: Int) {
        let bookmark = bookmarks[originalIndex]
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.deleteBookmark(bookmark)
                await MainActor.run {
                    guard let currentIndex = self.bookmarks.firstIndex(where: { $0.time == bookmark.time }) else {
                        self.applyFilter()
                        self.showTransientMessage(L10n.Reader.bookmarkStale)
                        return
                    }
                    self.bookmarks.remove(at: currentIndex)
                    self.applyFilter()
                    self.showTransientMessage(L10n.Common.delete)
                }
            } catch {
                await MainActor.run {
                    self.presentDeleteError(error)
                }
            }
        }
    }

    private func updateBookmark(_ bookmark: Bookmark) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.screen.updateBookmark(bookmark)
                await MainActor.run {
                    if let index = self.bookmarks.firstIndex(where: { $0.time == bookmark.time }) {
                        self.bookmarks[index] = bookmark
                    } else {
                        self.showTransientMessage(L10n.Reader.bookmarkStale)
                    }
                    self.applyFilter()
                    if self.bookmarks.contains(where: { $0.time == bookmark.time }) {
                        self.showTransientMessage(L10n.Common.save)
                    }
                }
            } catch {
                await MainActor.run {
                    self.presentSaveError(error)
                }
            }
        }
    }

    private func updateEmptyState() {
        defer { updateFastScrollAvailability() }
        if let loadErrorMessage {
            emptyView.configure(
                title: L10n.Reader.bookmarkLoadFailed,
                detail: "\(loadErrorMessage)\n\(L10n.Common.retry)"
            )
            emptyView.isHidden = false
            emptyView.isUserInteractionEnabled = true
            emptyView.accessibilityHint = L10n.Common.retry
            tableView.isScrollEnabled = false
            return
        }
        if isEmbeddedInChapterPanel {
            emptyView.isHidden = true
            emptyView.isUserInteractionEnabled = false
            tableView.isScrollEnabled = true
            return
        }
        let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        emptyView.configure(
            title: bookmarks.isEmpty ? L10n.Reader.bookmarkEmptyMessage : L10n.Reader.noSearchResults,
            detail: keyword.isEmpty ? nil : "\(keyword)\n\(L10n.Common.cancel)"
        )
        emptyView.isHidden = filteredIndices.isEmpty == false
        emptyView.isUserInteractionEnabled = keyword.isEmpty == false
        emptyView.accessibilityHint = keyword.isEmpty ? nil : L10n.Common.cancel
        tableView.isScrollEnabled = filteredIndices.isEmpty == false
    }

    private func handleBookmarkAction(_ action: ReaderBookmarkListTableAdapter.LegacyAction, bookmark: Bookmark) {
        guard let originalIndex = bookmarks.firstIndex(where: { $0.time == bookmark.time }) else {
            showTransientMessage(L10n.Reader.bookmarkStale)
            return
        }
        let currentBookmark = bookmarks[originalIndex]
        switch action {
        case .more: presentBookmarkActions(currentBookmark, originalIndex: originalIndex)
        case .delete: confirmDeleteBookmark(currentBookmark, fallbackIndex: originalIndex)
        case .edit: presentBookmarkEditor(currentBookmark)
        case .detail: presentBookmarkDetail(currentBookmark)
        }
    }

    private func openBookmark(_ bookmark: Bookmark) {
        guard !isEmbeddedInChapterPanel || canPerformEmbeddedBookmarkActions else { return }
        let chapterIndex = Int(bookmark.chapterIndex)
        let chapterPos = Int(bookmark.chapterPos)
        searchField.resignFirstResponder()
        guard delegate != nil else {
            showTransientMessage(L10n.Reader.bookmarkOpenUnavailable)
            return
        }

        guard !isEmbeddedInChapterPanel, let navigationController else {
            delegate?.bookmarkList(self, didSelectChapterIndex: chapterIndex, position: chapterPos)
            return
        }

        let delegate = delegate
        let controller = self
        navigationController.popViewController(animated: false)
        DispatchQueue.main.async {
            delegate?.bookmarkList(controller, didSelectChapterIndex: chapterIndex, position: chapterPos)
        }
    }

    private func presentBookmarkActions(_ bookmark: Bookmark, originalIndex: Int) {
        guard !isEmbeddedInChapterPanel || canPerformEmbeddedBookmarkActions else { return }
        if isEmbeddedInChapterPanel {
            presentBookmarkEditor(bookmark)
            return
        }
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: displayTitle(for: bookmark),
            options: [
                .init(
                    title: L10n.Common.edit, systemImage: "square.and.pencil", isSelected: false, isDestructive: false
                ) { [weak self] in
                    self?.presentBookmarkEditor(bookmark)
                },
                .init(
                    title: L10n.Reader.bookmarkViewDetail, systemImage: "eye", isSelected: false, isDestructive: false
                ) { [weak self] in
                    self?.presentBookmarkDetail(bookmark)
                },
                .init(
                    title: L10n.Reader.bookmarkDeleteTitle, systemImage: "trash", isSelected: false, isDestructive: true
                ) { [weak self] in
                    self?.confirmDeleteBookmark(bookmark, fallbackIndex: originalIndex)
                },
                .init(
                    title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false,
                    isDestructive: false
                ) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 4)), animated: true)
    }

    private func confirmDeleteBookmark(_ bookmark: Bookmark, fallbackIndex: Int) {
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        let alert = ReaderTocBookmarkEditCoordinator.makeDeleteConfirmation { [weak self] in
            self?.deleteBookmarkSafely(bookmark, fallbackIndex: fallbackIndex)
        }
        present(alert, animated: true)
    }

    private func deleteBookmarkSafely(_ bookmark: Bookmark, fallbackIndex: Int) {
        let index = bookmarks.firstIndex(where: { $0.time == bookmark.time }) ?? fallbackIndex
        guard bookmarks.indices.contains(index) else {
            showTransientMessage(L10n.Reader.bookmarkStale)
            return
        }
        deleteBookmark(at: index)
    }

    private func presentBookmarkEditor(_ bookmark: Bookmark) {
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        if isEmbeddedInChapterPanel {
            let controller = ReaderTocBookmarkEditCoordinator.makeEditor(
                bookmark: bookmark, screen: screen, interfaceStyle: traitCollection.userInterfaceStyle
            ) { [weak self] _ in
                // Rebind after the committed write; queued pre-edit emissions must not win.
                // BookmarkFragment relocates the committed snapshot; cancellation keeps its anchor.
                self?.chapterPanelNeedsInitialScroll = true
                self?.bookmarkObservation.reload()
            }
            present(controller, animated: true)
            return
        }
        let controller = AndroidBookmarkEditorSheetViewController(
            bookmark: bookmark,
            onSave: { [weak self] bookText, content in
                self?.updateBookmark(
                    ReaderTocBookmarkEditCoordinator.updatedBookmark(bookmark, bookText: bookText, content: content))
            },
            onDelete: { [weak self] in
                guard let self else { return }
                let fallbackIndex = self.bookmarks.firstIndex(where: { $0.time == bookmark.time }) ?? 0
                self.confirmDeleteBookmark(bookmark, fallbackIndex: fallbackIndex)
            }
        )
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 360), animated: true)
    }

    private func presentBookmarkDetail(_ bookmark: Bookmark) {
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        let controller = AndroidBookmarkDetailSheetViewController(
            titleText: displayTitle(for: bookmark),
            bookText: bookmark.bookText,
            contentText: bookmark.content
        )
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 390), animated: true)
    }

    private func displayTitle(for bookmark: Bookmark) -> String {
        let title = bookmark.chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? L10n.Reader.bookmarkChapterTitle(Int(bookmark.chapterIndex) + 1) : title
    }

}
