import UIKit
import shared

final class AndroidReplicaSearchViewController: UIViewController, NavigationCustomToolbarProviding, UITableViewDelegate,
    UITextFieldDelegate
{
    private let adapter = AndroidReplicaSearchAdapter()
    private let content = AndroidSearchContentView()
    private var topBar: AndroidSearchToolbarView { content.toolbar }
    private var searchField: UITextField { topBar.searchField }
    private let scopePreferences = SearchScopePreferencesClient()
    private let menuCoordinator = SearchScreenMenuCoordinator()
    private let emptyResultPrompt = SearchEmptyResultPrompt()
    private lazy var lifecycle = AndroidSearchLifecycle(owner: self)
    private let requestedInitialScope: SearchScopeSelection?
    private var isScopeReady = false
    private var scopeLoadError: String?
    private var needsScopeSearchOnReturn = false
    private var isUpdatingPrecision = false
    private var progressView: AndroidSearchLoadingView { content.progressView }
    private var tableView: UITableView { content.tableView }
    private var stopButton: AndroidSearchActionButton { content.stopButton }
    private let recoveryFooter = SearchRecoveryFooterView()
    private var emptyRecoveryView: SearchRecoveryFooterView { content.emptyRecoveryView }
    private lazy var recoveryPresentation = SearchRecoveryPresentation(
        table: tableView, footer: recoveryFooter, emptyView: emptyRecoveryView,
        emptyViewport: content.emptyRecoveryViewport)
    private var inputHelpView: SearchInputHelpView { content.inputHelpView }
    private lazy var resultList: AndroidSearchResultList = {
        let list = AndroidSearchResultList(tableView: tableView)
        list.onBookSelected = { [weak self] book in self?.openDetail(book) }
        list.canActivate = { [weak self] in self?.canInteractWithSearch == true }
        list.onContentSettled = { [weak self] in self?.schedulePaginationCheck() }
        list.setPresentationActive(false)
        return list
    }()
    private var isShowingInputHelp = true
    private var groups: [String] = []
    private var selectedScope: SearchScopeSelection
    private let initialKeyword: String?
    private var submittedKeyword: String?
    private var results: [SearchBook] = []
    private var bookshelfKeys: Set<String> = []
    private var session: SearchSessionState?
    private var isLoadingNextPage = false
    private var isStartingOperation = false
    private var didPrepareInitialInput = false
    private var isSearchStopped = false
    private var startupError: String?
    private var retryMessage: String?
    private var isRetainingRetryResults = false
    private var historySelectionTask: Task<Void, Never>?
    private var historySelectionID = UUID()
    private var searchGeneration = UUID()
    private var inputFocusOnReturn: Bool?
    private var paginationCheckScheduled = false
    private var automaticContentHeight: CGFloat = 0
    private var automaticallyRequestedPage: Int32?

    init(initialKeyword: String? = nil, initialScope: SearchScopeSelection? = nil) {
        self.initialKeyword = initialKeyword?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        requestedInitialScope = initialScope
        selectedScope = initialScope ?? .allEnabled
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(initialKeyword: String? = nil, preferredSourceURL: String) {
        let sourceURL = preferredSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!sourceURL.isEmpty, "preferredSourceURL must not be empty")
        self.init(initialKeyword: initialKeyword, initialScope: .source(url: sourceURL, name: sourceURL))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        bootstrap()
    }

    override func loadView() { view = content }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        recoveryPresentation.updateLayout()
        schedulePaginationCheck()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        BookshelfRootView.statusBarStyle(for: traitCollection)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lifecycle.didAppear()
        prepareInitialInputIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lifecycle.willDisappear()
    }

    private var canInteractWithSearch: Bool { lifecycle.canInteract }

    private func updatePresentation() {
        let active = canInteractWithSearch
        adapter.setPresentationActive(active)
        resultList.setPresentationActive(active)
        content.setPresentationActive(active)
        inputHelpView.setPresentationActive(active && isShowingInputHelp)
        if !active {
            historySelectionTask?.cancel()
            historySelectionTask = nil
        }
        if active {
            // Let menu-dismiss actions finish their scope change or navigation first.
            lifecycle.performWhenActive { [weak self] in
                guard let self, self.canInteractWithSearch else { return }
                self.resumeScopeSearchIfNeeded()
                self.prepareInitialInputIfNeeded()
                self.restoreInputHelpIfNeeded()
                self.presentEmptyResultSuggestionIfNeeded()
                self.schedulePaginationCheck()
            }
        }
    }

    override func present(_ controller: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        guard canInteractWithSearch, controller.presentingViewController == nil else { return }
        let presentationID = lifecycle.willPresent(controller)
        super.present(controller, animated: flag) { [weak self] in
            self?.lifecycle.didPresent(presentationID)
            completion?()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func themePaletteChanged() {
        menuCoordinator.refreshAppearance(interfaceStyle: traitCollection.userInterfaceStyle)
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            lifecycle.invalidate()
            cancelHistorySelection()
            scopePreferences.cancelObservation()
            menuCoordinator.dismiss()
            resultList.suspend()
            adapter.unbind()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        menuCoordinator.dismiss()
        // Pushing details and presenting sheets keep the search in its stack.
        var container: UIViewController? = self
        while let current = container {
            if current.isBeingDismissed {
                lifecycle.invalidate()
                cancelHistorySelection()
                scopePreferences.cancelObservation()
                resultList.suspend()
                adapter.unbind()
                break
            }
            container = current.parent
        }
    }

    deinit {
        historySelectionTask?.cancel()
        adapter.unbind()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureViews() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteChanged), name: .androidReplicaThemeDidChange, object: nil)
        lifecycle.onChange = { [weak self] in self?.updatePresentation() }
        lifecycle.onLeave = { [weak self] in
            self?.cancelHistorySelection()
            self?.emptyResultPrompt.invalidate()
        }
        menuCoordinator.onPresentationChange = { [weak self] presented in self?.lifecycle.setMenuPresented(presented) }
        inputHelpView.canActivate = { [weak self] in
            self?.canInteractWithSearch == true && self?.isShowingInputHelp == true
        }
        updatePresentation()
        topBar.onBack = { [weak self] in self?.handleBack() }
        topBar.onSubmit = { [weak self] in self?.submitSearch() }
        topBar.onMore = { [weak self] in self?.presentMoreMenu() }
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        progressView.progress = 0
        tableView.delegate = self
        _ = resultList
        stopButton.addTarget(self, action: #selector(stopSearch), for: .touchUpInside)
        recoveryFooter.onRetry = { [weak self] in self?.retrySearch() }
        emptyRecoveryView.onRetry = { [weak self] in
            guard let self, self.canInteractWithSearch else { return }
            if self.isScopeReady { self.retrySearch() } else { self.bootstrap() }
        }
        inputHelpView.onBookSelected = { [weak self] book in
            guard let self, self.canInteractWithSearch, self.isShowingInputHelp,
                let navigation = self.navigationController
            else { return }
            self.inputFocusOnReturn = self.searchField.isFirstResponder
            self.searchField.resignFirstResponder()
            navigation.pushViewController(
                AndroidReplicaBookDetailViewController(bookURL: book.bookUrl), animated: true)
        }
        inputHelpView.onHistorySelected = { [weak self] word in self?.selectHistory(word) }
        inputHelpView.onHistoryDeleted = { [weak self] word in
            guard let self, self.canInteractWithSearch, self.isShowingInputHelp else { return }
            self.adapter.deleteSearchHistory(word: word)
        }
        inputHelpView.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        updateScopeSummary()
    }

    private func bootstrap() {
        scopePreferences.cancelObservation()
        isScopeReady = false
        scopeLoadError = nil
        topBar.setInteractionEnabled(false)
        showInputHelp(true)
        scopePreferences.onSaveError = { [weak self] error in
            guard let self, self.navigationController?.topViewController === self else { return }
            self.presentError(error)
        }
        adapter.onHistoryChange = { [weak self] history in self?.inputHelpView.update(history: history) }
        adapter.onBookshelfSuggestionsChange = { [weak self] books in
            self?.inputHelpView.update(books: books)
        }
        adapter.onBookshelfKeysChange = { [weak self] keys in
            guard let self, self.bookshelfKeys != keys else { return }
            self.bookshelfKeys = keys
            self.resultList.setBookshelfKeys(keys)
        }
        adapter.onInputHelpError = { [weak self] error in
            guard let self, self.canInteractWithSearch, self.isShowingInputHelp else { return }
            self.presentError(error)
        }
        adapter.onSessionChange = { [weak self] session in
            self?.applySession(session)
        }
        adapter.onSearchError = { [weak self] error in
            guard let self, self.submittedKeyword != nil else { return }
            self.isLoadingNextPage = false
            self.isStartingOperation = false
            self.retryMessage = nil
            self.startupError = error.userFacingMessage
            self.renderResults()
        }
        restoreScope(initialScope: requestedInitialScope)
    }

    private func restoreScope(initialScope: SearchScopeSelection?) {
        scopePreferences.restore(
            initialScope: initialScope,
            onLoaded: { [weak self] scope in
                guard let self else { return }
                self.selectedScope = scope
                self.groups = self.scopePreferences.enabledGroups
                self.updateScopeSummary()
                try self.adapter.bootstrap(scope: scope).get()
                self.isScopeReady = true
                self.topBar.setInteractionEnabled(true)
                self.searchField.text = self.initialKeyword ?? self.searchField.text
                self.topBar.updateQueryControls()
                self.adapter.watchInputHelp(keyword: self.searchField.text ?? "")
                self.prepareInitialInputIfNeeded()
            },
            onSourcesChanged: { [weak self] in self?.reconcileScope() },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.scopeLoadError = error.userFacingMessage
                self.showInputHelp(false)
                self.renderResults()
            })
    }

    private func reconcileScope() {
        guard isScopeReady else { return }
        let currentGroups = scopePreferences.enabledGroups
        if groups != currentGroups { menuCoordinator.dismiss() }
        groups = currentGroups
        applyScope(scopePreferences.normalized(selectedScope), automatically: true)
    }

    private func resumeScopeSearchIfNeeded() {
        guard needsScopeSearchOnReturn, isScopeReady, canInteractWithSearch else { return }
        needsScopeSearchOnReturn = false
        if let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            performSearch(keyword: keyword)
        } else {
            showInputHelp(true)
        }
    }

    private func updateScopeSummary() {
        topBar.moreButton.accessibilityValue = selectedScope.summaryText
    }

    private func applyScope(_ scope: SearchScopeSelection, automatically: Bool = false) {
        let scope = scopePreferences.normalized(scope)
        guard isScopeReady, selectedScope != scope else { return }
        let sameSearchScope = (selectedScope.toSharedScope() as? NSObject)?.isEqual(scope.toSharedScope()) == true
        selectedScope = scope
        scopePreferences.persist(scope, automatically: automatically)
        updateScopeSummary()
        menuCoordinator.dismiss()
        emptyResultPrompt.invalidate()
        if automatically && sameSearchScope { return }
        cancelHistorySelection()
        let keywordToSearch =
            isShowingInputHelp ? nil : searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        adapter.cancelSearch(keepSession: false)
        submittedKeyword = nil
        session = nil
        results = []
        startupError = nil
        retryMessage = nil
        isRetainingRetryResults = false
        isLoadingNextPage = false
        isStartingOperation = false
        isSearchStopped = false
        needsScopeSearchOnReturn = false
        progressView.progress = 0
        if let keywordToSearch {
            if automatically && !canInteractWithSearch {
                needsScopeSearchOnReturn = true
                renderResults()
            } else {
                performSearch(keyword: keywordToSearch)
            }
        } else {
            showInputHelp(true)
            renderResults()
        }
    }

    private func applySession(_ session: SearchSessionState) {
        guard let submittedKeyword, session.keyword == submittedKeyword,
            (session.scope as? NSObject)?.isEqual(selectedScope.toSharedScope()) == true
        else { return }
        self.session = session
        isLoadingNextPage = false
        isStartingOperation = false
        startupError = nil
        if !session.isRunning { retryMessage = nil }
        // Keep the old list usable while a startup retry rebuilds its first page.
        if !isRetainingRetryResults
            || (!session.isRunning && !isSearchStopped && (!session.results.isEmpty || session.error == nil))
        {
            results = session.results
            isRetainingRetryResults = false
        }
        if session.sourceTotalCount > 0 {
            progressView.progress = min(
                max(Float(session.completedSourceCount) / Float(session.sourceTotalCount), 0), 1)
        } else {
            progressView.progress = 0
        }
        renderResults()
    }

    private var emptyResultContext: SearchEmptyResultPrompt.Context? {
        guard isScopeReady, !isShowingInputHelp, !isSearchStopped, !isSearchRunning, !isUpdatingPrecision,
            recoveryMessage == nil, results.isEmpty, let session, !session.isRunning, session.results.isEmpty,
            let submittedKeyword, !submittedKeyword.isEmpty,
            !searchField.isFirstResponder, searchField.markedTextRange == nil,
            searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) == submittedKeyword
        else { return nil }
        return .init(
            generation: searchGeneration, keyword: submittedKeyword, scope: selectedScope,
            page: session.page, precisionSearch: adapter.precisionSearch)
    }

    private func presentEmptyResultSuggestionIfNeeded() {
        emptyResultPrompt.presentIfNeeded(
            from: self, context: emptyResultContext,
            isCurrent: { [weak self] context, modal in
                guard let self, self.emptyResultContext == context, !self.menuCoordinator.isPresented else { return false }
                return self.lifecycle.ownsPresentation(allowing: modal)
            },
            onConfirm: { [weak self] action in
                switch action {
                case .disablePrecision: self?.togglePrecisionSearch()
                case .switchToAll: self?.applyScope(.allEnabled)
                }
            },
            onClose: { [weak self] in self?.updatePresentation() })
    }

    private var isSearchRunning: Bool {
        !isSearchStopped
            && (isStartingOperation || isLoadingNextPage || (startupError == nil && session?.isRunning == true))
    }

    private var recoveryMessage: String? {
        if let scopeLoadError { return scopeLoadError }
        guard !isSearchStopped else { return nil }
        return startupError ?? retryMessage ?? session?.error
    }

    private var canContinueSearch: Bool {
        isScopeReady && !isShowingInputHelp && !isSearchStopped && !isSearchRunning
            && recoveryMessage == nil && session?.hasMore == true && session?.isRunning == false
            && submittedKeyword?.isEmpty == false
    }

    private func updateSearchControls() {
        let running = isSearchRunning
        let canRetry = recoveryMessage != nil
        progressView.isHidden = isShowingInputHelp || !running
        stopButton.setAction(running ? .stop : (canRetry ? .retry : .nextPage))
        stopButton.isHidden =
            !isScopeReady || isShowingInputHelp
            || (!running && !canRetry && !canContinueSearch)
        recoveryPresentation.update(
            message: recoveryMessage, isRunning: running, showsInputHelp: isShowingInputHelp, hasResults: !results.isEmpty)
    }

    private func renderResults() {
        updateSearchControls()
        updatePresentation()
        resultList.render(books: results, generation: searchGeneration.uuidString)
    }

    private func showInputHelp(_ visible: Bool) {
        isShowingInputHelp = visible
        inputHelpView.isHidden = !visible
        tableView.isHidden = visible
        resultList.setContentVisible(!visible)
        tableView.isUserInteractionEnabled = !visible
        tableView.accessibilityElementsHidden = visible
        emptyRecoveryView.accessibilityElementsHidden = visible
        updateSearchControls()
        updatePresentation()
    }

    func textFieldDidBeginEditing(_: UITextField) {
        showInputHelp(!isSearchRunning)
        if isShowingInputHelp {
            adapter.watchInputHelp(keyword: searchField.text ?? "")
        }
    }

    func textFieldDidEndEditing(_: UITextField) {
        if inputFocusOnReturn != nil {
            showInputHelp(true)
            return
        }
        let hasQuery = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        showInputHelp(!isSearchRunning && (results.isEmpty || !hasQuery))
    }

    private func restoreInputHelpIfNeeded() {
        guard canInteractWithSearch, let restoreFocus = inputFocusOnReturn else { return }
        inputFocusOnReturn = nil
        showInputHelp(true)
        if restoreFocus { searchField.becomeFirstResponder() }
    }

    @objc private func searchTextChanged() {
        needsScopeSearchOnReturn = false
        cancelHistorySelection()
        emptyResultPrompt.invalidate()
        topBar.updateQueryControls()
        isSearchStopped = true
        adapter.cancelSearch()
        isLoadingNextPage = false
        isStartingOperation = false
        startupError = nil
        retryMessage = nil
        progressView.isHidden = true
        adapter.watchInputHelp(keyword: searchField.text ?? "")
        // SearchActivity.onQueryTextChange keeps the current layer; focus changes own input help.
        renderResults()
    }

    private func selectHistory(_ word: String) {
        guard isScopeReady, canInteractWithSearch, isShowingInputHelp, searchField.markedTextRange == nil else { return }
        cancelHistorySelection()
        let selectionID = historySelectionID
        let currentQuery = searchField.text ?? ""
        historySelectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let shouldSubmit = try await self.adapter.shouldSubmitHistory(word: word, currentQuery: currentQuery)
                try Task.checkCancellation()
                guard self.historySelectionID == selectionID,
                    (self.searchField.text ?? "") == currentQuery,
                    self.canInteractWithSearch, self.isShowingInputHelp, self.searchField.markedTextRange == nil
                else { return }
                self.historySelectionTask = nil
                self.searchField.text = word
                self.topBar.updateQueryControls()
                if shouldSubmit {
                    self.searchField.resignFirstResponder()
                    self.performSearch(keyword: word)
                } else {
                    self.searchTextChanged()
                    self.searchField.becomeFirstResponder()
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                    self.historySelectionID == selectionID,
                    self.navigationController?.topViewController === self
                else { return }
                self.historySelectionTask = nil
                self.presentError(error)
            }
        }
    }

    private func cancelHistorySelection() {
        historySelectionTask?.cancel()
        historySelectionTask = nil
        historySelectionID = UUID()
    }

    private func confirmClearHistory() {
        guard canInteractWithSearch, isShowingInputHelp else { return }
        cancelHistorySelection()
        let requestID = historySelectionID
        let alert = ReaderRestoreProgressDialogViewController(
            title: "提醒", message: L10n.Search.clearHistoryConfirm,
            accessibilityIdentifierPrefix: "search.clearHistory"
        ) { [weak self] accepted in
            guard accepted, let self, self.historySelectionID == requestID,
                self.canInteractWithSearch
            else { return }
            self.adapter.clearSearchHistory()
        }
        alert.canConfirm = { [weak self, weak alert] in
            guard let self, self.historySelectionID == requestID else { return false }
            return self.lifecycle.ownsPresentation(allowing: self.presentedViewController == nil ? nil : alert)
        }
        alert.onClose = { [weak self] in self?.updatePresentation() }
        present(alert, animated: true)
    }

    @objc private func handleBack() {
        cancelHistorySelection()
        if searchField.isFirstResponder {
            searchField.resignFirstResponder()
            return
        }
        navigationController?.popViewController(animated: true)
    }

    private func submitSearch() {
        _ = textFieldShouldReturn(searchField)
    }

    private func presentMoreMenu() {
        guard isScopeReady, canInteractWithSearch, !isUpdatingPrecision else { return }
        menuCoordinator.present(
            from: self, anchor: topBar.moreButton,
            scope: selectedScope, groups: groups, precisionSearch: adapter.precisionSearch,
            onTogglePrecision: { [weak self] in self?.togglePrecisionSearch() },
            onScopeDialog: { [weak self] in self?.presentScopeSelector() },
            onScopeSelected: { [weak self] scope in self?.applyScope(scope) }
        )
    }

    private func togglePrecisionSearch() {
        guard isScopeReady, canInteractWithSearch, !isUpdatingPrecision, searchField.markedTextRange == nil else { return }
        cancelHistorySelection()
        emptyResultPrompt.invalidate()
        isUpdatingPrecision = true
        topBar.moreButton.isEnabled = false
        let requestID = historySelectionID
        let generation = searchGeneration
        let scope = selectedScope
        let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isUpdatingPrecision = false
                self.topBar.moreButton.isEnabled = self.isScopeReady
            }
            guard self.canInteractWithSearch, self.historySelectionID == requestID else { return }
            do {
                try await self.adapter.togglePrecisionSearch()
                guard self.canInteractWithSearch, self.historySelectionID == requestID,
                    self.searchGeneration == generation, self.selectedScope == scope,
                    self.searchField.markedTextRange == nil,
                    self.searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty == keyword
                else { return }
                if let keyword { self.performSearch(keyword: keyword) }
            } catch {
                guard self.canInteractWithSearch, self.historySelectionID == requestID else { return }
                self.presentError(error)
            }
        }
    }

    @objc private func stopSearch() {
        guard canInteractWithSearch else { return }
        guard isSearchRunning else {
            if recoveryMessage != nil {
                retrySearch()
            } else if canContinueSearch {
                loadNextPage()
            }
            return
        }
        emptyResultPrompt.invalidate()
        cancelHistorySelection()
        isSearchStopped = true
        adapter.cancelSearch()
        isLoadingNextPage = false
        isStartingOperation = false
        retryMessage = nil
        progressView.isHidden = true
        stopButton.isHidden = true
        renderResults()
    }

    @objc private func presentScopeSelector() {
        guard isScopeReady, canInteractWithSearch else { return }
        let wasShowingInputHelp = isShowingInputHelp
        searchField.resignFirstResponder()
        showInputHelp(wasShowingInputHelp)
        SearchScopeDialogSourceLoader.load(from: self) { [weak self] sources in
            guard let self else { return }
            let controller = SearchScopeViewController(
                groups: self.groups, sources: sources, currentScope: self.selectedScope)
            controller.onScopeSelected = { [weak self] scope in
                self?.applyScope(scope)
            }
            self.present(controller, animated: true)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let keyword = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard isScopeReady, canInteractWithSearch, textField.markedTextRange == nil, !keyword.isEmpty else { return false }
        textField.resignFirstResponder()
        performSearch(keyword: keyword)
        return true
    }

    private func prepareInitialInputIfNeeded() {
        guard isScopeReady, !didPrepareInitialInput, canInteractWithSearch else { return }
        didPrepareInitialInput = true
        if let initialKeyword {
            searchField.resignFirstResponder()
            performSearch(keyword: initialKeyword)
        } else {
            searchField.becomeFirstResponder()
        }
    }

    private func performSearch(keyword: String, preservingResults: Bool = false) {
        guard isScopeReady else { return }
        needsScopeSearchOnReturn = false
        emptyResultPrompt.beginOperation()
        cancelHistorySelection()
        menuCoordinator.dismiss()
        if !preservingResults { searchGeneration = UUID() }
        automaticContentHeight = 0
        automaticallyRequestedPage = nil
        submittedKeyword = keyword
        retryMessage = preservingResults ? recoveryMessage : nil
        startupError = nil
        isRetainingRetryResults = preservingResults && !results.isEmpty
        isSearchStopped = false
        if !preservingResults { results = [] }
        session = nil
        isLoadingNextPage = false
        isStartingOperation = true
        showInputHelp(false)
        progressView.progress = 0
        progressView.isHidden = false
        stopButton.isHidden = false
        renderResults()
        adapter.startSearch(scope: selectedScope, keyword: keyword)
    }

    private func retrySearch() {
        guard canInteractWithSearch, !isShowingInputHelp, !isSearchRunning, let message = recoveryMessage else { return }
        if startupError == nil, let session, session.error != nil, session.failedSourceCount > 0 {
            emptyResultPrompt.beginOperation()
            cancelHistorySelection()
            retryMessage = message
            isLoadingNextPage = true
            isStartingOperation = true
            progressView.progress = 0
            updateSearchControls()
            adapter.loadNextPage()
        } else {
            let keyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !keyword.isEmpty else { return }
            performSearch(keyword: keyword, preservingResults: true)
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !isShowingInputHelp else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        resultList.select(at: indexPath)
    }

    private func loadNextPage() {
        guard canInteractWithSearch, canContinueSearch else { return }
        emptyResultPrompt.beginOperation()
        cancelHistorySelection()
        isSearchStopped = false
        isLoadingNextPage = true
        isStartingOperation = true
        progressView.progress = 0
        progressView.isHidden = false
        stopButton.isHidden = false
        renderResults()
        adapter.loadNextPage()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === tableView { schedulePaginationCheck() }
    }

    private func schedulePaginationCheck() {
        guard canInteractWithSearch, !paginationCheckScheduled else { return }
        paginationCheckScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.paginationCheckScheduled = false }
            guard self.canInteractWithSearch, self.canContinueSearch, self.resultList.isContentSettled,
                !self.results.isEmpty,
                self.tableView.bounds.height > self.tableView.adjustedContentInset.top + self.tableView.adjustedContentInset.bottom
            else { return }
            self.tableView.layoutIfNeeded()
            guard self.resultList.isContentSettled, let page = self.session?.page,
                page < Int32.max, self.automaticallyRequestedPage != page + 1
            else { return }
            let height = self.tableView.contentSize.height
            let bottom = self.tableView.contentOffset.y + self.tableView.bounds.height - self.tableView.adjustedContentInset.bottom
            let pixel = 1 / max(1, self.tableView.traitCollection.displayScale)
            guard height > self.automaticContentHeight, bottom >= height - pixel else { return }
            self.automaticContentHeight = height
            self.automaticallyRequestedPage = page + 1
            self.loadNextPage()
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        resultList.noteUserInteraction()
        automaticContentHeight = 0
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { resultList.finishScrolling() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { resultList.finishScrolling() }

    private func openDetail(_ book: SearchBook) {
        guard !isShowingInputHelp, canInteractWithSearch else { return }
        searchField.resignFirstResponder()
        navigationController?.pushViewController(
            AndroidReplicaBookDetailViewController(searchBook: book), animated: true)
    }
}
