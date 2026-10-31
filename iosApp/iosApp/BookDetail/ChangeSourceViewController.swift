import UIKit
import shared

protocol ChangeSourceDelegate: AnyObject {
    func changeSourceDidSelect(_ candidate: BookSourceChangeCandidate)
}

final class ChangeSourceViewController: UIViewController, UITableViewDelegate, UITextFieldDelegate {
    struct ChapterSelection {
        let title: String
        let load: (BookSourceChangeCandidate) async throws -> ChapterSourceChangeToc
        let replace: (BookSourceChangeCandidate, BookChapter, ChapterSourceCommitGate) async throws -> Void
        let onReplaced: () -> Void
        let onCancel: () -> Void
    }

    weak var delegate: ChangeSourceDelegate?
    var chapterSelection: ChapterSelection?
    var wholeBookSelection: WholeBookSourceSelection?
    var onDeletedCurrentSource: (() -> Void)?
    private var wholeBookCoordinator: WholeBookSourceChangeCoordinator?
    private var isSelectingBook = false

    /// Closure that creates a streaming search session. Provided by the presenting VC.
    private let sessionFactory:
        (
            _ onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
            _ onProgress: @escaping (SourceChangeSearchProgress) -> Void,
            _ onFinished: @escaping () -> Void
        ) async throws -> SourceChangeSearchSession

    private let currentSourceUrl: String
    private let currentBook: Book?
    private let titleText: String
    private var candidates: [BookSourceChangeCandidate] = []
    private var filteredCandidates: [BookSourceChangeCandidate] = []
    private let panel = ChangeSourcePanelView()
    private let screen = ChangeSourceScreenAdapter()
    private let ratingStore = ChangeSourceRatingStore()
    private let menuCoordinator = ChangeSourceMenuCoordinator()
    private var screenState: ChangeSourceScreenState?
    private var actionTask: Task<Void, Never>?
    private var isApplyingAction = false
    private var reloadOnReturn = false
    private var tableView: UITableView { panel.tableView }
    private lazy var resultList = ChangeSourceResultList(
        tableView: tableView, currentSourceURL: currentSourceUrl, currentBookURL: currentBook?.bookUrl,
        ratings: ratingStore)
    private var lastAppliedQuery = ""
    private var liveQueryMatches = Set<String>()
    private let chapterTocView = ChangeChapterSourceTocView()
    private var chapterTask: Task<Void, Never>?
    private let chapterReplacement = ChapterSourceReplacementCoordinator()
    private var chapterRequestID = UUID()
    private var selectedChapterCandidate: BookSourceChangeCandidate?
    private var loadedChapterToc: ChapterSourceChangeToc?
    private var isReplacingChapter = false
    private var isClosing = false
    private var didReplaceChapter = false
    private var isPresentationVisible = false
    private weak var presentationScene: UIWindowScene?
    private var isSceneActive = false

    // MARK: - F57 Search state control
    private var factoryTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var searchSession: SourceChangeSearchSession?
    private var isSearching = false
    private var offersAllGroupsOnFinish = false

    private var isSearchExpanded = false
    private var resultCount: Int { filteredCandidates.count }
    private var currentSourceName: String { currentBook?.originName.nilIfEmpty ?? currentSourceUrl }

