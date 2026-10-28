import Foundation
import shared

@MainActor
final class MangaReaderAdapter {
    let bookURL: String
    private let progress: ReaderProgressQueue
    private let requests: ReaderChapterRequestGate
    private var neighborRequests: [UUID: ReaderChapterRequestGate] = [:]
    private var neighborBookSubscription: FlowSubscription?
    private var neighborChaptersSubscription: FlowSubscription?
    private var neighborIdentity: MangaChapterWindowIdentity?
    private var neighborDirectory: [MangaChapterWindowIdentity.Entry] = []
    private var isNeighborContextValid = false
    private(set) var neighborGeneration = UUID()
    private var bindingID = UUID()
    private var reader: ReaderFacade?
    private var manga: MangaReaderFacade?
    private var books: BookDetailFacade?
    private var progressSyncClient: MangaReaderProgressSyncClient?
    private var progressSyncDirectory: [BookChapter] = []
    private var readTimeTask: Task<Void, Never>?
    private var readTimeError: Error?
    private var needsReadTimeSettlement = false
    private var isReading = false
    private var isRecovering = false
    private var isLoadingSuspended = false
    private(set) var isRetired = false
    private(set) var recoveryGeneration = UUID()
    private(set) var chapter: MangaReaderChapter?
    private lazy var exitClient = ReaderExitClient(
        binding: { [weak self] in (self?.bookURL ?? "", self?.bindingID ?? UUID()) },
        facade: { [weak self] in self?.books },
        flushProgress: { [weak self] in try await self?.progress.flushForExit() }
    )

    init(bookURL: String) {
        self.bookURL = bookURL
        progress = ReaderProgressQueue(bookURL: bookURL)
        requests = ReaderChapterRequestGate(bookURL: bookURL)
    }

    deinit {
        neighborBookSubscription?.cancel()
        neighborChaptersSubscription?.cancel()
        for gate in neighborRequests.values { gate.cancel() }
    }

    func bootstrap() throws {
        guard !isRetired else { throw CancellationError() }
        guard reader == nil else { return }
        let resolved = try SharedRuntime.readerFacade().get()
        let resolvedBooks = try SharedRuntime.bookDetailFacade().get()
        let resolvedManga = try BootstrapApiKt.sharedMangaReaderFacade()
        let settings = try SharedRuntime.settingsFacade().get()
        books = resolvedBooks
        manga = resolvedManga
        reader = resolved
        progress.bind(bookURL: bookURL, facade: resolved)
        requests.bind(bookURL: bookURL, facade: resolved)
        progressSyncClient = MangaReaderProgressSyncClient(
            bookURL: bookURL, reader: resolved, manga: resolvedManga, books: resolvedBooks,
            settings: settings, queue: progress,
            context: { [weak self] in
                guard let self, !self.isRetired, !self.isRecovering, let chapter = self.chapter else {
                    throw CancellationError()
                }
                return .init(
                    chapter: chapter, directory: self.progressSyncDirectory,
                    canPrepare: !self.isLoadingSuspended)
            })
        observeNeighborContext()
    }

    func loadInitial(index: Int?, position: Int?, refresh: Bool = false) async throws -> MangaReaderChapter {
        guard !isRecovering, !isRetired else { throw CancellationError() }
        progressSyncClient?.cancelPreparation()
        cancelNeighbors()
        isNeighborContextValid = false
        recoveryGeneration = UUID()
        let generation = recoveryGeneration
        try bootstrap()
        guard let books else { throw CancellationError() }
        let book = try await books.resolveBookAsync(bookUrl: bookURL)
        try Task.checkCancellation()
        guard recoveryGeneration == generation, !isRecovering, !isRetired else { throw CancellationError() }
        guard let book else { throw failure("书籍不存在或已被移除") }
        let requestedIndex = index ?? Int(book.durChapterIndex)
        let requestedPosition = position ?? (requestedIndex == Int(book.durChapterIndex) ? Int(book.durChapterPos) : 0)
        return try await load(index: requestedIndex, position: requestedPosition, refresh: refresh)
    }

