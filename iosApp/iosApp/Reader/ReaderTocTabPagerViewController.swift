import UIKit

final class ReaderTocTabPagerViewController: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate
{
    enum Tab { case chapters, bookmarks }

    private var pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let chapters: ReaderTocChapterPageViewController
    private let bookmarks = ReaderTocBookmarkPageHost()
    private let tabStrip = ReaderTocTabStrip()
    private weak var pagingScrollView: UIScrollView?
    private var pagingOffsetObservation: NSKeyValueObservation?
    private weak var prioritizedBackGesture: UIGestureRecognizer?
    private var bookmarksAvailable = false
    private var controlsEnabled = true
    private var fastScrollActive = false
    private var needsNeighborReload = false
    private var needsPagerRebuild = false
    private var isDeparting = false
    private var isProgrammaticTransition = false
    private var transitionID: UUID?
    private var transitionRecovery: DispatchWorkItem?
    private(set) var selectedTab: Tab = .chapters
    private(set) var isTransitioning = false

    var tabsView: UIView { tabStrip }
    var makeBookmarks: (() -> BookmarkListViewController?)?
    var onBookmarksUnavailable: (() -> Void)?
    var onTransitionBegan: (() -> Void)?
    var onTransitionStateChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?

    init(chapters: ReaderTocChapterPageViewController) {
        self.chapters = chapters
        super.init(nibName: nil, bundle: nil)
        tabStrip.onSelect = { [weak self] tab in self?.select(tab) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        transitionRecovery?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        installPager()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteDidChange), name: .androidReplicaThemeDidChange, object: nil)
        applyPalette()
    }

    private func installPager() {
        pagingOffsetObservation?.invalidate()
        pagingOffsetObservation = nil
        addChild(pager)
        pager.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pager.view)
        NSLayoutConstraint.activate([
            pager.view.topAnchor.constraint(equalTo: view.topAnchor),
            pager.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pager.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pager.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        pager.didMove(toParent: self)
        pager.delegate = isDeparting ? nil : self
        pager.dataSource = isDeparting ? nil : self
        pager.setViewControllers([controller(for: selectedTab)], direction: .forward, animated: false)
        if let scrollView = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first {
            pagingScrollView = scrollView
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.isDirectionalLockEnabled = true
            scrollView.scrollsToTop = false
            pagingOffsetObservation = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] scrollView, _ in
                self?.updateInteractiveIndicator(in: scrollView)
            }
        }
        tabStrip.select(selectedTab, animated: false)
        needsNeighborReload = isDeparting
        applyInteractionState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDeparting = false
        // Returning children can resume providers before the new pager has its final viewport.
        isTransitioning = true
        if needsPagerRebuild { rebuildPager() }
        pager.delegate = self
        reloadNeighborsIfNeeded()
        applyInteractionState()
        onTransitionStateChanged?()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        preserveScrollAnchors()
        isDeparting = true
        needsPagerRebuild = true
        transitionRecovery?.cancel()
        transitionRecovery = nil
        transitionID = nil
        isProgrammaticTransition = false
        isTransitioning = false
        tabStrip.select(selectedTab, animated: false)
        pager.delegate = nil
        pager.dataSource = nil
        applyInteractionState()
        onTransitionStateChanged?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if needsPagerRebuild { rebuildPager() }
    }

    private func preserveScrollAnchors() {
        chapters.preserveScrollAnchor()
        bookmarks.preserveScrollAnchor()
    }

    private func rebuildPager() {
        let previousPager = pager
        previousPager.delegate = nil
        previousPager.dataSource = nil
        pagingOffsetObservation?.invalidate()
        pagingOffsetObservation = nil
        if let scrollView = pagingScrollView {
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            scrollView.layer.removeAllAnimations()
        }
        previousPager.willMove(toParent: nil)
        let pages: [UIViewController] = [chapters, bookmarks]
        for page in pages where page.parent === previousPager {
            page.willMove(toParent: nil)
            page.viewIfLoaded?.removeFromSuperview()
            page.removeFromParent()
        }
        previousPager.view.removeFromSuperview()
        previousPager.removeFromParent()
        pagingScrollView = nil
        prioritizedBackGesture = nil
        // A fresh UIKit pager also separates late interactive delegate callbacks from the new session.
        pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
        needsPagerRebuild = false
        installPager()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        restoreSelectedScrollAnchor()
        setTransitioning(false)
        reloadNeighborsIfNeeded()
        settleSelectedPageLayout()
        refreshSelectedPageAccessibility()
        if let backGesture = navigationController?.interactivePopGestureRecognizer,
            prioritizedBackGesture !== backGesture
        {
            pagingScrollView?.panGestureRecognizer.require(toFail: backGesture)
            prioritizedBackGesture = backGesture
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else { return }
        themePaletteDidChange()
    }

    func setControlsEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        if isViewLoaded { applyInteractionState() }
    }

    func setFastScrollActive(_ active: Bool) {
        fastScrollActive = active
        if isViewLoaded { applyInteractionState() }
    }

    func setBookmarksAvailable(_ available: Bool) {
        guard bookmarksAvailable != available else { return }
        bookmarksAvailable = available
        needsNeighborReload = true
        if isViewLoaded { reloadNeighborsIfNeeded() }
    }

    func resetBookmarks() {
        guard selectedTab == .chapters, !isTransitioning else { return }
        bookmarks.removeContent()
        needsNeighborReload = true
        if isViewLoaded { reloadNeighborsIfNeeded() }
    }

    func select(_ tab: Tab, animated: Bool = true) {
        guard controlsEnabled, !isDeparting, !needsPagerRebuild,
            !isTransitioning, selectedTab != tab
        else { return }
        loadViewIfNeeded()
        guard prepare(tab) else {
            onBookmarksUnavailable?()
            return
        }
        preserveScrollAnchors()
        let requestID = UUID()
        transitionID = requestID
        isProgrammaticTransition = true
        setTransitioning(true)
        onTransitionBegan?()
        let activePager = pager
        let animates = animated && view.window != nil
        if animates {
            // UIKit can leave a scroll-style pager without a completion after repeated tab/layout changes.
            // Keep the requested tab and retained pages; never leave the entire toolbar disabled forever.
            let recovery = DispatchWorkItem { [weak self, weak activePager] in
                guard let self, let activePager, self.pager === activePager,
                    self.transitionID == requestID, self.isProgrammaticTransition, !self.isDeparting
                else { return }
                self.completeTransition(to: tab, rebuildingPager: true)
            }
            transitionRecovery = recovery
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: recovery)
        }
        // TabLayout.selectTab updates text selection before the ViewPager settles.
        tabStrip.select(tab, animated: animates)
        activePager.setViewControllers(
            [controller(for: tab)], direction: tab == .bookmarks ? .forward : .reverse,
            animated: animates
        ) { [weak self, weak activePager] finished in
            // The callback runs inside UIKit's queuing-scroll cleanup. Layout and row restoration
            // must wait until that stack unwinds, or _flushViewController can reenter itself.
            DispatchQueue.main.async { [weak self, weak activePager] in
                guard let self, let activePager, self.pager === activePager,
                    !self.isDeparting, self.transitionID == requestID
                else { return }
                self.finishTransition(completed: finished)
            }
        }
    }

    private func controller(for tab: Tab) -> UIViewController {
        tab == .chapters ? chapters : bookmarks
    }

    private func tab(for controller: UIViewController?) -> Tab? {
        if controller === chapters { return .chapters }
        if controller === bookmarks { return .bookmarks }
        return nil
    }

    private func prepare(_ tab: Tab) -> Bool {
        guard tab == .bookmarks else { return true }
        guard bookmarksAvailable else { return false }
        if bookmarks.hasContent { return true }
        guard controlsEnabled, !isDeparting, let controller = makeBookmarks?() else { return false }
        bookmarks.install(controller)
        return true
    }

    private func setTransitioning(_ transitioning: Bool) {
        isTransitioning = transitioning
        applyInteractionState()
        onTransitionStateChanged?()
    }

    private func applyInteractionState() {
        let enabled = controlsEnabled && !isDeparting
        tabStrip.isUserInteractionEnabled = enabled && !isTransitioning
        tabStrip.setControlsEnabled(enabled && !isTransitioning)
        // Leave the descendant control alive while excluding horizontal page swipes.
        pager.view.isUserInteractionEnabled = (enabled || fastScrollActive) && !isDeparting
        pagingScrollView?.isScrollEnabled = enabled && !isProgrammaticTransition && !fastScrollActive
        chapters.viewIfLoaded?.accessibilityElementsHidden = isDeparting || isTransitioning || selectedTab != .chapters
        bookmarks.viewIfLoaded?.accessibilityElementsHidden = isDeparting || isTransitioning || selectedTab != .bookmarks
    }

    private func finishTransition(completed: Bool) {
        guard isTransitioning, transitionID != nil, !isDeparting else { return }
        var target = selectedTab
        if completed, let visible = tab(for: pager.viewControllers?.first),
            visible == .chapters || bookmarks.hasContent
        {
            target = visible
        } else if pager.viewControllers?.first !== controller(for: selectedTab) {
            pager.setViewControllers([controller(for: selectedTab)], direction: .forward, animated: false)
        }
        if isProgrammaticTransition {
            // Re-establish the displayed page after the animated queue has unwound before accepting another command.
            pager.dataSource = nil
            pager.setViewControllers([controller(for: target)], direction: .forward, animated: false)
            pager.dataSource = self
        }
        completeTransition(to: target)
    }

    private func completeTransition(to target: Tab, rebuildingPager: Bool = false) {
        transitionRecovery?.cancel()
        transitionRecovery = nil
        transitionID = nil
        isProgrammaticTransition = false
        let previous = selectedTab
        selectedTab = target
        if rebuildingPager { rebuildPager() }
        // Existing data owners must see the restored row when they drain their URL/time-preserving updates.
        restoreSelectedScrollAnchor()
        tabStrip.select(selectedTab, animated: false)
        if previous != selectedTab { onSelectionChanged?() }
        setTransitioning(false)
        reloadNeighborsIfNeeded()
        settleSelectedPageLayout()
        refreshSelectedPageAccessibility()
    }

    private func restoreSelectedScrollAnchor(rebasing: Bool = false) {
        view.layoutIfNeeded()
        if selectedTab == .chapters {
            chapters.restoreScrollAnchorAfterTransition(rebasing: rebasing)
        } else {
            bookmarks.restoreScrollAnchorAfterTransition(rebasing: rebasing)
        }
    }

    private func refreshSelectedPageAccessibility() {
        guard !isDeparting, !isTransitioning, view.window != nil else { return }
        // Notify after geometry settles; the notification itself does not restore the viewport.
        ReaderTocTableScrollAnchor.layoutTable(in: controller(for: selectedTab))
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    private func settleSelectedPageLayout() {
        // Rebase after synchronous callbacks: a changed filter or snapshot owns its new row, not the old tab index.
        restoreSelectedScrollAnchor(rebasing: true)
        ReaderTocTableScrollAnchor.layoutTable(in: controller(for: selectedTab))
    }

    private func updateInteractiveIndicator(in scrollView: UIScrollView) {
        guard isTransitioning, !isProgrammaticTransition, !isDeparting,
            let sourceView = controller(for: selectedTab).viewIfLoaded,
            let targetView = controller(for: selectedTab == .chapters ? .bookmarks : .chapters).viewIfLoaded,
            sourceView.isDescendant(of: scrollView), targetView.isDescendant(of: scrollView)
        else { return }
        let pageFrame = sourceView.convert(sourceView.bounds, to: scrollView)
        let targetFrame = targetView.convert(targetView.bounds, to: scrollView)
        let travel = targetFrame.midX - pageFrame.midX
        guard pageFrame.width.isFinite, pageFrame.width > 0, pageFrame.minX.isFinite,
            travel.isFinite, abs(travel) > 1,
            scrollView.contentOffset.x.isFinite
        else { return }
        // Actual neighbor placement handles both layout directions without private slot assumptions.
        let fraction = (scrollView.contentOffset.x - pageFrame.minX) / travel
        let progress = min(1, max(0, selectedTab == .chapters ? fraction : 1 - fraction))
        // TabLayout.setScrollPosition rounds the page offset for the selected text state.
        tabStrip.setTransitionProgress(progress)
    }

    private func reloadNeighborsIfNeeded() {
        guard needsNeighborReload, !isTransitioning, !isDeparting, !needsPagerRebuild else { return }
        needsNeighborReload = false
        if !bookmarksAvailable, selectedTab == .bookmarks {
            selectedTab = .chapters
            tabStrip.select(.chapters, animated: false)
            onSelectionChanged?()
        }
        // UIPageViewController caches absent neighbors, including before the book is available.
        preserveScrollAnchors()
        pager.dataSource = nil
        pager.setViewControllers([controller(for: selectedTab)], direction: .forward, animated: false)
        pager.dataSource = self
        applyInteractionState()
    }

    private func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        view.backgroundColor = palette.background
        bookmarks.viewIfLoaded?.backgroundColor = view.backgroundColor
        tabStrip.applyPalette(palette)
        chapters.refreshPalette()
    }

    @objc private func themePaletteDidChange() {
        guard isViewLoaded else { return }
        applyPalette()
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard pageViewController === pager, !isDeparting else { return nil }
        return viewController === bookmarks ? chapters : nil
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        // Neighbor discovery must not create/load the bookmark adapter.
        guard pageViewController === pager, !isDeparting else { return nil }
        return viewController === chapters && bookmarksAvailable ? bookmarks : nil
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        guard pageViewController === pager, controlsEnabled, !isDeparting, !isTransitioning else { return }
        preserveScrollAnchors()
        if let next = tab(for: pendingViewControllers.first), !prepare(next) {
            onBookmarksUnavailable?()
        }
        transitionID = UUID()
        isProgrammaticTransition = false
        setTransitioning(true)
        onTransitionBegan?()
        if let pagingScrollView { updateInteractiveIndicator(in: pagingScrollView) }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, didFinishAnimating _: Bool,
        previousViewControllers _: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard pageViewController === pager, !isProgrammaticTransition, let requestID = transitionID else { return }
        DispatchQueue.main.async { [weak self, weak pageViewController] in
            guard let self, let pageViewController, self.pager === pageViewController,
                !self.isProgrammaticTransition, self.transitionID == requestID
            else { return }
            self.finishTransition(completed: completed)
        }
    }
}

