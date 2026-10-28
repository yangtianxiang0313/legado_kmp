import Foundation
import shared

/// Android ReadManga / ReadMangaViewModel at 5f5d314; image positions are never text offsets.
@MainActor
final class MangaReaderProgressSyncClient {
    struct Context {
        let chapter: MangaReaderChapter
        let directory: [BookChapter]
        let canPrepare: Bool
    }

    private let bookURL: String
    private let reader: ReaderFacade
    private let manga: MangaReaderFacade
    private let books: BookDetailFacade
    private let settings: SettingsFacade
    private let queue: ReaderProgressQueue
    private let context: () throws -> Context
    private let requests: ReaderChapterRequestGate
    private var generation = UUID()
    private var preparation = UUID()
    private var cloudRequests: [UUID: FlowSubscription] = [:]
    private var pauseTasks: [UUID: Task<Void, Error>] = [:]
    private lazy var syncClient = ReaderSyncClient(
        binding: { [weak self] in (self?.bookURL ?? "", self?.generation ?? UUID()) },
        reader: { [reader] in reader }, settings: { [settings] in settings },
        books: { [books] in books }, queue: queue)

    init(
        bookURL: String, reader: ReaderFacade, manga: MangaReaderFacade, books: BookDetailFacade,
        settings: SettingsFacade, queue: ReaderProgressQueue, context: @escaping () throws -> Context
    ) {
        self.bookURL = bookURL
        self.reader = reader
        self.manga = manga
        self.books = books
        self.settings = settings
        self.queue = queue
        self.context = context
        requests = ReaderChapterRequestGate(bookURL: bookURL)
        requests.bind(bookURL: bookURL, facade: reader)
    }

    func cancelPreparation() {
        preparation = UUID()
        requests.cancel()
    }

    func invalidate() {
        generation = UUID()
        cancelPreparation()
        let subscriptions = Array(cloudRequests.values)
        cloudRequests.removeAll()
        for subscription in subscriptions { subscription.cancel() }
        for task in pauseTasks.values { task.cancel() }
    }

    func snapshot() async throws -> Book {
        let selected = generation
        let current = try context()
        try await queue.flushForExit()
        try check(selected, context: current)
        return try await readSnapshot(current, generation: selected, allowPreview: true)
    }

    func sync() async throws -> SyncProgressResult {
        let selected = generation
        let book = try await snapshot()
        try check(selected)
        guard !book.isNotShelf, try !context().chapter.book.isNotShelf else {
            return SyncProgressResult.Disabled.shared
        }
        let client = ReaderProgressSyncClient(reader: reader, settings: settings)
        let result = try await response { client.syncExpectedRequest(book: book, onResult: $0) }
        try check(selected)
        guard let result = result.result else { throw failure("云端进度同步未返回结果") }
        return result
    }

    func read(book: Book) async throws -> BookProgress? {
        guard !book.isNotShelf, try !context().chapter.book.isNotShelf else { return nil }
        let selected = generation
        let current = try await snapshot()
        guard Self.sameRevision(book, current) else { throw CancellationError() }
        try check(selected)
        let client = ReaderProgressSyncClient(reader: reader, settings: settings)
        let result = try await response { client.readRequest(book: current, onResult: $0) }
        try check(selected)
        let latest = try await readSnapshot(try context(), generation: selected, allowPreview: false)
        guard Self.sameRevision(current, latest) else { throw CancellationError() }
        return result.progress
    }

    func upload(book: Book) async throws {
        guard !book.isNotShelf, try !context().chapter.book.isNotShelf else { throw CancellationError() }
        let selected = generation
        let current = try await snapshot()
        guard Self.sameRevision(book, current), !current.isNotShelf else { throw CancellationError() }
        try check(selected)
        let client = ReaderProgressSyncClient(reader: reader, settings: settings)
        _ = try await response { client.uploadRequest(book: current, onResult: $0) }
        try check(selected)
    }

