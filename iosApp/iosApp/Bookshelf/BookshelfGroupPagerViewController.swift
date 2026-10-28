import UIKit
import shared

final class BookshelfGroupPagerViewController: UIViewController,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate
{
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private var groupIDs: [Int64] = []
    private var pages: [Int64: BookshelfBookPageViewController] = [:]
    private var loadTasks: [Int64: Task<Void, Never>] = [:]
    private var loadTokens: [Int64: UUID] = [:]
    private var layoutMode: BookshelfLayoutMode = .grid3
    private var preferences: AppUiPreferences?
    private var refreshEnabled: [Int64: Bool] = [:]
    private var refreshingGroupId: Int64?
    private var refreshingBookURLs: Set<String> = []
    private var isTransitioning = false
    private var needsNeighborReload = false
    private var pendingSelection: (id: Int64, animated: Bool)?
    private weak var pagingScrollView: UIScrollView?
    private var pagingObservation: NSKeyValueObservation?
    private var transitionTarget: Int64?
    private var isProgrammaticTransition = false
    private(set) var selectedGroupId: Int64?

    var onSelectGroup: ((Int64) -> Void)?
    var onTransitionProgress: ((Int64, Int64, CGFloat, Bool) -> Void)?
    var onTransitionSettled: (() -> Void)?
    var onOpen: ((Book) -> Void)?
    var onDetails: ((Book) -> Void)?
    var onRefresh: ((Int64) -> Void)?
    var loadBooks: ((Int64) async throws -> [Book])?

    var currentPage: BookshelfBookPageViewController? {
        pager.viewControllers?.first as? BookshelfBookPageViewController
    }

    deinit {
        for task in loadTasks.values { task.cancel() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
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
        pager.dataSource = self
        pager.delegate = self
        if let scrollView = pager.view.subviews.compactMap({ $0 as? UIScrollView }).first {
            pagingScrollView = scrollView
            scrollView.scrollsToTop = false
            pagingObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                self?.updateInteractiveProgress(in: scrollView)
            }
        }
    }

    func configure(groups: [BookGroup], selectedGroupId: Int64) {
        loadViewIfNeeded()
        let visibleIDs = groups.map { $0.groupId == 0 ? BookshelfScreenAdapter.allGroupId : $0.groupId }
        let ids =
            selectedGroupId == BookshelfScreenAdapter.rootGroupId
            ? [selectedGroupId] : (visibleIDs.isEmpty ? [BookshelfScreenAdapter.allGroupId] : visibleIDs)
        let changed = ids != groupIDs
        needsNeighborReload = needsNeighborReload || changed
        groupIDs = ids
        refreshEnabled = Dictionary(
            groups.map {
                ($0.groupId == 0 ? BookshelfScreenAdapter.allGroupId : $0.groupId, $0.enableRefresh)
            }, uniquingKeysWith: { _, last in last })
        for (id, page) in pages { configure(page, id: id) }
        let target = ids.contains(selectedGroupId) ? selectedGroupId : ids[0]
        if isTransitioning {
            if self.selectedGroupId != selectedGroupId || !ids.contains(self.selectedGroupId ?? target) {
                pendingSelection = (target, false)
            }
            return
        }
        if self.selectedGroupId != target {
            showGroup(target, animated: false, notify: false)
        } else {
            reloadNeighborsIfNeeded()
        }
        removeInvalidPages()
    }

    func selectGroup(_ id: Int64, animated: Bool = true) {
        guard groupIDs.contains(id) else { return }
        if isTransitioning {
            pendingSelection = (id, animated)
            return
        }
        showGroup(id, animated: animated, notify: true)
    }

    func render(books: [Book], groupId: Int64) {
        guard groupIDs.contains(groupId) else { return }
        let page = page(for: groupId)
        loadTasks.removeValue(forKey: groupId)?.cancel()
        loadTokens.removeValue(forKey: groupId)
        page.render(books: books)
    }

    func configureAppearance(layoutMode: BookshelfLayoutMode, preferences: AppUiPreferences?) {
        self.layoutMode = layoutMode
        self.preferences = preferences
        for (id, page) in pages { configure(page, id: id) }
    }

    func setRefreshing(groupId: Int64?, bookURLs: Set<String>) {
        refreshingGroupId = groupId
        refreshingBookURLs = bookURLs
        for (id, page) in pages {
            page.setRefreshing(bookURLs: bookURLs, isRefreshing: id == groupId)
        }
    }

    func reloadCachedPages() {
        for id in Array(pages.keys) { loadPage(id) }
    }

    func scrollCurrentPageToTop() { currentPage?.scrollToTop() }

    private func configure(_ page: BookshelfBookPageViewController, id: Int64) {
        page.configure(layoutMode: layoutMode, preferences: preferences, canRefresh: refreshEnabled[id] ?? true)
        page.setRefreshing(bookURLs: refreshingBookURLs, isRefreshing: id == refreshingGroupId)
    }

    private func page(for id: Int64) -> BookshelfBookPageViewController {
        if let existing = pages[id] { return existing }
        let page = BookshelfBookPageViewController(groupId: id)
        pages[id] = page
        page.isAvailablePage = { [weak self, weak page] in
            guard let self, let page else { return false }
            return !self.isTransitioning && self.selectedGroupId == id && self.currentPage === page
        }
        configure(page, id: id)
        page.onOpen = { [weak self] book in
            guard let self, !self.isTransitioning, self.selectedGroupId == id else { return }
            self.onOpen?(book)
        }
        page.onDetails = { [weak self] book in
            guard let self, !self.isTransitioning, self.selectedGroupId == id else { return }
            self.onDetails?(book)
        }
        page.onRefresh = { [weak self] in
            guard let self, !self.isTransitioning, self.selectedGroupId == id else { return }
            self.onRefresh?(id)
        }
        page.onRetry = { [weak self] in self?.loadPage(id) }
        loadPage(id)
        return page
    }