private struct ReaderTocTableScrollAnchor {
    private weak var tableView: UITableView?
    private let row: IndexPath
    private let topOffset: CGFloat

    init?(in controller: UIViewController) {
        guard let view = controller.viewIfLoaded, let tableView = Self.findTable(in: view),
            tableView.bounds.width > 0, tableView.bounds.height > 0
        else { return nil }
        tableView.layoutIfNeeded()
        guard let row = tableView.indexPathsForVisibleRows?.min() else { return nil }
        self.tableView = tableView
        self.row = row
        topOffset = tableView.rectForRow(at: row).minY - tableView.contentOffset.y
    }

    func restore(in controller: UIViewController) -> Bool {
        guard let tableView else { return true }
        guard controller.parent != nil else { return false }
        guard tableView.bounds.height > 0 else { return false }
        guard row.section < tableView.numberOfSections,
            row.row < tableView.numberOfRows(inSection: row.section)
        else { return true }
        // As in ReaderListFastScroller, the first jump can replace estimated heights. Realize the target before
        // computing its intra-row offset, then align once more against the measured geometry.
        for _ in 0..<2 {
            tableView.scrollToRow(at: row, at: .top, animated: false)
            tableView.layoutIfNeeded()
            let minY = -tableView.adjustedContentInset.top
            let maxY = max(
                minY, tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
            let y = tableView.rectForRow(at: row).minY - topOffset
            tableView.setContentOffset(CGPoint(x: 0, y: min(maxY, max(minY, y))), animated: false)
            tableView.layoutIfNeeded()
        }
        return true
    }

    static func layoutTable(in controller: UIViewController) {
        guard let view = controller.viewIfLoaded else { return }
        view.layoutIfNeeded()
        findTable(in: view)?.layoutIfNeeded()
    }

    private static func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        for subview in view.subviews {
            if let table = findTable(in: subview) { return table }
        }
        return nil
    }
}