    /// Prepares only. The coordinator must accept and record after checking its own UI context.
    func prepare(_ remote: BookProgress, expected: Book) async throws -> MangaReaderChapter {
        cancelPreparation()
        let selected = generation
        let requestID = preparation
        let current = try context()
        guard current.canPrepare, !current.chapter.book.isNotShelf, !expected.isNotShelf,
            expected.bookUrl == bookURL, remote.name == expected.name, remote.author == expected.author,
            remote.durChapterIndex >= 0, remote.durChapterPos >= 0, remote.durChapterTime >= 0
        else { throw failure("云端进度与当前漫画不匹配") }
        let local = try await snapshot()
        try checkPreparation(requestID, generation: selected, context: current)
        guard Self.sameRevision(expected, local), !local.isNotShelf else { throw CancellationError() }
        let index = Int(remote.durChapterIndex)
        let position = Int(remote.durChapterPos)
        let readable = try readableCount(local, directory: current.directory)
        guard current.directory.indices.contains(index), index < readable, !current.directory[index].isVolume else {
            throw failure("云端章节已超出漫画目录或可读范围")
        }
        let ticket = try requests.begin()
        defer {
            if preparation == requestID { requests.cancel() }
        }
        let gate = requests
        let payload: ReaderChapterPayload = try await SharedCancellableAsync.value { completion in
            let subscription = ticket.facade.prepareChapterRequest(
                bookUrl: ticket.bookURL, chapterIndex: remote.durChapterIndex, refreshContent: false
            ) { result in
                gate.finish(ticket)
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if result.errorCode != nil || result.errorMessage != nil {
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.mangaProgressSync", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? "漫画章节加载失败"]))
                } else {
                    completion(result.payload, nil)
                }
            }
            gate.register(subscription, for: ticket)
            return subscription
        }
        try checkPreparation(requestID, generation: selected, context: current)
        try gate.check(ticket)
        guard ReaderSyncClient.sameIdentity(expected, payload.book), !payload.book.isNotShelf,
            ReaderCatalogSnapshot.signature(payload.chapters) == ReaderCatalogSnapshot.signature(current.directory),
            Int(payload.chapter.index) == index, !payload.chapter.isVolume,
            ReaderCatalogSnapshot.signature([payload.chapter])
                == ReaderCatalogSnapshot.signature([current.directory[index]]),
            try readableCount(payload.book, directory: payload.chapters) == readable
        else { throw failure("漫画书籍、目录或可读范围已变化") }
        let prepared: MangaReaderChapter = try await SharedAsync.value { completion in
            manga.prepareReaderChapter(
                payload: payload, chapterPosition: remote.durChapterPos, completionHandler: completion)
        }
        try checkPreparation(requestID, generation: selected, context: current)
        try gate.check(ticket)
        // The shared parser clamps; validate the original image index, not the clamped result.
        guard ReaderSyncClient.sameIdentity(expected, prepared.book), !prepared.isVolume,
            Int(prepared.chapterIndex) == index, prepared.pages.indices.contains(position),
            Int(prepared.chapterPosition) == position,
            ReaderCatalogSnapshot.signature(prepared.chapters)
                == ReaderCatalogSnapshot.signature(Array(current.directory.prefix(readable)))
        else { throw failure("云端图片页码无效，或漫画目录已变化") }
        let latest = try await readSnapshot(current, generation: selected, allowPreview: false)
        try checkPreparation(requestID, generation: selected, context: current)
        try gate.check(ticket)
        guard Self.sameRevision(expected, latest), try readableCount(latest, directory: current.directory) == readable else {
            throw CancellationError()
        }
        return prepared
    }

