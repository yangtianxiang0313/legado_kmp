import UIKit
import shared

@MainActor
final class MangaReaderViewController: UIViewController {
    let bookURL: String
    private let initialChapterIndex: Int?
    private let initialChapterPosition: Int?
    private let adapter: MangaReaderAdapter
    private let images: MangaImagePipeline
    private lazy var strip: MangaReaderStripController = MangaReaderStripController(pipeline: images)
    private lazy var chapterWindow: MangaChapterWindow = MangaChapterWindow(adapter: adapter)
    private var readerLayout: MangaReaderLayout { strip.layout }
    private var collection: UICollectionView { strip.collection }
    private var prefetcher: MangaReaderLayoutPrefetcher { strip.prefetcher }
    private let readingSettings = MangaReadingSettings()
    private var readingOptions = MangaReadingOptions()
    private lazy var automaticReading = MangaReaderAutomaticReading(
        collection: collection, layout: readerLayout,
        canInteract: { [weak self] in self?.canUseActions == true },
        onStart: { [weak self] in self?.setControlsVisible(false) },
        onMoved: { [weak self] in self?.automaticReadingMoved() },
        onEnd: { [weak self] in self?.advanceAutomaticChapter() ?? false })
    private lazy var recovery = MangaReaderRecoveryActions(
        presenter: self, bookURL: bookURL, adapter: adapter,
        canInteract: { [weak self] in self?.canUseActions == true },
        onBusyChange: { [weak self] busy in self?.recoveryBusyChanged(busy) },
        onCommitted: { [weak self] result, originalURL, targets in
            self?.sourceChangeCommitted(result, replacing: originalURL, targets: targets)
        },
        onSuspendForLogin: { [weak self] in self?.suspendForLogin() })
    private lazy var sourceDestination = MangaReaderSourceChangeDestination(owner: self, adapter: adapter)
    private lazy var bookInfo = MangaReaderBookInfoNavigation(
        owner: self, bookURL: bookURL, currentBook: { [weak self] in self?.chapter?.book },
        snapshot: { [weak self] in
            guard let self else { throw CancellationError() }
            self.recordPosition(immediate: true)
            return try await self.adapter.snapshotForBookInfo()
        },
        canInteract: { [weak self] in
            self?.canUseActions == true && self?.isReadingVisible == true && self?.presentedViewController == nil
        },
        onWillNavigate: { [weak self] in
            guard let self else { return }
            self.requestResumeFromBookInfo(chapterIndex: Int(self.chapter?.chapterIndex ?? 0), chapterPosition: self.pagePosition)
            self.setControlsVisible(false)
            self.persistPause()
        })
    private lazy var catalog = MangaChapterListPresentationCoordinator(
        owner: self, adapter: adapter,
        canPresent: { [weak self] in
            guard let self else { return false }
            return !self.isLoading && !self.isApplyingChapter && !self.isExiting && !self.recovery.isBusy
                && !self.sourceDestination.isPending
        }, onPrepared: { [weak self] in self?.apply($0) })
    private lazy var progressSync: MangaProgressSyncCoordinator = MangaProgressSyncCoordinator(
        owner: self, adapter: adapter,
        context: { [weak self] in
            guard let self, let chapter = self.chapter else { return nil }
            return MangaProgressSyncContext(chapter: chapter, position: self.pagePosition)
        },
        canInteract: { [weak self] in self?.canSyncProgress == true },
        stage: { [weak self] in self?.recordPosition(immediate: true) },
        apply: { [weak self] prepared in self?.apply(prepared) })
    private lazy var exitFlow: MangaReaderExitFlow = MangaReaderExitFlow(
        owner: self, adapter: adapter,
        canNavigate: { [weak self] in self?.canNavigate == true },
        prepare: { [weak self] in self?.prepareForExit() },
        stateDidChange: { [weak self] exiting in
            guard let self else { return }
            self.catalogActivityChanged()
            if !exiting { self.resumeIfNeeded() }
        })
    private var wasLoadingBeforeRecovery = false
    private lazy var gestures = MangaReaderGestures(
        collection: collection, canInteract: { [weak self] in self?.canUseActions == true },
        onTap: { [weak self] in self?.tapPage(at: $0) }, onZoom: { [weak self] in self?.zoomPage(at: $0) },
        onMenu: { [weak self] in self?.setControlsVisible(true) })
    private let chrome = MangaReaderChrome()
    private let brightness = MangaReaderBrightness()
    private lazy var downloadCoordinator = MangaReaderDownloadCoordinator(bookURL: bookURL)
    private let stateView = MangaReaderStateView()
    private let catalogStateView = MangaReaderStateView()
    private var chapter: MangaReaderChapter?
    private var pagePosition = 0
    private var loadTask: Task<Void, Never>?
    private var loadRevision = UUID()
    private var requestedIndex: Int?
    private var requestedPosition: Int?
    private var requestedRefresh = false
    private var needsReload = false
    private var isLoading = false
    private var isApplyingChapter = false
    private var isExiting: Bool { exitFlow.isExiting }
    private var controlsVisible = false
    private var isReadingVisible = false
    private var previousNavigationHidden: Bool?
    private var previousPopEnabled: Bool?
    private weak var readingScene: UIWindowScene?