private final class ReaderTocBookmarkPageHost: UIViewController {
    private var pendingScrollAnchor: ReaderTocTableScrollAnchor?
    var hasContent: Bool { !children.isEmpty }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ReaderTocPalette(traits: traitCollection).background
        view.clipsToBounds = true
    }

    func preserveScrollAnchor() {
        if pendingScrollAnchor == nil { pendingScrollAnchor = ReaderTocTableScrollAnchor(in: self) }
    }

    func restoreScrollAnchorAfterTransition(rebasing: Bool = false) {
        ReaderTocTableScrollAnchor.layoutTable(in: self)
        if rebasing { pendingScrollAnchor = ReaderTocTableScrollAnchor(in: self) }
        guard let anchor = pendingScrollAnchor else { return }
        // Realizing rows can lay out this host again; consume before entering UITableView.
        pendingScrollAnchor = nil
        if !anchor.restore(in: self) { pendingScrollAnchor = anchor }
    }

    func install(_ controller: BookmarkListViewController) {
        loadViewIfNeeded()
        addChild(controller)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        controller.didMove(toParent: self)
    }

    func removeContent() {
        pendingScrollAnchor = nil
        for controller in children {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
    }
}

final class ReaderTocChapterPageViewController: UIViewController {
    let tableView = UITableView(frame: .zero, style: .plain)
    let emptyLabel = UILabel()
    private lazy var fastScroller = ReaderListFastScroller(tableView: tableView)
    private var fastScrollEnabled = true
    private let bottomBackground = UIView()
    private let bottomBar = UIView()
    private let currentChapterButton = UIButton(type: .system)
    private let topButton = UIButton(type: .system)
    private let bottomButton = UIButton(type: .system)
    private var controlsEnabled = true
    private var canLocateCurrent = false
    private var hasVisibleChapters = false
    private lazy var bottomBarHeight = bottomBar.heightAnchor.constraint(equalToConstant: 36)
    private var pendingScrollAnchor: ReaderTocTableScrollAnchor?

