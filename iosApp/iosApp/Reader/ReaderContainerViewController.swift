import UIKit
import shared

final class ReaderContainerViewController: UIViewController, NavigationContentChromeProviding {
    var isInBookshelf: Bool = true
    private(set) var bookURL: String {
        didSet {
            if oldValue != bookURL {
                exitCoordinator.readerContextDidChange(resetProgress: true)
                chapterPrefetchCoordinator.contextDidChange()
            }
        }
    }
    var chapterIndex: Int {
        didSet {
            if oldValue != chapterIndex {
                exitCoordinator.readerContextDidChange()
                chapterPrefetchCoordinator.contextDidChange()
            }
        }
    }
    let screen: ReaderScreenAdapter
    let chapterLoadCoordinator = ReaderChapterLoadCoordinator()
    let chapterListRefreshCoordinator = ReaderChapterListRefreshCoordinator()
    let chapterListPresentationCoordinator = ReaderChapterListPresentationCoordinator()
    let chapterListOrderCoordinator = ReaderChapterListOrderCoordinator()
    lazy var sourceChangeActions = ReaderSourceChangeActions(reader: self)
    lazy var contentEditingCoordinator = ReaderContentEditingCoordinator(reader: self)
    lazy var replaceRuleCoordinator = ReaderReplaceRuleCoordinator(reader: self)
    lazy var autoPageCoordinator = ReaderAutoPageCoordinator(reader: self)
    lazy var pageAnimationSelectionCoordinator = ReaderPageAnimationSelectionCoordinator(reader: self)
    lazy var bookSettingsCoordinator = ReaderBookSettingsCoordinator(reader: self)
    lazy var imageInteractionCoordinator = ReaderImageInteractionCoordinator(reader: self)
    lazy var textSelectionCoordinator = ReaderTextSelectionCoordinator(reader: self)
    lazy var chapterMessageCoordinator = ReaderChapterMessageCoordinator(reader: self)
    let jumpNavigationCoordinator = ReaderJumpNavigationCoordinator()
    lazy var exitCoordinator = ReaderExitCoordinator(reader: self)
    lazy var progressSyncCoordinator = ReaderProgressSyncCoordinator(reader: self)
    lazy var chapterPrefetchCoordinator = ReaderChapterPrefetchCoordinator(reader: self)
    private let paginationCoordinator = ReaderPaginationCoordinator()
    let renderView = ReaderRenderView()
    let scrollPagerView = ReaderScrollPagerView()
    let readMenu = AndroidReadMenuView()
    weak var readerOverflowMenu: ReaderOverflowMenuView?
    var readerOverflowRequestID = UUID()
    lazy var searchMenu = AndroidSearchMenuView(screen: screen)
    let loadingIndicator = UIActivityIndicatorView(style: .large)
    let loadFailureView = ReaderLoadFailureView()
    private let toastLabel = UILabel()

