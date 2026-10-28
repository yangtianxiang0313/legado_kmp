import shared
import UIKit
import WebKit

final class AndroidReplicaRssArticleViewController: UIViewController, WKNavigationDelegate, WKUIDelegate,
    NavigationBackActionHandling, UIGestureRecognizerDelegate
{
    private let article: RssArticle
    private var source: RssSource?
    private let screen: RssScreenAdapter
    private let initialFavorites: [RssStar]

    private lazy var topBar = AndroidReplicaDetailBar(title: titleText, target: self, backAction: #selector(handleBack))
    private let favoriteButton = UIButton(type: .system)
    private let refreshButton = UIButton(type: .system)
    private let readAloudButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let dividerView = UIView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let stateView = ContentStateView()
    private let speech = RssArticleSpeechController()
    private let userContentController = WKUserContentController()
    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .nonPersistent()
        config.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.backgroundColor = AndroidReplicaTheme.background
        webView.isOpaque = false
        webView.scrollView.backgroundColor = AndroidReplicaTheme.background
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = self
        webView.uiDelegate = self
        return webView
    }()

    private var progressObservation: NSKeyValueObservation?
    private var contentTask: Task<Void, Never>?
    private var contentRequestID: UUID?
    private var favoriteTask: Task<Void, Never>?
    private var favoritesSubscription: FlowSubscription?
    private var favoritesObservationID: UUID?
    private var hasObservedFavorites = false
    private var isFavoriteSynchronized = false
    private var isPageActive = false
    private var pageID = UUID()
    private var isFavorite = false
    private var renderedContent: String?
    private var contentErrorMessage: String?
    private var needsWebReload = false
    private var isWebContentReady = false
    private var remotePageURL: URL?
    private var currentNavigation: WKNavigation?
    private lazy var browser = RssArticleWebSession(article: article)
    private var navigationTask: Task<Void, Never>?
    private var navigationRequestID = UUID()
    private var waitsForRefresh = false
    private var articleReturnOffset: CGPoint?
    private var restoresArticleOffset = false
    private var resourcePolicy: RssArticleResourcePolicy?
    private var programmaticURL: URL?
    private var imagePageID: UUID?
    private weak var imageLongPress: UILongPressGestureRecognizer?
    private lazy var imageActions = RssArticleImageCoordinator(
        owner: self,
        prepareResource: { [weak self] url in
            guard let self else { throw CancellationError() }
            return try await self.browser.prepareResource(url)
        },
        canUseActions: { [weak self] in
            guard let self else { return false }
            return self.isPageActive && self.pageID == self.imagePageID
                && UIApplication.shared.applicationState == .active
                && self.viewIfLoaded?.window?.isKeyWindow == true
                && AppLockManager.shared.isUnlocked(in: self.viewIfLoaded?.window)
        })
    private lazy var linkActions = RssArticleLinkActionCoordinator(owner: self) { [weak self] in
        self?.canUseArticleActions == true
    }

    private var canUseArticleActions: Bool {
        isPageActive && canPerformNavigationAction && presentedViewController == nil
            && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.isKeyWindow == true
            && AppLockManager.shared.isUnlocked(in: viewIfLoaded?.window)
    }

    private var usesRemoteWebPage: Bool {
        RssArticleContentResolver.usesWebPage(article: article, source: source)
    }

    private var titleText: String {
        article.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.RSS.articleReaderTitle : article.title
    }

    init(article: RssArticle, source: RssSource?, screen: RssScreenAdapter, favorites: [RssStar]) {
        self.article = article
        self.source = source
        self.screen = screen
        initialFavorites = favorites
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        contentTask?.cancel()
        favoriteTask?.cancel()
        favoritesSubscription?.cancel()
        navigationTask?.cancel()
        progressObservation?.invalidate()
        stopReadAloud()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleText
        view.backgroundColor = AndroidReplicaTheme.background
        speech.canSpeak = { [weak self] in
            guard let self else { return false }
            return self.canUseArticleActions && self.isWebContentReady && self.contentErrorMessage == nil
        }
        speech.onChange = { [weak self] in self?.updateReadAloudButton() }
        isFavorite = initialFavorites.contains { $0.origin == article.origin && $0.link == article.link }
        configureChrome()
        configureWebView()
        configureStateView()
        configureProgress()
        NotificationCenter.default.addObserver(
            self, selector: #selector(suspendArticle), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resumeArticle), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        isPageActive = true
        refreshFavoriteState()
        observeFavorites()
        if contentErrorMessage == nil, !waitsForRefresh {
            if let renderedContent {
                if needsWebReload { renderHTML(renderedContent) }
            } else if usesRemoteWebPage {
                if needsWebReload || !isWebContentReady { loadContent() }
            } else if contentTask == nil {
                loadContent()
            }
        }
        updateReadAloudButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPageActive = false
        pageID = UUID()
        cancelContentLoad()
        navigationRequestID = UUID()
        navigationTask?.cancel()
        navigationTask = nil
        browser.cancel()
        imageActions.cancel()
        programmaticURL = nil
        stopObservingFavorites()
        needsWebReload = needsWebReload || webView.isLoading || !isWebContentReady
        if usesRemoteWebPage, let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            remotePageURL = url
        }
        currentNavigation = nil
        webView.stopLoading()
        progressView.isHidden = true
        stopReadAloud()
        updateFavoriteButton()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle,
            contentErrorMessage == nil,
            let renderedContent
        else { return }
        renderHTML(renderedContent)
    }

    private func configureChrome() {
        refreshButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        refreshButton.accessibilityLabel = "刷新文章"
        refreshButton.accessibilityIdentifier = "rss.article.refresh"
        refreshButton.addTarget(self, action: #selector(refreshArticle), for: .touchUpInside)
        favoriteButton.accessibilityIdentifier = UIIdentifiers.RSS.articleFavoriteButton
        favoriteButton.addTarget(self, action: #selector(toggleFavorite), for: .touchUpInside)

        readAloudButton.accessibilityIdentifier = "rss.readAloudButton"
        readAloudButton.addTarget(self, action: #selector(toggleReadAloud), for: .touchUpInside)

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.accessibilityLabel = L10n.Bookshelf.moreActions
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.makeMoreMenu().children ?? [])
            }
        ])

        topBar.addAction(refreshButton)
        topBar.addAction(favoriteButton)
        topBar.addAction(readAloudButton)
        topBar.addAction(moreButton)
        updateFavoriteButton()
        updateReadAloudButton()

        dividerView.backgroundColor = AndroidReplicaTheme.divider
        dividerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        view.addSubview(dividerView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            dividerView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            dividerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    private func configureWebView() {
        view.addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self
        longPress.cancelsTouchesInView = false
        imageLongPress = longPress
        webView.addGestureRecognizer(longPress)
    }

    private func configureStateView() {
        stateView.setTestingIdentifier("rss_web_state")
        stateView.backgroundColor = AndroidReplicaTheme.background
        view.addSubview(stateView)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stateView.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureProgress() {
        progressView.tintColor = AndroidReplicaTheme.accent
        progressView.trackTintColor = .clear
        progressView.progress = 0
        progressView.isHidden = true
        view.addSubview(progressView)
        progressView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: dividerView.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self, self.isPageActive, self.contentErrorMessage == nil else { return }
                let progress = Float(webView.estimatedProgress)
                self.progressView.setProgress(progress, animated: true)
                self.progressView.isHidden = !webView.isLoading || progress >= 1.0
            }
        }
    }

    private func makeMoreMenu() -> UIMenu {
        var actions: [UIAction] = []
        if source?.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || source?.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            actions.append(
                UIAction(title: "订阅源登录", image: UIImage(systemName: "person.crop.circle.badge.checkmark")) {
                    [weak self] _ in self?.openSourceLogin()
                })
        }
        if let linkURL = webView.url.flatMap({ ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }) ?? linkURL
        {
            actions.append(
                UIAction(title: L10n.RSS.shareLink, image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    self?.share(url: linkURL)
                })
            actions.append(
                UIAction(title: externalOpenTitle(for: linkURL), image: UIImage(systemName: "arrow.up.forward.app")) { _ in
                    UIApplication.shared.open(linkURL)
                })
        }
        return UIMenu(children: actions)
    }

    @objc private func refreshArticle() {
        guard canUseArticleActions else { return }
        waitsForRefresh = false
        remotePageURL = nil
        loadContent(refresh: true)
    }

    private func openSourceLogin() {
        guard canUseArticleActions, source != nil else { return }
        waitsForRefresh = true
        cancelContentLoad()
        navigationRequestID = UUID()
        navigationTask?.cancel()
        browser.cancel()
        currentNavigation = nil
        webView.stopLoading()
        stopReadAloud()
        SourceLoginEntry.openRss(sourceURL: article.origin, from: self)
    }

    private var linkURL: URL? {
        let trimmed = article.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return URL(string: trimmed)
    }

    private func externalOpenTitle(for url: URL) -> String {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? L10n.RSS.openInBrowser : "在外部应用中打开"
    }

    private func loadContent(refresh: Bool = false) {
        guard isPageActive, !waitsForRefresh else { return }
        articleReturnOffset = nil
        restoresArticleOffset = false
        imageActions.cancel()
        programmaticURL = nil
        cancelContentLoad()
        navigationRequestID = UUID()
        navigationTask?.cancel()
        browser.cancel()
        currentNavigation = nil
        webView.stopLoading()
        stopReadAloud()
        renderedContent = nil
        contentErrorMessage = nil
        needsWebReload = false
        isWebContentReady = false
        progressView.isHidden = true
        stateView.showLoading(message: L10n.RSS.loadingContent)
        updateReadAloudButton()
        let requestID = UUID()
        contentRequestID = requestID
        contentTask = Task { @MainActor [weak self, screen, article] in
            guard let self else { return }
            defer { if self.contentRequestID == requestID { self.contentTask = nil } }
            do {
                let resolution = try await RssArticleContentResolver.resolve(
                    article: article, source: self.source, refresh: refresh,
                    screen: screen, browser: self.browser, webView: self.webView)
                try Task.checkCancellation()
                guard self.isPageActive, self.contentRequestID == requestID else { return }
                self.source = resolution.source
                let policy = try await RssArticleResourcePolicy.prepare(
                    contentBlacklist: self.source?.contentBlacklist, contentWhitelist: self.source?.contentWhitelist)
                try Task.checkCancellation()
                guard self.isPageActive, self.contentRequestID == requestID else { return }
                policy.install(on: self.userContentController)
                self.resourcePolicy = policy
                switch resolution.content {
                case let .web(request):
                    self.configureUserScripts()
                    self.loadWebRequest(request)
                case let .html(content):
                    guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        self.showContentError(L10n.ContentState.emptyTable)
                        return
                    }
                    self.renderHTML(content)
                    do {
                        let facade = try RssArticleFavoritesFacade.companion.create()
                        try await SharedAsync.void {
                            facade.retainContent(
                                origin: article.origin, link: article.link, content: content, completionHandler: $0)
                        }
                    } catch {
                        if !Task.isCancelled, self.isPageActive, self.contentRequestID == requestID {
                            self.showTransientMessage("收藏正文保留失败，请重试")
                        }
                    }
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, self.isPageActive, self.contentRequestID == requestID else { return }
                self.showContentError(error.userFacingMessage)
            }
        }
    }

    private func cancelContentLoad() {
        contentRequestID = nil
        contentTask?.cancel()
        contentTask = nil
    }

    private func showContentError(_ message: String, browserURL: URL? = nil) {
        contentErrorMessage = message
        renderedContent = nil
        currentNavigation = nil
        isWebContentReady = false
        webView.stopLoading()
        progressView.isHidden = true
        stopReadAloud()
        let actionTitle = browserURL.map { externalOpenTitle(for: $0) } ?? L10n.Common.retry
        stateView.showMessage(title: L10n.RSS.contentFailed, message: message, actionTitle: actionTitle) { [weak self] in
            guard let self, self.isPageActive else { return }
            if let browserURL { UIApplication.shared.open(browserURL) } else { self.loadContent() }
        }
    }

    private func renderHTML(_ content: String) {
        if !restoresArticleOffset { articleReturnOffset = nil }
        renderedContent = content
        guard isPageActive else {
            needsWebReload = true
            return
        }
        stopReadAloud()
        imageActions.cancel()
        programmaticURL = nil
        currentNavigation = nil
        webView.stopLoading()
        needsWebReload = false
        isWebContentReady = false
        stateView.showLoading(message: L10n.RSS.loadingContent)
        configureUserScripts()

        let baseURL = source?.loadWithBaseUrl == true ? linkURL : nil
        currentNavigation = webView.loadHTMLString(
            RssArticleHTMLRenderer.render(content, source: source, traits: traitCollection), baseURL: baseURL)
        updateReadAloudButton()
    }

    private func configureUserScripts() {
        userContentController.removeAllUserScripts()
        let imageCallout = """
            (function() {
                var style = document.createElement('style');
                style.textContent = 'img { -webkit-touch-callout: none !important; }';
                (document.head || document.documentElement).appendChild(style);
            })();
            """
        userContentController.addUserScript(
            WKUserScript(source: imageCallout, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        for script in RssArticleHTMLRenderer.userScripts(source: source, remote: usesRemoteWebPage) {
            userContentController.addUserScript(script)
        }
    }

    private func loadWebRequest(_ request: URLRequest) {
        programmaticURL = request.url
        currentNavigation = webView.load(request)
    }

    @objc private func suspendArticle() {
        guard isPageActive else { return }
        needsWebReload = needsWebReload || contentTask != nil || webView.isLoading || !isWebContentReady
        cancelContentLoad()
        navigationRequestID = UUID()
        navigationTask?.cancel()
        navigationTask = nil
        browser.cancel()
        programmaticURL = nil
        webView.stopLoading()
        stopReadAloud()
        linkActions.cancel()
    }

    @objc private func resumeArticle() {
        guard canUseArticleActions, needsWebReload, !waitsForRefresh, contentErrorMessage == nil else { return }
        if let renderedContent { renderHTML(renderedContent) } else { loadContent() }
    }

    @objc private func handleBack() {
        stopReadAloud()
        if navigateBackInArticle() { return }
        navigationController?.popViewController(animated: true)
    }

    func interceptNavigationBackGesture() -> Bool { navigateBackInArticle() }

    private func navigateBackInArticle() -> Bool {
        if webView.canGoBack {
            webView.goBack()
            return true
        }
        guard articleReturnOffset != nil, let renderedContent else { return false }
        restoresArticleOffset = true
        renderHTML(renderedContent)
        return true
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard canUseArticleActions, isWebContentReady, gesture.state == .began, !imageActions.isBusy else { return }
        let point = gesture.location(in: webView)
        imagePageID = pageID
        let anchor = webView.convert(CGRect(x: point.x, y: point.y, width: 1, height: 1), to: view)
        imageActions.presentImage(at: point, in: webView, anchor: anchor)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === imageLongPress || otherGestureRecognizer === imageLongPress
    }

    @objc private func toggleFavorite() {
        guard canUseArticleActions, isFavoriteSynchronized, favoriteTask == nil else { return }
        let id = pageID
        stopObservingFavorites()
        let favoriteArticle = RssArticleContentResolver.favoriteArticle(article, content: renderedContent)
        favoriteTask = Task { @MainActor [weak self, article = favoriteArticle] in
            do {
                let facade = try RssArticleFavoritesFacade.companion.create()
                let existing: RssStar? = try await SharedAsync.optionalValue {
                    facade.getFavorite(origin: article.origin, link: article.link, completionHandler: $0)
                }
                let star: RssStar
                if let existing {
                    star = existing
                } else {
                    star = try await SharedAsync.value {
                        facade.saveFavorite(article: article, title: article.title, group: article.group, completionHandler: $0)
                    }
                }
                let groups: [String] = try await SharedAsync.value { facade.favoriteGroups(completionHandler: $0) }
                guard let self else { return }
                self.favoriteTask = nil
                self.observeFavorites()
                guard self.pageID == id, self.canUseArticleActions else { return }
                let editor = RssArticleFavoriteEditorViewController(star: star, groups: groups)
                editor.onSave = { title, group in
                    let _: RssStar = try await SharedAsync.value {
                        facade.saveFavorite(article: article, title: title, group: group, completionHandler: $0)
                    }
                }
                editor.onDelete = {
                    try await SharedAsync.void {
                        facade.deleteFavorite(origin: article.origin, link: article.link, completionHandler: $0)
                    }
                }
                self.present(UINavigationController(rootViewController: editor), animated: true)
            } catch {
                guard let self else { return }
                self.favoriteTask = nil
                self.observeFavorites()
                if self.pageID == id, self.canUseArticleActions { self.presentError(error) }
            }
        }
        updateFavoriteButton()
    }

    private func refreshFavoriteState() {
        if hasObservedFavorites, favoriteTask == nil {
            isFavorite = screen.currentFavorites.contains { $0.origin == article.origin && $0.link == article.link }
        }
        updateFavoriteButton()
    }

    private func observeFavorites() {
        stopObservingFavorites()
        guard isPageActive, favoriteTask == nil else { return }
        switch SharedRuntime.rssFacade() {
        case .success(let facade):
            favoriteButton.accessibilityHint = nil
            let observationID = UUID()
            favoritesObservationID = observationID
            favoritesSubscription = facade.watchFavorites { [weak self] favorites in
                DispatchQueue.main.async {
                    guard let self, self.isPageActive, self.favoritesObservationID == observationID else { return }
                    self.isFavorite = favorites.contains { $0.origin == self.article.origin && $0.link == self.article.link }
                    self.hasObservedFavorites = true
                    self.isFavoriteSynchronized = true
                    self.updateFavoriteButton()
                }
            }
        case .failure(let error):
            favoriteButton.accessibilityHint = error.message
        }
        updateFavoriteButton()
    }

    private func stopObservingFavorites() {
        favoritesObservationID = nil
        favoritesSubscription?.cancel()
        favoritesSubscription = nil
        isFavoriteSynchronized = false
    }

    private func updateFavoriteButton() {
        favoriteButton.setImage(UIImage(systemName: isFavorite ? "star.fill" : "star"), for: .normal)
        favoriteButton.accessibilityLabel = isFavorite ? "编辑收藏" : L10n.RSS.markFavorite
        favoriteButton.isEnabled = isPageActive && isFavoriteSynchronized && favoriteTask == nil
    }

    @objc private func toggleReadAloud() {
        speech.toggle(webView)
    }

    private func stopReadAloud() {
        speech.stop()
    }

    private func updateReadAloudButton() {
        let isActive = speech.isPlaying
        readAloudButton.setImage(UIImage(systemName: isActive ? "pause.circle" : "play.circle"), for: .normal)
        readAloudButton.accessibilityLabel = isActive ? L10n.RSS.stopReadAloud : L10n.RSS.readAloud
        readAloudButton.isEnabled = isPageActive && isWebContentReady && contentErrorMessage == nil
    }

    private func share(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = moreButton
            popover.sourceRect = moreButton.bounds
        }
        present(activityVC, animated: true)
    }

    func webView(_: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard isPageActive, contentErrorMessage == nil else { return }
        currentNavigation = navigation
        isWebContentReady = false
        pageID = UUID()
        imageActions.cancel()
        stopReadAloud()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isPageActive, contentErrorMessage == nil, let navigation, navigation === currentNavigation else { return }
        isWebContentReady = true
        if restoresArticleOffset, let offset = articleReturnOffset {
            webView.scrollView.setContentOffset(offset, animated: false)
            articleReturnOffset = nil
            restoresArticleOffset = false
        }
        needsWebReload = false
        stateView.hide()
        progressView.isHidden = true
        updateReadAloudButton()
        if let pageTitle = webView.title,
            pageTitle.isEmpty == false,
            pageTitle != webView.url?.absoluteString
        {
            topBar.setTitle(pageTitle)
            title = pageTitle
        }
    }

    func webView(_: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error: error)
    }

    func webView(_: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(navigation, error: error)
    }

    private func handleNavigationFailure(_ navigation: WKNavigation?, error: Error) {
        guard isPageActive, let navigation, navigation === currentNavigation,
            (error as NSError).domain != NSURLErrorDomain || (error as NSError).code != NSURLErrorCancelled
        else { return }
        showContentError(error.userFacingMessage)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        preferences.allowsContentJavaScript = source?.enableJs ?? true
        let decide: (WKNavigationActionPolicy) -> Void = { decisionHandler($0, preferences) }
        guard isPageActive, !waitsForRefresh, let url = navigationAction.request.url else { decide(.cancel); return }
        if url.scheme == "about" {
            decide(url.absoluteString.hasPrefix("about:blank") ? .allow : .cancel)
            return
        }
        if navigationAction.navigationType == .linkActivated, renderedContent != nil, articleReturnOffset == nil {
            articleReturnOffset = webView.scrollView.contentOffset
        }
        let bypassHook = navigationAction.navigationType == .other && programmaticURL == url
        if bypassHook { programmaticURL = nil }
        navigationTask?.cancel()
        let id = UUID()
        navigationRequestID = id
        navigationTask = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { decide(.cancel); return }
            defer { if self.navigationRequestID == id { self.navigationTask = nil } }
            do {
                var actions: [RssArticleNavigationAction] = []
                if !bypassHook {
                    let facade = try RssArticleNavigationFacade.companion.create()
                    let result: RssArticleNavigationResult = try await SharedCancellableAsync.value { completion in
                        facade.evaluateRequest(article: self.article, targetUrl: url.absoluteString) { result in
                            completion(result.isCancelled ? nil : result, result.isCancelled ? CancellationError() : nil)
                        }
                    }
                    try Task.checkCancellation()
                    guard self.canUseArticleActions, self.navigationRequestID == id else { decide(.cancel); return }
                    actions = result.actions
                    if let message = result.errorMessage { self.showTransientMessage(message) }
                    if result.isOverridden {
                        decide(.cancel)
                        self.linkActions.perform(actions)
                        return
                    }
                }
                let scheme = url.scheme?.lowercased() ?? ""
                guard ["http", "https"].contains(scheme) else {
                    decide(.cancel)
                    if !actions.isEmpty {
                        self.linkActions.perform(actions)
                    } else if ["legado", "yuedu"].contains(scheme) {
                        self.linkActions.open(url)
                    } else {
                        self.linkActions.offerExternal(url)
                    }
                    return
                }
                guard self.resourcePolicy?.allowsMainDocument(url.absoluteString) != false else {
                    decide(.cancel)
                    self.linkActions.perform(actions)
                    self.showTransientMessage("订阅源的内容规则已拦截此链接")
                    return
                }
                let request = try await self.browser.prepareNavigation(navigationAction.request, webView: webView)
                try Task.checkCancellation()
                guard self.isPageActive, self.navigationRequestID == id, !self.waitsForRefresh else {
                    decide(.cancel)
                    return
                }
                if request.allHTTPHeaderFields != navigationAction.request.allHTTPHeaderFields {
                    decide(.cancel)
                    self.loadWebRequest(request)
                } else {
                    decide(.allow)
                }
                self.linkActions.perform(actions)
            } catch {
                decide(.cancel)
                if !(error is CancellationError), self.isPageActive, self.navigationRequestID == id {
                    self.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil, canUseArticleActions else { return nil }
        loadWebRequest(navigationAction.request)
        return nil
    }

}