    var onLocateCurrent: (() -> Void)?
    var onScrollToTop: (() -> Void)?
    var onScrollToBottom: (() -> Void)?
    var onFastScrollStateChange: ((Bool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        for item in [bottomBackground, tableView, emptyLabel, bottomBar] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        emptyLabel.font = .preferredFont(forTextStyle: .callout)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = UIIdentifiers.ReaderChapterList.emptyState
        configureBottomBar()
        fastScroller.translatesAutoresizingMaskIntoConstraints = false
        fastScroller.accessibilityIdentifier = "reader.chapterList.fastScroll"
        fastScroller.onScrubbingChanged = { [weak self] in self?.onFastScrollStateChange?($0) }
        fastScroller.isEnabled = fastScrollEnabled
        tableView.showsVerticalScrollIndicator = false
        view.addSubview(fastScroller)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bottomBarHeight,
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bottomBackground.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            bottomBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableView.leadingAnchor, constant: 28),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableView.trailingAnchor, constant: -28),
            fastScroller.widthAnchor.constraint(equalToConstant: 24),
            fastScroller.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            fastScroller.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 8),
            fastScroller.bottomAnchor.constraint(equalTo: tableView.bottomAnchor, constant: -8),
        ])
        refreshPalette()
        setControlsEnabled(controlsEnabled)
    }

    func preserveScrollAnchor() {
        if pendingScrollAnchor == nil { pendingScrollAnchor = ReaderTocTableScrollAnchor(in: self) }
    }

    func restoreScrollAnchorAfterTransition(rebasing: Bool = false) {
        ReaderTocTableScrollAnchor.layoutTable(in: self)
        if rebasing { pendingScrollAnchor = ReaderTocTableScrollAnchor(in: self) }
        guard let anchor = pendingScrollAnchor else { return }
        pendingScrollAnchor = nil
        if !anchor.restore(in: self) { pendingScrollAnchor = anchor }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelFastScrolling()
    }

    func setFastScrollEnabled(_ enabled: Bool) {
        fastScrollEnabled = enabled
        if isViewLoaded { fastScroller.isEnabled = enabled }
    }

    func reloadFastScroll() {
        if isViewLoaded { fastScroller.reload() }
    }

    func cancelFastScrolling() {
        if isViewLoaded { fastScroller.cancelScrubbing() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            refreshPalette()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFooterFont()
        }
    }

    func setCurrentChapterInfo(_ text: String, canLocate: Bool, hasVisibleChapters: Bool) {
        currentChapterButton.setTitle(text, for: .normal)
        currentChapterButton.accessibilityValue = text
        canLocateCurrent = canLocate
        self.hasVisibleChapters = hasVisibleChapters
        setControlsEnabled(controlsEnabled)
    }

    func setControlsEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        currentChapterButton.isEnabled = enabled && canLocateCurrent && hasVisibleChapters
        topButton.isEnabled = enabled && hasVisibleChapters
        bottomButton.isEnabled = enabled && hasVisibleChapters
        // Keep the original touch target alive while the parent pager is tracking its pan.
        tableView.allowsSelection = enabled
    }

    private func configureBottomBar() {
        updateFooterFont()
        currentChapterButton.titleLabel?.numberOfLines = 1
        currentChapterButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
        currentChapterButton.contentHorizontalAlignment = .leading
        currentChapterButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        currentChapterButton.accessibilityIdentifier = "reader.chapterList.locateCurrent"
        currentChapterButton.accessibilityLabel = L10n.Reader.chapterLocateCurrentAction
        currentChapterButton.accessibilityHint = L10n.Reader.chapterLocateCurrentAction
        currentChapterButton.addTarget(self, action: #selector(locateCurrent), for: .touchUpInside)
        for (button, icon, label, identifier, action) in [
            (
                topButton, ReaderTocAndroidIcon.top, L10n.Reader.scrollToTop,
                UIIdentifiers.ReaderChapterList.scrollTopButton, #selector(scrollToTop)
            ),
            (
                bottomButton, ReaderTocAndroidIcon.bottom, L10n.Reader.scrollToBottom,
                UIIdentifiers.ReaderChapterList.scrollBottomButton, #selector(scrollToBottom)
            ),
        ] {
            // The XML ImageView has a 36dp box, no padding, and defaults to FIT_CENTER.
            button.setImage(icon.image(size: 36), for: .normal)
            button.accessibilityLabel = label
            button.accessibilityIdentifier = identifier
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        for button in [currentChapterButton, topButton, bottomButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: bottomBar.topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            ])
        }
        currentChapterButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            currentChapterButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 10),
            currentChapterButton.trailingAnchor.constraint(equalTo: topButton.leadingAnchor),
            topButton.widthAnchor.constraint(equalToConstant: 36),
            topButton.trailingAnchor.constraint(equalTo: bottomButton.leadingAnchor),
            bottomButton.widthAnchor.constraint(equalToConstant: 36),
            bottomButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -10),
        ])
        bottomBar.layer.shadowColor = UIColor.black.cgColor
        bottomBar.layer.shadowOpacity = 0.12
        bottomBar.layer.shadowRadius = 2
        bottomBar.layer.shadowOffset = CGSize(width: 0, height: -1)
    }

    private func updateFooterFont() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        currentChapterButton.titleLabel?.font = font
        // The standard bar is 36dp; iOS accessibility text still needs a complete line.
        bottomBarHeight.constant = max(36, ceil(font.lineHeight) + 12)
    }

    func refreshPalette() {
        guard isViewLoaded else { return }
        let palette = ReaderTocPalette(traits: traitCollection)
        fastScroller.apply(accent: palette.accent)
        view.backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        bottomBackground.backgroundColor = palette.bottomBackground
        bottomBar.backgroundColor = palette.bottomBackground
        emptyLabel.textColor = palette.secondaryText
        for button in [currentChapterButton, topButton, bottomButton] {
            button.tintColor = palette.bottomText
            button.setTitleColor(palette.bottomText, for: .normal)
        }
        // Android assigns a single btc color, including disabled current-chapter text.
        currentChapterButton.setTitleColor(palette.bottomText, for: .disabled)
    }

    @objc private func locateCurrent() { onLocateCurrent?() }
    @objc private func scrollToTop() { onScrollToTop?() }
    @objc private func scrollToBottom() { onScrollToBottom?() }
}