    var book: Book? {
        didSet {
            isInBookshelf = book.map { !$0.isNotShelf } ?? false
            exitCoordinator.bookDidChange(from: oldValue)
            progressSyncCoordinator.contextDidChange()
            chapterPrefetchCoordinator.contextDidChange()
        }
    }
    var chapters: [BookChapter] = [] {
        didSet { chapterPrefetchCoordinator.catalogDidChange() }
    }
    var chapterTitle = ""
    var chapterContent = ""
    var currentChapterSameTitleRemoved = false
    var readAloudContent = ReaderReadAloudContent(pages: [])
    var pages: [ReaderPageLayout] = [] {
        didSet {
            exitCoordinator.readerContextDidChange()
            cancelPageTurnForContentChange()
            // Selection may have reopened on the old pages while pagination was pending.
            textSelectionCoordinator.dismiss(clearSelection: true)
            readAloudContent = ReaderReadAloudContent(pages: pages)
            refreshReadAloudSheetAvailability()
        }
    }
    var currentPageIndex = 0 {
        didSet { if oldValue != currentPageIndex { exitCoordinator.readerContextDidChange() } }
    }
    var themeController = ReaderThemeController()
    var preferences: AppUiPreferences?
    var runtimeConfig: AppRuntimeConfig?
    var autoReadSpeedOverride: Int?
    var autoPageAdvanceInFlight = false
    var readAloudRateSaveTask: Task<Void, Never>?
    var readAloudTimerSaveTask: Task<Void, Never>?
    var readerBrightnessSaveTask: Task<Void, Never>?
    var pendingReaderBrightnessValue: Int?
    var pendingReaderBrightnessIsNight = false
    var originalScreenBrightness: CGFloat?
    var readerBrightnessAutoPreference = ReaderLocalSettings.load().brightnessAuto
    var screenTimeoutTimer: Timer?
    private var lastRenderSize: CGSize = .zero
    private var lastReaderSafeAreaPolicy = ReaderSafeAreaPolicy.zero
    var chromeRefreshTimer: Timer?
    var lastChromeSnapshot: ReaderChromeSnapshot?
    var readerTapGesture: ReaderTapGestureRecognizer?
    var scrollTapGesture: ReaderTapGestureRecognizer?
    var isMenuVisible = false
    var isAutoPageRunning = false
    var isAutoChangingSource = false
    var hardwarePagingLastFireTime: CFTimeInterval = 0
    var readAloudState: ReadAloudState?
    weak var readAloudSheetController: ReaderReadAloudSheetViewController?
    var pendingReadAloudChapterRestart = false
    var pendingReadAloudShouldPauseAfterRestart = false
    var pendingReadAloudBackgroundPlayback = false
    var currentChapterURL: String? {
        didSet {
            if oldValue != currentChapterURL {
                exitCoordinator.readerContextDidChange()
                chapterPrefetchCoordinator.contextDidChange()
            }
        }
    }
    var selectedTextRange: NSRange?
    var textSelectionMenu: AndroidReaderTextActionMenuView?
    var selectedTextPageIndex: Int?
    var pageTurnTransition: ReaderPageTurnTransition?
    var pageTurnGesture = ReaderPageTurnGestureDecision()
    var canNavigateReaderPages: Bool { paginationCoordinator.canNavigate(in: self) }
    private lazy var readingSession = ReaderReadingSession(reader: self)
    var tapZoneActionsOverride: ReaderTapZoneActions?
    var pendingSearchSelectionRange: NSRange?
    var pendingSearchResult: ContentSearchResult?
    var searchResultNeedsJump = false
    var searchSelectionRequestID = UUID()
    var shouldPresentSearchSelection = false
    lazy var readAloudService = ReaderReadAloudService(
        callbacks: .init(
            advanceToNextBlock: { [weak self] in try? await self?.screen.advanceReadAloudToNextBlock() },
            updateCurrentRange: { [weak self] start, end in
                try? await self?.screen.updateReadAloudCurrentRange(start: start, end: end)
            },
            updatePlaybackState: { [weak self] isInBackground in
                try? await self?.screen.updateReadAloudPlaybackState(isInBackground: isInBackground)
            },
            pausePlayback: { [weak self] in try? await self?.screen.pauseReadAloud() },
            fail: { [weak self] message in
                guard let controller = self else { return }
                try? await controller.screen.failReadAloud(message: message)
                await MainActor.run { [weak controller] in
                    controller?.showToast(message)
                }
            },
            resumePlayback: { [weak self] in try? await self?.screen.resumeReadAloud() }
        )
    )
    private let initialChapterPosition: Int?

