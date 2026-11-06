import Foundation
import shared

@MainActor
final class AndroidReplicaBookDetailAdapter {
    private var observedBookURL: String
    private var facade: BookDetailFacade?
    private var readerFacade: ReaderFacade?
    private var previewCandidate: SearchBook?
    private var retainedPreview: Book?
    private var appearanceTask: Task<Void, Never>?
    private var identityGeneration = UUID()
    private lazy var sourceChangeClient = ReaderSourceChangeClient(
        binding: { [weak self] in
            guard let self else { return (bookURL: "", generation: UUID()) }
            return (bookURL: self.observedBookURL, generation: self.identityGeneration)
        },
        facade: { [weak self] in self?.facade },
        flushProgress: { [weak self] in await self?.onFlushReadingProgress?() }
    )

    var onFlushReadingProgress: (() async -> Void)?

    init(bookURL: String, previewCandidate: SearchBook? = nil) {
        observedBookURL = bookURL
        self.previewCandidate = previewCandidate
    }

    deinit { appearanceTask?.cancel() }

    func retainPreviewSnapshot(_ book: Book) {
        guard book.bookUrl == observedBookURL else { return }
        retainedPreview = book.isNotShelf && !book.isLocal ? book : nil
    }

    func refreshAppearance(onUpdate: @escaping (Book) -> Void) {
        cancelAppearanceRefresh()
        guard let facade else { return }
        let generation = identityGeneration
        let bookURL = observedBookURL
        appearanceTask = Task { @MainActor [weak self] in
            defer { if !Task.isCancelled { self?.appearanceTask = nil } }
            do {
                let book: Book? = try await SharedAsync.optionalValue { completion in
                    facade.resolvePersistedBook(bookUrl: bookURL, completionHandler: completion)
                }
                guard let self, !Task.isCancelled, self.identityGeneration == generation,
                    self.observedBookURL == bookURL, let book
                else { return }
                // Preview exit removes its row, not the detail page's retained snapshot.
                self.retainPreviewSnapshot(book)
                onUpdate(book)
            } catch {}
        }
    }

    func cancelAppearanceRefresh() {
        appearanceTask?.cancel()
        appearanceTask = nil
    }

