import Foundation
import shared

internal final class AndroidReplicaSearchAdapter {
    private let bindings = ScreenBindingController(owner: "AndroidReplicaSearch")
    private var searchFacade: SearchFacade?
    private var bookshelfFacade: BookshelfFacade?
    private var settingsFacade: SettingsFacade?
    // Keep cancelled work through unbind so the next start waits for Kotlin startup.
    private var operationTask: Task<Void, Never>?
    private var historyOperationTasks: [UUID: Task<Void, Never>] = [:]
    private var bindingGeneration = UUID()
    private var operationGeneration = UUID()
    private var sessionObservationGeneration = UUID()
    private var inputGeneration = UUID()
    private var observedInputKeyword: String?
    private var isPresentationActive = false
    private var ownsSearchSession = false
    private var startingFacade: SearchFacade?
    private var expectedKeyword: String?
    private var expectedScope: SearchScope?
    private var acceptsRunningSession = true
    private var lastSourcesSignature: String?
    private var lastGroupsSignature: String?
    private var lastSessionSignature: SessionSignature?
    private(set) var precisionSearch = false
    var onSourcesChange: (([BookSource]) -> Void)?
    var onGroupsChange: (([String]) -> Void)?
    var onSessionChange: ((SearchSessionState) -> Void)?
    var onHistoryChange: (([SearchKeyword]) -> Void)?
    var onBookshelfSuggestionsChange: (([Book]) -> Void)?
    var onBookshelfKeysChange: ((Set<String>) -> Void)?
    var onPrecisionSearchChange: ((Bool) -> Void)?
    var onSearchError: ((Error) -> Void)?
    var onInputHelpError: ((Error) -> Void)?