    init(bookURL: String, initialChapterIndex: Int = 0, initialChapterPosition: Int? = nil) {
        self.bookURL = bookURL
        chapterIndex = initialChapterIndex
        self.initialChapterPosition = initialChapterPosition
        screen = ReaderScreenAdapter(bookURL: bookURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        ReaderLocalSettings.load().screenOrientation.interfaceOrientations
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        ReaderLocalSettings.load().screenOrientation.preferredInterfaceOrientation
    }

    override var shouldAutorotate: Bool {
        ReaderLocalSettings.load().screenOrientation.allowsAutorotation
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? { readerBackKeyCommands + (readerHardwarePagingKeyCommands ?? []) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = themeController.backgroundColor
        navigationController?.setNavigationBarHidden(true, animated: false)
        configureViews()
        bindScreen()
        installHardwarePagingHandlers()
        loadChapter(index: chapterIndex, restorePosition: initialChapterPosition)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        paginationCoordinator.resume()
        chapterLoadCoordinator.resume(in: self)
        view.setNeedsLayout()
        applyReaderScreenTimeout(ReaderLocalSettings.load().screenTimeout)
        beginReaderBrightnessControlIfNeeded()
        startChromeRefresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        exitCoordinator.readerDidAppear()
        readingSession.resume()
        progressSyncCoordinator.resume()
        chapterPrefetchCoordinator.resume()
        searchMenu.setInteractionActive(true)
        replaceRuleCoordinator.resume()
        bookSettingsCoordinator.resume()
        becomeFirstResponder()
        applyReaderOrientationPreference(ReaderLocalSettings.load())
        ReaderReadAloudStateSupport.applyPlayback(in: self)
        refreshSearchSelectionPresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        textSelectionCoordinator.relayout()
        chapterMessageCoordinator.updateGeometry()
        guard renderView.bounds.size.width > 0, renderView.bounds.size.height > 0 else { return }
        let policy = currentReaderSafeAreaPolicy()
        guard
            renderView.bounds.size != lastRenderSize || policy != lastReaderSafeAreaPolicy
                || paginationCoordinator.needsPagination
        else { return }
        lastRenderSize = renderView.bounds.size
        lastReaderSafeAreaPolicy = policy
        repaginate(restoreLocation: currentCharacterOffset())
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let policy = currentReaderSafeAreaPolicy()
        guard policy != lastReaderSafeAreaPolicy else { return }
        lastReaderSafeAreaPolicy = policy
        repaginate(restoreLocation: currentCharacterOffset())
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle,
            let preferences,
            preferences.themeMode == ThemeMode.system
        else { return }
        applyThemeMode(preferences.themeMode)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        chapterPrefetchCoordinator.suspend()
        progressSyncCoordinator.suspend()
        exitCoordinator.readerWillDisappear()
        readingSession.suspend()
        searchMenu.setInteractionActive(false)
        textSelectionCoordinator.dismiss(clearSelection: true)
        readerOverflowRequestID = UUID()
        readerOverflowMenu?.dismiss()
        cancelPageTurnForContentChange()
        resignFirstResponder()
        sourceChangeActions.cancelPreparation()
        chapterListPresentationCoordinator.cancel()
        chapterListRefreshCoordinator.cancel(in: self)
        bookSettingsCoordinator.suspend()
        imageInteractionCoordinator.suspend()
        chapterLoadCoordinator.suspend(in: self)
        if presentedViewController is AndroidChapterListSheetViewController {
            // The full-screen directory owns explicit refreshes while reader turns stay suspended.
            screen.resumeChapterLoading()
        }
        paginationCoordinator.suspend()
        flushPendingReaderBrightness()
        cancelPendingReaderSettingTasks()
        stopChromeRefresh()
        stopAutoPage(showMessage: false)
        cancelReaderScreenTimeout()
        restoreSystemBrightnessIfNeeded()
        readAloudService.apply(state: nil)
        Task { [screen] in
            await screen.flushReadingProgressNow()
        }
    }

    deinit {
        flushPendingReaderBrightness()
        cancelPendingReaderSettingTasks()
        restoreSystemBrightnessIfNeeded()
        stopChromeRefresh()
        cancelReaderScreenTimeout()
        NotificationCenter.default.removeObserver(self)
        screen.unbind()
    }

    override var prefersStatusBarHidden: Bool {
        runtimeConfig?.reader.hideStatusBar == true && !isMenuVisible
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        if isMenuVisible && !themeController.canReadBarStyleFollowPage {
            return traitCollection.userInterfaceStyle == .dark ? UIStatusBarStyle.lightContent : UIStatusBarStyle.darkContent
        }
        return themeController.darkStatusIcon ? UIStatusBarStyle.darkContent : UIStatusBarStyle.lightContent
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        runtimeConfig?.reader.hideNavigationBar == true && !isMenuVisible
    }

    override func accessibilityPerformMagicTap() -> Bool {
        if textSelectionCoordinator.isSelecting {
            dismissTextSelectionMenu(clearSelection: true)
            return true
        }
        showReaderActionMenu()
        return true
    }

    override func accessibilityPerformEscape() -> Bool { performReaderAccessibilityEscape() }

    private func configureViews() {
        renderView.translatesAutoresizingMaskIntoConstraints = false
        scrollPagerView.translatesAutoresizingMaskIntoConstraints = false
        readMenu.translatesAutoresizingMaskIntoConstraints = false
        searchMenu.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadFailureView.translatesAutoresizingMaskIntoConstraints = false
        toastLabel.translatesAutoresizingMaskIntoConstraints = false

        renderView.bookURL = bookURL
        renderView.theme = readerRenderTheme()
        renderView.chrome = emptyChrome()
        renderView.accessibilityIdentifier = UIIdentifiers.Reader.pageContainer
        scrollPagerView.isHidden = true
        scrollPagerView.accessibilityIdentifier = UIIdentifiers.Reader.pageContainer
        scrollPagerView.onPageIndexChange = { [weak self] index in
            guard let self, self.isScrollPageMode, !self.scrollPagerView.isHidden,
                self.paginationCoordinator.canNavigate(in: self), self.pages.indices.contains(index)
            else { return }
            self.currentPageIndex = index
            self.refreshChromeSnapshot(force: true)
            self.updateMenuState()
            self.stageProgress(immediate: false)
            Task { [screen = self.screen] in
                try? await screen.onPageChanged()
            }
        }
        scrollPagerView.onBoundaryRequest = { [weak self] boundary in
            guard let self, self.isScrollPageMode, !self.scrollPagerView.isHidden,
                self.paginationCoordinator.canNavigate(in: self)
            else { return false }
            switch boundary {
            case .previous:
                self.openPreviousChapter(toLast: true)
            case .next:
                self.openNextChapter()
            }
            return true
        }

        configureReaderMenuCallbacks()

        toastLabel.alpha = 0
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        toastLabel.font = .systemFont(ofSize: 14)
        toastLabel.textAlignment = .center
        toastLabel.numberOfLines = 0
        toastLabel.layer.cornerRadius = 16
        toastLabel.layer.masksToBounds = true

        view.addSubview(renderView)
        view.addSubview(scrollPagerView)
        view.addSubview(loadFailureView)
        view.addSubview(readMenu)
        view.addSubview(searchMenu)
        view.addSubview(loadingIndicator)
        view.addSubview(toastLabel)

        NSLayoutConstraint.activate([
            renderView.topAnchor.constraint(equalTo: view.topAnchor),
            renderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollPagerView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollPagerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollPagerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollPagerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            loadFailureView.topAnchor.constraint(equalTo: view.topAnchor),
            loadFailureView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadFailureView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadFailureView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            readMenu.topAnchor.constraint(equalTo: view.topAnchor),
            readMenu.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            readMenu.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            readMenu.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            searchMenu.topAnchor.constraint(equalTo: view.topAnchor),
            searchMenu.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchMenu.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchMenu.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -92),
            toastLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])

        installReaderGestures()
    }

    private func bindScreen() {
        screen.onChapterLoadingActivityChange = { [weak self] interrupted in
            self?.chapterPrefetchCoordinator.chapterLoadingActivityDidChange(interrupted: interrupted)
        }
        screen.onBookChange = { [weak self] book in
            guard let self else { return }
            self.book = book
            self.readMenu.updateBookTitle(book?.name ?? self.chapterTitle)
            self.readMenu.updateBookLocalState(isLocal: book?.isLocal == true)
        }
        screen.onChaptersChange = { [weak self] chapters in
            self?.chapters = chapters
            self?.refreshReadAloudSheetAvailability()
            self?.updateMenuState()
        }
        screen.onPreferencesChange = { [weak self] preferences in
            guard let self else { return }
            let needsPagination = ReaderPaginationCoordinator.preferencesRequirePagination(
                previous: self.preferences, updated: preferences,
                userInterfaceStyle: self.traitCollection.userInterfaceStyle)
            self.preferences = preferences
            self.themeController.apply(preferences: preferences, userInterfaceStyle: self.traitCollection.userInterfaceStyle)
            self.applyThemeMode(preferences.themeMode, refresh: false)
            self.applyTheme()
            if needsPagination {
                self.repaginate(restoreLocation: self.currentCharacterOffset())
            } else {
                self.refreshChromeSnapshot(force: true)
            }
        }
        screen.onRuntimeConfigChange = { [weak self] runtimeConfig in
            guard let self else { return }
            let needsPagination = ReaderPaginationCoordinator.runtimeRequiresPagination(
                previous: self.runtimeConfig, updated: runtimeConfig)
            self.tapZoneActionsOverride = nil
            self.runtimeConfig = runtimeConfig
            self.chapterPrefetchCoordinator.contextDidChange()
            self.progressSyncCoordinator.configurationDidChange()
            if self.autoReadSpeedOverride == Int(runtimeConfig.reader.autoReadSpeed) {
                self.autoReadSpeedOverride = nil
                UserDefaults.standard.removeObject(forKey: Self.autoReadSpeedUserDefaultsKey)
            }
            self.syncReadAloudVoice(from: runtimeConfig.reader)
            self.themeController.apply(runtimeConfig: runtimeConfig)
            self.applyReaderBrightnessIfNeeded()
            self.setNeedsStatusBarAppearanceUpdate()
            self.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self.applyTheme()
            if needsPagination { self.repaginate(restoreLocation: self.currentCharacterOffset()) }
        }
        screen.onReadAloudStateChange = { [weak self] state in
            guard let self else { return }
            ReaderReadAloudStateSupport.receive(state, in: self)
        }

        switch screen.bootstrap() {
        case .success:
            break
        case .failure(let error):
            showToast(error.message)
        }
    }

    func applyTheme() {
        let renderTheme = readerRenderTheme()
        loadFailureView.apply(theme: renderTheme)
        view.backgroundColor = renderTheme.visibleBackgroundColor
        renderView.theme = renderTheme
        scrollPagerView.backgroundColor = renderTheme.visibleBackgroundColor
        chapterMessageCoordinator.updateGeometry()
        readMenu.apply(readerTheme: renderTheme)
        searchMenu.apply(readerTheme: renderTheme)
        setNeedsStatusBarAppearanceUpdate()
    }

    func loadChapter(index: Int, restorePosition: Int?, forceRefresh: Bool = false) {
        chapterLoadCoordinator.load(in: self, index: index, restorePosition: restorePosition, forceRefresh: forceRefresh)
    }

    func adoptSourceChangeResult(_ result: BookDetailRefreshResult) {
        clearSearchSelection()
        searchMenu.resetResults(currentChapterIndex: Int(result.book.durChapterIndex))
        bookURL = result.book.bookUrl
        renderView.bookURL = bookURL
        screen.rebindBookURL(bookURL, book: result.book, chapters: result.chapters)
        book = result.book
        chapters = result.chapters
        chapterIndex = Int(result.book.durChapterIndex)
        chapterTitle = result.book.durChapterTitle ?? ""
        chapterContent = ""
        currentChapterURL = nil
        currentChapterSameTitleRemoved = false
        currentPageIndex = 0
        paginationCoordinator.beginChapter(bookURL: bookURL, index: chapterIndex, url: nil, restoreLocation: 0)
        pages = []
        renderCurrentPage()
        refreshChromeSnapshot(force: true)
        updateMenuState()
    }

    func applyPayload(_ payload: ReaderChapterPayload, restorePosition: Int?) {
        guard !Task.isCancelled, !isMovingFromParent, !isBeingDismissed,
            navigationController?.topViewController === self
        else { return }
        dismissTextSelectionMenu(clearSelection: true)
        book = payload.book
        let payloadBookURL = payload.book.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if payloadBookURL.isEmpty == false {
            if bookURL != payloadBookURL { jumpNavigationCoordinator.endSearch() }
            bookURL = payloadBookURL
            renderView.bookURL = payloadBookURL
        }
        jumpNavigationCoordinator.bookDidChange(to: bookURL)
        chapters = payload.chapters
        chapterIndex = Int(payload.chapter.index)
        if pendingSearchResult.map({ Int($0.chapterIndex) != chapterIndex }) == true {
            searchResultNeedsJump = false
        }
        chapterTitle = payload.displayTitle.nilIfEmpty ?? payload.chapter.title
        chapterContent = payload.content
        currentChapterSameTitleRemoved = payload.sameTitleRemoved
        currentChapterURL = payload.chapter.url
        chapterMessageCoordinator.preparingPage(index: chapterIndex)
        let restoreLocation = restorePosition ?? Int(payload.book.durChapterPos)
        paginationCoordinator.beginChapter(
            bookURL: bookURL,
            index: chapterIndex,
            url: currentChapterURL,
            restoreLocation: restoreLocation
        )
        pages = []
        currentPageIndex = 0
        screen.markLoadedProgress(book: payload.book)
        readMenu.updateBookTitle(payload.book.name)
        readMenu.updateBookLocalState(isLocal: payload.book.isLocal)
        readMenu.updateChapter(title: chapterTitle, source: payload.book.originName, url: payload.chapter.url)
        repaginate(restoreLocation: restoreLocation)
    }

    func applyReaderOrientationPreference(_ settings: ReaderLocalSettings) {
        setNeedsUpdateOfSupportedInterfaceOrientations()
        navigationController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard #available(iOS 16.0, *),
            let windowScene = view.window?.windowScene
        else {
            UIViewController.attemptRotationToDeviceOrientation()
            return
        }
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: settings.screenOrientation.interfaceOrientations))
    }

    func repaginate(restoreLocation: Int?) {
        autoPageCoordinator.contentWillChange()
        cancelPageTurnForContentChange()
        paginationCoordinator.repaginate(
            in: self,
            restoreLocation: restoreLocation,
            hasLaidOutRenderView: lastRenderSize == renderView.bounds.size && lastRenderSize != .zero
        )
    }

    func renderCurrentPage() {
        defer {
            autoPageCoordinator.contentDidRender()
            readingSession.refresh()
            progressSyncCoordinator.refresh()
            refreshSearchSelectionPresentation()
        }
        paginationCoordinator.renderCurrentPage(in: self)
    }

    func setMenuVisible(_ visible: Bool) {
        if !visible {
            readerOverflowRequestID = UUID()
            readerOverflowMenu?.dismiss()
        }
        cancelPageTurnForContentChange()
        isMenuVisible = visible
        autoPageCoordinator.menuVisibilityDidChange(visible)
        loadFailureView.accessibilityViewIsModal = !visible
        if visible {
            searchMenu.setVisible(false, currentChapterIndex: chapterIndex)
            readMenu.reloadLocalSettings()
        }
        updateMenuState()
        readMenu.setPresented(visible, animated: true)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    func previousPage() {
        guard paginationCoordinator.canNavigate(in: self) else { return }
        if isScrollPageMode {
            guard scrollPagerView.scrollByViewport(forward: false, animated: true) else {
                openPreviousChapter(toLast: true)
                return
            }
            return
        }
        let step = nonScrollPageStep()
        guard currentPageIndex > 0 else {
            openPreviousChapter(toLast: true)
            return
        }
        currentPageIndex = max(currentPageIndex - step, 0)
        renderCurrentPage()
        updateMenuState()
    }

    func nextPage() {
        guard paginationCoordinator.canNavigate(in: self) else { return }
        if isScrollPageMode {
            guard scrollPagerView.scrollByViewport(forward: true, animated: true) else {
                openNextChapter()
                return
            }
            return
        }
        let step = nonScrollPageStep()
        guard currentPageIndex + step < pages.count else {
            openNextChapter()
            return
        }
        currentPageIndex += step
        renderCurrentPage()
        updateMenuState()
    }

    func openPreviousChapter(toLast: Bool) {
        let target = readerActionChapterIndex
        guard target > 0 else {
            showToast(L10n.Reader.menuPrevious)
            return
        }
        loadChapter(index: target - 1, restorePosition: toLast ? Int.max : 0)
    }

    func openNextChapter() {
        let target = readerActionChapterIndex
        guard target + 1 < ReaderSimulatedReadingPolicy.count(in: self) else {
            autoPageAdvanceInFlight = false
            if isAutoPageRunning {
                stopAutoPage(showMessage: false)
                showToast(L10n.Reader.autoPageReachedEnd)
            } else {
                showToast(L10n.Reader.menuNext)
            }
            return
        }
        loadChapter(index: target + 1, restorePosition: 0)
    }

    func reloadCurrentChapter() {
        guard !chapterLoadCoordinator.isLoading else { return }
        if let target = chapterMessageCoordinator.requestedIndex {
            chapterLoadCoordinator.retry(in: self, fallbackIndex: target)
            return
        }
        chapterLoadCoordinator.load(
            in: self, index: chapterIndex, restorePosition: currentCharacterOffset(),
            forceRefresh: true, successMessage: L10n.Reader.refreshCurrentSuccess
        )
    }

    func skipBySliderValue(_ value: Int, behavior: ReaderProgressBehavior) {
        jumpNavigationCoordinator.skipSliderValue(value, behavior: behavior, in: self)
    }

    func showChapterPicker() {
        chapterListPresentationCoordinator.present(in: self)
    }

    func applyChapterListOrder(_ result: BookDetailRefreshResult, restorePosition: Int) {
        guard result.book.bookUrl == bookURL,
            let chapter = result.chapters.first(where: { $0.index == result.book.durChapterIndex })
        else { return }
        book = result.book
        chapters = result.chapters
        screen.rebindBookURL(bookURL, book: result.book, chapters: result.chapters)
        clearSearchSelection()
        searchMenu.resetResults(currentChapterIndex: Int(chapter.index))
        guard chapter.url == currentChapterURL else {
            loadChapter(index: Int(chapter.index), restorePosition: Int(result.book.durChapterPos))
            return
        }
        chapterIndex = Int(chapter.index)
        paginationCoordinator.beginChapter(
            bookURL: bookURL, index: chapterIndex, url: currentChapterURL, restoreLocation: restorePosition)
        screen.markLoadedProgress(book: result.book)
        refreshChromeSnapshot(force: true)
        updateMenuState()
        view.setNeedsLayout()
    }

    func localChapterListItems() -> [ReaderChapterListItem] {
        chapters.map { chapter in
            ReaderChapterListItem(
                chapter: chapter,
                displayTitle: chapter.title.nilIfEmpty ?? String(format: L10n.Reader.chapterLabel, Int(chapter.index) + 1),
                isCurrent: Int(chapter.index) == chapterIndex,
                isCached: book?.isLocal == true || chapter.isVolume
                    || (Int(chapter.index) == chapterIndex
                        && chapterContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            )
        }
    }

    func updateMenuState() {
        searchMenu.updateCurrentChapter(index: chapterIndex)
        let target = readerActionChapterIndex
        let readableCount = ReaderSimulatedReadingPolicy.count(in: self)
        let hasContent = loadFailureView.isHidden
        readMenu.updateChapter(
            title: hasContent ? chapterTitle : (chapters[safe: target]?.title ?? chapterTitle),
            source: book?.originName ?? "", url: readerActionChapterURL)
        readMenu.updateProgressContext(bookURL: bookURL, chapterURL: readerActionChapterURL)
        readMenu.updateMenuProgress(
            page: hasContent ? currentPageIndex : 0, pageCount: hasContent ? pages.count : 1,
            chapter: target, chapterCount: readableCount)
        readMenu.setNavigationEnabled(previous: target > 0 && readableCount > 0, next: target < readableCount - 1)
        readMenu.setProgressAvailability(page: hasContent && canNavigateReaderPages, chapter: readableCount > 0)
        readMenu.setChapterLoading(chapterLoadCoordinator.isLoading || loadFailureView.isShowingLoading)
        readMenu.setAutoPageRunning(isAutoPageRunning)
        chapterPrefetchCoordinator.refresh()
    }

    func pageIndex(for characterOffset: Int) -> Int {
        guard pages.isEmpty == false else { return 0 }
        if let index = pages.lastIndex(where: { $0.characterOffset <= characterOffset }) {
            return min(max(index, 0), pages.count - 1)
        }
        return 0
    }

    func currentCharacterOffset() -> Int {
        paginationCoordinator.currentPosition(in: self)
    }

    func stageProgress(immediate: Bool) {
        guard let position = paginationCoordinator.progressPosition(in: self) else { return }
        exitCoordinator.didStageProgress(chapterIndex: chapterIndex, position: position)
        progressSyncCoordinator.didStageProgress(chapterIndex: chapterIndex, position: position)
        screen.stageReadingProgress(
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            chapterPosition: position,
            immediate: immediate
        )
    }

    func showToast(_ message: String) {
        toastLabel.text = "  \(message)  "
        UIView.animate(
            withDuration: 0.15,
            animations: {
                self.toastLabel.alpha = 1
            },
            completion: { _ in
                UIView.animate(withDuration: 0.25, delay: 1.4, options: [.beginFromCurrentState]) {
                    self.toastLabel.alpha = 0
                }
            }
        )
    }
}