    init(bookURL: String, initialChapterIndex: Int? = nil, initialChapterPosition: Int? = nil) {
        self.bookURL = bookURL
        self.initialChapterIndex = initialChapterIndex
        self.initialChapterPosition = initialChapterPosition
        adapter = MangaReaderAdapter(bookURL: bookURL)
        images = MangaImagePipeline(bookURL: bookURL)
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(back)),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(back)),
        ]
    }

    override func loadView() {
        view = MangaReaderRootView(
            collection: collection, chrome: chrome, state: stateView, catalogState: catalogStateView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        configureCollection()
        configureChrome()
        catalogStateView.hide()
        progressSync.onPresentationChanged = { [weak self] in self?.updateAutomaticReading() }
        catalog.onActivityChanged = { [weak self] in self?.catalogActivityChanged() }
        chapterWindow.onChange = { [weak self] in self?.renderWindowPages() }
        chapterWindow.onFailure = { [weak self] index, error in self?.neighborFailed(index: index, error: error) }
        readingSettings.onChange = { [weak self] options in self?.applyReadingOptions(options) }
        readingSettings.onError = { [weak self] message in
            guard let self, self.canNavigate, self.presentedViewController == nil else { return }
            self.showTransientMessage(message, duration: 4)
        }
        readingSettings.load()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDeactivated(_:)), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneActivated(_:)), name: UIScene.didActivateNotification, object: nil)
        load(index: initialChapterIndex, position: initialChapterPosition)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if previousNavigationHidden == nil {
            previousNavigationHidden = navigationController?.isNavigationBarHidden
            previousPopEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
        }
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isReadingVisible = true
        chrome.setReaderVisible(true)
        brightness.setActive(true, window: view.window)
        readingScene = view.window?.windowScene
        becomeFirstResponder()
        sourceDestination.navigateIfNeeded()
        resumeIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        bookInfo.cancel()
        catalog.ownerWillDisappear()
        isReadingVisible = false
        chrome.setReaderVisible(false)
        brightness.restore()
        automaticReading.update(isEligible: false, speed: readingOptions.autoPageSpeed)
        guard isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        automaticReading.stop()
        recovery.cancelPreparation()
        loadRevision = UUID()
        loadTask?.cancel()
        adapter.suspendLoading()
        chapterWindow.suspend()
        recordPosition(immediate: true)
        progressSync.suspend(upload: !recovery.isBusy && !sourceDestination.isPending)
        strip.cancel()
        prefetcher.cancel()
        images.cancelAll()
        persistPause()
        if let hidden = previousNavigationHidden {
            navigationController?.setNavigationBarHidden(hidden, animated: false)
        }
        if let enabled = previousPopEnabled {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = enabled
        }
        let adapter = adapter
        Task { await adapter.finish() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collection.bounds.width > 0, collection.bounds.height > 0, readerLayout.needsViewportUpdate else {
            return
        }
        strip.updateViewport()
        updatePrefetch()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        prefetcher.reset()
        images.clearMemory()
    }

    private var canNavigate: Bool {
        isViewLoaded && view.window != nil && view.window?.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
            && !isMovingFromParent && !isBeingDismissed
    }

    private var canUseActions: Bool {
        canNavigate && !isReaderBusy && !isApplyingChapter
            && navigationController?.topViewController === self
            && view.window.map { AppLockManager.shared.isUnlocked(in: $0) } == true
    }

    private var isReaderBusy: Bool {
        isLoading || isExiting || recovery.isBusy || sourceDestination.isPending || catalog.isActive
    }

    private var canSyncProgress: Bool {
        canUseActions && isReadingVisible && !hasVisiblePresentation
    }

    func requestResumeFromBookInfo(chapterIndex: Int, chapterPosition: Int?) {
        requestedIndex = max(0, chapterIndex)
        requestedPosition = chapterPosition.map { max(0, $0) }
        needsReload = true
    }

    func flushReadingProgressForBookInfo() async { await adapter.pause() }

    func adoptBookInfoSourceChange(_ result: BookDetailRefreshResult, replacing originalURL: String) {
        guard bookURL == originalURL else { return }
        sourceChangeCommitted(result, replacing: originalURL, targets: [])
    }

    private func configureCollection() {
        collection.contentInset = .zero
        collection.verticalScrollIndicatorInsets = collection.contentInset
        strip.applyOptions(readingOptions)
        strip.canInteract = { [weak self] in
            guard let self else { return false }
            return self.canUseActions && self.isReadingVisible && self.presentedViewController == nil
        }
        strip.onPageChanged = { [weak self] page in self?.visiblePageChanged(page) }
        strip.onDragBegan = { [weak self] in
            guard let self else { return }
            self.automaticReading.update(isEligible: false, speed: self.readingOptions.autoPageSpeed)
        }
        strip.onScrollSettled = { [weak self] in
            guard let self else { return }
            self.recordPosition(immediate: true)
            self.updateAutomaticReading()
            if self.canUseActions, self.readerLayout.isPastEnd(threshold: 80) { self.changeChapter(by: 1) }
        }
        gestures.setZoomEnabled(readingOptions.allowsZoom)
    }

    private func configureChrome() {
        chrome.onBack = { [weak self] in self?.back() }
        chrome.onPrevious = { [weak self] in self?.changeChapter(by: -1) }
        chrome.onNext = { [weak self] in self?.changeChapter(by: 1) }
        chrome.onContents = { [weak self] in self?.showContents() }
        chrome.onDismiss = { [weak self] in self?.setControlsVisible(false) }
        chrome.onChangeSource = { [weak self] in
            guard let self, self.canUseActions else { return }
            self.bookInfo.cancel()
            self.setControlsVisible(false)
            self.recovery.presentSourcePicker()
        }
        chrome.onRefresh = { [weak self] in self?.refreshCurrentChapter() }
        chrome.onBookInfo = { [weak self] in
            guard let self, let chapter = self.chapter else { return }
            self.bookInfo.open(expectedOrigin: chapter.book.origin)
        }
        chrome.menuProvider = { [weak self] in await self?.readingMenu() ?? [] }
        chrome.onDownload = { [weak self] in self?.showDownloads() }
        chrome.onSettings = { [weak self] in self?.showSettings() }
        chrome.setControlsVisible(controlsVisible, animated: false)
        downloadCoordinator.onStatusChange = { [weak self] status in
            self?.chrome.setDownloadStatus(status)
        }
        downloadCoordinator.onFeedback = { [weak self] message in
            guard let self, self.canNavigate, self.presentedViewController == nil else { return }
            self.showTransientMessage(message, duration: 4)
        }
        downloadCoordinator.observe()
        chrome.onSeek = { [weak self] position in self?.seek(to: position) }
    }

    private func updateReaderInteraction() {
        let busy = isReaderBusy
        collection.isUserInteractionEnabled = !busy
        collection.isScrollEnabled = !busy
        stateView.isUserInteractionEnabled = !busy
        stateView.accessibilityElementsHidden = busy
        chrome.setBusy(busy)
    }

    private func catalogActivityChanged() {
        updateReaderInteraction()
        if catalog.isPreparing {
            collection.setContentOffset(collection.contentOffset, animated: false)
            catalogStateView.show(message: L10n.text("manga.flow.loading", "正在加载漫画…"), loading: true)
        } else {
            catalogStateView.hide()
        }
        updatePrefetch()
        updateAutomaticReading()
    }

    private func load(index: Int?, position: Int?, refresh: Bool = false) {
        guard !isExiting, !recovery.isBusy, !sourceDestination.isPending else { return }
        bookInfo.cancel()
        catalog.cancel()
        progressSync.invalidateContext()
        recordPosition(immediate: true)
        chapterWindow.cancel()
        prefetcher.cancel()
        loadTask?.cancel()
        adapter.cancelLoading()
        adapter.resumeLoading()
        let revision = UUID()
        loadRevision = revision
        requestedIndex = index
        requestedPosition = position
        requestedRefresh = refresh
        needsReload = false
        isLoading = true
        adapter.setReadingActive(false)
        collection.isUserInteractionEnabled = false
        chrome.setBusy(true)
        showState(message: L10n.text("manga.flow.loading", "正在加载漫画…"), loading: true)
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared: MangaReaderChapter
                if let index, let position {
                    prepared = try await self.adapter.load(index: index, position: position, refresh: refresh)
                } else {
                    prepared = try await self.adapter.loadInitial(index: index, position: position, refresh: refresh)
                }
                try Task.checkCancellation()
                guard self.loadRevision == revision else { return }
                self.loadTask = nil
                self.isLoading = false
                self.updateReaderInteraction()
                self.apply(prepared)
            } catch {
                guard self.loadRevision == revision else { return }
                self.loadTask = nil
                if error is CancellationError || Task.isCancelled { return }
                self.isLoading = false
                self.updateReaderInteraction()
                self.showState(message: error.localizedDescription, actionTitle: L10n.Common.retry, icon: "arrow.clockwise") {
                    [weak self] in
                    self?.retryLoad()
                }
                self.updateAutomaticReading()
            }
        }
    }

    private func apply(_ prepared: MangaReaderChapter) {
        isApplyingChapter = true
        adapter.accept(prepared)
        chapter = prepared
        pagePosition = Int(prepared.chapterPosition)
        prefetcher.reset()
        chapterWindow.reset(prepared)
        let key =
            prepared.pages.indices.contains(pagePosition)
            ? MangaWindowPage(chapter: prepared, position: pagePosition).key : nil
        strip.setPages(prepared.pages.isEmpty ? [] : chapterWindow.pages, restoring: key)
        isApplyingChapter = false
        updateChapterChrome()
        chrome.setBusy(isReaderBusy)
        if prepared.pages.isEmpty {
            let hasNext = Int(prepared.chapterIndex) + 1 < prepared.chapters.count
            showState(message: prepared.chapterTitle, actionTitle: hasNext ? L10n.Reader.menuNext : nil, icon: "forward.end") {
                [weak self] in
                self?.changeChapter(by: 1)
            }
        } else {
            stateView.hide()
            if automaticReading.mode != .off { setControlsVisible(false, animated: false) }
        }
        adapter.record(position: pagePosition, immediate: true)
        progressSync.contextDidChange()
        adapter.setReadingActive(canNavigate)
        updatePrefetch()
        updateAutomaticReading()
        UIAccessibility.post(notification: .screenChanged, argument: controlsVisible ? chrome.topBar : collection)
    }

    private func updateChapterChrome() {
        guard let prepared = chapter else { return }
        chrome.setTitle(book: prepared.book.name, chapter: prepared.chapterTitle)
        chrome.setNavigation(
            previous: prepared.chapterIndex > 0, next: Int(prepared.chapterIndex) + 1 < prepared.chapters.count)
        chrome.setReadingInfo(prepared, position: pagePosition, configuration: readingOptions.footer)
        chrome.setPage(pagePosition, count: prepared.pages.count)
        chrome.setBusy(isReaderBusy)
    }

    private func renderWindowPages() {
        guard !isLoading, !isApplyingChapter, !isExiting, chapter?.pages.isEmpty == false, !sourceDestination.isPending
        else {
            return
        }
        strip.setPages(chapterWindow.pages)
        updatePrefetch()
    }

    private func visiblePageChanged(_ page: MangaWindowPage) {
        guard canUseActions, page.chapter.book.bookUrl == bookURL,
            page.chapter.book.origin == chapter?.book.origin
        else { return }
        let changedChapter = chapter?.chapterIndex != page.chapter.chapterIndex
        let changedPosition = pagePosition != page.position
        pagePosition = page.position
        if changedChapter {
            adapter.accept(page.chapter)
            chapter = page.chapter
            if chapterWindow.activate(chapterIndex: page.chapterIndex) == nil { chapterWindow.reset(page.chapter) }
        }
        updateChapterChrome()
        if changedChapter || changedPosition {
            adapter.record(position: page.position, immediate: changedChapter)
            progressSync.contextDidChange()
        }
        updatePrefetch()
    }

    private func neighborFailed(index: Int, error: Error) {
        guard canUseActions, presentedViewController == nil, let chapter,
            index > Int(chapter.chapterIndex), pagePosition == chapter.pages.count - 1
        else { return }
        showTransientMessage(
            L10n.format("manga.flow.next_chapter_failed", "下一章加载失败：%@", error.userFacingMessage), duration: 4)
        setControlsVisible(true)
    }

    private func showState(
        message: String, loading: Bool = false, actionTitle: String? = nil, icon: String = "arrow.clockwise",
        action: (() -> Void)? = nil
    ) {
        stateView.show(message: message, loading: loading, actionTitle: actionTitle, icon: icon, action: action)
        if !loading { setControlsVisible(true, animated: false) }
    }

    private func retryLoad() {
        guard !catalog.isActive else { return }
        load(index: requestedIndex, position: requestedPosition, refresh: requestedRefresh)
    }

    private func changeChapter(by delta: Int) {
        guard canUseActions, let chapter else { return }
        bookInfo.cancel()
        let index = Int(chapter.chapterIndex) + delta
        guard chapter.chapters.indices.contains(index) else { return }
        if let prepared = chapterWindow.pages.first(where: { $0.chapterIndex == index })?.chapter {
            recordPosition(immediate: true)
            adapter.accept(prepared)
            self.chapter = prepared
            pagePosition = 0
            _ = chapterWindow.activate(chapterIndex: index)
            let key = MangaWindowPage(chapter: prepared, position: 0).key
            strip.setPages(chapterWindow.pages, restoring: key)
            stateView.hide()
            updateChapterChrome()
            adapter.record(position: 0, immediate: true)
            progressSync.contextDidChange()
            updatePrefetch()
            updateAutomaticReading()
            return
        }
        load(index: index, position: 0)
    }

    private func showContents() {
        guard canUseActions, !catalog.isActive, presentedViewController == nil, chapter != nil else { return }
        bookInfo.cancel()
        recordPosition(immediate: true)
        setControlsVisible(false)
        catalog.present()
    }

    private func showDownloads() {
        guard canUseActions, presentedViewController == nil, let chapter else { return }
        bookInfo.cancel()
        recordPosition(immediate: true)
        let revision = loadRevision
        downloadCoordinator.present(from: self, chapter: chapter, anchor: chrome.downloadAnchor) { [weak self] in
            guard let self else { return false }
            return self.canUseActions && self.loadRevision == revision
        }
    }

    private func readingMenu() async -> [UIMenuElement] {
        guard canUseActions, !recovery.isBusy else { return [] }
        let revision = loadRevision
        let recoveryItems = await recovery.menuElements()
        guard canUseActions, !recovery.isBusy, loadRevision == revision else { return [] }
        return MangaReaderMenuCommands.existingMore(
            recoveryItems: recoveryItems, progressItems: progressSync.menuElements(),
            automaticItems: automaticReading.menuElements(), onDownload: { [weak self] in self?.showDownloads() },
            onSettings: { [weak self] in self?.showSettings() })
    }

    private func showSettings() {
        guard canUseActions, presentedViewController == nil else { return }
        bookInfo.cancel()
        recordPosition(immediate: true)
        readingSettings.present(from: self)
    }

    private func refreshCurrentChapter() {
        guard canUseActions, presentedViewController == nil else { return }
        setControlsVisible(false)
        load(
            index: chapter.map { Int($0.chapterIndex) } ?? requestedIndex,
            position: chapter == nil ? requestedPosition : pagePosition, refresh: true)
    }

    private func setControlsVisible(_ visible: Bool, animated: Bool = true) {
        controlsVisible = visible
        chrome.setControlsVisible(visible, animated: animated)
        updateAutomaticReading()
    }

    private func updateAutomaticReading() {
        let eligible =
            isReadingVisible && canUseActions && !recovery.isBusy && !controlsVisible && stateView.isHidden
            && !catalog.isActive && !hasVisiblePresentation && !collection.isDragging && !collection.isDecelerating
            && !readerLayout.needsViewportUpdate && view.window?.isKeyWindow == true
            && view.window.map { AppLockManager.shared.isUnlocked(in: $0) } == true
        automaticReading.update(
            isEligible: eligible, speed: readingOptions.autoPageSpeed, animatesPages: readingOptions.animatesPages)
        if canSyncProgress { progressSync.refresh() }
    }

    private func automaticReadingMoved() {
        strip.didMoveAutomatically()
    }

    private var hasVisiblePresentation: Bool {
        var owner: UIViewController? = self
        while let current = owner {
            if current.presentedViewController != nil { return true }
            owner = current.parent
        }
        return false
    }

    private func advanceAutomaticChapter() -> Bool {
        guard canUseActions, let chapter, Int(chapter.chapterIndex) + 1 < chapter.chapters.count else { return false }
        changeChapter(by: 1)
        return true
    }

    private func recoveryBusyChanged(_ busy: Bool) {
        if busy {
            bookInfo.cancel()
            catalog.cancel()
            progressSync.invalidateContext()
            wasLoadingBeforeRecovery = isLoading || chapter == nil
            recordPosition(immediate: true)
            automaticReading.stop()
            loadRevision = UUID()
            loadTask?.cancel()
            loadTask = nil
            adapter.suspendLoading()
            chapterWindow.suspend()
            strip.cancel()
            adapter.setReadingActive(false)
            prefetcher.cancel()
            collection.isUserInteractionEnabled = false
            chrome.setBusy(true)
        } else {
            sourceDestination.navigateIfNeeded()
            guard !sourceDestination.isPending else { return }
            catalogActivityChanged()
            if wasLoadingBeforeRecovery { retryLoad() } else { resumeIfNeeded() }
        }
    }

    private func sourceChangeCommitted(
        _ result: BookDetailRefreshResult, replacing originalURL: String, targets: [UIViewController]
    ) {
        catalog.cancel()
        progressSync.invalidateContext()
        automaticReading.stop()
        loadRevision = UUID()
        loadTask?.cancel()
        loadTask = nil
        prefetcher.cancel()
        images.cancelAll()
        chapterWindow.cancel()
        strip.cancel()
        sourceDestination.committed(result, replacing: originalURL, targets: targets)
    }

    private func suspendForLogin() {
        catalog.cancel()
        progressSync.invalidateContext()
        recordPosition(immediate: true)
        automaticReading.stop()
        loadRevision = UUID()
        loadTask?.cancel()
        loadTask = nil
        adapter.suspendLoading()
        chapterWindow.suspend()
        strip.cancel()
        prefetcher.cancel()
        images.cancelAll()
        persistPause()
    }

    private func seek(to position: Int) {
        guard canUseActions, let chapter, chapter.pages.indices.contains(position) else { return }
        pagePosition = position
        strip.seek(to: MangaWindowPage(chapter: chapter, position: position).key)
        chrome.setPage(position, count: chapter.pages.count)
        adapter.record(position: position, immediate: true)
        progressSync.contextDidChange()
        updatePrefetch()
    }

    private func applyReadingOptions(_ options: MangaReadingOptions) {
        guard !isExiting else { return }
        readingOptions = options
        gestures.setZoomEnabled(options.allowsZoom)
        strip.applyOptions(options)
        brightness.update(options.colorFilter, window: view.window, active: isReadingVisible && canNavigate)
        updateChapterChrome()
        if !options.allowsZoom, let navigation = presentedViewController as? UINavigationController,
            navigation.topViewController is MangaImageZoomViewController
        {
            navigation.dismiss(animated: false)
        }
        updatePrefetch()
        updateAutomaticReading()
    }

    private func updatePrefetch() {
        strip.updatePrefetch(enabled: readingSettings.isReady && canUseActions && chapter != nil)
    }

    private func recordPosition(immediate: Bool) {
        guard chapter != nil, !sourceDestination.isPending else { return }
        if !isLoading, let page = strip.currentPage(), page.chapter.book.bookUrl == bookURL,
            page.chapter.book.origin == chapter?.book.origin
        {
            if chapter?.chapterIndex != page.chapter.chapterIndex {
                adapter.accept(page.chapter)
                chapter = page.chapter
            }
            pagePosition = page.position
        }
        adapter.record(position: pagePosition, immediate: immediate)
        progressSync.contextDidChange()
    }

    private func persistPause() {
        adapter.setReadingActive(false)
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "MangaProgress", expirationHandler: nil)
        let adapter = adapter
        Task {
            await adapter.pause()
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) }
        }
    }

    private func resumeIfNeeded() {
        let ownedPresentationVisible =
            presentedViewController?.viewIfLoaded?.window?.windowScene === readingScene
            && readingScene?.activationState == .foregroundActive
        guard canNavigate || ownedPresentationVisible, !isExiting, !recovery.isBusy, !sourceDestination.isPending
        else {
            return
        }
        adapter.resumeLoading()
        chapterWindow.resume()
        if needsReload { retryLoad() } else if !isLoading { adapter.setReadingActive(chapter != nil) }
        updatePrefetch()
        progressSync.resume()
        updateAutomaticReading()
    }

    private func tapPage(at point: CGPoint) {
        guard canUseActions else { return }
        switch readerLayout.tapAction(at: point, clickScroll: readingOptions.clickScroll) {
        case .controls:
            setControlsVisible(!controlsVisible)
        case .page(let direction):
            guard let offset = readerLayout.pageOffset(by: direction) else { return }
            readerLayout.releaseRestoredAnchor()
            let animated = readingOptions.animatesPages && !UIAccessibility.isReduceMotionEnabled
            collection.setContentOffset(offset, animated: animated)
            if !animated {
                strip.didMoveAutomatically()
                recordPosition(immediate: true)
                updatePrefetch()
            }
        case .none: break
        }
    }

    private func zoomPage(at point: CGPoint) {
        guard canUseActions, readingOptions.allowsZoom, presentedViewController == nil,
            let path = collection.indexPathForItem(at: point),
            strip.pages.indices.contains(path.item)
        else { return }
        recordPosition(immediate: true)
        MangaImageZoomViewController.present(strip.pages[path.item], pipeline: images, options: readingOptions, from: self)
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === (readingScene ?? viewIfLoaded?.window?.windowScene)
        else {
            return
        }
        catalog.cancel()
        bookInfo.cancel()
        recordPosition(immediate: true)
        progressSync.suspend(upload: !recovery.isBusy && !sourceDestination.isPending)
        chrome.setReaderVisible(false)
        brightness.restore()
        automaticReading.update(isEligible: false, speed: readingOptions.autoPageSpeed)
        prefetcher.cancel()
        if isLoading {
            needsReload = true
            loadRevision = UUID()
            loadTask?.cancel()
            loadTask = nil
        }
        adapter.suspendLoading()
        chapterWindow.suspend()
        strip.cancel()
        exitFlow.cancelPendingWork()
        persistPause()
    }

    @objc private func sceneActivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === (readingScene ?? viewIfLoaded?.window?.windowScene)
        else {
            return
        }
        resumeIfNeeded()
        chrome.setReaderVisible(isReadingVisible)
        brightness.setActive(isReadingVisible, window: view.window)
    }

    @objc private func back() {
        guard canNavigate, !isExiting, !recovery.isBusy, !sourceDestination.isPending, presentedViewController == nil
        else {
            return
        }
        exitFlow.begin()
    }

    private func prepareForExit() {
        bookInfo.cancel()
        catalog.cancel()
        progressSync.invalidateContext()
        automaticReading.stop()
        recordPosition(immediate: true)
        if isLoading { needsReload = true }
        loadRevision = UUID()
        loadTask?.cancel()
        loadTask = nil
        adapter.suspendLoading()
        chapterWindow.suspend()
        strip.cancel()
        prefetcher.cancel()
    }
}
