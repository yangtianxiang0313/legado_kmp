import shared
import UIKit

final class AndroidReplicaRssDetailViewController: UIViewController {
    private enum RetryAction: Equatable {
        case bootstrap, sorts, firstPage, more
    }

    private typealias ArticleIdentity = RssArticleListIdentity

    private let source: RssSource
    private let screen = RssScreenAdapter()
    private lazy var directoryLoader = RssDirectoryLoadingCoordinator(screen: screen)
    private lazy var directoryActions = RssDirectoryActionsCoordinator(
        owner: self, screen: screen, source: source,
        canUseActions: { [weak self] in self?.canUseArticleList == true },
        isRuntimeReady: { [weak self] in self?.isRuntimeReady == true },
        sourceAvailable: { [weak self] in self?.sourceAvailable == true },
        currentStyle: { [weak self] in self?.layoutStyle ?? .compact },
        onStyleChange: { [weak self] in self?.applyLayoutStyle($0) },
        onClearStarted: { [weak self] in self?.prepareToClearArticles() },
        onClearFinished: { [weak self] in self?.finishClearingArticles(success: $0) },
        onReturn: { [weak self] in self?.resumeAfterTransition() })
    private lazy var topBar = AndroidReplicaDetailBar(
        title: source.sourceName, target: self, backAction: #selector(handleBack))
    private let refreshButton = UIButton(type: .system)
    private let sortButton = UIButton(type: .system)
    private let articleList = RssArticleListController()
    private var layoutStyle: RssArticlePresentationStyle
    private var sourceAvailable = true
    private let stateView = ContentStateView()
    private let statusBar = UIStackView()
    private let statusLabel = UILabel()
    private let statusSpinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private var sorts: [(name: String, url: String)] = []
    private var selectedSort: (name: String, url: String)?
    private var articles: [RssArticle] = []
    private var readLinks = Set<Data>()
    private var articlesClearedUntilRefresh = false
    private var favorites: [RssStar] = []
    private var nextPageUrl: String?
    private var currentPage: Int32 = 0
    private var visitedPageURLs = Set<String>()
    private var isPaginationFinished = true
    private var isLoadingFirstPage = false
    private var isLoadingMore = false
    private var isShowingSavedArticles = false
    private var isRuntimeReady = false
    private var hasLeftPage = false
    private var hasAppeared = false
    private var applicationSuspended = UIApplication.shared.applicationState != .active
    private var sceneSuspended = false
    private var protectedDataSuspended = false
    private var lockSuspended = false
    private var retryAction: RetryAction?
    private var requestGeneration = 0
    private var sortsTask: Task<Void, Never>?
    private weak var pageNavigationController: UINavigationController?

    init(source: RssSource) {
        self.source = source
        layoutStyle = RssArticlePresentationStyle(articleStyle: source.articleStyle)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        sortsTask?.cancel()
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
        navigationController?.setNavigationBarHidden(true, animated: false)
        pageNavigationController = navigationController
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        sceneSuspended = view.window?.windowScene?.activationState != .foregroundActive
        resumeAfterTransition()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hasAppeared = false
        articleList.suspend()
        directoryActions.pageWillDisappear()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        articleList.layoutDidChange()
        directoryActions.updateButtons()
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
        articleList.suspend()
        directoryActions.suspend()
        NotificationCenter.default.removeObserver(self)
        invalidateRequests()
        screen.unbind()
        isRuntimeReady = false
    }

    private var canUseArticleList: Bool {
        hasAppeared && !hasLeftPage && !applicationSuspended && !sceneSuspended && !protectedDataSuspended
            && !lockSuspended
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
        case .appLockWillCover: lockSuspended = true
        default: break
        }
        articleList.suspend()
        directoryActions.suspend()
    }