    func makePauseWork(expected: Book, enhanced: Bool) throws -> @MainActor () async throws -> Void {
        let current = try context()
        let readable = try readableCount(expected, directory: current.directory)
        guard !expected.isNotShelf, !current.chapter.book.isNotShelf, expected.bookUrl == bookURL,
            ReaderSyncClient.sameIdentity(expected, current.chapter.book),
            current.directory.enumerated().allSatisfy({ $0.element.bookUrl == bookURL && Int($0.element.index) == $0.offset }),
            ReaderCatalogSnapshot.signature(current.chapter.chapters)
                == ReaderCatalogSnapshot.signature(Array(current.directory.prefix(readable)))
        else { throw CancellationError() }
        let selected = generation
        let queueBinding = queue.currentBindingID
        let work = try syncClient.makePauseWork(expected: expected, enhanced: enhanced)
        // Retain the queue/facades and this lifetime token, never the VC or the adapter context closure.
        return { [self] in
            try self.check(selected)
            guard queueBinding == self.queue.currentBindingID else { throw CancellationError() }
            let id = UUID()
            let task = Task { @MainActor [self] in
                try self.check(selected)
                guard queueBinding == self.queue.currentBindingID else { throw CancellationError() }
                let original = try await self.persistedBook()
                try self.check(selected)
                guard queueBinding == self.queue.currentBindingID, let original, !original.isNotShelf,
                    ReaderSyncClient.sameIdentity(expected, original)
                else { throw CancellationError() }
                try await self.queue.flushForExit()
                try self.check(selected)
                let latest = try await self.persistedBook()
                try self.check(selected)
                guard let latest, !latest.isNotShelf, ReaderSyncClient.sameIdentity(expected, latest) else {
                    throw CancellationError()
                }
                try self.validate(latest, context: current)
                let directory = try await self.persistedDirectory()
                try self.check(selected)
                guard queueBinding == self.queue.currentBindingID,
                    ReaderCatalogSnapshot.signature(directory) == ReaderCatalogSnapshot.signature(current.directory)
                else { throw CancellationError() }
                try await work()
                try self.check(selected)
            }
            self.pauseTasks[id] = task
            defer { self.pauseTasks.removeValue(forKey: id) }
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    private func readSnapshot(_ current: Context, generation selected: UUID, allowPreview: Bool) async throws -> Book {
        var book = try await persistedBook()
        try check(selected, context: current)
        if book == nil, allowPreview, current.chapter.book.isNotShelf {
            book = try await books.resolveBookAsync(bookUrl: bookURL)
            try check(selected, context: current)
            guard book?.isNotShelf == true else { throw CancellationError() }
        }
        guard let book, allowPreview || !book.isNotShelf else { throw CancellationError() }
        try validate(book, context: current)
        let directory = try await persistedDirectory()
        try check(selected, context: current)
        guard ReaderCatalogSnapshot.signature(directory) == ReaderCatalogSnapshot.signature(current.directory) else {
            throw failure("漫画目录已变化，请重新加载当前章节")
        }
        let latest = try await persistedBook()
        try check(selected, context: current)
        if let latest {
            guard Self.sameRevision(book, latest), book.isNotShelf == latest.isNotShelf else { throw CancellationError() }
            try validate(latest, context: current)
            return latest
        }
        guard allowPreview, book.isNotShelf else { throw CancellationError() }
        return book
    }

    private func validate(_ book: Book, context current: Context) throws {
        let chapter = current.chapter
        let index = Int(chapter.chapterIndex)
        let readable = try readableCount(book, directory: current.directory)
        guard book.bookUrl == bookURL, ReaderSyncClient.sameIdentity(chapter.book, book),
            current.directory.enumerated().allSatisfy({ $0.element.bookUrl == bookURL && Int($0.element.index) == $0.offset }),
            current.directory.indices.contains(index), index < readable,
            book.durChapterIndex == chapter.chapterIndex, book.durChapterPos >= 0, book.durChapterTime >= 0,
            !chapter.isVolume, !current.directory[index].isVolume,
            chapter.pages.indices.contains(Int(book.durChapterPos)),
            ReaderCatalogSnapshot.signature(chapter.chapters)
                == ReaderCatalogSnapshot.signature(Array(current.directory.prefix(readable)))
        else { throw failure("当前漫画书籍、章节或目录身份已变化") }
    }

    private func readableCount(_ book: Book, directory: [BookChapter]) throws -> Int {
        guard let size = Int32(exactly: directory.count) else { throw failure("漫画目录过大") }
        let count = Int(reader.computeSimulatedChapterSize(readConfig: book.readConfig, realChapterSize: size))
        guard count > 0, count <= directory.count else { throw failure("漫画没有可读章节") }
        return count
    }

    private func persistedBook() async throws -> Book? {
        try await SharedAsync.optionalValue { books.resolvePersistedBook(bookUrl: bookURL, completionHandler: $0) }
    }

    private func persistedDirectory() async throws -> [BookChapter] {
        var subscription: FlowSubscription?
        defer { subscription?.cancel() }
        return try await SharedCancellableAsync.value { completion in
            let watching = books.watchChapters(bookUrl: bookURL) { completion($0, nil) }
            subscription = watching
            return watching
        }
    }

    private func check(_ selected: UUID, context expected: Context? = nil) throws {
        try Task.checkCancellation()
        guard selected == generation else { throw CancellationError() }
        if let expected {
            let current = try context()
            guard current.chapter === expected.chapter,
                ReaderCatalogSnapshot.signature(current.directory) == ReaderCatalogSnapshot.signature(expected.directory)
            else { throw CancellationError() }
        }
    }

    private func checkPreparation(_ id: UUID, generation selected: UUID, context current: Context) throws {
        try check(selected, context: current)
        guard id == preparation, try context().canPrepare else { throw CancellationError() }
    }

    private func response(
        _ start: (@escaping (ReaderProgressSyncResponse) -> Void) -> FlowSubscription
    ) async throws -> ReaderProgressSyncResponse {
        try Task.checkCancellation()
        let id = UUID()
        defer { cloudRequests.removeValue(forKey: id)?.cancel() }
        return try await SharedCancellableAsync.value { completion in
            let subscription = start { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if let code = result.errorCode {
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.mangaProgressSync", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? code, "errorCode": code]))
                } else {
                    completion(result, nil)
                }
            }
            cloudRequests[id] = subscription
            return subscription
        }
    }

    private static func sameRevision(_ lhs: Book, _ rhs: Book) -> Bool {
        ReaderSyncClient.sameIdentity(lhs, rhs) && lhs.durChapterIndex == rhs.durChapterIndex
            && lhs.durChapterPos == rhs.durChapterPos && lhs.durChapterTime == rhs.durChapterTime
            && lhs.durChapterTitle == rhs.durChapterTitle
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.mangaProgressSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