    private func loadPage(_ id: Int64) {
        guard let page = pages[id], let loadBooks else { return }
        loadTasks.removeValue(forKey: id)?.cancel()
        let token = UUID()
        loadTokens[id] = token
        page.showLoading()
        loadTasks[id] = Task { @MainActor [weak self, weak page] in
            do {
                let books = try await loadBooks(id)
                try Task.checkCancellation()
                guard let self, self.loadTokens[id] == token, self.groupIDs.contains(id) else { return }
                page?.render(books: books)
                self.loadTasks.removeValue(forKey: id)
                self.loadTokens.removeValue(forKey: id)
            } catch {
                guard !Task.isCancelled, let self, self.loadTokens[id] == token else { return }
                page?.showFailure(error.userFacingMessage)
                self.loadTasks.removeValue(forKey: id)
                self.loadTokens.removeValue(forKey: id)
            }
        }
    }

    private func showGroup(_ id: Int64, animated: Bool, notify: Bool) {
        guard groupIDs.contains(id), selectedGroupId != id || currentPage?.groupId != id else { return }
        let previous = selectedGroupId.flatMap { groupIDs.firstIndex(of: $0) } ?? 0
        let next = groupIDs.firstIndex(of: id) ?? 0
        let target = page(for: id)
        let shouldAnimate = animated && view.window != nil && currentPage != nil
        isTransitioning = shouldAnimate
        isProgrammaticTransition = shouldAnimate
        for page in pages.values { page.suspendPresentation() }
        if shouldAnimate, let selectedGroupId {
            onTransitionProgress?(selectedGroupId, id, 1, true)
        }
        pager.setViewControllers([target], direction: next >= previous ? .forward : .reverse, animated: shouldAnimate) {
            [weak self] finished in
            guard let self else { return }
            self.isTransitioning = false
            self.isProgrammaticTransition = false
            if finished || self.currentPage?.groupId == id { self.completeSelection(id, notify: notify) }
            self.onTransitionSettled?()
            self.applyPendingSelection()
        }
    }

    private func completeSelection(_ id: Int64, notify: Bool) {
        guard groupIDs.contains(id) else {
            pendingSelection = groupIDs.first.map { ($0, false) }
            return
        }
        let changed = selectedGroupId != id
        selectedGroupId = id
        reloadNeighborsIfNeeded()
        currentPage?.resumePresentation()
        if changed && notify { onSelectGroup?(id) }
        removeInvalidPages()
    }

    private func applyPendingSelection() {
        guard let pending = pendingSelection else { return }
        pendingSelection = nil
        selectGroup(pending.id, animated: pending.animated)
    }

    private func reloadNeighborsIfNeeded() {
        guard needsNeighborReload, !isTransitioning, let currentPage else { return }
        needsNeighborReload = false
        // UIPageViewController caches missing neighbors when the shelf initially has one group.
        pager.dataSource = nil
        pager.setViewControllers([currentPage], direction: .forward, animated: false)
        pager.dataSource = self
    }

    private func removeInvalidPages() {
        guard !isTransitioning else { return }
        for id in pages.keys.filter({ !groupIDs.contains($0) && $0 != currentPage?.groupId }) {
            pages.removeValue(forKey: id)
            loadTasks.removeValue(forKey: id)?.cancel()
            loadTokens.removeValue(forKey: id)
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? BookshelfBookPageViewController,
            let index = groupIDs.firstIndex(of: page.groupId), index > 0
        else { return nil }
        return self.page(for: groupIDs[index - 1])
    }

    func pageViewController(
        _ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? BookshelfBookPageViewController,
            let index = groupIDs.firstIndex(of: page.groupId), index + 1 < groupIDs.count
        else { return nil }
        return self.page(for: groupIDs[index + 1])
    }

    func pageViewController(_: UIPageViewController, willTransitionTo pending: [UIViewController]) {
        isTransitioning = true
        for page in pages.values { page.suspendPresentation() }
        isProgrammaticTransition = false
        transitionTarget = (pending.first as? BookshelfBookPageViewController)?.groupId
        if let pagingScrollView { updateInteractiveProgress(in: pagingScrollView) }
    }

    func pageViewController(
        _: UIPageViewController, didFinishAnimating _: Bool,
        previousViewControllers _: [UIViewController], transitionCompleted completed: Bool
    ) {
        isTransitioning = false
        transitionTarget = nil
        currentPage?.resumePresentation()
        if completed, let currentPage { completeSelection(currentPage.groupId, notify: true) }
        onTransitionSettled?()
        applyPendingSelection()
    }

    private func updateInteractiveProgress(in scrollView: UIScrollView) {
        guard isTransitioning, !isProgrammaticTransition,
            let sourceID = selectedGroupId, let targetID = transitionTarget,
            let source = pages[sourceID]?.viewIfLoaded, let target = pages[targetID]?.viewIfLoaded,
            source.isDescendant(of: scrollView), target.isDescendant(of: scrollView)
        else { return }
        let sourceFrame = source.convert(source.bounds, to: scrollView)
        let targetFrame = target.convert(target.bounds, to: scrollView)
        let travel = targetFrame.midX - sourceFrame.midX
        guard travel.isFinite, abs(travel) > 1, scrollView.contentOffset.x.isFinite else { return }
        let fraction = (scrollView.contentOffset.x - sourceFrame.minX) / travel
        onTransitionProgress?(sourceID, targetID, min(1, max(0, fraction)), false)
    }
}