    init(
        currentSourceUrl: String,
        currentBook: Book? = nil,
        titleText: String = L10n.BookDetail.changeSource,
        sessionFactory:
            @escaping (
                _ onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
                _ onProgress: @escaping (SourceChangeSearchProgress) -> Void,
                _ onFinished: @escaping () -> Void
            ) async throws -> SourceChangeSearchSession
    ) {
        self.currentSourceUrl = currentSourceUrl
        self.currentBook = currentBook
        self.titleText = titleText
        self.sessionFactory = sessionFactory
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        chapterTask?.cancel()
        factoryTask?.cancel()
        searchSession?.dispose()
        NotificationCenter.default.removeObserver(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() { view = panel }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleText
        panel.configure(book: currentBook, title: titleText, sourceName: currentSourceName)
        if let wholeBookSelection {
            wholeBookCoordinator = WholeBookSourceChangeCoordinator(
                host: self, currentBook: currentBook, selection: wholeBookSelection,
                onBusyChange: { [weak self] busy in
                    guard let self else { return }
                    self.isSelectingBook = busy
                    self.updateActionAvailability()
                })
        }
        if let chapterSelection {
            panel.configureChapter(title: chapterSelection.title, sourceName: currentSourceName)
            panel.installChapterToc(chapterTocView)
            chapterTocView.onClose = { [weak self] in self?.hideChapterToc() }
            chapterTocView.onSelect = { [weak self] chapter in self?.selectChapter(chapter) }
        }
        panel.onBack = { [weak self] in self?.dismissSelf() }
        panel.onFilter = { [weak self] in self?.toggleFilter() }
        panel.onSearchToggle = { [weak self] in self?.toggleSearch() }
        panel.onMore = { [weak self] in
            guard let self, self.canInteract, let state = self.screenState,
                !self.isApplyingAction, !self.isReplacingChapter, !self.isSelectingBook
            else {
                return
            }
            self.view.endEditing(true)
            self.menuCoordinator.show(state: state, anchor: self.panel.moreButton, host: self.view)
        }
        panel.onCollapseFilter = { [weak self] in self?.collapseFilter() }
        panel.onLocateCurrent = { [weak self] in self?.scrollToCurrentSource() }
        panel.onTop = { [weak self] in self?.scrollToEdge(last: false) }
        panel.onBottom = { [weak self] in self?.scrollToEdge(last: true) }
        panel.searchField.delegate = self
        panel.searchField.addTarget(self, action: #selector(filterChanged), for: .editingChanged)
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        resultList.onVisibleCountChange = { [weak self] count in
            guard let self else { return }
            self.panel.setEmptyStateVisible(count == 0)
            self.panel.reloadFastScroller()
        }
        resultList.canInteract = { [weak self] in
            guard let self else { return false }
            return self.canInteract && self.chapterTocView.isHidden && !self.menuCoordinator.isVisible
                && !self.isApplyingAction && !self.isReplacingChapter && !self.isSelectingBook
        }
        panel.onFastScrollingChange = { [weak self] active in self?.resultList.setFastScrolling(active) }
        panel.onPaletteChange = { [weak self] in
            guard let self, !self.isClosing else { return }
            self.chapterTocView.refreshPalette()
            self.resultList.refreshPalette()
        }
        resultList.onScore = { [weak self] candidate, score in
            guard let self, self.canInteract, !self.isApplyingAction,
                !self.isReplacingChapter, !self.isSelectingBook
            else { return }
            self.ratingStore.setScore(score, for: candidate)
            self.resultList.noteScoreChanged()
            self.applyFilter()
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(candidateLongPressed(_:)))
        tableView.addGestureRecognizer(longPress)
        menuCoordinator.onAction = { [weak self] action in self?.handleMenuAction(action) }
        menuCoordinator.onDismiss = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.updatePresentationActivity() }
        }
        screen.onState = { [weak self] state in
            guard let self, !self.isClosing else { return }
            let first = self.screenState == nil
            self.screenState = state
            self.resultList.loadWordCount = state.config.changeSourceLoadWordCount
            self.applyFilter()
            self.updateActionAvailability()
            if first { self.startSearch() }
        }
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        updateActionAvailability()
        do { try screen.bind() } catch { panel.setSummary(error.userFacingMessage) }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canInteract, !chapterReplacement.isCommitting, !isApplyingAction, !isSelectingBook else { return [] }
        return [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(dismissSelf))]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationVisible = true
        presentationScene = view.window?.windowScene
        isSceneActive = presentationScene?.activationState == .foregroundActive
        updatePresentationActivity()
        becomeFirstResponder()
    }

    func cancelPendingBookSelection() { wholeBookCoordinator?.cancel() }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract, !chapterReplacement.isCommitting, !isApplyingAction, !isSelectingBook else { return false }
        dismissSelf()
        return true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        if reloadOnReturn {
            reloadOnReturn = false
            startSearch()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationVisible = false
        updatePresentationActivity()
        menuCoordinator.dismiss()
        if isLeavingPresentation {
            wholeBookCoordinator?.cancel()
            if !didReplaceChapter { hideChapterToc() }
            resultList.suspend()
            stopSearch()
            screen.unbind()
        }
    }

    // MARK: - F57 Search control

    private var canInteract: Bool {
        isPresentationVisible && isSceneActive && !isClosing && canPerformNavigationAction
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === presentationScene else { return }
        isSceneActive = notification.name == UIScene.didActivateNotification
        if !isSceneActive {
            menuCoordinator.dismiss()
            if chapterTask != nil || isReplacingChapter { hideChapterToc() }
        }
        updatePresentationActivity()
    }

    private func updatePresentationActivity() {
        let active =
            isPresentationVisible && isSceneActive && !isClosing && chapterTocView.isHidden
            && !isApplyingAction && !isReplacingChapter && !isSelectingBook
        resultList.setActive(active)
        panel.setFastScrollInteractionEnabled(active)
        if active, !isSearching, resultCount == 0, let group = screenState?.config.searchGroup {
            menuCoordinator.showEmptySearchRecovery(group: group, host: self) { [weak self] in
                guard let self, !self.isSearching, self.resultCount == 0,
                    self.screenState?.config.searchGroup == group
                else { return }
                self.handleMenuAction(.group(""))
            }
        }
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent {
                return true
            }
            controller = current.parent
        }
        return false
    }

    private func acceptsSearchCallbacks(for generation: Int) -> Bool {
        searchGeneration == generation && isSearching && !isLeavingPresentation && !isClosing
    }

    private func startSearch(refreshCandidates: [BookSourceChangeCandidate]? = nil, onlyMissingWordCount: Bool = false) {
        stopSearch()
        guard !isLeavingPresentation else { return }
        resultList.beginNewGeneration()
        let generation = searchGeneration
        offersAllGroupsOnFinish = refreshCandidates == nil
        if let refreshCandidates {
            let pendingURLs = Set(
                refreshCandidates.filter {
                    !onlyMissingWordCount || $0.chapterWordCountText == nil
                }.map(\.bookUrl))
            candidates.removeAll { pendingURLs.contains($0.bookUrl) }
            liveQueryMatches.subtract(pendingURLs)
        } else {
            candidates.removeAll()
            liveQueryMatches.removeAll()
        }
        if refreshCandidates == nil, let book = currentBook, book.origin == currentSourceUrl, !book.bookUrl.isEmpty {
            candidates.append(
                BookSourceChangeCandidate(
                    bookUrl: book.bookUrl, sourceUrl: book.origin, sourceName: book.originName,
                    displayName: book.name, author: book.author, latestChapterTitle: book.latestChapterTitle,
                    chapterWordCountText: nil, respondTime: -1, chapterWordCount: -1, bookType: book.type))
        }
        applyFilter(resetScroll: true)
        panel.setSummary(currentSourceName)
        updateSearchState(searching: true)

        factoryTask = Task { @MainActor [weak self, sessionFactory] in
            guard !Task.isCancelled, self?.acceptsSearchCallbacks(for: generation) == true else { return }
            do {
                let session = try await sessionFactory(
                    // onCandidate
                    { [weak self] candidate in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.acceptsSearchCallbacks(for: generation) else { return }
                            self.handleNewCandidate(candidate)
                        }
                    },
                    // onProgress
                    { [weak self] progress in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.acceptsSearchCallbacks(for: generation) else { return }
                            self.handleProgress(progress)
                        }
                    },
                    // onFinished
                    { [weak self] in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.acceptsSearchCallbacks(for: generation) else { return }
                            self.handleSearchFinished()
                        }
                    }
                )
                // The factory may return a session even after its task was cancelled.
                guard !Task.isCancelled, let self, self.acceptsSearchCallbacks(for: generation) else {
                    session.dispose()
                    return
                }
                self.factoryTask = nil
                self.searchSession = session
                if let refreshCandidates {
                    session.refresh(candidates: refreshCandidates, onlyMissingWordCount: onlyMissingWordCount)
                } else {
                    session.start()
                }
            } catch {
                guard let self, self.acceptsSearchCallbacks(for: generation) else { return }
                let wasCancelled = Task.isCancelled || error is CancellationError
                self.stopSearch()
                if !wasCancelled {
                    self.panel.setSummary(error.userFacingMessage)
                }
            }
        }
    }

    private func stopSearch() {
        searchGeneration &+= 1
        menuCoordinator.resetEmptySearchRecovery()
        updateSearchState(searching: false)
        factoryTask?.cancel()
        factoryTask = nil
        let session = searchSession
        searchSession = nil
        session?.dispose()
    }

    @objc private func toggleSearch() {
        guard canInteract, !isReplacingChapter, !isApplyingAction, !isSelectingBook else { return }
        if isSearching {
            stopSearch()
        } else {
            startSearch()
        }
    }

    private func updateSearchState(searching: Bool) {
        isSearching = searching
        panel.setSearching(searching)
    }

    // MARK: - Callbacks from search session

    private func handleNewCandidate(_ candidate: BookSourceChangeCandidate) {
        let query = activeQuery
        if !query.isEmpty, candidate.displayName.contains(query) { liveQueryMatches.insert(candidate.bookUrl) }
        if let index = candidates.firstIndex(where: {
            $0.sourceUrl == candidate.sourceUrl && $0.bookUrl == candidate.bookUrl
        }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
        applyFilter()
    }

    private func handleProgress(_ progress: SourceChangeSearchProgress) {
        guard isSearching else { return }
        panel.setProgress(progress, resultCount: resultCount)
    }

    private func handleSearchFinished() {
        stopSearch()
        panel.currentSourceButton.accessibilityValue = String(
            format: L10n.BookDetail.changeSourceSearchComplete, resultCount)
        if offersAllGroupsOnFinish, resultCount == 0, let group = screenState?.config.searchGroup {
            menuCoordinator.offerAllGroupsAfterEmptySearch(group: group)
            updatePresentationActivity()
        }
    }

    // MARK: - F69 Scroll to current source

    private func scrollToCurrentSource() {
        guard canInteract, chapterTocView.isHidden else { return }
        if !filteredCandidates.contains(where: { $0.sourceUrl == currentSourceUrl }) {
            panel.searchField.text = nil
            applyFilter()
        }
        view.endEditing(true)
        resultList.scrollToCurrent()
    }

    // MARK: - F52 Search filter

    @objc private func filterChanged() {
        guard panel.searchField.markedTextRange == nil else { return }
        applyFilter()
    }

    private var activeQuery: String {
        panel.searchField.markedTextRange == nil
            ? (panel.searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : lastAppliedQuery
    }

    func textFieldDidEndEditing(_: UITextField) { applyFilter() }

    private func toggleFilter() {
        guard canInteract, !isReplacingChapter, !isApplyingAction, !isSelectingBook else { return }
        if isSearchExpanded, !(panel.searchField.text ?? "").isEmpty {
            panel.searchField.text = nil
            applyFilter()
            panel.searchField.becomeFirstResponder()
            return
        }
        isSearchExpanded.toggle()
        panel.setFilterExpanded(isSearchExpanded)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func applyFilter(resetScroll: Bool = false) {
        let query = activeQuery
        if query != lastAppliedQuery {
            liveQueryMatches.removeAll()
            resultList.beginNewGeneration()
        }
        let visible = screenState.map { state in candidates.filter { state.includes($0) } } ?? candidates
        filteredCandidates = ChangeSourceCandidatePolicy.ordered(
            visible, query: query, checkAuthor: screenState?.config.changeSourceCheckAuthor ?? false,
            author: currentBook?.author ?? "", loadWordCount: screenState?.config.changeSourceLoadWordCount ?? false,
            ratings: ratingStore, sourceOrders: screenState?.sourceOrders ?? [:], liveMatches: liveQueryMatches)
        resultList.render(filteredCandidates, resetScroll: resetScroll || query != lastAppliedQuery)
        lastAppliedQuery = query
        panel.setFilterHasQuery(!query.isEmpty)
        panel.currentSourceButton.isEnabled = candidates.contains { $0.sourceUrl == currentSourceUrl }
    }

    private func scrollToEdge(last: Bool) {
        guard canInteract, chapterTocView.isHidden, !filteredCandidates.isEmpty else { return }
        view.endEditing(true)
        resultList.scrollToEdge(last: last)
    }

    private func collapseFilter() {
        guard canInteract, !isApplyingAction, !isReplacingChapter, !isSelectingBook else { return }
        panel.searchField.text = nil
        isSearchExpanded = false
        panel.setFilterExpanded(false)
        applyFilter()
    }

    private func updateActionAvailability() {
        let enabled = !isApplyingAction && !isReplacingChapter && !isSelectingBook && !isClosing
        // The toolbar lock includes Back; preparation keeps it available while action guards stay busy.
        panel.setActionsEnabled(!isApplyingAction && !isSelectingBook && !isClosing && !chapterReplacement.isCommitting)
        panel.moreButton.isEnabled = enabled && screenState != nil
        resultList.isScoreEnabled = enabled && screenState != nil
        updatePresentationActivity()
    }

    @objc private func candidateLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, canInteract, chapterTocView.isHidden, !menuCoordinator.isVisible,
            !isApplyingAction, !isReplacingChapter, !isSelectingBook,
            let indexPath = tableView.indexPathForRow(at: gesture.location(in: tableView)),
            let candidate = resultList.candidate(at: indexPath), let cell = tableView.cellForRow(at: indexPath)
        else { return }
        view.endEditing(true)
        menuCoordinator.show(candidate: candidate, anchor: cell, host: view)
    }

    private func handleMenuAction(_ action: ChangeSourceMenuCoordinator.Action) {
        guard canInteract, !isApplyingAction, !isReplacingChapter, !isSelectingBook else { return }
        switch action {
        case .manage:
            openSourcePage(AndroidReplicaSourceManagementViewController())
        case .edit(let candidate):
            let editorScreen = SourceManagementScreenAdapter()
            do {
                try editorScreen.bootstrap().get()
                openSourcePage(BookSourceEditViewController(mode: .edit(candidate.sourceUrl), screen: editorScreen))
            } catch {
                showTransientMessage(error.userFacingMessage)
            }
        case .refresh:
            startSearch(refreshCandidates: filteredCandidates)
        case .option(let option):
            guard let state = screenState else { return }
            let enabled = !option.value(in: state.config)
            performAction { [self] in
                try await screen.set(option, enabled: enabled)
                if option == .loadWordCount && enabled {
                    startSearch(refreshCandidates: filteredCandidates, onlyMissingWordCount: true)
                }
                applyFilter()
            }
        case .group(let group):
            stopSearch()
            hideChapterToc()
            performAction { [self] in
                try await screen.setGroup(group)
                startSearch()
            }
        case .top(let candidate):
            performAction { [screen] in try await screen.move(candidate, toTop: true) }
        case .bottom(let candidate):
            performAction { [screen] in try await screen.move(candidate, toTop: false) }
        case .disable(let candidate):
            stopSearch()
            hideChapterToc()
            performAction { [self] in
                try await screen.disable(candidate)
                candidates.removeAll { $0.sourceUrl == candidate.sourceUrl }
                applyFilter()
            }
        case .delete(let candidate):
            confirmDelete(candidate)
        case .close:
            closePicker()
        }
    }

    private func performAction(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isApplyingAction, !isClosing, !isReplacingChapter, !isSelectingBook else { return }
        isApplyingAction = true
        updateActionAvailability()
        applyFilter()
        // A settings/source write must finish even if the presenting page goes away.
        actionTask = Task { @MainActor [self] in
            defer {
                isApplyingAction = false
                actionTask = nil
                updateActionAvailability()
                if !isClosing && !isLeavingPresentation { applyFilter() }
            }
            do { try await operation() } catch {
                guard !isClosing, !isLeavingPresentation, !(error is CancellationError) else { return }
                showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func openSourcePage(_ controller: UIViewController) {
        hideChapterToc()
        stopSearch()
        reloadOnReturn = true
        let navigation = SwipeBackNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    private func confirmDelete(_ candidate: BookSourceChangeCandidate) {
        let alert = UIAlertController(title: "删除", message: "确定删除？\n\(candidate.sourceName)", preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "changeSource.deleteConfirmation"
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.stopSearch()
                self.hideChapterToc()
                self.performAction { [self] in
                    try await self.screen.delete(candidate)
                    self.ratingStore.removeSource(candidate.sourceUrl)
                    self.resultList.noteScoreChanged()
                    self.candidates.removeAll { $0.sourceUrl == candidate.sourceUrl }
                    self.applyFilter()
                    if candidate.sourceUrl == self.currentSourceUrl,
                        let onDeletedCurrentSource = self.onDeletedCurrentSource
                    {
                        self.closePicker(onClose: onDeletedCurrentSource)
                    }
                }
            })
        present(alert, animated: true)
    }

    private func closePicker(onClose: (() -> Void)? = nil) {
        guard !chapterReplacement.isCommitting, !isSelectingBook, !isClosing else { return }
        hideChapterToc()
        isClosing = true
        updateActionAvailability()
        resultList.suspend()
        stopSearch()
        dismiss(animated: true, completion: onClose)
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canInteract, chapterTocView.isHidden, !menuCoordinator.isVisible,
            !isApplyingAction, !isReplacingChapter, !isSelectingBook,
            let candidate = resultList.candidate(at: indexPath)
        else { return }
        if chapterSelection != nil {
            openChapterToc(candidate)
            return
        }
        guard candidate.bookUrl != currentBook?.bookUrl else { return }
        if let wholeBookCoordinator {
            view.endEditing(true)
            wholeBookCoordinator.select(candidate)
            return
        }
        view.endEditing(true)
        resultList.suspend()
        stopSearch()
        let delegate = delegate
        dismiss(animated: true) { delegate?.changeSourceDidSelect(candidate) }
    }

    @objc private func dismissSelf() {
        guard canInteract, !chapterReplacement.isCommitting, !isApplyingAction, !isSelectingBook else { return }
        if menuCoordinator.isVisible {
            menuCoordinator.dismiss()
        } else if !chapterTocView.isHidden {
            hideChapterToc()
        } else if isSearchExpanded {
            panel.searchField.text = nil
            isSearchExpanded = false
            panel.setFilterExpanded(false)
            applyFilter()
        } else {
            isClosing = true
            resultList.suspend()
            stopSearch()
            dismiss(animated: true)
        }
    }

    private func openChapterToc(_ candidate: BookSourceChangeCandidate) {
        guard canInteract, !isReplacingChapter, let chapterSelection else { return }
        hideChapterToc()
        let id = UUID()
        chapterRequestID = id
        selectedChapterCandidate = candidate
        view.endEditing(true)
        panel.setChapterTocVisible(true)
        chapterTocView.showLoading(canClose: true)
        updatePresentationActivity()
        chapterTask = Task { @MainActor [weak self] in
            do {
                let toc = try await chapterSelection.load(candidate)
                guard let self, self.acceptsChapterRequest(id), !Task.isCancelled else { return }
                self.chapterTask = nil
                guard !toc.chapters.isEmpty else {
                    self.hideChapterToc()
                    self.showTransientMessage(L10n.Reader.chapterChangeSourceEmptyToc)
                    return
                }
                self.loadedChapterToc = toc
                self.chapterTocView.show(chapters: toc.chapters, suggestedIndex: Int(toc.suggestedIndex))
            } catch {
                guard let self, self.acceptsChapterRequest(id), !Task.isCancelled else { return }
                self.hideChapterToc()
                if !(error is CancellationError) { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func hideChapterToc() {
        guard !chapterReplacement.isCommitting, !didReplaceChapter else { return }
        chapterRequestID = UUID()
        chapterTask?.cancel()
        chapterTask = nil
        chapterReplacement.cancel()
        isReplacingChapter = false
        loadedChapterToc = nil
        selectedChapterCandidate = nil
        chapterTocView.reset()
        panel.setChapterTocVisible(false)
        chapterSelection?.onCancel()
        updateActionAvailability()
    }

    private func acceptsChapterRequest(_ id: UUID) -> Bool {
        chapterRequestID == id && !isClosing && !isLeavingPresentation
            && viewIfLoaded?.window != nil
    }

    private func selectChapter(_ chapter: BookChapter) {
        guard canInteract, !isReplacingChapter, let chapterSelection,
            let window = view.window, let candidate = selectedChapterCandidate, let toc = loadedChapterToc,
            toc.chapters.contains(where: { $0.index == chapter.index && $0.url == chapter.url })
        else { return }
        let id = chapterRequestID
        guard acceptsChapterRequest(id) else { return }
        guard
            chapterReplacement.start(
                canCommit: { [weak self, weak window] in
                    guard let self, let window else { return false }
                    return self.canInteract && self.acceptsChapterRequest(id)
                        && self.viewIfLoaded?.window === window && !self.chapterTocView.isHidden
                },
                onCommit: { [weak self] in
                    self?.chapterTocView.showReplacementLoading(canClose: false)
                    self?.updateActionAvailability()
                },
                onFinish: { [self] outcome in
                    finishChapterReplacement(outcome, requestID: id, selection: chapterSelection)
                },
                replace: { gate in try await chapterSelection.replace(candidate, chapter, gate) }
            )
        else { return }
        isReplacingChapter = true
        chapterTocView.showReplacementLoading(canClose: true)
        updateActionAvailability()
    }

    private func finishChapterReplacement(
        _ outcome: ChapterSourceReplacementCoordinator.Outcome, requestID id: UUID, selection: ChapterSelection
    ) {
        switch outcome {
        case .committed:
            isReplacingChapter = false
            didReplaceChapter = true
            isClosing = true
            updateActionAvailability()
            stopSearch()
            resultList.suspend()
            if isPresentationVisible, !isLeavingPresentation, viewIfLoaded?.window != nil {
                dismiss(animated: true, completion: selection.onReplaced)
            } else {
                selection.onReplaced()
            }
        case .cancelled, .failed:
            guard chapterRequestID == id else { return }
            let canReportError = acceptsChapterRequest(id)
            hideChapterToc()
            if canReportError, case .failed(let error) = outcome { showTransientMessage(error.userFacingMessage) }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resultList.noteUserInteraction()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resultList.interactionDidEnd() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { resultList.interactionDidEnd() }
}