    private func prepareRetainedPreview() async throws -> Book? {
        try Task.checkCancellation()
        guard let retainedPreview else { return nil }
        guard let facade else { throw runtimeNotReadyError() }
        let generation = identityGeneration
        let prepared = try await bookRequestValue { completion in
            facade.preparePreviewSnapshotRequest(book: retainedPreview, onResult: completion)
        }
        try checkIdentity(generation)
        retainPreviewSnapshot(prepared)
        return prepared
    }

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        switch SharedRuntime.bookDetailFacade() {
        case .success(let facade):
            self.facade = facade
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func resolveInitialBook(preparingForReading: Bool = false) async throws -> Book? {
        try Task.checkCancellation()
        guard let facade else { throw runtimeNotReadyError() }
        let generation = identityGeneration
        let bookURL = observedBookURL
        let resolved: Book?
        if let previewCandidate {
            let prepared = try await bookRequestValue { completion in
                facade.preparePreviewRequest(candidate: previewCandidate, onResult: completion)
            }
            try checkIdentity(generation)
            // Preview persistence is not rolled back when its caller leaves.
            self.previewCandidate = nil
            resolved = prepared
        } else if let retainedPreview, !preparingForReading {
            // Passive returns retain the detail snapshot without recreating a discarded preview row.
            let persisted: Book? = try await SharedAsync.optionalValue { completion in
                facade.resolvePersistedBook(bookUrl: bookURL, completionHandler: completion)
            }
            try checkIdentity(generation)
            resolved = persisted ?? retainedPreview
        } else if let prepared = try await prepareRetainedPreview() {
            resolved = prepared
        } else {
            if preparingForReading {
                resolved = try await bookRequestValue { completion in
                    facade.prepareReadingPreviewRequest(bookUrl: bookURL, onResult: completion)
                }
            } else {
                resolved = try await facade.resolveBookAsync(bookUrl: bookURL)
            }
            try checkIdentity(generation)
        }
        try checkIdentity(generation)
        guard observedBookURL == bookURL, resolved == nil || resolved?.bookUrl == bookURL else {
            throw CancellationError()
        }
        if let resolved { retainPreviewSnapshot(resolved) }
        return resolved
    }

    func adoptCommittedSourceChange(replacing originalBookURL: String, bookURL: String) -> Bool {
        guard observedBookURL == originalBookURL, !bookURL.isEmpty else { return false }
        identityGeneration = UUID()
        observedBookURL = bookURL
        previewCandidate = nil
        retainedPreview = nil
        cancelAppearanceRefresh()
        return true
    }

    private func checkIdentity(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard generation == identityGeneration else { throw CancellationError() }
    }

    func prepareSourceEditor() async throws -> (sourceURL: String, screen: SourceManagementScreenAdapter) {
        try Task.checkCancellation()
        let generation = identityGeneration
        let bookURL = observedBookURL
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        guard let facade else { throw runtimeNotReadyError() }
        let unavailableError = NSError(
            domain: "io.legado.kmp.ios", code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.BookDetail.editSourceUnavailable])

        do {
            let book = try await facade.resolveBookAsync(bookUrl: bookURL)
            try checkIdentity(generation)
            guard observedBookURL == bookURL else { throw CancellationError() }
            guard let book, !book.isLocal,
                !book.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw unavailableError }

            let sourceURL = book.origin
            let sourceFacade = try SharedRuntime.sourceManagementFacade().get()
            let source = try await sourceFacade.getSourceAsync(sourceUrl: sourceURL)
            try checkIdentity(generation)
            guard observedBookURL == bookURL else { throw CancellationError() }
            guard source != nil else { throw unavailableError }

            let screen = SourceManagementScreenAdapter()
            try screen.bootstrap().get()
            return (sourceURL: sourceURL, screen: screen)
        } catch {
            try checkIdentity(generation)
            guard observedBookURL == bookURL else { throw CancellationError() }
            throw error
        }
    }

    @MainActor
    func createSourceChangeSearchSession(
        onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
        onProgress: @escaping (SourceChangeSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> SourceChangeSearchSession {
        let generation = identityGeneration
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        return try await sourceChangeClient.createSourceChangeSearchSession(
            onCandidate: onCandidate,
            onProgress: onProgress,
            onFinished: onFinished
        )
    }

    @MainActor
    func prepareSourceChange(candidateBookUrl: String, sourceUrl: String) async throws -> PreparedBookSourceChange {
        try await sourceChangeClient.prepareSourceChange(candidateBookUrl: candidateBookUrl, sourceUrl: sourceUrl)
    }

    @MainActor
    func commitSourceChange(_ prepared: PreparedBookSourceChange) async throws -> BookDetailRefreshResult {
        // Identity adoption belongs to the caller; preserve every completed persistent write.
        try await sourceChangeClient.commitSourceChange(prepared)
    }

    func refreshInfo() async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        let generation = identityGeneration
        let bookURL = observedBookURL
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        return try await bookRequestValue { completion in
            facade.refreshInfoRequest(bookUrl: bookURL, onResult: completion)
        }
    }

    func loadInitialChapters(book: Book, forceRefresh: Bool) async throws -> BookDetailRefreshResult {
        try Task.checkCancellation()
        let generation = identityGeneration
        guard book.bookUrl == observedBookURL else { throw CancellationError() }
        if !forceRefresh {
            let items = try await loadChapterListState()
            try checkIdentity(generation)
            if !items.isEmpty {
                return BookDetailRefreshResult(book: book, chapters: items.map(\.chapter), epubReflowPlan: nil)
            }
        }
        try checkIdentity(generation)
        return try await refreshChapters()
    }

    func refreshChapters() async throws -> BookDetailRefreshResult {
        guard let facade else { throw runtimeNotReadyError() }
        let generation = identityGeneration
        let bookURL = observedBookURL
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        return try await requestValue { completion in
            facade.refreshChaptersRequest(bookUrl: bookURL) { result in
                completion(
                    result.result,
                    Self.requestError(
                        cancelled: result.isCancelled, code: result.errorCode, message: result.errorMessage))
            }
        }
    }

    private func bookRequestValue(
        _ start: @MainActor (@escaping (BookDetailBookRequestResult) -> Void) -> FlowSubscription
    ) async throws -> Book {
        try await requestValue { completion in
            start { result in
                completion(
                    result.book,
                    Self.requestError(
                        cancelled: result.isCancelled, code: result.errorCode, message: result.errorMessage))
            }
        }
    }

    private func requestValue<T>(_ start: @MainActor (@escaping @Sendable (T?, Error?) -> Void) -> FlowSubscription) async throws
        -> T
    {
        let generation = identityGeneration
        let value: T = try await SharedCancellableAsync.valueOnMainActor(
            awaitCancellationCompletion: true, start: start)
        try checkIdentity(generation)
        return value
    }

    nonisolated private static func requestError(cancelled: Bool, code: String?, message: String?) -> Error? {
        if cancelled { return CancellationError() }
        guard code != nil || message != nil else { return nil }
        var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message ?? code ?? L10n.Shared.emptyValue]
        userInfo["errorCode"] = code
        userInfo["errorMessage"] = message
        return NSError(domain: "io.legado.kmp.ios", code: code.flatMap { Int($0) } ?? -1, userInfo: userInfo)
    }

    func addToBookshelf() async throws -> Book {
        guard let facade else { throw runtimeNotReadyError() }
        let generation = identityGeneration
        let bookURL = observedBookURL
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        let added = try await facade.addToBookshelfAsync(bookUrl: bookURL)
        if identityGeneration == generation, observedBookURL == bookURL { retainPreviewSnapshot(added) }
        return added
    }

    func removeFromBookshelf() async throws {
        try Task.checkCancellation()
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.removeFromBookshelfAsync(bookUrl: observedBookURL)
    }

    func deleteFromBookshelf(expectedBookURL: String, deleteOriginal: Bool) async throws {
        guard facade != nil, observedBookURL == expectedBookURL else { throw CancellationError() }
        let generation = identityGeneration
        await onFlushReadingProgress?()
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        let bookshelf = try SharedRuntime.bookshelfFacade().get()
        let result =
            try await
            (deleteOriginal
            ? bookshelf.removeBooksAndLocalFilesAsync(bookUrls: [expectedBookURL])
            : bookshelf.removeBooksAsync(bookUrls: [expectedBookURL]))
        guard result.updatedCount == 1, result.failedCount == 0 else {
            throw NSError(domain: "io.legado.kmp.detail", code: 1, userInfo: [NSLocalizedDescriptionKey: "移出书架失败"])
        }
        if identityGeneration == generation, observedBookURL == expectedBookURL {
            previewCandidate = nil
            retainedPreview = nil
            cancelAppearanceRefresh()
        }
    }

    func loadGroups() async throws -> [BookGroup] {
        let generation = identityGeneration
        try Task.checkCancellation()
        let groups = try await SharedRuntime.bookshelfFacade().get().loadGroupsAsync()
        try checkIdentity(generation)
        return groups.filter { $0.groupId > 0 }.sorted {
            $0.order == $1.order ? $0.groupId < $1.groupId : $0.order < $1.order
        }
    }

    func prepareBookEditor() async throws -> Book {
        try Task.checkCancellation()
        let generation = identityGeneration
        let bookURL = observedBookURL
        await onFlushReadingProgress?()
        try checkIdentity(generation)
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        guard let facade else { throw runtimeNotReadyError() }
        guard let book = try await facade.resolveBookAsync(bookUrl: bookURL) else {
            throw runtimeNotReadyError()
        }
        try checkIdentity(generation)
        return book
    }

    func loadMenuSource(expectedBookURL: String) async throws -> BookSource? {
        let generation = identityGeneration
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        guard let facade else { throw runtimeNotReadyError() }
        guard let book = try await facade.resolveBookAsync(bookUrl: expectedBookURL) else {
            throw runtimeNotReadyError()
        }
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        guard !book.isLocal, !book.origin.isEmpty else { return nil }
        let source = try await SharedRuntime.sourceManagementFacade().get().getSourceAsync(sourceUrl: book.origin)
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        return source
    }

    func pinToTop(expectedBookURL: String) async throws -> Book {
        try await prepareMenuMutation(expectedBookURL: expectedBookURL)
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.pinToTopAsync(bookUrl: expectedBookURL)
    }

    func loadVariableEditor(expectedBookURL: String, sourceURL: String, forSource: Bool) async throws
        -> BookDetailVariableSnapshot
    {
        let generation = identityGeneration
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL, let facade else { throw CancellationError() }
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        let snapshot: BookDetailVariableSnapshot = try await SharedAsync.value { completion in
            facade.loadVariableEditor(
                bookUrl: expectedBookURL, expectedSourceUrl: sourceURL, forSource: forSource,
                completionHandler: completion)
        }
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        return snapshot
    }

    func saveVariable(expectedBookURL: String, sourceURL: String, forSource: Bool, value: String) async throws -> Book? {
        try await prepareMenuMutation(expectedBookURL: expectedBookURL)
        guard let facade else { throw runtimeNotReadyError() }
        if forSource {
            try await SharedAsync.void { completion in
                facade.saveSourceVariable(
                    bookUrl: expectedBookURL, expectedSourceUrl: sourceURL, value: value,
                    completionHandler: completion)
            }
            return nil
        }
        return try await SharedAsync.value { completion in
            facade.saveCustomBookVariable(
                bookUrl: expectedBookURL, expectedSourceUrl: sourceURL, value: value,
                completionHandler: completion)
        }
    }

    func toggleCanUpdate(expectedBookURL: String) async throws -> Book {
        try await prepareMenuMutation(expectedBookURL: expectedBookURL)
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.toggleCanUpdateAsync(bookUrl: expectedBookURL)
    }

    func clearCache(expectedBookURL: String) async throws {
        try await prepareMenuMutation(expectedBookURL: expectedBookURL)
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.clearCacheAsync(bookUrl: expectedBookURL)
    }

    private func prepareMenuMutation(expectedBookURL: String) async throws {
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        _ = try await prepareBookEditor()
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func saveEditedBookInfo(
        expectedBookURL: String, name: String, author: String, coverURL: String, intro: String, bookType: Int32
    ) async throws -> Book {
        try Task.checkCancellation()
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        guard let facade else { throw runtimeNotReadyError() }
        // Return completed writes even if the editor's presentation changes during the save.
        return try await facade.saveEditedBookInfoAsync(
            bookUrl: expectedBookURL, name: name, author: author, coverUrl: coverURL, intro: intro,
            bookType: bookType)
    }

    @MainActor
    func createCoverSearchSession(
        expectedBookURL: String,
        onResult: @escaping (CoverSearchResult) -> Void,
        onProgress: @escaping (CoverSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> CoverSearchSession {
        let generation = identityGeneration
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        guard let facade else { throw runtimeNotReadyError() }
        let session = try await facade.createCoverSearchSessionAsync(
            bookUrl: expectedBookURL, onResult: onResult, onProgress: onProgress, onFinished: onFinished)
        do {
            try checkIdentity(generation)
            guard observedBookURL == expectedBookURL else { throw CancellationError() }
            return session
        } catch {
            session.dispose()
            throw error
        }
    }

    @MainActor
    func updateCover(expectedBookURL: String, coverURL: String) async throws -> Book {
        let generation = identityGeneration
        try checkIdentity(generation)
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        guard let facade else { throw runtimeNotReadyError() }
        let updated = try await facade.updateBookInfoAsync(
            bookUrl: expectedBookURL, name: nil, author: nil, coverUrl: coverURL, intro: nil)
        // A completed write stays persisted; only its adoption by a different identity is rejected.
        guard identityGeneration == generation, observedBookURL == expectedBookURL else {
            throw CancellationError()
        }
        return updated
    }

    func createGroup(name: String) async throws -> BookGroup {
        try Task.checkCancellation()
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw NSError(
                domain: "io.legado.kmp.ios", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "分组名称不能为空"])
        }
        return try await SharedRuntime.bookshelfFacade().get().saveGroupAsync(
            groupId: 0, name: normalized, show: true, enableRefresh: true, bookSort: -1)
    }

    func observeSelectableGroups(_ onUpdate: @escaping ([BookGroup]) -> Void) throws -> FlowSubscription {
        try SharedRuntime.bookshelfFacade().get().watchSelectableGroups(onUpdate: onUpdate)
    }

    func saveGroupDetails(groupID: Int64, draft: BookGroupEditDraft) async throws -> BookGroup {
        try Task.checkCancellation()
        return try await SharedRuntime.bookshelfFacade().get().saveGroupDetailsAsync(
            groupId: groupID, name: draft.name, cover: draft.cover,
            enableRefresh: draft.enableRefresh, bookSort: draft.bookSort)
    }

    func deleteBookGroup(_ groupID: Int64) async throws {
        try Task.checkCancellation()
        try await SharedRuntime.bookshelfFacade().get().deleteGroupAsync(groupId: groupID)
    }

    func reorderBookGroups(_ ids: [Int64]) async throws {
        try Task.checkCancellation()
        try await SharedRuntime.bookshelfFacade().get().reorderGroupsAsync(groupIds: ids.map { KotlinLong(longLong: $0) })
    }

    func updateGroup(groupID: Int64, expectedBookURL: String) async throws -> Book {
        try Task.checkCancellation()
        let generation = identityGeneration
        guard observedBookURL == expectedBookURL else { throw CancellationError() }
        _ = try await prepareRetainedPreview()
        try checkIdentity(generation)
        guard let facade else { throw runtimeNotReadyError() }
        // A completed grouping write must not be discarded as if cancellation rolled it back.
        return try await facade.updateGroupAsync(bookUrl: expectedBookURL, groupId: groupID)
    }

    func loadChapterListState() async throws -> [ReaderChapterListItem] {
        try Task.checkCancellation()
        let generation = identityGeneration
        let items = try await requireReaderFacade().loadChapterListStateAsync(bookUrl: observedBookURL)
        try checkIdentity(generation)
        return items
    }

    func reverseChapterList() async throws -> BookDetailRefreshResult {
        try Task.checkCancellation()
        // Do not discard a committed reorder when the presenting panel is cancelled.
        return try await requireReaderFacade().reverseChapterList(bookUrl: observedBookURL)
    }

    private func requireReaderFacade() throws -> ReaderFacade {
        if let readerFacade { return readerFacade }
        let resolved = try SharedRuntime.readerFacade().get()
        readerFacade = resolved
        return resolved
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.BookDetail.unavailable])
    }
}