    func load(index: Int, position: Int, refresh: Bool = false) async throws -> MangaReaderChapter {
        guard !isRecovering, !isRetired else { throw CancellationError() }
        progressSyncClient?.cancelPreparation()
        cancelNeighbors()
        isNeighborContextValid = false
        recoveryGeneration = UUID()
        try bootstrap()
        guard let manga else { throw CancellationError() }
        let ticket = try requests.begin()
        do {
            try await progress.flushForExit()
            try requests.check(ticket)
            let requestGate = requests
            let payload: ReaderChapterPayload = try await SharedCancellableAsync.value { completion in
                let subscription = ticket.facade.prepareChapterRequest(
                    bookUrl: ticket.bookURL, chapterIndex: Int32(clamping: index), refreshContent: refresh
                ) { result in
                    requestGate.finish(ticket)
                    if result.isCancelled {
                        completion(nil, CancellationError())
                    } else if result.errorCode != nil || result.errorMessage != nil {
                        completion(
                            nil,
                            NSError(
                                domain: "io.legado.manga", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "漫画章节加载失败"]))
                    } else {
                        completion(result.payload, nil)
                    }
                }
                requestGate.register(subscription, for: ticket)
                return subscription
            }
            try requests.check(ticket)
            let prepared: MangaReaderChapter = try await SharedAsync.value { completion in
                manga.prepareReaderChapter(
                    payload: payload, chapterPosition: Int32(clamping: position), completionHandler: completion)
            }
            try requests.check(ticket)
            guard prepared.book.bookUrl == bookURL else { throw failure("漫画书籍状态已变化") }
            neighborIdentity = MangaChapterWindowIdentity(prepared)
            neighborDirectory = payload.chapters.map(MangaChapterWindowIdentity.Entry.init)
            progressSyncDirectory = payload.chapters
            isNeighborContextValid = neighborIdentity?.isValid == true
            return prepared
        } catch {
            try requests.check(ticket)
            throw error
        }
    }

    // Preparation has its own gates: it never flushes, accepts, or changes the reading generation.
    func loadNeighbor(index: Int, expectedOrigin: String) async throws -> MangaReaderChapter {
        try Task.checkCancellation()
        guard let identity = neighborIdentity, canLoadNeighbors(identity), identity.origin == expectedOrigin,
            identity.entries.indices.contains(index), neighborRequests.count < 2,
            let reader, let manga, let books
        else { throw CancellationError() }
        let generation = neighborGeneration
        let directory = neighborDirectory
        let id = UUID()
        let gate = ReaderChapterRequestGate(bookURL: bookURL)
        gate.bind(bookURL: bookURL, facade: reader)
        neighborRequests[id] = gate
        defer {
            gate.cancel()
            neighborRequests.removeValue(forKey: id)
        }
        let ticket = try gate.begin()
        do {
            let original: Book? = try await SharedAsync.optionalValue { completion in
                books.resolvePersistedBook(bookUrl: bookURL, completionHandler: completion)
            }
            try checkNeighbor(id, generation: generation, identity: identity)
            try gate.check(ticket)
            guard let original, original.bookUrl == bookURL, original.origin == expectedOrigin,
                Int(
                    reader.computeSimulatedChapterSize(
                        readConfig: original.readConfig, realChapterSize: Int32(clamping: directory.count)))
                    == identity.entries.count
            else { throw failure("漫画邻章书籍或可读范围已变化") }
            let payload: ReaderChapterPayload = try await SharedCancellableAsync.value { completion in
                let subscription = ticket.facade.prepareChapterRequest(
                    bookUrl: ticket.bookURL, chapterIndex: Int32(clamping: index), refreshContent: false
                ) { result in
                    gate.finish(ticket)
                    if result.isCancelled {
                        completion(nil, CancellationError())
                    } else if result.errorCode != nil || result.errorMessage != nil {
                        completion(
                            nil,
                            NSError(
                                domain: "io.legado.manga", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "漫画邻章加载失败"]))
                    } else {
                        completion(result.payload, nil)
                    }
                }
                gate.register(subscription, for: ticket)
                return subscription
            }
            try checkNeighbor(id, generation: generation, identity: identity)
            try gate.check(ticket)
            guard payload.book.bookUrl == bookURL, payload.book.origin == expectedOrigin,
                Int(payload.chapter.index) == index,
                MangaChapterWindowIdentity.Entry(payload.chapter) == identity.entries[index],
                payload.chapters.map(MangaChapterWindowIdentity.Entry.init) == directory
            else { throw failure("漫画邻章目录已变化，请重新加载当前章节") }
            let prepared: MangaReaderChapter = try await SharedAsync.value { completion in
                manga.prepareReaderChapter(payload: payload, chapterPosition: 0, completionHandler: completion)
            }
            try checkNeighbor(id, generation: generation, identity: identity)
            try gate.check(ticket)
            // Resolve only persisted state: a search preview must not revive a removed book.
            let latest: Book? = try await SharedAsync.optionalValue { completion in
                books.resolvePersistedBook(bookUrl: bookURL, completionHandler: completion)
            }
            try checkNeighbor(id, generation: generation, identity: identity)
            try gate.check(ticket)
            guard let latest, latest.bookUrl == bookURL, latest.origin == expectedOrigin,
                MangaChapterWindowIdentity(prepared) == identity, Int(prepared.chapterIndex) == index,
                Int(
                    reader.computeSimulatedChapterSize(
                        readConfig: latest.readConfig, realChapterSize: Int32(clamping: directory.count)))
                    == identity.entries.count
            else { throw failure("漫画邻章书籍或可读范围已变化") }
            return prepared
        } catch {
            try checkNeighbor(id, generation: generation, identity: identity)
            try gate.check(ticket)
            throw error
        }
    }

    func cancelNeighbors() {
        neighborGeneration = UUID()
        let gates = Array(neighborRequests.values)
        neighborRequests.removeAll()
        for gate in gates { gate.cancel() }
    }

    func canLoadNeighbors(_ identity: MangaChapterWindowIdentity) -> Bool {
        !isRetired && !isRecovering && !isLoadingSuspended && isNeighborContextValid
            && identity.isValid && identity.bookURL == bookURL && neighborIdentity == identity
    }

    private func checkNeighbor(_ id: UUID, generation: UUID, identity: MangaChapterWindowIdentity) throws {
        try Task.checkCancellation()
        guard neighborGeneration == generation, neighborRequests[id] != nil, canLoadNeighbors(identity) else {
            throw CancellationError()
        }
    }

    private func observeNeighborContext() {
        guard let books else { return }
        let binding = bindingID
        neighborBookSubscription = books.watchBook(bookUrl: bookURL) { [weak self] book in
            DispatchQueue.main.async {
                guard let self, self.bindingID == binding, !self.isRetired,
                    let identity = self.neighborIdentity
                else { return }
                if let current = self.chapter,
                    book.map({ ReaderSyncClient.sameIdentity(current.book, $0) }) != true
                {
                    self.progressSyncClient?.invalidate()
                }
                guard let book, book.bookUrl == identity.bookURL, book.origin == identity.origin,
                    let reader = self.reader,
                    Int(
                        reader.computeSimulatedChapterSize(
                            readConfig: book.readConfig, realChapterSize: Int32(clamping: self.neighborDirectory.count)))
                        == identity.entries.count
                else {
                    self.isNeighborContextValid = false
                    self.cancelNeighbors()
                    return
                }
            }
        }
        neighborChaptersSubscription = books.watchChapters(bookUrl: bookURL) { [weak self] chapters in
            let directory = chapters.map(MangaChapterWindowIdentity.Entry.init)
            DispatchQueue.main.async {
                guard let self, self.bindingID == binding, !self.isRetired, self.neighborIdentity != nil else {
                    return
                }
                if ReaderCatalogSnapshot.signature(chapters) != ReaderCatalogSnapshot.signature(self.progressSyncDirectory) {
                    self.progressSyncClient?.invalidate()
                }
                guard directory != self.neighborDirectory else { return }
                self.isNeighborContextValid = false
                self.cancelNeighbors()
            }
        }
    }

    func accept(_ prepared: MangaReaderChapter) {
        guard !isRecovering, !isRetired, prepared.book.bookUrl == bookURL else { return }
        progressSyncClient?.cancelPreparation()
        recoveryGeneration = UUID()
        chapter = prepared
    }

    func record(position: Int, immediate: Bool) {
        guard !isRecovering, !isRetired, let chapter else { return }
        let bounded = max(0, min(position, chapter.pages.count - 1))
        progress.stage(
            .init(chapterIndex: Int(chapter.chapterIndex), chapterTitle: chapter.chapterTitle, chapterPosition: bounded),
            immediate: immediate)
    }

    func flush() async {
        guard !isRetired else { return }
        await progress.flushNow()
    }

    func progressSyncSnapshot() async throws -> Book {
        try await requireProgressSyncClient().snapshot()
    }

    func syncProgress() async throws -> SyncProgressResult {
        try await requireProgressSyncClient().sync()
    }

    func readCloudProgress(book: Book) async throws -> BookProgress? {
        try await requireProgressSyncClient().read(book: book)
    }

    func uploadCloudProgress(book: Book) async throws {
        try await requireProgressSyncClient().upload(book: book)
    }

    func prepareCloudProgress(_ remote: BookProgress, expected: Book) async throws -> MangaReaderChapter {
        try await requireProgressSyncClient().prepare(remote, expected: expected)
    }

    func makeProgressSyncPauseWork(expected: Book, enhanced: Bool) throws -> @MainActor () async throws -> Void {
        try requireProgressSyncClient().makePauseWork(expected: expected, enhanced: enhanced)
    }

    private func requireProgressSyncClient() throws -> MangaReaderProgressSyncClient {
        guard !isRetired, !isRecovering else { throw CancellationError() }
        try bootstrap()
        guard let progressSyncClient else { throw CancellationError() }
        return progressSyncClient
    }

    func flushForRecovery() async throws {
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
        isRecovering = true
        isLoadingSuspended = true
        progressSyncClient?.invalidate()
        cancelNeighbors()
        requests.suspend()
        setReadingActive(false)
        let generation = recoveryGeneration
        let readTime = readTimeTask
        var progressError: Error?
        do {
            try await progress.flushForExit()
        } catch {
            progressError = error
        }
        // Settle both writers even when one fails; cancellation cannot leave a detached old-key write.
        await readTime?.value
        try Task.checkCancellation()
        guard !isRetired, isRecovering, recoveryGeneration == generation else { throw CancellationError() }
        if let progressError { throw progressError }
        if let readTimeError { throw readTimeError }
        guard !isReading, !needsReadTimeSettlement else { throw failure("阅读时长尚未保存，请稍后重试") }
    }

    func pause() async {
        guard !isRetired else { return }
        setReadingActive(false)
        await progress.flushNow()
        await readTimeTask?.value
    }

    func contents() async throws -> [ReaderChapterListItem] {
        guard !isRetired, !isRecovering, let reader else { throw CancellationError() }
        let generation = recoveryGeneration
        let items: [ReaderChapterListItem] = try await SharedAsync.value { completion in
            reader.loadChapterListState(bookUrl: bookURL, completionHandler: completion)
        }
        try Task.checkCancellation()
        guard !isRetired, !isRecovering, recoveryGeneration == generation else { throw CancellationError() }
        return items
    }

    func suspendLoading() {
        progressSyncClient?.cancelPreparation()
        recoveryGeneration = UUID()
        isLoadingSuspended = true
        cancelNeighbors()
        requests.suspend()
    }

    func resumeLoading() {
        guard !isRetired else { return }
        if isLoadingSuspended || isRecovering { recoveryGeneration = UUID() }
        isLoadingSuspended = false
        isRecovering = false
        requests.resume()
    }

    func cancelLoading() {
        progressSyncClient?.cancelPreparation()
        recoveryGeneration = UUID()
        cancelNeighbors()
        requests.cancel()
    }

    func setReadingActive(_ active: Bool) {
        guard !isRetired, !active || !isRecovering,
            active != isReading || (!active && readTimeError != nil), let reader
        else { return }
        isReading = active
        let previous = readTimeTask
        let url = bookURL
        readTimeTask = Task { @MainActor [self] in
            await previous?.value
            if active {
                guard !isRetired, !isRecovering, isReading else { return }
                reader.beginReadSession(bookUrl: url)
                needsReadTimeSettlement = true
            } else {
                guard needsReadTimeSettlement else { return }
                do {
                    try await SharedAsync.void { completion in
                        reader.endReadSession(bookUrl: url, completionHandler: completion)
                    }
                    needsReadTimeSettlement = false
                    readTimeError = nil
                } catch {
                    readTimeError = error
                    SharedRuntime.log("manga read time save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func resolveForExit() async throws -> Book? {
        guard !isRetired, !isRecovering else { throw CancellationError() }
        guard books != nil else { return nil }
        return try await exitClient.resolve()
    }

    func completeExit(expectedOrigin: String, addToShelf: Bool) async throws {
        guard !isRetired, !isRecovering else { throw CancellationError() }
        _ = try await exitClient.complete(bookURL: bookURL, expectedOrigin: expectedOrigin, addToShelf: addToShelf)
    }

    func finish() async {
        guard !isRetired else { return }
        suspendLoading()
        setReadingActive(false)
        await progress.flushNow()
        await readTimeTask?.value
        progress.cancelDebounce()
    }

    // Recovery must have flushed successfully before commit. Retirement never flushes the replaced key.
    func retireAfterSourceChange() async {
        guard !isRetired else { return }
        progressSyncClient?.invalidate()
        isRetired = true
        isRecovering = true
        isLoadingSuspended = true
        isReading = false
        recoveryGeneration = UUID()
        bindingID = UUID()
        chapter = nil
        cancelNeighbors()
        neighborBookSubscription?.cancel()
        neighborBookSubscription = nil
        neighborChaptersSubscription?.cancel()
        neighborChaptersSubscription = nil
        neighborIdentity = nil
        neighborDirectory = []
        progressSyncDirectory = []
        isNeighborContextValid = false
        requests.suspend()
        requests.bind(bookURL: "", facade: nil)
        progress.cancelDebounce()
        progress.bind(bookURL: "", facade: nil)
        await readTimeTask?.value
        readTimeTask = nil
        reader = nil
        manga = nil
        books = nil
        progressSyncClient = nil
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.manga", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
