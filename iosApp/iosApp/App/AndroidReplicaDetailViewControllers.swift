import UIKit
import shared

final class AndroidReplicaBookDetailViewController: UIViewController, NavigationContentChromeProviding {
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    private(set) var bookURL: String
    private var seed: BookDetailPreviewSeed?
    private let adapter: AndroidReplicaBookDetailAdapter
    private lazy var topBar = AndroidReplicaDetailBar(
        title: "书籍信息", target: self, backAction: #selector(handleBack), appearance: .coverOverlay)
    private let editButton = UIButton(type: .custom)
    private let shareButton = UIButton(type: .custom)
    private let moreButton = UIButton(type: .custom)
    private let contentView = AndroidReplicaBookDetailContentView()
    private lazy var pageView = AndroidReplicaBookDetailPageView(topBar: topBar, contentView: contentView)
    private var shelfButton: UIButton { pageView.shelfButton }
    private var readButton: UIButton { pageView.readButton }
    private var spinner: UIActivityIndicatorView { pageView.spinner }
    private var book: Book?
    private var chapters: [BookChapter] = []
    private var isInBookshelf = false
    private var isUpdatingShelf = false
    private var isReady = false
    private var isDetailActive = false
    private weak var detailScene: UIWindowScene?
    private var isSceneActive = false
    private var interactionGeneration = 0
    private var directorySessionID: UUID?
    private var chapterFailureID: UUID?
    private var needsAppearanceLoad = true
    private var isOpeningReader = false
    private var isChangingSource = false
    private var isChangingGroup = false
    private var isChangingCover = false
    private var isPerformingMenuAction = false
    private var groupName: String?
    private var needsInfo = false
    private var needsChapters = true
    private var catalogState = AndroidReplicaBookDetailContentView.CatalogState.ready
    private var loadGeneration = 0
    private var loadingTask: Task<Void, Never>?
    private var shelfTask: Task<Void, Never>?
    private lazy var webFiles = WebBookFileCoordinator(
        owner: self, onChange: { [weak self] in self?.updateActions() },
        onImported: { [weak self] result, read in
            guard let self, self.canInteract() else { return }
            self.adoptCommittedSourceChange(result, replacing: self.bookURL)
            if read { self.loadInitial(openReader: true) }
        })
    private lazy var shelfRemoval = BookDetailShelfRemovalCoordinator(
        presenter: self, currentBook: { [weak self] in self?.book },
        canPresent: { [weak self] in self?.canInteract() == true },
        waitForDetailLoad: { [weak self] in await self?.loadingTask?.value },
        removeBook: { [adapter] url, deleteOriginal in
            try await adapter.deleteFromBookshelf(expectedBookURL: url, deleteOriginal: deleteOriginal)
        },
        onBusyChange: { [weak self] busy in
            guard let self else { return }
            self.isUpdatingShelf = busy
            if busy {
                self.cancelLoading()
                self.spinner.startAnimating()
            } else {
                self.spinner.stopAnimating()
                self.needsAppearanceLoad = true
                self.resumeAppearanceLoadIfNeeded()
            }
            self.updateActions()
        },
        onRemoved: { url, navigation in BookDetailNavigationActions.closeRemovedBook(url, in: navigation) },
        onDismiss: { [weak self] in self?.updateActions() })
    private lazy var coverActions = BookDetailCoverActions(
        presenter: self, pageView: pageView, imageView: contentView.coverImageView, adapter: adapter,
        currentBook: { [weak self] in self?.book },
        isActive: { [weak self] in
            guard let self else { return false }
            return self.isDetailActive && self.navigationController?.topViewController === self
        },
        canPresent: { [weak self] in self?.canInteract() == true },
        waitForDetailLoad: { [weak self] in
            guard let self else { return }
            await self.loadingTask?.value
        },
        onBusyChange: { [weak self] busy in
            guard let self else { return }
            self.isChangingCover = busy
            self.updateActions()
            if !busy { self.resumeAppearanceLoadIfNeeded() }
        },
        onCommitted: { [weak self] updated in
            guard let self, self.bookURL == updated.bookUrl else { return }
            self.book = updated
            if self.isDetailActive { self.renderBook() }
        })
    private lazy var groupActions = BookDetailGroupActions(
        presenter: self, adapter: adapter,
        currentBook: { [weak self] in self?.book },
        canPresent: { [weak self] in
            guard let self else { return false }
            return self.canInteract(
                allowing: .group, in: self.presentedViewController as? AndroidReplicaBookDetailGroupPickerViewController
            )
        },
        onNameChange: { [weak self] name in
            guard let self, self.groupName != name else { return }
            self.groupName = name
            self.renderBook()
        },
        onBusyChange: { [weak self] busy in
            self?.isChangingGroup = busy
            self?.updateActions()
            if !busy { self?.resumeAppearanceLoadIfNeeded() }
        },
        onCommitted: { [weak self] updated in
            guard let self, self.bookURL == updated.bookUrl else { return }
            self.book = updated
            self.renderBook()
        })
    private lazy var sourceChangeActions = BookDetailSourceChangeActions(
        presenter: self, adapter: adapter,
        currentBook: { [weak self] in self?.book },
        canPresent: { [weak self] in self?.canInteract(allowing: .source) == true },
        onBusyChange: { [weak self] busy in
            guard let self else { return }
            self.isChangingSource = busy
            if busy {
                self.cancelLoading()
                self.spinner.startAnimating()
            } else {
                self.spinner.stopAnimating()
            }
            self.updateActions()
        },
        onCommitted: { [weak self] result, originalURL, targets in
            self?.adoptCommittedSourceChange(result, replacing: originalURL)
            BookSourceChangeNavigation.publish(result, replacing: originalURL, to: targets, excluding: self)
        })

    private lazy var overflowActions = BookDetailOverflowMenuCoordinator(
        presenter: self, adapter: adapter,
        currentBook: { [weak self] in self?.book },
        canPresent: { [weak self] in self?.canInteract() == true },
        waitForDetailLoad: { [weak self] in
            guard let self else { return }
            await self.loadingTask?.value
        },
        onBusyChange: { [weak self] busy in
            guard let self else { return }
            self.isPerformingMenuAction = busy
            self.updateActions()
            if busy { self.spinner.startAnimating() } else if self.isDetailActive { self.spinner.stopAnimating() }
            if !busy { self.resumeAppearanceLoadIfNeeded() }
        },
        onCommitted: { [weak self] updated in
            guard let self, self.bookURL == updated.bookUrl else { return }
            self.book = updated
            if self.isDetailActive { self.renderBook() }
        },
        onRefresh: { [weak self] in self?.refreshInfo() },
        canContinueRelink: { [weak self] in self?.canInteract(allowing: .menu, in: $0) == true },
        onRelinkCommitted: { [weak self] updated in
            guard let self, self.bookURL == updated.bookUrl else { return }
            self.directorySessionID = nil
            self.chapterFailureID = nil
            self.book = updated
            self.chapters = []
            self.needsInfo = false
            self.needsChapters = true
            self.needsAppearanceLoad = true
            self.catalogState = .loading
            if self.isDetailActive { self.renderBook() }
        })

    private var displayedChapterCount: Int {
        chapters.isEmpty ? max(Int(book?.totalChapterNum ?? 0), 0) : chapters.count
    }

    private enum DetailOperation { case navigation, shelf, source, group, cover, menu }

    private func isBusy(except operation: DetailOperation? = nil) -> Bool {
        (isOpeningReader && operation != .navigation) || (isUpdatingShelf && operation != .shelf)
            || (isChangingSource && operation != .source) || (isChangingGroup && operation != .group)
            || (isChangingCover && operation != .cover) || (isPerformingMenuAction && operation != .menu)
            || webFiles.isBusy
    }

    private func canInteract(allowing operation: DetailOperation? = nil, in ownedModal: UIViewController? = nil) -> Bool {
        guard isDetailActive, isSceneActive, !isBusy(except: operation) else { return false }
        return BookDetailInteractionOwner.canInteract(owner: self, scene: detailScene, ownedModal: ownedModal)
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === detailScene else { return }
        isSceneActive = notification.name == UIScene.didActivateNotification
        // Revoke pending presentations, not callbacks belonging to an already presented directory or alert.
        if !isSceneActive {
            interactionGeneration &+= 1
            overflowActions.sceneDidDeactivate()
        }
        updateActions()
        if isSceneActive { resumeAppearanceLoadIfNeeded() }
    }

    private func resumeAppearanceLoadIfNeeded() {
        if needsAppearanceLoad { loadInitial() }
    }

    init(bookURL: String) {
        self.bookURL = bookURL
        seed = nil
        adapter = AndroidReplicaBookDetailAdapter(bookURL: bookURL)
        super.init(nibName: nil, bundle: nil)
    }

    init(searchBook: SearchBook) {
        bookURL = searchBook.bookUrl
        seed = BookDetailPreviewSeed(searchBook: searchBook)
        adapter = AndroidReplicaBookDetailAdapter(bookURL: searchBook.bookUrl, previewCandidate: searchBook)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        loadingTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        view = pageView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        adapter.onFlushReadingProgress = { [weak self] in
            guard let self else { return }
            await BookSourceChangeNavigation.flushReadingProgress(
                for: self.bookURL, in: self.navigationController?.viewControllers ?? [])
        }
        configureActions()
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        bootstrap()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDetailActive = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let scene = viewIfLoaded?.window?.windowScene
        if detailScene !== scene { interactionGeneration &+= 1 }
        detailScene = scene
        isSceneActive = scene?.activationState == .foregroundActive
        renderBook()
        DispatchQueue.main.async { [weak self] in self?.resumeAppearanceLoadIfNeeded() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        overflowActions.dismiss()
        let leavingStack = navigationController.map { $0.topViewController !== self } ?? false
        guard isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true || leavingStack
        else { return }
        isDetailActive = false
        overflowActions.cancelRelink()
        interactionGeneration &+= 1
        directorySessionID = nil
        chapterFailureID = nil
        needsAppearanceLoad = true
        sourceChangeActions.cancelPreparation()
        groupActions.cancelPreparation()
        cancelLoading()
        coverActions.cancel()
        webFiles.cancel()
        contentView.setRefreshing(false)
        spinner.stopAnimating()
        updateActions()
    }

    private func configureActions() {
        // Legado ic_edit (24dp) / ic_share (20dp); neither declares autoMirrored.
        editButton.setImage(UIImage(named: "BookDetailAndroidEdit")?.withRenderingMode(.alwaysTemplate), for: .normal)
        editButton.accessibilityLabel = L10n.BookDetail.editBookInfo
        editButton.accessibilityIdentifier = "bookDetail.edit"
        editButton.addTarget(self, action: #selector(openBookEditor), for: .touchUpInside)
        shareButton.setImage(UIImage(named: "BookDetailAndroidShare")?.withRenderingMode(.alwaysTemplate), for: .normal)
        shareButton.accessibilityLabel = L10n.BookDetail.shareBook
        shareButton.accessibilityIdentifier = "bookDetail.share"
        shareButton.addTarget(self, action: #selector(shareBook), for: .touchUpInside)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        moreButton.addTarget(self, action: #selector(showMoreActions), for: .touchUpInside)
        moreButton.accessibilityLabel = L10n.BookDetail.moreActions
        moreButton.accessibilityIdentifier = "bookDetail.more"
        topBar.addAction(editButton)
        topBar.addAction(shareButton)
        topBar.addAction(moreButton, isOverflow: true)

        contentView.onTitleTap = { [weak self] in self?.openRelatedSearch(author: false) }
        contentView.onRefresh = { [weak self] in self?.refreshInfo() }
        contentView.onAuthorTap = { [weak self] in self?.openRelatedSearch(author: true) }
        contentView.onSourceTap = { [weak self] in self?.openSourceEditor() }
        contentView.onGroupTap = { [weak self] in self?.groupActions.presentPicker() }
        contentView.onCoverTap = { [weak self] in self?.coverActions.presentPicker() }
        contentView.onCoverLongPress = { [weak self] in self?.coverActions.presentPreview() }
        contentView.onTocTap = { [weak self] in
            guard let self else { return }
            if self.catalogState == .failed {
                self.refreshChapters(silent: false)
            } else {
                self.openChapterList()
            }
        }
        contentView.onSourceChangeTap = { [weak self] in
            guard let self, !self.isChangingSource else { return }
            self.sourceChangeActions.presentPicker()
        }

        shelfButton.addTarget(self, action: #selector(toggleShelf), for: .touchUpInside)
        readButton.addTarget(self, action: #selector(readBook), for: .touchUpInside)
        updateActions()
    }

    private func bootstrap() {
        switch adapter.bootstrap() {
        case .success:
            isReady = true
            renderSeedIfNeeded()
        case .failure(let error):
            showMessage(error.message)
        }
    }

    private func loadInitial(
        openReader: Bool = false, silentChapters: Bool = true,
        chapterIndex: Int? = nil, chapterPosition: Int? = nil, forceChapterRefresh: Bool = false
    ) {
        guard isReady, canInteract() else { return }
        needsAppearanceLoad = false
        let previous = loadingTask
        cancelLoading()
        let generation = loadGeneration
        let interaction = interactionGeneration
        isOpeningReader = openReader
        spinner.startAnimating()
        updateActions()
        loadingTask = Task { @MainActor [weak self, adapter] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.loadGeneration == generation {
                    self.loadingTask = nil
                    self.isOpeningReader = false
                    self.contentView.setRefreshing(false)
                    self.spinner.stopAnimating()
                    self.updateActions()
                }
            }
            guard self.acceptsLoad(generation) else { return }
            self.traceLoad(
                "start read=\(openReader) info=\(self.needsInfo) chapters=\(self.needsChapters)", generation: generation
            )
            var reportErrors = true
            var loadingChapters = false
            do {
                let resolved = try await adapter.resolveInitialBook(preparingForReading: openReader)
                guard self.acceptsLoad(generation) else { return }
                self.traceLoad("accept resolve", generation: generation)
                self.book = resolved
                self.renderBook()
                if openReader {
                    guard self.acceptsNavigation(generation, interaction: interaction),
                        let resolved, !resolved.isNotShelf || self.displayedChapterCount > 0
                    else { return }
                    BookReadingDestination.open(
                        resolved, from: self, chapterIndex: chapterIndex, chapterPosition: chapterPosition)
                    return
                }
                guard let resolved else { return }
                self.needsInfo = self.needsInfo || (!resolved.isLocal && resolved.tocUrl.isEmpty)
                let refreshChapters = forceChapterRefresh || self.needsInfo
                if self.needsInfo {
                    do {
                        let refreshed = try await adapter.refreshInfo()
                        guard self.acceptsLoad(generation) else { return }
                        self.traceLoad("accept info", generation: generation)
                        self.needsInfo = false
                        self.book = refreshed
                        self.renderBook()
                    } catch {
                        guard self.acceptsLoad(generation), !(error is CancellationError) else { return }
                        self.catalogState = self.chapters.isEmpty ? .failed : .ready
                        self.renderBook()
                        if self.canInteract() { self.showMessage(error.userFacingMessage) }
                        return
                    }
                }
                if self.needsChapters {
                    if self.book?.isWebFile == true {
                        self.needsChapters = false
                        self.catalogState = .ready
                        self.renderBook()
                        return
                    }
                    loadingChapters = true
                    self.catalogState = .loading
                    self.renderBook()
                    reportErrors = !silentChapters
                    if silentChapters { self.spinner.stopAnimating() }
                    let result = try await adapter.loadInitialChapters(
                        book: self.book ?? resolved, forceRefresh: refreshChapters)
                    guard self.acceptsLoad(generation) else { return }
                    self.traceLoad("accept chapters", generation: generation)
                    self.needsChapters = false
                    self.book = result.book
                    self.chapters = result.chapters
                    self.catalogState = result.chapters.isEmpty ? .failed : .ready
                    self.renderBook()
                }
            } catch {
                guard self.acceptsLoad(generation), !(error is CancellationError) else { return }
                if loadingChapters {
                    self.catalogState = .failed
                    self.renderBook()
                }
                if reportErrors, self.canInteract(allowing: .navigation) { self.showMessage(error.userFacingMessage) }
            }
        }
    }

    private func cancelLoading() {
        if let loadingTask, !loadingTask.isCancelled { traceLoad("cancel", generation: loadGeneration) }
        loadGeneration &+= 1
        loadingTask?.cancel()
        contentView.setRefreshing(false)
        isOpeningReader = false
    }

    func adoptCommittedSourceChange(_ result: BookDetailRefreshResult, replacing originalBookURL: String) {
        guard adapter.adoptCommittedSourceChange(replacing: originalBookURL, bookURL: result.book.bookUrl) else {
            return
        }
        cancelLoading()
        directorySessionID = nil
        chapterFailureID = nil
        bookURL = result.book.bookUrl
        seed = nil
        book = result.book
        chapters = result.chapters
        needsInfo = false
        needsChapters = false
        catalogState = result.chapters.isEmpty ? .failed : .ready
        if isViewLoaded { renderBook() }
    }

    private func acceptsLoad(_ generation: Int) -> Bool {
        isDetailActive && loadGeneration == generation && !Task.isCancelled
    }

    private func acceptsNavigation(_ generation: Int, interaction: Int) -> Bool {
        acceptsLoad(generation) && interactionGeneration == interaction && canInteract(allowing: .navigation)
    }

    private func traceLoad(_ event: String, generation: Int) {
        #if DEBUG
            SharedRuntime.log("[BookDetail] \(event) generation=\(generation) url=\(bookURL)")
        #endif
    }

    private func renderBook() {
        isInBookshelf = book?.isNotShelf == false
        guard let book else {
            renderSeedIfNeeded()
            updateActions()
            return
        }
        contentView.render(
            .init(
                name: book.name, author: book.getRealAuthor(), kind: book.kind, wordCount: book.wordCount,
                intro: book.displayIntro,
                originName: book.originName,
                readingProgress: isInBookshelf ? book.durChapterTitle?.nilIfEmpty : nil,
                chapterCount: displayedChapterCount, latestChapter: book.latestChapterTitle,
                catalogState: catalogState, currentChapterTitle: book.durChapterTitle, groupName: groupName,
                showsCatalog: !book.isWebFile))
        updateActions()
        coverActions.loadCover(book)
        groupActions.refreshLabel(for: book)
    }

    private func renderSeedIfNeeded() {
        guard book == nil, let seed else { return }
        contentView.render(
            .init(
                name: seed.name, author: seed.author, kind: seed.kind, wordCount: seed.coverCandidate.wordCount,
                intro: seed.intro,
                originName: seed.originName, readingProgress: nil,
                chapterCount: displayedChapterCount, latestChapter: nil,
                catalogState: catalogState))
        coverActions.loadSeedCover(seed.coverCandidate)
        updateActions()
    }

    private func updateActions() {
        var shelfConfig = shelfButton.configuration ?? .plain()
        shelfConfig.title =
            isInBookshelf ? L10n.BookDetail.primaryActionShelfRemove : L10n.BookDetail.primaryActionShelfAdd
        shelfButton.configuration = shelfConfig
        let canAct = !isBusy()
        shelfButton.isEnabled = book != nil && canAct
        readButton.isEnabled = book != nil && canAct && (isInBookshelf || displayedChapterCount > 0 || book?.isWebFile == true)
        editButton.isHidden = !isInBookshelf
        editButton.isEnabled = isInBookshelf && book != nil && canAct
        shareButton.isEnabled = book != nil && canAct
        moreButton.isEnabled = book != nil && canAct
        contentView.isTocEnabled = book != nil && book?.isWebFile == false && canAct
        contentView.isSourceChangeVisible = book?.isLocal == false && book?.origin.nilIfEmpty != nil
        contentView.isSourceChangeEnabled = contentView.isSourceChangeVisible && canAct
        contentView.isSourceEditEnabled = contentView.isSourceChangeVisible && canAct
        contentView.isGroupEnabled = book != nil && canAct
        contentView.isCoverEnabled = book != nil && canAct
        // Over-full-screen sheets need not send appearance callbacks when they close.
        contentView.isRefreshEnabled =
            isDetailActive && isSceneActive && canAct && isReady && book != nil
            && (loadingTask == nil || loadingTask?.isCancelled == true)
    }

    @objc private func handleBack() {
        guard canInteract() else { return }
        navigationController?.popViewController(animated: true)
    }

    @objc private func refreshInfo() {
        guard canInteract() else { return }
        needsInfo = true
        needsChapters = true
        loadInitial(forceChapterRefresh: true)
    }

    @objc private func showMoreActions() {
        guard canInteract(), book != nil else { return }
        overflowActions.present(anchor: moreButton)
    }

    private func refreshChapters(silent: Bool) {
        guard canInteract(), book?.isWebFile == false else { return }
        needsChapters = true
        loadInitial(silentChapters: silent, forceChapterRefresh: true)
    }

    @objc private func toggleShelf() {
        guard canInteract(), book != nil else { return }
        if isInBookshelf {
            shelfRemoval.present()
            return
        }
        if let book, book.isWebFile {
            webFiles.start(book: book, openAfterImport: false)
            return
        }
        let previous = loadingTask
        cancelLoading()
        let generation = loadGeneration
        isUpdatingShelf = true
        updateActions()
        spinner.startAnimating()
        // Shelf writes must finish even if the detail leaves the navigation stack.
        shelfTask = Task { @MainActor [self] in
            await previous?.value
            defer {
                self.isUpdatingShelf = false
                self.shelfTask = nil
                self.needsAppearanceLoad = true
                self.spinner.stopAnimating()
                self.updateActions()
                self.resumeAppearanceLoadIfNeeded()
            }
            do {
                _ = try await self.adapter.addToBookshelf()
            } catch {
                if self.canInteract(allowing: .shelf), self.loadGeneration == generation {
                    self.showMessage(error.userFacingMessage)
                }
            }
        }
    }

    @objc private func readBook() {
        guard canInteract(), let book, isInBookshelf || displayedChapterCount > 0 || book.isWebFile else { return }
        if book.isWebFile { webFiles.start(book: book, openAfterImport: true); return }
        loadInitial(openReader: true)
    }

    private func openRelatedSearch(author: Bool) {
        guard canInteract() else { return }
        BookDetailNavigationActions.search(author: author, book: book, seed: seed, from: self)
    }

    @objc private func openBookEditor() {
        guard canInteract(), isInBookshelf, book != nil else { return }
        let expectedBookURL = bookURL
        prepareNavigation { [adapter] owner, generation, interaction in
            let current = try await adapter.prepareBookEditor()
            guard owner.acceptsNavigation(generation, interaction: interaction), owner.bookURL == expectedBookURL
            else { return }
            let editor = BookInfoEditViewController(
                book: current,
                saveEditedBook: { name, author, cover, intro, type in
                    try await adapter.saveEditedBookInfo(
                        expectedBookURL: expectedBookURL, name: name, author: author, coverURL: cover,
                        intro: intro, bookType: type)
                },
                createCoverSearchSession: { result, progress, finished in
                    try await adapter.createCoverSearchSession(
                        expectedBookURL: expectedBookURL, onResult: result, onProgress: progress,
                        onFinished: finished)
                },
                onSave: { [weak owner] updated in
                    guard let owner, owner.bookURL == updated.bookUrl else { return }
                    owner.book = updated
                    owner.renderBook()
                })
            let navigation = UINavigationController(rootViewController: editor)
            navigation.modalPresentationStyle = .fullScreen
            owner.present(navigation, animated: true)
        }
    }

    private func openSourceEditor() {
        guard canInteract(), contentView.isSourceEditEnabled else { return }
        let expectedBookURL = bookURL
        prepareNavigation { [adapter] owner, generation, interaction in
            let prepared = try await adapter.prepareSourceEditor()
            guard owner.acceptsNavigation(generation, interaction: interaction), owner.bookURL == expectedBookURL
            else { return }
            let editor = BookSourceEditViewController(mode: .edit(prepared.sourceURL), screen: prepared.screen)
                .configuredForDrillDownPresentation()
            editor.onSourceSaved = { [weak owner] _ in
                guard let owner, owner.bookURL == expectedBookURL, owner.book?.origin == prepared.sourceURL else {
                    return
                }
                owner.needsInfo = true
                owner.needsChapters = true
            }
            owner.navigationController?.pushViewController(editor, animated: true)
        }
    }

    private func openChapterList() {
        guard canInteract(), let book, !book.isWebFile else { return }
        let expectedBookURL = bookURL
        prepareNavigation(
            onFailure: { [weak self] in self?.showChapterListFailure($0) },
            operation: {
                [adapter] owner, generation, interaction in
                let resolved = try await adapter.resolveInitialBook()
                guard owner.acceptsLoad(generation) else { return }
                owner.book = resolved
                var items = try await adapter.loadChapterListState()
                if items.isEmpty {
                    let result = try await adapter.refreshChapters()
                    guard owner.acceptsLoad(generation) else { return }
                    owner.book = result.book
                    owner.chapters = result.chapters
                    owner.needsChapters = false
                    owner.catalogState = result.chapters.isEmpty ? .failed : .ready
                    items = try await adapter.loadChapterListState()
                }
                guard owner.acceptsNavigation(generation, interaction: interaction), owner.bookURL == expectedBookURL,
                    let book = owner.book, !book.isWebFile
                else { return }
                owner.chapters = items.map(\.chapter)
                owner.needsChapters = false
                owner.catalogState = items.isEmpty ? .failed : .ready
                owner.renderBook()
                guard !items.isEmpty else {
                    owner.showChapterListFailure(L10n.BookDetail.emptyChapters)
                    return
                }
                let sessionID = UUID()
                owner.directorySessionID = sessionID
                let list = AndroidChapterListSheetViewController(
                    items: items, book: book,
                    // Both TOC callbacks run after dismiss completion, when the detail owns interaction again.
                    onSelect: { [weak owner] index in
                        guard owner?.directorySessionID == sessionID, owner?.bookURL == expectedBookURL else { return }
                        owner?.readChapter(index, position: 0)
                    },
                    onSelectPosition: { [weak owner] index, position in
                        guard owner?.directorySessionID == sessionID, owner?.bookURL == expectedBookURL else { return }
                        owner?.readChapter(index, position: position)
                    },
                    onRefresh: nil,
                    onReverse: { [weak owner, adapter] in
                        let result = try await adapter.reverseChapterList()
                        if let owner, owner.bookURL == result.book.bookUrl {
                            owner.book = result.book
                            owner.chapters = result.chapters
                            owner.renderBook()
                        }
                        return try await adapter.loadChapterListState()
                    },
                    onReloadTitles: { [adapter] in try await adapter.loadChapterListState() },
                    onShowLogs: { [weak owner] presenter in
                        guard let owner, owner.directorySessionID == sessionID, owner.bookURL == expectedBookURL,
                            owner.canInteract(in: presenter)
                        else { return }
                        presenter.present(ReaderAppLogDialogViewController(), animated: true)
                    })
                list.modalPresentationStyle = .fullScreen
                owner.present(list, animated: true)
            })
    }

    private func prepareNavigation(
        onFailure: ((String) -> Void)? = nil,
        operation: @escaping (AndroidReplicaBookDetailViewController, Int, Int) async throws -> Void
    ) {
        let previous = loadingTask
        cancelLoading()
        let generation = loadGeneration
        let interaction = interactionGeneration
        isOpeningReader = true
        spinner.startAnimating()
        updateActions()
        loadingTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.loadGeneration == generation {
                    self.loadingTask = nil
                    self.isOpeningReader = false
                    self.spinner.stopAnimating()
                    self.updateActions()
                }
            }
            guard self.acceptsNavigation(generation, interaction: interaction) else { return }
            do {
                try await operation(self, generation, interaction)
            } catch {
                guard self.acceptsNavigation(generation, interaction: interaction), !(error is CancellationError)
                else { return }
                if let onFailure {
                    onFailure(error.userFacingMessage)
                } else {
                    self.showMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func readChapter(_ index: Int, position: Int) {
        guard canInteract() else { return }
        loadInitial(openReader: true, chapterIndex: index, chapterPosition: max(position, 0))
    }

    private func showChapterListFailure(_ message: String) {
        guard canInteract(allowing: .navigation) else { return }
        let presentationID = UUID()
        chapterFailureID = presentationID
        let expectedBookURL = bookURL
        let alert = UIAlertController(
            title: L10n.BookDetail.refreshChaptersFailed, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.retry, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, self.chapterFailureID == presentationID,
                    self.bookURL == expectedBookURL, self.isDetailActive, self.isSceneActive, !self.isBusy()
                else { return }
                BookDetailInteractionOwner.dismissOwnedForAction(alert, owner: self, scene: self.detailScene) {
                    [weak self] in
                    guard let self, self.chapterFailureID == presentationID, self.bookURL == expectedBookURL,
                        self.canInteract()
                    else { return }
                    self.chapterFailureID = nil
                    self.openChapterList()
                }
            })
        present(alert, animated: true)
    }

    private func showMessage(_ message: String) {
        showTransientMessage(message)
    }

    @objc private func shareBook() {
        guard canInteract(), book != nil else { return }
        BookDetailShareAction.present(
            name: book?.name ?? seed?.name, bookURL: book?.bookUrl ?? bookURL, from: self, anchor: shareButton)
    }
}
