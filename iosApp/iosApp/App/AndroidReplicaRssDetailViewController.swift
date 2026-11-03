import shared
import UIKit

final class AndroidReplicaRssDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum RetryAction: Equatable {
        case bootstrap, sorts, firstPage, more
    }

    private typealias ArticleIdentity = RssArticleListIdentity

    private let source: RssSource
    private let screen = RssScreenAdapter()
    private lazy var topBar = AndroidReplicaDetailBar(
        title: source.sourceName, target: self, backAction: #selector(handleBack))
    private let refreshButton = UIButton(type: .system)
    private let sortButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let stateView = ContentStateView()
    private let statusBar = UIStackView()
    private let statusLabel = UILabel()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var sorts: [(name: String, url: String)] = []
    private var selectedSort: (name: String, url: String)?
    private var articles: [RssArticle] = []
    private var readInSession = Set<ArticleIdentity>()
    private var favorites: [RssStar] = []
    private var nextPageUrl: String?
    private var currentPage: Int32 = 0
    private var visitedPageURLs = Set<String>()
    private var isPaginationFinished = true
    private var isLoadingFirstPage = false
    private var isLoadingMore = false
    private var isRendering = false
    private var isRuntimeReady = false
    private var hasLeftPage = false
    private var hasAppeared = false
    private var applicationSuspended = UIApplication.shared.applicationState != .active
    private var sceneSuspended = false
    private var protectedDataSuspended = false
    private var thumbnailGeneration = UUID()
    private var cellArticles: [ObjectIdentifier: RssArticle] = [:]
    private var pendingSizeChanges: [ObjectIdentifier: () -> Bool] = [:]
    private var sizeUpdate: DispatchWorkItem?
    private var needsSizeUpdateOnResume = false
    private var retryAction: RetryAction?
    private var requestGeneration = 0
    private var sortsTask: Task<Void, Never>?
    private var articlesTask: Task<Void, Never>?
    private weak var pageNavigationController: UINavigationController?

    init(source: RssSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        sizeUpdate?.cancel()
        sortsTask?.cancel()
        articlesTask?.cancel()
        screen.unbind()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification, UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(suspendPresentation(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification,
            UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification,
            .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(resumePresentation(_:)), name: name, object: nil)
        }
        bootstrap()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pageNavigationController = navigationController
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        sceneSuspended = view.window?.windowScene?.activationState != .foregroundActive
        DispatchQueue.main.async { [weak self] in self?.resumeVisibleThumbnails() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hasAppeared = false
        suspendThumbnails()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if canUseArticleList { resumeVisibleThumbnails() } else { suspendThumbnails() }
        scheduleSizeUpdate()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if let navigationController {
            pageNavigationController = navigationController
        } else if parent == nil, pageNavigationController != nil {
            leavePage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Article pushes and category sheets keep this controller active in its stack.
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            if controller.isMovingFromParent || controller.isBeingDismissed {
                leavePage()
                return
            }
            ancestor = controller.parent
        }
        if pageNavigationController?.viewControllers.contains(where: { $0 === self }) == false {
            leavePage()
        }
    }

    private func leavePage() {
        guard !hasLeftPage else { return }
        hasLeftPage = true
        suspendThumbnails()
        cellArticles.removeAll()
        NotificationCenter.default.removeObserver(self)
        invalidateRequests()
        screen.unbind()
        isRuntimeReady = false
    }

    private var canUseArticleList: Bool {
        hasAppeared && !hasLeftPage && !applicationSuspended && !sceneSuspended && !protectedDataSuspended
            && RssArticleListPresentation.isActive(self)
    }

    @objc private func suspendPresentation(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification:
            applicationSuspended = true
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification:
            sceneSuspended = true
        case UIApplication.protectedDataWillBecomeUnavailableNotification: protectedDataSuspended = true
        default: break
        }
        suspendThumbnails()
    }

    @objc private func resumePresentation(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        switch notification.name {
        case UIApplication.didBecomeActiveNotification: applicationSuspended = false
        case UIScene.didActivateNotification: sceneSuspended = false
        case UIApplication.protectedDataDidBecomeAvailableNotification: protectedDataSuspended = false
        default: break
        }
        DispatchQueue.main.async { [weak self] in self?.resumeVisibleThumbnails() }
    }

    private func suspendThumbnails() {
        thumbnailGeneration = UUID()
        sizeUpdate?.cancel()
        sizeUpdate = nil
        needsSizeUpdateOnResume = needsSizeUpdateOnResume || !pendingSizeChanges.isEmpty
        pendingSizeChanges.removeAll()
        for case let cell as AndroidReplicaRssArticleCell in tableView.visibleCells { cell.cancelThumbnailLoading() }
    }

    private func resumeVisibleThumbnails() {
        guard canUseArticleList else { suspendThumbnails(); return }
        let updateSizes = needsSizeUpdateOnResume
        needsSizeUpdateOnResume = false
        for case let cell as AndroidReplicaRssArticleCell in tableView.visibleCells {
            if let article = cellArticles[ObjectIdentifier(cell)], isCurrentVisibleCell(cell, article: article) {
                cell.resumeThumbnailLoading()
                if updateSizes { articleSizeChanged(cell, article: article) }
            } else {
                cell.cancelThumbnailLoading()
            }
        }
    }

    private func configureViews() {
        refreshButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshButton.accessibilityLabel = L10n.RSS.refreshArticles
        refreshButton.accessibilityIdentifier = UIIdentifiers.RSS.refreshButton
        refreshButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.RSS.refreshArticles))
        refreshButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        sortButton.setImage(UIImage(systemName: "line.3.horizontal.decrease.circle"), for: .normal)
        sortButton.accessibilityLabel = L10n.RSS.sortFallback
        sortButton.accessibilityIdentifier = UIIdentifiers.RSS.sortButton
        sortButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.RSS.sortFallback))
        sortButton.addTarget(self, action: #selector(showSortPicker), for: .touchUpInside)
        topBar.addAction(refreshButton)
        topBar.addAction(sortButton)
        updateSortMenu()

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.table
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.register(
            AndroidReplicaRssArticleCell.self, forCellReuseIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier)
        tableView.register(
            AndroidReplicaLoadMoreCell.self, forCellReuseIdentifier: AndroidReplicaLoadMoreCell.reuseIdentifier)

        statusBar.axis = .horizontal
        statusBar.alignment = .center
        statusBar.spacing = 8
        statusBar.isHidden = true
        statusBar.accessibilityIdentifier = "rss.detail.status"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.numberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.accessibilityLabel = L10n.Common.retry
        retryButton.accessibilityIdentifier = "rss.detail.retry"
        retryButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Common.retry))
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        let retryWidth = retryButton.widthAnchor.constraint(equalToConstant: 44)
        retryWidth.priority = .defaultHigh
        retryWidth.isActive = true
        let retryHeight = retryButton.heightAnchor.constraint(equalToConstant: 44)
        retryHeight.priority = .defaultHigh
        retryHeight.isActive = true
        let statusHeight = statusBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        statusHeight.priority = .defaultHigh
        statusHeight.isActive = true
        let leadingSpace = UIView()
        let trailingSpace = UIView()
        leadingSpace.widthAnchor.constraint(equalToConstant: 8).isActive = true
        trailingSpace.widthAnchor.constraint(equalToConstant: 0).isActive = true
        [leadingSpace, statusSpinner, statusLabel, retryButton, trailingSpace].forEach {
            statusBar.addArrangedSubview($0)
        }

        let contentStack = UIStackView(arrangedSubviews: [topBar, statusBar, tableView])
        contentStack.axis = .vertical
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        stateView.backgroundColor = AndroidReplicaTheme.background
        stateView.setTestingIdentifier(UIIdentifiers.RSS.state)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        view.addSubview(stateView)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.topAnchor.constraint(equalTo: tableView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: tableView.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func bootstrap() {
        guard !hasLeftPage else { return }
        screen.onFavoritesChange = { [weak self] favorites in
            guard let self, !self.hasLeftPage else { return }
            self.favorites = favorites
        }
        switch screen.bootstrap() {
        case .success:
            isRuntimeReady = true
            loadSorts(forceRefresh: false)
        case let .failure(error):
            showFailure(message: error.message, action: .bootstrap)
        }
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func refresh() {
        guard !hasLeftPage else { return }
        if isRuntimeReady {
            loadSorts(forceRefresh: true)
        } else {
            bootstrap()
        }
    }

    private func invalidateRequests() {
        // The shared continuation can complete after cancellation; invalidate UI delivery too.
        requestGeneration &+= 1
        sortsTask?.cancel()
        articlesTask?.cancel()
        sortsTask = nil
        articlesTask = nil
        isLoadingFirstPage = false
        isLoadingMore = false
    }

    private func isCurrentRequest(_ generation: Int, sort: (name: String, url: String)?) -> Bool {
        !hasLeftPage && generation == requestGeneration && selectedSort?.name == sort?.name
            && selectedSort?.url == sort?.url
    }

    private func clearArticles() {
        articles = []
        currentPage = 0
        nextPageUrl = nil
        visitedPageURLs = []
        isPaginationFinished = true
    }

    private func beginFirstPageLoad(keepingArticles: Bool) {
        invalidateRequests()
        if !keepingArticles { clearArticles() }
        isLoadingFirstPage = true
        retryAction = nil
        renderArticles(resetOffset: !keepingArticles)
    }

    private func loadSorts(forceRefresh: Bool) {
        guard !hasLeftPage else { return }
        beginFirstPageLoad(keepingArticles: !articles.isEmpty)
        showLoading(L10n.RSS.loadingSorts)
        let generation = requestGeneration
        let previousSort = selectedSort
        sortsTask = Task { @MainActor [weak self, screen, source] in
            do {
                try Task.checkCancellation()
                let loadedSorts = try await screen.loadSorts(source: source, forceRefresh: forceRefresh)
                guard !Task.isCancelled, let self, self.isCurrentRequest(generation, sort: previousSort) else { return }
                self.sortsTask = nil
                self.sorts = loadedSorts
                self.selectedSort =
                    loadedSorts.first(where: { $0.url == previousSort?.url && $0.name == previousSort?.name })
                    ?? loadedSorts.first(where: { $0.url == previousSort?.url })
                    ?? loadedSorts.first(where: { $0.name == previousSort?.name })
                    ?? loadedSorts.first
                self.updateSortMenu()
                if self.selectedSort?.url != previousSort?.url || self.selectedSort?.name != previousSort?.name {
                    self.clearArticles()
                    self.renderArticles(resetOffset: true)
                }
                guard let selectedSort = self.selectedSort else {
                    self.isLoadingFirstPage = false
                    self.clearArticles()
                    self.renderArticles(resetOffset: true)
                    self.showEmpty(L10n.RSS.emptySortPlaceholder)
                    return
                }
                self.showLoading(L10n.RSS.loadingArticles)
                self.loadArticles(
                    sort: selectedSort, requestURL: selectedSort.url, page: 1, append: false, generation: generation)
            } catch {
                guard !Task.isCancelled, let self, self.isCurrentRequest(generation, sort: previousSort) else { return }
                self.sortsTask = nil
                self.isLoadingFirstPage = false
                self.showFailure(message: error.userFacingMessage, action: .sorts)
            }
        }
    }

    private func updateSortMenu() {
        let title = selectedSort?.name ?? L10n.RSS.sortFallback
        topBar.setTitle(title.isEmpty ? source.sourceName : "\(title) · \(source.sourceName)")
        sortButton.accessibilityValue = selectedSort?.name
        sortButton.isEnabled = sorts.isEmpty == false
        sortButton.tintColor = sorts.isEmpty ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
    }

    @objc private func showSortPicker() {
        guard !hasLeftPage, presentedViewController == nil else { return }
        guard sorts.isEmpty == false else {
            showTransientMessage(L10n.RSS.sortUnavailable)
            return
        }
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.RSS.sortFallback,
            options: sorts.map { sort in
                .init(title: sort.name, isSelected: sort.name == selectedSort?.name && sort.url == selectedSort?.url) {
                    [weak self] in
                    self?.selectSort(sort)
                }
            }
        )
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: sorts.count)),
            animated: true
        )
    }

    private func selectSort(_ sort: (name: String, url: String)) {
        guard !hasLeftPage, sort.name != selectedSort?.name || sort.url != selectedSort?.url,
            let currentSort = sorts.first(where: { $0.name == sort.name && $0.url == sort.url })
        else { return }
        selectedSort = currentSort
        updateSortMenu()
        beginFirstPageLoad(keepingArticles: false)
        showLoading(L10n.RSS.loadingArticles)
        loadArticles(
            sort: currentSort, requestURL: currentSort.url, page: 1, append: false, generation: requestGeneration)
    }

    private func loadArticles(
        sort: (name: String, url: String), requestURL: String, page: Int32, append: Bool, generation: Int
    ) {
        guard isCurrentRequest(generation, sort: sort), articlesTask == nil, sortsTask == nil else { return }
        articlesTask = Task { @MainActor [weak self, screen, source] in
            do {
                try Task.checkCancellation()
                let payload = try await screen.loadArticles(
                    sortName: sort.name, sortUrl: requestURL, source: source, page: page)
                guard !Task.isCancelled, let self, self.isCurrentRequest(generation, sort: sort) else { return }
                self.articlesTask = nil
                self.applyArticles(payload, requestURL: requestURL, page: page, append: append)
            } catch {
                guard !Task.isCancelled, let self, self.isCurrentRequest(generation, sort: sort) else { return }
                self.articlesTask = nil
                self.isLoadingFirstPage = false
                self.isLoadingMore = false
                self.showFailure(message: error.userFacingMessage, action: append ? .more : .firstPage)
                if append,
                    let cell = self.tableView.cellForRow(at: IndexPath(row: self.articles.count, section: 0))
                        as? AndroidReplicaLoadMoreCell
                {
                    self.configurePaginationCell(cell)
                }
            }
        }
    }

    private func applyArticles(_ payload: RssArticlesPayload, requestURL: String, page: Int32, append: Bool) {
        let previousCount = articles.count
        let hadPaginationRow = showsPaginationRow
        var seen = append ? Set(articles.map { ArticleIdentity($0) }) : Set<ArticleIdentity>()
        let newArticles = payload.articles.filter { seen.insert(ArticleIdentity($0)).inserted }
        if append {
            articles.append(contentsOf: newArticles)
        } else {
            articles = newArticles
            visitedPageURLs = []
        }
        visitedPageURLs.insert(requestURL)
        currentPage = page
        nextPageUrl = payload.nextPageUrl
        // PAGE retains its URL rule; the same template is rebuilt with the incremented page.
        let repeatsURL = !usesPageTemplate && (nextRequestURL.map { visitedPageURLs.contains($0) } ?? false)
        isPaginationFinished = newArticles.isEmpty || nextRequestURL == nil || repeatsURL || page == Int32.max
        isLoadingFirstPage = false
        isLoadingMore = false
        retryAction = nil
        hideStatus()
        if articles.isEmpty {
            showEmpty(L10n.RSS.emptyArticles)
        } else {
            stateView.hide()
        }
        if append {
            renderAppendedArticles(from: previousCount, hadPaginationRow: hadPaginationRow)
        } else {
            renderArticles()
        }
    }

    private var usesPageTemplate: Bool {
        source.ruleNextPage?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PAGE"
    }

    private var nextRequestURL: String? {
        guard let url = nextPageUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        return url
    }

    private var hasMore: Bool {
        !isPaginationFinished && nextRequestURL != nil && currentPage > 0 && currentPage < Int32.max
    }

    private var showsPaginationRow: Bool {
        hasMore && !isLoadingFirstPage && (retryAction == nil || retryAction == .more)
    }

    private func showLoading(_ message: String) {
        retryAction = nil
        if articles.isEmpty {
            hideStatus()
            stateView.showLoading(message: message)
        } else {
            stateView.hide()
            statusLabel.text = message
            statusSpinner.isHidden = false
            statusSpinner.startAnimating()
            retryButton.isHidden = true
            statusBar.isHidden = false
        }
    }

    private func hideStatus() {
        statusSpinner.stopAnimating()
        statusBar.isHidden = true
    }

    private func showEmpty(_ message: String) {
        retryAction = nil
        hideStatus()
        stateView.showMessage(title: message)
    }

    private func showFailure(message: String, action: RetryAction) {
        retryAction = action
        statusSpinner.stopAnimating()
        if articles.isEmpty {
            hideStatus()
            stateView.showMessage(title: L10n.RSS.loadArticlesFailed, message: message, actionTitle: L10n.Common.retry)
            {
                [weak self] in
                self?.retry()
            }
        } else {
            stateView.hide()
            statusLabel.text = "\(L10n.RSS.loadArticlesFailed)\n\(message)"
            statusSpinner.isHidden = true
            retryButton.isHidden = false
            statusBar.isHidden = false
        }
    }

    @objc private func retry() {
        guard !hasLeftPage else { return }
        switch retryAction {
        case .bootstrap:
            bootstrap()
        case .sorts:
            loadSorts(forceRefresh: true)
        case .firstPage:
            guard let selectedSort else { return }
            beginFirstPageLoad(keepingArticles: !articles.isEmpty)
            showLoading(L10n.RSS.loadingArticles)
            loadArticles(
                sort: selectedSort, requestURL: selectedSort.url, page: 1, append: false, generation: requestGeneration)
        case .more:
            loadMore()
        case nil:
            break
        }
    }

    private func renderArticles(resetOffset: Bool = false) {
        suspendThumbnails()
        cellArticles.removeAll()
        isRendering = true
        defer {
            isRendering = false
            resumeVisibleThumbnails()
        }
        let offset = tableView.contentOffset
        tableView.accessibilityValue = "\(articles.count)"
        tableView.reloadData()
        view.layoutIfNeeded()
        let top = -tableView.adjustedContentInset.top
        let bottom = max(
            top, tableView.contentSize.height + tableView.adjustedContentInset.bottom - tableView.bounds.height)
        tableView.setContentOffset(
            CGPoint(x: 0, y: resetOffset ? top : min(max(offset.y, top), bottom)), animated: false)
    }

    private func renderAppendedArticles(from previousCount: Int, hadPaginationRow: Bool) {
        guard canUseArticleList else { renderArticles(); return }
        isRendering = true
        tableView.accessibilityValue = "\(articles.count)"
        UIView.performWithoutAnimation {
            tableView.performBatchUpdates {
                if hadPaginationRow {
                    tableView.deleteRows(at: [IndexPath(row: previousCount, section: 0)], with: .none)
                }
                var inserted = (previousCount..<articles.count).map { IndexPath(row: $0, section: 0) }
                if showsPaginationRow { inserted.append(IndexPath(row: articles.count, section: 0)) }
                if !inserted.isEmpty { tableView.insertRows(at: inserted, with: .none) }
            }
        }
        isRendering = false
        resumeVisibleThumbnails()
        scheduleSizeUpdate()
    }

    private func configureArticleCell(_ cell: AndroidReplicaRssArticleCell, article: RssArticle) {
        cell.onSizeChange = nil
        cellArticles[ObjectIdentifier(cell)] = article
        cell.configure(article: article, isRead: article.read || readInSession.contains(ArticleIdentity(article)))
        cell.cancelThumbnailLoading()
        cell.onSizeChange = { [weak self, weak cell] changedCell in
            guard let self, let cell, changedCell === cell, self.isCurrentVisibleCell(cell, article: article) else {
                return
            }
            self.articleSizeChanged(cell, article: article)
        }
    }

    private func isCurrentVisibleCell(_ cell: AndroidReplicaRssArticleCell, article: RssArticle) -> Bool {
        // Immutable Kotlin val fields: reference identity also rejects replaced origin/link/image/variable payloads.
        guard canUseArticleList, cellArticles[ObjectIdentifier(cell)] === article,
            let path = tableView.indexPath(for: cell), articles.indices.contains(path.row),
            articles[path.row] === article,
            tableView.cellForRow(at: path) === cell, tableView.indexPathsForVisibleRows?.contains(path) == true,
            cell.window === viewIfLoaded?.window, !cell.isHidden, cell.alpha > 0.01,
            tableView.bounds.intersects(tableView.rectForRow(at: path))
        else { return false }
        return true
    }

    private func articleSizeChanged(_ cell: AndroidReplicaRssArticleCell, article: RssArticle) {
        let generation = thumbnailGeneration
        pendingSizeChanges[ObjectIdentifier(cell)] = {
            [
                weak self, weak cell, weak window = cell.window, weak scene = cell.window?.windowScene,
                weak navigation = navigationController, weak root = cell.window?.rootViewController
            ] in
            guard let self, let cell, let window, let scene, let navigation, let root,
                self.thumbnailGeneration == generation, self.viewIfLoaded?.window === window,
                window.windowScene === scene, window.rootViewController === root,
                self.navigationController === navigation
            else { return false }
            return self.isCurrentVisibleCell(cell, article: article)
        }
        scheduleSizeUpdate()
    }

    private var canUpdateSizes: Bool {
        canUseArticleList && !isRendering && !tableView.isTracking && !tableView.isDragging
            && !tableView.isDecelerating && !tableView.hasUncommittedUpdates
    }

    private func scheduleSizeUpdate() {
        guard sizeUpdate == nil, !pendingSizeChanges.isEmpty, canUpdateSizes else { return }
        let generation = thumbnailGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.thumbnailGeneration == generation else { return }
            self.sizeUpdate = nil
            guard self.canUpdateSizes else { return }
            let changes = Array(self.pendingSizeChanges.values)
            self.pendingSizeChanges.removeAll()
            guard changes.contains(where: { $0() }) else { return }
            self.isRendering = true
            UIView.performWithoutAnimation { self.tableView.performBatchUpdates(nil) }
            self.isRendering = false
            self.scheduleSizeUpdate()
        }
        sizeUpdate = work
        DispatchQueue.main.async(execute: work)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        articles.count + (showsPaginationRow ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if showsPaginationRow, indexPath.row == articles.count {
            let cell =
                tableView.dequeueReusableCell(
                    withIdentifier: AndroidReplicaLoadMoreCell.reuseIdentifier, for: indexPath)
                as! AndroidReplicaLoadMoreCell
            configurePaginationCell(cell)
            return cell
        }
        let article = articles[indexPath.row]
        let cell =
            tableView.dequeueReusableCell(withIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier, for: indexPath)
            as! AndroidReplicaRssArticleCell
        cell.accessibilityIdentifier = UIIdentifiers.RSS.articleCell
        configureArticleCell(cell, article: article)
        return cell
    }

    private func configurePaginationCell(_ cell: AndroidReplicaLoadMoreCell) {
        let title =
            isLoadingMore ? L10n.RSS.loadingNextPage : (retryAction == .more ? L10n.Common.retry : L10n.Common.loadMore)
        cell.configure(title: title)
        cell.isAccessibilityElement = true
        cell.accessibilityIdentifier = UIIdentifiers.RSS.loadMoreCell
        cell.accessibilityLabel = title
        cell.accessibilityTraits = isLoadingMore ? [.button, .notEnabled] : [.button]
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard tableView === self.tableView, let cell = cell as? AndroidReplicaRssArticleCell,
            articles.indices.contains(indexPath.row)
        else { return }
        let article = articles[indexPath.row]
        if cellArticles[ObjectIdentifier(cell)] !== article { configureArticleCell(cell, article: article) }
        let generation = thumbnailGeneration
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self, let cell, self.thumbnailGeneration == generation,
                self.isCurrentVisibleCell(cell, article: article)
            else { return }
            cell.resumeThumbnailLoading()
        }
    }

    func tableView(_: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt _: IndexPath) {
        guard let cell = cell as? AndroidReplicaRssArticleCell else { return }
        cell.cancelThumbnailLoading()
        cell.onSizeChange = nil
        cellArticles.removeValue(forKey: ObjectIdentifier(cell))
        pendingSizeChanges.removeValue(forKey: ObjectIdentifier(cell))
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canUseArticleList else { return }
        if showsPaginationRow, indexPath.row == articles.count {
            loadMore()
        } else if articles.indices.contains(indexPath.row) {
            openArticle(articles[indexPath.row])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isRendering, retryAction == nil, scrollView.isDragging || scrollView.isDecelerating,
            scrollView.contentOffset.y + scrollView.bounds.height > scrollView.contentSize.height - 120
        else { return }
        loadMore()
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleSizeUpdate() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { scheduleSizeUpdate() }

    private func loadMore() {
        guard canUseArticleList, !isRendering, hasMore, !isLoadingFirstPage, !isLoadingMore,
            sortsTask == nil, articlesTask == nil, retryAction == nil || retryAction == .more,
            let selectedSort, let nextRequestURL
        else { return }
        let requestURL = usesPageTemplate ? selectedSort.url : nextRequestURL
        isLoadingMore = true
        retryAction = nil
        hideStatus()
        if let cell = tableView.cellForRow(at: IndexPath(row: articles.count, section: 0))
            as? AndroidReplicaLoadMoreCell
        {
            configurePaginationCell(cell)
        }
        loadArticles(
            sort: selectedSort, requestURL: requestURL, page: currentPage + 1, append: true,
            generation: requestGeneration)
    }

    private func openArticle(_ article: RssArticle) {
        guard canUseArticleList, !isRendering, let navigation = navigationController,
            articles.contains(where: { $0 === article })
        else { return }
        let controller = AndroidReplicaRssArticleViewController(
            article: article, source: source, screen: screen, favorites: favorites)
        controller.hidesBottomBarWhenPushed = true
        suspendThumbnails()
        navigation.pushViewController(controller, animated: true)
        if navigation.topViewController === controller {
            readInSession.insert(ArticleIdentity(article))
            for case let cell as AndroidReplicaRssArticleCell in tableView.visibleCells
            where cellArticles[ObjectIdentifier(cell)] === article { cell.updateReadState(true) }
        }
    }
}
