import UIKit
import shared

final class BookshelfBookPageViewController: UIViewController,
    UICollectionViewDataSource, UICollectionViewDelegateFlowLayout
{
    let groupId: Int64
    let collectionView: UICollectionView
    private let refreshControl = UIRefreshControl()
    private let emptyLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private lazy var fastScroller = ReaderListFastScroller(collectionView: collectionView)
    private lazy var detailsGesture = UILongPressGestureRecognizer(target: self, action: #selector(openDetails(_:)))
    private(set) var books: [Book] = []
    private var displayedBooks: [Book] = []
    private var pendingBooks: [Book]?
    private var pendingConfiguration: Configuration?
    private var pendingStatus: Status?
    private var needsTypographyRefresh = false
    private var needsBookStatusRefresh = false
    private var needsLatestUpdateTimeRefresh = false
    private var latestUpdateTimeTimer: Timer?
    private var highlightedBook: RowSnapshot?
    private var selectedBook: RowSnapshot?
    private lazy var presentation = BookshelfBookPagePresentationCoordinator(collectionView: collectionView)
    private var hasLoaded = false
    private var layoutMode: BookshelfLayoutMode = .list
    private var preferences: AppUiPreferences?
    private var canRefresh = true
    private var refreshingBookURLs: Set<String> = []
    private var layoutSize: CGSize = .zero
    private var layoutInsets: UIEdgeInsets = .zero
    private var layoutSafeAreaInsets: UIEdgeInsets = .zero
    private var isPageVisible = false
    private var isSceneSuspended = false
    private var isApplicationSuspended = false
    private var preferencesSubscription: FlowSubscription?
    private var preferencesGeneration = UUID()
    private var suspendedAncestorPans: [(UIPanGestureRecognizer, Bool)] = []
    private var selectionBeforeScrubbing = true
    private var detailsEnabledBeforeScrubbing = true

    private struct Configuration {
        let layout: BookshelfLayoutMode
        let preferences: AppUiPreferences?
        let canRefresh: Bool
    }

    private enum Status {
        case loading, loaded
        case failure(String)
    }

    private struct RowSnapshot: Equatable {
        let url: String
        let origin: String
        let cell: ObjectIdentifier
    }

    var onOpen: ((Book) -> Void)?
    var onDetails: ((Book) -> Void)?
    var onRefresh: (() -> Void)?
    var onRetry: (() -> Void)?
    var isAvailablePage: (() -> Bool)?

    init(groupId: Int64) {
        self.groupId = groupId
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collectionView = BookshelfVerticalCollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        latestUpdateTimeTimer?.invalidate()
        preferencesSubscription?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        collectionView.backgroundColor = AndroidReplicaTheme.background
        collectionView.accessibilityIdentifier = "bookshelf.books"
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.refreshControl = refreshControl
        collectionView.register(
            AndroidReplicaBookshelfCell.self,
            forCellWithReuseIdentifier: AndroidReplicaBookshelfCell.reuseIdentifier)
        refreshControl.tintColor = AndroidReplicaTheme.accent
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.addGestureRecognizer(detailsGesture)
        collectionView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        presentation.canDeliver = { [weak self] in self?.canPresentContent == true }
        presentation.canAwaitPresentation = { [weak self] in self?.isForegroundPage == true }
        presentation.onDeliver = { [weak self] in self?.deliverPresentation() }
        presentation.onCancelSelection = { [weak self] in
            self?.highlightedBook = nil
            self?.selectedBook = nil
        }
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(willDeactivate(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(didActivate(_:)), name: name, object: nil)
        }
        fastScroller.accessibilityIdentifier = "bookshelf.fastScroll"
        fastScroller.apply(accent: AndroidReplicaTheme.accent)
        fastScroller.isEnabled = false
        fastScroller.isHidden = true
        fastScroller.onScrubbingChanged = { [weak self] active in
            self?.scrubbingChanged(active)
        }
        emptyLabel.text = BookshelfEmptyState.message
        emptyLabel.textColor = AndroidReplicaTheme.primaryText
        emptyLabel.font = BookshelfEmptyState.font(compatibleWith: traitCollection)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.accessibilityIdentifier = "bookshelf.empty"
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.tintColor = AndroidReplicaTheme.accent
        retryButton.accessibilityIdentifier = "bookshelf.retry"
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        retryButton.isHidden = true
        loadingIndicator.color = AndroidReplicaTheme.accent
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.accessibilityIdentifier = "bookshelf.loading"
        for item in [collectionView, emptyLabel, loadingIndicator, retryButton, fastScroller] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            fastScroller.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: ReaderListFastScrollerGeometry.columnWidth),
            fastScroller.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            fastScroller.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 12),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        renderStatus()
        updateFastScrollerAvailability()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isPageVisible = true
        // Wait for the current store value instead of enabling a cached preference on return.
        observeCurrentPreferences()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isSceneSuspended = view.window?.windowScene?.activationState != .foregroundActive
        isApplicationSuspended = UIApplication.shared.applicationState != .active
        resumePresentation()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPageVisible = false
        suspendPresentation()
        stopObservingPreferences()
        fastScroller.cancelScrubbing()
        fastScroller.isEnabled = false
        fastScroller.isHidden = true
        refreshControl.endRefreshing()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        presentation.resumeDelivery()
        let size = collectionView.bounds.size
        let insets = collectionView.adjustedContentInset
        let safeInsets = view.safeAreaInsets
        guard size != layoutSize || insets != layoutInsets || safeInsets != layoutSafeAreaInsets else { return }
        let anchor = readingAnchor()
        let widthChanged = size.width != layoutSize.width
        presentation.suspend()
        fastScroller.cancelScrubbing()
        layoutSize = size
        layoutInsets = insets
        layoutSafeAreaInsets = safeInsets
        if widthChanged { collectionView.collectionViewLayout.invalidateLayout() }
        collectionView.layoutIfNeeded()
        restore(anchor)
        fastScroller.reload()
        presentation.resumeDelivery()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        needsTypographyRefresh = true
        presentation.requestDelivery()
    }

    func configure(layoutMode: BookshelfLayoutMode, preferences: AppUiPreferences?, canRefresh: Bool) {
        // Invalidate queued store callbacks before accepting the parent's newer configuration.
        stopObservingPreferences()
        stageConfiguration(layoutMode: layoutMode, preferences: preferences, canRefresh: canRefresh)
        if isPageVisible { observeCurrentPreferences() }
    }

    private func stageConfiguration(layoutMode: BookshelfLayoutMode, preferences: AppUiPreferences?, canRefresh: Bool) {
        pendingConfiguration = Configuration(layout: layoutMode, preferences: preferences, canRefresh: canRefresh)
        loadViewIfNeeded()
        presentation.requestDelivery()
    }

    func render(books: [Book]) {
        loadViewIfNeeded()
        self.books = books
        pendingBooks = books
        pendingStatus = .loaded
        presentation.requestDelivery()
    }

    func showLoading() {
        loadViewIfNeeded()
        guard !hasLoaded, pendingBooks == nil else { return }
        pendingStatus = .loading
        presentation.requestDelivery()
    }

    func showFailure(_ message: String) {
        loadViewIfNeeded()
        guard !hasLoaded, pendingBooks == nil else { return }
        pendingStatus = .failure(message)
        presentation.requestDelivery()
    }

    func setRefreshing(bookURLs: Set<String>, isRefreshing _: Bool) {
        refreshingBookURLs = bookURLs
        needsBookStatusRefresh = true
        guard isViewLoaded else { return }
        presentation.requestDelivery()
    }

    func scrollToTop() {
        presentation.suspend()
        fastScroller.cancelScrubbing()
        collectionView.setContentOffset(
            CGPoint(x: -collectionView.adjustedContentInset.left, y: -collectionView.adjustedContentInset.top),
            animated: !UIAccessibility.isReduceMotionEnabled)
        presentation.resumeDelivery()
    }

    private func renderStatus() {
        emptyLabel.text = BookshelfEmptyState.message
        emptyLabel.textColor = AndroidReplicaTheme.primaryText
        emptyLabel.font = BookshelfEmptyState.font(compatibleWith: traitCollection)
        emptyLabel.isHidden = !hasLoaded || !displayedBooks.isEmpty
    }

    private func stopObservingPreferences() {
        preferencesGeneration = UUID()
        preferencesSubscription?.cancel()
        preferencesSubscription = nil
    }

    private func observeCurrentPreferences() {
        stopObservingPreferences()
        guard isPageVisible, case .success(let settings) = SharedRuntime.settingsFacade() else { return }
        let generation = preferencesGeneration
        preferencesSubscription = settings.watchPreferences { [weak self] preferences in
            DispatchQueue.main.async {
                guard let self, self.isPageVisible, self.preferencesGeneration == generation else { return }
                self.stageConfiguration(
                    layoutMode: preferences.bookshelfLayoutMode, preferences: preferences,
                    canRefresh: self.canRefresh)
            }
        }
    }

    private func updateFastScrollerAvailability() {
        guard isViewLoaded else { return }
        let requested = preferences?.bookGroupStyle == 0 && preferences?.showBookshelfFastScroller == true
        collectionView.showsVerticalScrollIndicator = !requested
        let enabled = isForegroundPage && canPerformNavigationAction && requested
        if !enabled { fastScroller.cancelScrubbing() }
        fastScroller.isEnabled = enabled
        fastScroller.isHidden = !enabled
        fastScroller.apply(accent: AndroidReplicaTheme.accent)
    }

    private func scrubbingChanged(_ active: Bool) {
        if active {
            presentation.cancelSelection()
            selectionBeforeScrubbing = collectionView.allowsSelection
            detailsEnabledBeforeScrubbing = detailsGesture.isEnabled
            collectionView.allowsSelection = false
            detailsGesture.isEnabled = false
            for cell in collectionView.visibleCells { cell.isHighlighted = false }
            refreshControl.endRefreshing()
            // UIPageViewController's ancestor scroll view otherwise cancels the overlay touch.
            var ancestor = view.superview
            while let current = ancestor {
                if let scrollView = current as? UIScrollView,
                    scrollView.contentSize.width > scrollView.bounds.width + 0.5
                {
                    let pan = scrollView.panGestureRecognizer
                    suspendedAncestorPans.append((pan, pan.isEnabled))
                    pan.isEnabled = false
                }
                ancestor = current.superview
            }
        } else {
            collectionView.allowsSelection = selectionBeforeScrubbing
            detailsGesture.isEnabled = detailsEnabledBeforeScrubbing
            let pans = suspendedAncestorPans
            suspendedAncestorPans.removeAll()
            for (pan, wasEnabled) in pans { pan.isEnabled = wasEnabled }
            presentation.resumeDelivery()
        }
    }

    func resumePresentation() {
        guard isViewLoaded else { return }
        presentation.resumeDelivery()
        updateFastScrollerAvailability()
        updateLatestUpdateTimeTimer()
    }

    func suspendPresentation() {
        guard isViewLoaded else { return }
        stopLatestUpdateTimeTimer()
        presentation.suspend()
        fastScroller.cancelScrubbing()
        fastScroller.isEnabled = false
        fastScroller.isHidden = true
    }

    private func updateLatestUpdateTimeTimer() {
        guard isForegroundPage, layoutMode == .list, preferences?.bookGroupStyle != 1,
            preferences?.showLastUpdateTime == true, !displayedBooks.isEmpty
        else {
            stopLatestUpdateTimeTimer()
            return
        }
        guard latestUpdateTimeTimer == nil else { return }
        requestLatestUpdateTimeRefresh()
        // BooksFragment.startLastUpdateTimeJob runs only for the resumed tab's list layout.
        let timer = Timer(
            timeInterval: 30, target: LatestUpdateTimeTarget(owner: self),
            selector: #selector(LatestUpdateTimeTarget.tick(_:)), userInfo: nil, repeats: true)
        latestUpdateTimeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLatestUpdateTimeTimer() {
        latestUpdateTimeTimer?.invalidate()
        latestUpdateTimeTimer = nil
    }

    private func requestLatestUpdateTimeRefresh() {
        needsLatestUpdateTimeRefresh = true
        presentation.requestDelivery()
    }

    private func refreshVisibleLatestUpdateTimes() {
        let now = Date()
        for case let cell as AndroidReplicaBookshelfCell in collectionView.visibleCells {
            cell.refreshLatestUpdateTime(now: now)
        }
    }

    private var isForegroundPage: Bool {
        isPageVisible && !isSceneSuspended && !isApplicationSuspended && isAvailablePage?() != false
            && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var canPresentContent: Bool {
        guard isForegroundPage, canPerformNavigationAction, !fastScroller.isScrubbing else { return false }
        var owner = parent
        while let candidate = owner {
            if let bookshelf = candidate as? AndroidReplicaBookshelfViewController,
                bookshelf.bookshelfOverflowMenu?.superview != nil
            {
                return false
            }
            owner = candidate.parent
        }
        return true
    }

    private var canOpenBook: Bool {
        let pan = collectionView.panGestureRecognizer.state
        return canPresentContent && !presentation.suppressesSelection
            && !collectionView.isDragging && !collectionView.isDecelerating
            && pan != .began && pan != .changed
    }

    private func deliverPresentation() {
        guard canPresentContent else { return }
        let anchor = readingAnchor()
        var reload = needsTypographyRefresh
        needsTypographyRefresh = false
        var reconfigure = needsBookStatusRefresh
        needsBookStatusRefresh = false
        let refreshLatestUpdateTime = needsLatestUpdateTimeRefresh
        needsLatestUpdateTimeRefresh = false
        if let configuration = pendingConfiguration {
            pendingConfiguration = nil
            reconfigure = true
            reload = reload || layoutMode != configuration.layout
            layoutMode = configuration.layout
            preferences = configuration.preferences
            canRefresh = configuration.canRefresh
        }
        if let pendingBooks {
            self.pendingBooks = nil
            reconfigure = true
            reload = reload || displayedBooks.map(\.bookUrl) != pendingBooks.map(\.bookUrl)
            displayedBooks = pendingBooks
        }
        UIView.performWithoutAnimation {
            if reload {
                presentation.cancelSelection()
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.reloadData()
                collectionView.layoutIfNeeded()
                restore(anchor)
                fastScroller.reload()
            } else if reconfigure {
                reconfigureVisibleCells()
            } else if refreshLatestUpdateTime {
                refreshVisibleLatestUpdateTimes()
            }
        }
        if let status = pendingStatus {
            pendingStatus = nil
            switch status {
            case .loaded:
                hasLoaded = true
                loadingIndicator.stopAnimating()
                retryButton.isHidden = true
                renderStatus()
            case .loading:
                if !hasLoaded {
                    emptyLabel.isHidden = true
                    retryButton.isHidden = true
                    loadingIndicator.startAnimating()
                }
            case .failure(let message):
                if !hasLoaded {
                    loadingIndicator.stopAnimating()
                    emptyLabel.text = message
                    emptyLabel.textColor = AndroidReplicaTheme.secondaryText
                    emptyLabel.font = .preferredFont(forTextStyle: .body)
                    emptyLabel.isHidden = false
                    retryButton.isHidden = false
                }
            }
        }
        collectionView.accessibilityValue = String(displayedBooks.count)
        refreshControl.isEnabled = canRefresh && !displayedBooks.isEmpty
        updateFastScrollerAvailability()
        updateLatestUpdateTimeTimer()
    }

    private func reconfigureVisibleCells() {
        for path in collectionView.indexPathsForVisibleItems {
            guard displayedBooks.indices.contains(path.item),
                let cell = collectionView.cellForItem(at: path) as? AndroidReplicaBookshelfCell
            else { continue }
            configure(cell, at: path)
        }
    }

    private func configure(_ cell: AndroidReplicaBookshelfCell, at path: IndexPath) {
        let book = displayedBooks[path.item]
        cell.configure(
            book: book, isGrid: layoutMode != .list, preferences: preferences,
            isRefreshing: refreshingBookURLs.contains(book.bookUrl))
        cell.onOpenDetails = { [weak self, weak cell] in
            guard let self, let cell, self.canOpenBook,
                let path = self.collectionView.indexPath(for: cell),
                let snapshot = self.snapshot(at: path), snapshot.url == book.bookUrl,
                snapshot.origin == book.origin, let currentBook = self.currentBook(for: snapshot)
            else { return }
            self.presentation.cancelSelection()
            self.onDetails?(currentBook)
        }
    }

    private struct ScrollAnchor {
        let bookURL: String
        let fallbackIndex: Int
        let distanceFromTop: CGFloat
    }

    private func readingAnchor() -> ScrollAnchor? {
        guard isViewLoaded else { return nil }
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let paths = collectionView.indexPathsForVisibleItems.sorted()
        guard
            let path = paths.first(where: {
                collectionView.layoutAttributesForItem(at: $0).map { $0.frame.maxY > top } ?? false
            }), displayedBooks.indices.contains(path.item), let frame = collectionView.layoutAttributesForItem(at: path)?.frame
        else { return nil }
        return ScrollAnchor(bookURL: displayedBooks[path.item].bookUrl, fallbackIndex: path.item, distanceFromTop: frame.minY - top)
    }

    private func restore(_ anchor: ScrollAnchor?) {
        guard let anchor, !displayedBooks.isEmpty else { return }
        let index = displayedBooks.firstIndex(where: { $0.bookUrl == anchor.bookURL }) ?? min(anchor.fallbackIndex, displayedBooks.count - 1)
        guard
            let frame = collectionView.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
        else { return }
        let insets = collectionView.adjustedContentInset
        let maximum = max(-insets.top, collectionView.contentSize.height - collectionView.bounds.height + insets.bottom)
        let y = min(max(frame.minY - anchor.distanceFromTop - insets.top, -insets.top), maximum)
        collectionView.setContentOffset(CGPoint(x: -insets.left, y: y), animated: false)
    }

    @objc private func refresh() {
        refreshControl.endRefreshing()
        guard canPresentContent, pendingConfiguration?.canRefresh ?? canRefresh, !books.isEmpty else { return }
        onRefresh?()
    }
    @objc private func retry() {
        guard canPresentContent else { return }
        onRetry?()
    }

    @objc private func openDetails(_ gesture: UILongPressGestureRecognizer) {
        guard canOpenBook, gesture.state == .began,
            let path = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
            let snapshot = snapshot(at: path), let currentBook = currentBook(for: snapshot)
        else { return }
        presentation.cancelSelection()
        onDetails?(currentBook)
    }

    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int { displayedBooks.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell =
            collectionView.dequeueReusableCell(
                withReuseIdentifier: AndroidReplicaBookshelfCell.reuseIdentifier, for: indexPath)
            as! AndroidReplicaBookshelfCell
        configure(cell, at: indexPath)
        return cell
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let selected = selectedBook
        selectedBook = nil
        collectionView.deselectItem(at: indexPath, animated: false)
        guard canOpenBook, let selected, let snapshot = snapshot(at: indexPath),
            selected.url == snapshot.url, selected.origin == snapshot.origin, selected.cell == snapshot.cell,
            let currentBook = currentBook(for: snapshot)
        else { return }
        presentation.cancelSelection()
        onOpen?(currentBook)
    }

    func collectionView(_: UICollectionView, shouldSelectItemAt path: IndexPath) -> Bool {
        selectedBook = nil
        guard canOpenBook, let snapshot = snapshot(at: path), currentBook(for: snapshot) != nil else { return false }
        if let highlightedBook,
            highlightedBook.url != snapshot.url || highlightedBook.origin != snapshot.origin || highlightedBook.cell != snapshot.cell
        {
            return false
        }
        selectedBook = snapshot
        return true
    }

    func collectionView(_: UICollectionView, shouldHighlightItemAt path: IndexPath) -> Bool {
        guard canPresentContent, !collectionView.isDragging, !collectionView.isDecelerating,
            let snapshot = snapshot(at: path), currentBook(for: snapshot) != nil
        else { return false }
        highlightedBook = snapshot
        return true
    }

    func collectionView(_: UICollectionView, didUnhighlightItemAt path: IndexPath) {
        let old = highlightedBook
        DispatchQueue.main.async { [weak self] in
            if self?.highlightedBook == old { self?.highlightedBook = nil }
            self?.presentation.resumeDelivery()
        }
    }

    private func snapshot(at path: IndexPath) -> RowSnapshot? {
        guard path.section == 0, displayedBooks.indices.contains(path.item),
            let cell = collectionView.cellForItem(at: path) as? AndroidReplicaBookshelfCell
        else { return nil }
        let book = displayedBooks[path.item]
        return RowSnapshot(url: book.bookUrl, origin: book.origin, cell: ObjectIdentifier(cell))
    }

    private func currentBook(for snapshot: RowSnapshot) -> Book? {
        books.first { $0.bookUrl == snapshot.url && $0.origin == snapshot.origin }
    }

    func scrollViewWillBeginDragging(_: UIScrollView) { presentation.cancelSelection() }
    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { presentation.resumeDelivery() }
    }
    func scrollViewDidEndDecelerating(_: UIScrollView) { presentation.resumeDelivery() }
    func scrollViewDidEndScrollingAnimation(_: UIScrollView) { presentation.resumeDelivery() }
    func scrollViewDidScrollToTop(_: UIScrollView) { presentation.resumeDelivery() }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed {
            presentation.cancelSelection()
        } else if recognizer.state == .ended || recognizer.state == .cancelled || recognizer.state == .failed {
            presentation.resumeDelivery()
        }
    }

    @objc private func willDeactivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if notification.name == UIScene.willDeactivateNotification { isSceneSuspended = true }
        if notification.name == UIApplication.willResignActiveNotification { isApplicationSuspended = true }
        suspendPresentation()
    }

    @objc private func didActivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if notification.name == UIScene.didActivateNotification { isSceneSuspended = false }
        if notification.name == UIApplication.didBecomeActiveNotification { isApplicationSuspended = false }
        resumePresentation()
    }

    func scrollViewDidChangeAdjustedContentInset(_: UIScrollView) {
        view.setNeedsLayout()
    }

    func collectionView(
        _ collectionView: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt _: IndexPath
    ) -> CGSize {
        let columns: CGFloat = layoutMode == .list ? 1 : CGFloat(max(Int(layoutMode.columnCount), 3))
        let insets = collectionView.adjustedContentInset
        return AndroidReplicaBookshelfCell.preferredSize(
            width: floor(max(1, collectionView.bounds.width - insets.left - insets.right) / columns), isGrid: layoutMode != .list,
            contentSizeCategory: traitCollection.preferredContentSizeCategory,
            displayScale: collectionView.traitCollection.displayScale)
    }

    @MainActor
    private final class LatestUpdateTimeTarget: NSObject {
        weak var owner: BookshelfBookPageViewController?

        init(owner: BookshelfBookPageViewController) {
            self.owner = owner
        }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.requestLatestUpdateTimeRefresh()
        }
    }
}

private final class BookshelfVerticalCollectionView: UICollectionView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}