    func bootstrap(scope: SearchScopeSelection) -> Result<Void, SharedRuntimeError> {
        unbind()
        let generation = bindingGeneration
        expectedKeyword = nil
        expectedScope = scope == .allEnabled ? nil : scope.toSharedScope()
        acceptsRunningSession = true
        lastSourcesSignature = nil
        lastGroupsSignature = nil
        lastSessionSignature = nil
        switch SharedRuntime.searchFacade() {
        case .success(let facade):
            searchFacade = facade
            if case .success(let settingsFacade) = SharedRuntime.settingsFacade() {
                self.settingsFacade = settingsFacade
                bindings.bind(
                    settingsFacade.watchRuntimeConfig { [weak self] config in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.bindingGeneration == generation else { return }
                            guard self.precisionSearch != config.precisionSearch else { return }
                            self.precisionSearch = config.precisionSearch
                            self.onPrecisionSearchChange?(config.precisionSearch)
                        }
                    })
            }
            if case .success(let bookshelfFacade) = SharedRuntime.bookshelfFacade() {
                self.bookshelfFacade = bookshelfFacade
                bindings.bind(
                    bookshelfFacade.watchBookshelfKeys { [weak self] keys in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.bindingGeneration == generation else { return }
                            self.onBookshelfKeysChange?(keys)
                        }
                    })
            }
            bindings.bind(
                facade.watchEnabledSources { [weak self] sources in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handleSources(sources)
                    }
                })
            bindings.bind(
                facade.watchEnabledGroups { [weak self] groups in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handleGroups(groups)
                    }
                })
            bindSession(facade)
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func watchInputHelp(keyword: String) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard observedInputKeyword != keyword else { return }
        observedInputKeyword = keyword
        inputGeneration = UUID()
        let generation = bindingGeneration
        let inputGeneration = self.inputGeneration
        bindings.unbind(key: "history")
        bindings.unbind(key: "bookshelfSuggestions")
        onBookshelfSuggestionsChange?([])
        onHistoryChange?([])
        guard let searchFacade else { return }
        bindings.replaceBinding(
            key: "history",
            with: searchFacade.watchSearchHistory(keyword: keyword) { [weak self] history in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                        self.bindingGeneration == generation,
                        self.inputGeneration == inputGeneration
                    else { return }
                    self.onHistoryChange?(history)
                }
            })
        guard keyword.isEmpty == false, let bookshelfFacade else { return }
        bindings.replaceBinding(
            key: "bookshelfSuggestions",
            with: bookshelfFacade.watchBooks(groupId: BookGroup.companion.ID_ALL) { [weak self] books in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                        self.bindingGeneration == generation,
                        self.inputGeneration == inputGeneration
                    else { return }
                    let suggestions = books.filter {
                        $0.name.range(of: keyword, options: .caseInsensitive) != nil
                            || $0.author.range(of: keyword, options: .caseInsensitive) != nil
                    }
                    self.onBookshelfSuggestionsChange?(suggestions)
                }
            })
    }

    func clearSearchHistory() {
        performHistoryOperation { facade in
            try await facade.clearSearchHistoryAsync()
        }
    }

    func deleteSearchHistory(word: String) {
        performHistoryOperation { facade in
            try await facade.deleteSearchHistoryAsync(word: word)
        }
    }

    @MainActor
    func shouldSubmitHistory(word: String, currentQuery: String) async throws -> Bool {
        try Task.checkCancellation()
        if currentQuery == word { return true }
        guard let facade = bookshelfFacade else { throw runtimeNotReadyError() }
        let generation = bindingGeneration
        let books: [Book]
        do {
            books = try await facade.loadBooksAsync(groupId: BookGroup.companion.ID_ALL)
        } catch {
            try Task.checkCancellation()
            guard bindingGeneration == generation, bookshelfFacade === facade else { throw CancellationError() }
            throw error
        }
        try Task.checkCancellation()
        guard bindingGeneration == generation, bookshelfFacade === facade else { throw CancellationError() }
        return !books.contains { $0.name == word }
    }

    func startSearch(scope: SearchScopeSelection, keyword: String) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let sharedScope = scope.toSharedScope()
        expectedKeyword = keyword
        expectedScope = sharedScope
        performOperation { facade in
            try await facade.startSearchAsync(searchScope: sharedScope, keyword: keyword)
        }
    }

    // The owner supplies the combined scene, visibility, menu and modal intent on main.
    func setPresentationActive(_ active: Bool) {
        isPresentationActive = active
        guard let searchFacade else { return }
        applyPresentationIntent(to: searchFacade)
    }

    func cancelSearch(keepSession: Bool = true) {
        let shouldCancelSession = ownsSearchSession || (searchFacade != nil && startingFacade === searchFacade)
        operationGeneration = UUID()
        operationTask?.cancel()
        sessionObservationGeneration = UUID()
        bindings.unbind(key: "session")
        acceptsRunningSession = false
        ownsSearchSession = false
        guard let searchFacade else { return }
        // Bootstrap observation alone does not grant operation ownership.
        if shouldCancelSession { searchFacade.cancelSearch() }
        if keepSession {
            bindSession(searchFacade)
        }
    }

    func loadNextPage() {
        // A bootstrap replay alone must not let this page continue another owner's search.
        guard expectedKeyword != nil else { return }
        performOperation { facade in
            try await facade.loadNextPageAsync()
        }
    }

    func retryFailedSources() {
        guard expectedKeyword != nil else { return }
        performOperation { facade in
            try await SharedAsync.void { completion in
                facade.retryFailedSources(completionHandler: completion)
            }
        }
    }

    func togglePrecisionSearch() async throws {
        guard let settingsFacade else { throw runtimeNotReadyError() }
        try await settingsFacade.setPrecisionSearchAsync(enabled: !precisionSearch)
    }

    func unbind() {
        cancelSearch(keepSession: false)
        bindingGeneration = UUID()
        inputGeneration = UUID()
        observedInputKeyword = nil
        bindings.cancelAll()
        for task in historyOperationTasks.values { task.cancel() }
        historyOperationTasks.removeAll()
        searchFacade = nil
        bookshelfFacade = nil
        settingsFacade = nil
    }

    private func performHistoryOperation(_ operation: @escaping (SearchFacade) async throws -> Void) {
        guard let facade = searchFacade else {
            onInputHelpError?(runtimeNotReadyError())
            return
        }
        let generation = bindingGeneration
        let inputGeneration = self.inputGeneration
        let operationID = UUID()
        historyOperationTasks[operationID] = Task { @MainActor [weak self] in
            guard Task.isCancelled == false, self?.bindingGeneration == generation else { return }
            var failure: Error?
            do {
                try await operation(facade)
            } catch {
                failure = error
            }
            guard let self, self.bindingGeneration == generation else { return }
            self.historyOperationTasks[operationID] = nil
            // The active history flow owns list updates, not mutation completions.
            guard Task.isCancelled == false,
                self.inputGeneration == inputGeneration,
                let failure
            else { return }
            self.onInputHelpError?(failure)
        }
    }

    private func performOperation(_ operation: @escaping (SearchFacade) async throws -> Void) {
        operationGeneration = UUID()
        let generation = operationGeneration
        let bindingGeneration = self.bindingGeneration
        sessionObservationGeneration = UUID()
        bindings.unbind(key: "session")
        let previousTask = operationTask
        previousTask?.cancel()
        guard let facade = searchFacade else {
            onSearchError?(runtimeNotReadyError())
            return
        }
        operationTask = Task { @MainActor [weak self] in
            // SharedAsync cancellation does not stop Kotlin's in-flight startup.
            await previousTask?.value
            guard Task.isCancelled == false,
                self?.bindingGeneration == bindingGeneration,
                self?.operationGeneration == generation,
                self?.searchFacade === facade
            else { return }
            self?.startingFacade = facade
            var failure: Error?
            do {
                try await operation(facade)
            } catch {
                failure = error
            }
            self?.startingFacade = nil
            guard Task.isCancelled == false, let self,
                self.bindingGeneration == bindingGeneration,
                self.operationGeneration == generation,
                self.searchFacade === facade
            else {
                facade.cancelSearch()
                return
            }
            self.operationTask = nil
            if let failure {
                self.applyPresentationIntent(to: facade)
                self.onSearchError?(failure)
            } else {
                // Only an explicit operation may own this facade's session, never a replay.
                self.ownsSearchSession = true
                self.acceptsRunningSession = true
                // Kotlin startup can finish after the page has already disappeared.
                // Read the current intent after await rather than capturing it at launch.
                self.applyPresentationIntent(to: facade)
                self.bindSession(facade)
            }
        }
    }

    private func bindSession(_ facade: SearchFacade) {
        let bindingGeneration = self.bindingGeneration
        let generation = operationGeneration
        sessionObservationGeneration = UUID()
        let observationGeneration = sessionObservationGeneration
        lastSessionSignature = nil
        bindings.replaceBinding(
            key: "session",
            with: facade.watchSearchSession { [weak self] session in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                        self.bindingGeneration == bindingGeneration,
                        self.operationGeneration == generation,
                        self.sessionObservationGeneration == observationGeneration,
                        self.searchFacade === facade
                    else { return }
                    self.handleSession(session)
                }
            })
    }

    private func handleSession(_ session: SearchSessionState) {
        guard acceptsRunningSession || session.isRunning == false else { return }
        if let expectedScope {
            guard (session.scope as? NSObject)?.isEqual(expectedScope) == true else {
                relinquishSearchSession()
                return
            }
        }
        if let expectedKeyword {
            guard session.keyword == expectedKeyword else {
                relinquishSearchSession()
                return
            }
        }
        if session.isRunning, let searchFacade {
            // Also cover a delayed running emission while presentation is inactive.
            applyPresentationIntent(to: searchFacade)
        }
        let signature = SessionSignature(session)
        guard signature != lastSessionSignature else { return }
        lastSessionSignature = signature
        onSessionChange?(session)
    }

    private func applyPresentationIntent(to facade: SearchFacade) {
        guard searchFacade === facade, ownsSearchSession, acceptsRunningSession else { return }
        if isPresentationActive {
            facade.resumeSearch()
        } else {
            facade.pauseSearch()
        }
    }

    private func relinquishSearchSession() {
        ownsSearchSession = false
    }

    private func handleSources(_ sources: [BookSource]) {
        let sortedSources = sources.sorted { lhs, rhs in
            lhs.bookSourceName.localizedCompare(rhs.bookSourceName) == .orderedAscending
        }
        let signature = sortedSources.map {
            "\($0.bookSourceUrl)#\($0.bookSourceName)#\($0.bookSourceGroup ?? "")"
        }.joined(separator: "|")
        guard signature != lastSourcesSignature else { return }
        lastSourcesSignature = signature
        onSourcesChange?(sortedSources)
    }

    private func handleGroups(_ groups: [String]) {
        let sortedGroups = groups.sorted()
        let signature = sortedGroups.joined(separator: "|")
        guard signature != lastGroupsSignature else { return }
        lastGroupsSignature = signature
        onGroupsChange?(sortedGroups)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Search.unavailable])
    }

    private struct SessionSignature: Equatable {
        let keyword: String
        let scope: NSObject?
        let page: Int32
        let isRunning: Bool
        let isPaused: Bool
        let hasMore: Bool
        let sourceTotalCount: Int32
        let completedSourceCount: Int32
        let failedSourceCount: Int32
        let error: String?
        let results: [BookSignature]

        init(_ session: SearchSessionState) {
            keyword = session.keyword
            scope = session.scope as? NSObject
            page = session.page
            isRunning = session.isRunning
            isPaused = session.isPaused
            hasMore = session.hasMore
            sourceTotalCount = session.sourceTotalCount
            completedSourceCount = session.completedSourceCount
            failedSourceCount = session.failedSourceCount
            error = session.error
            results = session.results.map { BookSignature($0) }
        }
    }

    // SearchBook equality only compares bookUrl; snapshot metadata and origins too.
    private struct BookSignature: Equatable {
        let bookUrl: String
        let origin: String
        let originName: String
        let type: Int32
        let name: String
        let author: String
        let kind: String?
        let coverUrl: String?
        let intro: String?
        let wordCount: String?
        let latestChapterTitle: String?
        let tocUrl: String
        let time: Int64
        let variable: String?
        let originOrder: Int32
        let chapterWordCountText: String?
        let chapterWordCount: Int32
        let respondTime: Int32
        let originExtras: [String]
        let infoHtml: String?
        let tocHtml: String?

        init(_ book: SearchBook) {
            bookUrl = book.bookUrl
            origin = book.origin
            originName = book.originName
            type = book.type
            name = book.name
            author = book.author
            kind = book.kind
            coverUrl = book.coverUrl
            intro = book.intro
            wordCount = book.wordCount
            latestChapterTitle = book.latestChapterTitle
            tocUrl = book.tocUrl
            time = book.time
            variable = book.variable
            originOrder = book.originOrder
            chapterWordCountText = book.chapterWordCountText
            chapterWordCount = book.chapterWordCount
            respondTime = book.respondTime
            originExtras = book.originExtras
            infoHtml = book.infoHtml
            tocHtml = book.tocHtml
        }
    }
}