    @objc private func resumePresentation(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        switch notification.name {
        case UIApplication.didBecomeActiveNotification: applicationSuspended = false
        case UIScene.didActivateNotification: sceneSuspended = false
        case UIApplication.protectedDataDidBecomeAvailableNotification: protectedDataSuspended = false
        case .appLockStatusDidChange:
            lockSuspended = !AppLockManager.shared.isUnlocked(in: viewIfLoaded?.window)
        default: break
        }
        DispatchQueue.main.async { [weak self] in
            self?.articleList.resume(); self?.directoryActions.updateButtons()
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
        directoryActions.configureButtons()
        topBar.addAction(directoryActions.layoutButton)
        topBar.addAction(directoryActions.moreButton, isOverflow: true)
        updateSortMenu()
        articleList.isPresentationActive = { [weak self] in self?.canUseArticleList == true }
        articleList.isArticleRead = { [weak self] article in
            self?.readLinks.contains(Data(article.link.utf8)) == true
        }
        articleList.onSelectArticle = { [weak self] in self?.openArticle($0) }
        articleList.onLoadMore = { [weak self] in self?.loadMore() }

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

        let contentStack = UIStackView(arrangedSubviews: [topBar, statusBar, articleList.view])
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
            stateView.topAnchor.constraint(equalTo: articleList.view.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: articleList.view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: articleList.view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: articleList.view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func bootstrap() {
        guard !hasLeftPage else { return }
        screen.onFavoritesChange = { [weak self] favorites in
            guard let self, !self.hasLeftPage else { return }
            self.favorites = favorites
        }
        screen.onReadRecordsChange = { [weak self] records in
            guard let self, !self.hasLeftPage else { return }
            self.readLinks = Set(records.filter(\.read).map { Data($0.record.utf8) })
            self.articleList.refreshReadStates()
        }
        screen.onSourcesChange = { [weak self] sources in
            guard let self, !self.hasLeftPage else { return }
            let current = sources.first { $0.sourceUrl.utf8.elementsEqual(self.source.sourceUrl.utf8) }
            self.sourceAvailable = current != nil
            if let current { self.applyLayoutStyle(RssArticlePresentationStyle(articleStyle: current.articleStyle)) }
            self.directoryActions.updateButtons()
        }
        switch screen.bootstrap() {
        case .success:
            isRuntimeReady = true
            loadSorts(forceRefresh: false)
            directoryActions.updateButtons()
        case let .failure(error):
            showFailure(message: error.message, action: .bootstrap)
        }
    }

    @objc private func handleBack() {
        guard canUseArticleList else { return }
        navigationController?.popViewController(animated: true)
    }

    private func resumeAfterTransition() {
        let enqueue = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.articleList.resume(); self?.directoryActions.updateButtons()
            }
        }
        if let transition = transitionCoordinator,
            transition.animate(alongsideTransition: nil, completion: { _ in enqueue() })
        {
            return
        }
        enqueue()
    }

    private func applyLayoutStyle(_ style: RssArticlePresentationStyle) {
        guard style != layoutStyle else { return }
        layoutStyle = style
        renderArticles()
        directoryActions.updateButtons()
    }

    private func prepareToClearArticles() {
        invalidateRequests()
        hideStatus()
        if articles.isEmpty { stateView.showLoading(message: L10n.Common.loadingTitle) }
        articleList.updatePagination(pagination)
        updateSortMenu()
    }

    private func finishClearingArticles(success: Bool) {
        guard !hasLeftPage else { return }
        if success {
            invalidateRequests()
            articlesClearedUntilRefresh = true
            clearArticles()
            renderArticles(resetOffset: true)
            showEmpty(L10n.RSS.emptyArticles)
        } else if articles.isEmpty {
            showEmpty(L10n.RSS.emptyArticles)
        }
        updateSortMenu()
    }

    @objc private func refresh() {
        guard canUseArticleList, !directoryActions.isClearingArticles else { return }
        articlesClearedUntilRefresh = false
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
        directoryLoader.cancel()
        sortsTask = nil
        isLoadingFirstPage = false
        isLoadingMore = false
    }

    private func isCurrentRequest(_ generation: Int, sort: (name: String, url: String)?) -> Bool {
        !hasLeftPage && generation == requestGeneration && selectedSort?.name == sort?.name
            && selectedSort?.url == sort?.url
    }

    private func clearArticles() {
        articles = []
        isShowingSavedArticles = false
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
        guard !hasLeftPage, !directoryActions.isClearingArticles, !articlesClearedUntilRefresh else { return }
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
                self.acceptSorts(loadedSorts, previous: previousSort)
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
                await self.restoreSavedSorts(after: error, generation: generation, previous: previousSort)
            }
        }
    }

    private func acceptSorts(_ loaded: [(name: String, url: String)], previous: (name: String, url: String)?) {
        sorts = loaded
        selectedSort =
            loaded.first { $0.url == previous?.url && $0.name == previous?.name }
            ?? loaded.first { $0.url == previous?.url } ?? loaded.first { $0.name == previous?.name } ?? loaded.first
        updateSortMenu()
        if selectedSort?.url != previous?.url || selectedSort?.name != previous?.name {
            clearArticles()
            renderArticles(resetOffset: true)
        }
    }

    private func restoreSavedSorts(after error: Error, generation: Int, previous: (name: String, url: String)?) async {
        do {
            let savedSorts = try await screen.cachedSorts(source: source)
            guard !Task.isCancelled, isCurrentRequest(generation, sort: previous) else { return }
            if !savedSorts.isEmpty { acceptSorts(savedSorts, previous: previous) }
            if articles.isEmpty, let sort = selectedSort {
                let saved = try await screen.cachedArticles(source: source, sortName: sort.name, sortURL: sort.url)
                guard !Task.isCancelled, isCurrentRequest(generation, sort: sort) else { return }
                if !saved.isEmpty { applySavedArticles(saved) }
            }
        } catch {
            guard !Task.isCancelled, !hasLeftPage, generation == requestGeneration else { return }
        }
        guard !Task.isCancelled, !hasLeftPage, generation == requestGeneration else { return }
        sortsTask = nil
        isLoadingFirstPage = false
        showFailure(message: error.userFacingMessage, action: .sorts)
    }

    private func updateSortMenu() {
        let title = selectedSort?.name ?? L10n.RSS.sortFallback
        topBar.setTitle(title.isEmpty ? source.sourceName : "\(title) · \(source.sourceName)")
        sortButton.accessibilityValue = selectedSort?.name
        sortButton.isEnabled = !sorts.isEmpty && !directoryActions.isClearingArticles
        refreshButton.isEnabled = !directoryActions.isClearingArticles
        sortButton.tintColor = sorts.isEmpty ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
    }

    @objc private func showSortPicker() {
        guard canUseArticleList, !directoryActions.isClearingArticles, presentedViewController == nil else { return }
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
        guard !hasLeftPage, !directoryActions.isClearingArticles,
            sort.name != selectedSort?.name || sort.url != selectedSort?.url,
            let currentSort = sorts.first(where: { $0.name == sort.name && $0.url == sort.url })
        else { return }
        selectedSort = currentSort
        updateSortMenu()
        if articlesClearedUntilRefresh {
            invalidateRequests()
            clearArticles()
            renderArticles(resetOffset: true)
            showEmpty(L10n.RSS.emptyArticles)
            return
        }
        beginFirstPageLoad(keepingArticles: false)
        showLoading(L10n.RSS.loadingArticles)
        loadArticles(
            sort: currentSort, requestURL: currentSort.url, page: 1, append: false, generation: requestGeneration)
    }

    private func loadArticles(
        sort: (name: String, url: String), requestURL: String, page: Int32, append: Bool, generation: Int
    ) {
        guard isCurrentRequest(generation, sort: sort), !directoryActions.isClearingArticles,
            !articlesClearedUntilRefresh, !directoryLoader.isLoading, sortsTask == nil
        else { return }
        directoryLoader.load(
            source: source, sort: sort, requestURL: requestURL, page: page, showSaved: !append && articles.isEmpty,
            onSaved: { [weak self] saved in
                guard let self, self.isCurrentRequest(generation, sort: sort), self.articles.isEmpty else { return }
                self.applySavedArticles(saved)
                self.showLoading(L10n.RSS.loadingArticles)
            },
            onSuccess: { [weak self] result in
                guard let self, self.isCurrentRequest(generation, sort: sort) else { return }
                self.applyArticles(
                    RssArticlesPayload(articles: result.articles, nextPageUrl: result.nextPageUrl),
                    requestURL: requestURL, page: page, append: append)
                if !result.cacheRetained, self.canUseArticleList {
                    self.showTransientMessage(L10n.RSS.directoryRetentionFailed)
                }
            },
            onFailure: { [weak self] error in
                guard let self, self.isCurrentRequest(generation, sort: sort) else { return }
                self.isLoadingFirstPage = false
                self.isLoadingMore = false
                self.showFailure(message: error.userFacingMessage, action: append ? .more : .firstPage)
                if append { self.articleList.updatePagination(self.pagination) }
            })
    }

    private func applySavedArticles(_ saved: [RssArticle]) {
        articles = saved
        currentPage = 0
        nextPageUrl = nil
        visitedPageURLs = []
        isPaginationFinished = true
        isShowingSavedArticles = true
        stateView.hide()
        renderArticles()
    }

    private func applyArticles(_ payload: RssArticlesPayload, requestURL: String, page: Int32, append: Bool) {
        let previousCount = articles.count
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
        isShowingSavedArticles = false
        retryAction = nil
        hideStatus()
        if articles.isEmpty {
            showEmpty(L10n.RSS.emptyArticles)
        } else {
            stateView.hide()
        }
        if append {
            renderAppendedArticles(from: previousCount)
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
            statusBar.accessibilityValue = isShowingSavedArticles ? "saved-loading" : "loading"
        }
    }

    private func hideStatus() {
        statusSpinner.stopAnimating()
        statusBar.isHidden = true
        statusBar.accessibilityValue = "hidden"
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
            let title =
                isShowingSavedArticles
                ? "\(L10n.RSS.savedArticles) · \(L10n.RSS.loadArticlesFailed)" : L10n.RSS.loadArticlesFailed
            statusLabel.text = "\(title)\n\(message)"
            statusSpinner.isHidden = true
            retryButton.isHidden = false
            statusBar.isHidden = false
            statusBar.accessibilityValue = isShowingSavedArticles ? "saved-error" : "error"
        }
    }

    @objc private func retry() {
        guard !hasLeftPage, !directoryActions.isClearingArticles, !articlesClearedUntilRefresh else { return }
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
        articleList.display(articles: articles, style: layoutStyle, pagination: pagination, resetOffset: resetOffset)
    }

    private func renderAppendedArticles(from previousCount: Int) {
        articleList.display(articles: articles, style: layoutStyle, pagination: pagination, appendFrom: previousCount)
    }

    private var pagination: RssArticleListController.Pagination? {
        guard showsPaginationRow else { return nil }
        return .init(
            title: isLoadingMore
                ? L10n.RSS.loadingNextPage : (retryAction == .more ? L10n.Common.retry : L10n.Common.loadMore),
            isLoading: isLoadingMore)
    }

    private func loadMore() {
        guard canUseArticleList, !directoryActions.isClearingArticles, !articlesClearedUntilRefresh,
            !articleList.isRendering, hasMore, !isLoadingFirstPage, !isLoadingMore,
            sortsTask == nil, !directoryLoader.isLoading, retryAction == nil || retryAction == .more,
            let selectedSort, let nextRequestURL
        else { return }
        let requestURL = usesPageTemplate ? selectedSort.url : nextRequestURL
        isLoadingMore = true
        retryAction = nil
        hideStatus()
        articleList.updatePagination(pagination)
        loadArticles(
            sort: selectedSort, requestURL: requestURL, page: currentPage + 1, append: true,
            generation: requestGeneration)
    }

    private func openArticle(_ article: RssArticle) {
        guard canUseArticleList, !directoryActions.isClearingArticles,
            !articleList.isRendering, let navigation = navigationController,
            articles.contains(where: { $0 === article })
        else { return }
        let controller = AndroidReplicaRssArticleViewController(
            article: article, source: source, screen: screen, favorites: favorites)
        controller.hidesBottomBarWhenPushed = true
        articleList.suspend()
        navigation.pushViewController(controller, animated: true)
        if navigation.topViewController === controller {
            let window = viewIfLoaded?.window
            let root = window?.rootViewController
            let scene = window?.windowScene
            Task { @MainActor [screen, weak controller, weak window, weak root, weak scene] in
                do { try await screen.markRead(article: article) } catch {
                    let showFailure = { [weak controller, weak window, weak root, weak scene] in
                        guard let controller, let window, let root, let scene,
                            controller.canPerformNavigationAction, controller.viewIfLoaded?.window === window,
                            window.rootViewController === root, window.windowScene === scene, window.isKeyWindow,
                            scene.activationState == .foregroundActive, UIApplication.shared.isProtectedDataAvailable,
                            AppLockManager.shared.isUnlocked(in: window)
                        else { return }
                        controller.showTransientMessage(L10n.RSS.readRecordFailed)
                    }
                    if let transition = controller?.transitionCoordinator,
                        transition.animate(
                            alongsideTransition: nil,
                            completion: { context in
                                if !context.isCancelled { DispatchQueue.main.async(execute: showFailure) }
                            })
                    {
                        return
                    }
                    DispatchQueue.main.async(execute: showFailure)
                }
            }
        } else {
            articleList.resume()
        }
    }
}
