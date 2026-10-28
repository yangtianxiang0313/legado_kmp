import Foundation
import shared

struct ReaderCatalogSnapshot {
    let book: Book
    let chapters: [BookChapter]

    var progress: ReaderProgressQueue.Snapshot {
        .init(
            chapterIndex: Int(book.durChapterIndex), chapterTitle: book.durChapterTitle,
            chapterPosition: Int(book.durChapterPos))
    }

    func hasSameCatalog(as other: ReaderCatalogSnapshot) -> Bool {
        book.bookUrl == other.book.bookUrl && book.origin == other.book.origin
            && book.tocUrl == other.book.tocUrl && book.config.reverseToc == other.book.config.reverseToc
            && Self.signature(chapters) == Self.signature(other.chapters)
    }

    static func signature(_ chapters: [BookChapter]) -> String {
        // Kotlin BookChapter equality only compares URLs, not the EPUB ranges behind them.
        chapters.map(chapterSignature).joined(separator: "|")
    }

    private static func chapterSignature(_ chapter: BookChapter) -> String {
        var fields: [String] = [chapter.bookUrl, String(chapter.index), chapter.url, chapter.baseUrl, chapter.title]
        fields.append(contentsOf: [
            chapter.resourceUrl ?? "", String(describing: chapter.start?.int64Value),
            String(describing: chapter.end?.int64Value),
        ])
        fields.append(contentsOf: [
            chapter.startFragmentId ?? "", chapter.endFragmentId ?? "",
            String(chapter.isVolume), chapter.variable ?? "",
        ])
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

@MainActor
final class ReaderCatalogRefreshClient {
    final class Session {
        let barrier: ReaderProgressQueue.CatalogBarrier
        let bookURL: String
        let generation: UUID
        let reader: ReaderFacade
        let books: BookDetailFacade
        var before: ReaderCatalogSnapshot?
        fileprivate(set) var didStartMutation = false
        fileprivate var waiters: [CheckedContinuation<Void, Never>] = []

        init(
            barrier: ReaderProgressQueue.CatalogBarrier, bookURL: String, generation: UUID,
            reader: ReaderFacade, books: BookDetailFacade, before: ReaderCatalogSnapshot?
        ) {
            self.barrier = barrier
            self.bookURL = bookURL
            self.generation = generation
            self.reader = reader
            self.books = books
            self.before = before
        }
    }

    private let binding: () -> (bookURL: String, generation: UUID)
    private let reader: () -> ReaderFacade?
    private let books: () -> BookDetailFacade?
    private let queue: ReaderProgressQueue
    private let publish: (ReaderCatalogSnapshot) -> Void
    private var active: Session?

    init(
        binding: @escaping () -> (bookURL: String, generation: UUID),
        reader: @escaping () -> ReaderFacade?, books: @escaping () -> BookDetailFacade?,
        queue: ReaderProgressQueue, publish: @escaping (ReaderCatalogSnapshot) -> Void
    ) {
        self.binding = binding
        self.reader = reader
        self.books = books
        self.queue = queue
        self.publish = publish
    }

    var isBlockingObservation: Bool { active.map(isCurrent) == true }

    func isCurrent(_ session: Session) -> Bool {
        let current = binding()
        return active === session && current.bookURL == session.bookURL && current.generation == session.generation
    }

    func begin(before: ReaderCatalogSnapshot? = nil) throws -> Session {
        guard active == nil, let reader = reader(), let books = books() else { throw CancellationError() }
        let current = binding()
        let session = Session(
            barrier: try queue.beginCatalogBarrier(), bookURL: current.bookURL, generation: current.generation,
            reader: reader, books: books, before: before)
        active = session
        return session
    }

    func waitUntilSettled() async {
        guard let active else { return }
        await withCheckedContinuation { active.waiters.append($0) }
    }

    func refresh(_ session: Session) async throws -> BookDetailRefreshResult {
        guard await queue.drainCatalogBarrier(session.barrier), isCurrent(session) else {
            throw NSError(
                domain: "io.legado.readerProgress", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "阅读进度尚未保存，请稍后重试"])
        }
        try Task.checkCancellation()
        session.before = try await read(session)
        try Task.checkCancellation()
        guard isCurrent(session) else { throw CancellationError() }
        let request = ReaderCatalogTerminalRequest()
        session.didStartMutation = true
        // Cancellation asks Kotlin to stop, but does not release the barrier before its terminal callback.
        let result: BookDetailRefreshResult = try await withTaskCancellationHandler {
            try await SharedAsync.value { completion in
                let subscription = session.books.refreshChaptersRequest(bookUrl: session.bookURL) { response in
                    request.finish()
                    if response.isCancelled {
                        completion(nil, CancellationError())
                    } else if response.errorCode != nil || response.errorMessage != nil {
                        completion(
                            nil,
                            NSError(
                                domain: "io.legado.kmp.ios", code: -1,
                                userInfo: [
                                    NSLocalizedDescriptionKey: response.errorMessage ?? response.errorCode
                                        ?? L10n.Shared.emptyValue,
                                    "errorCode": response.errorCode ?? "",
                                ]))
                    } else {
                        completion(response.result, nil)
                    }
                }
                request.install(subscription)
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        guard isCurrent(session), result.book.bookUrl == session.bookURL else { throw CancellationError() }
        return result
    }

    func read(_ session: Session) async throws -> ReaderCatalogSnapshot {
        // Recovery can begin before refresh() reaches its drain, including an early UI cancellation.
        _ = await queue.drainCatalogBarrier(session.barrier)
        guard isCurrent(session) else { throw CancellationError() }
        let request = ReaderCatalogTerminalRequest(cancelOnFinish: true)
        let chapters: [BookChapter] = try await SharedCancellableAsync.value { completion in
            request.setDeadline {
                completion(
                    nil,
                    NSError(
                        domain: "io.legado.readerCatalog", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]))
            }
            // Watch the persisted rows directly: no requireBook fallback, parsing or catalog repair.
            let subscription = session.reader.watchChapters(bookUrl: session.bookURL) { chapters in
                request.finish()
                completion(chapters, nil)
            }
            request.install(subscription)
            return subscription
        }
        let book: Book? = try await SharedAsync.optionalValue {
            session.books.resolvePersistedBook(bookUrl: session.bookURL, completionHandler: $0)
        }
        guard isCurrent(session), let book else { throw CancellationError() }
        return ReaderCatalogSnapshot(book: book, chapters: chapters)
    }

    func load(_ session: Session, index: Int) async throws -> ReaderChapterPayload {
        guard isCurrent(session) else { throw CancellationError() }
        let payload = try await session.reader.peekChapterAsync(bookUrl: session.bookURL, chapterIndex: Int32(index))
        guard isCurrent(session), payload.book.bookUrl == session.bookURL else { throw CancellationError() }
        return payload
    }

    @discardableResult
    func finish(
        _ session: Session, persisted: ReaderCatalogSnapshot?, acceptsPresentation: Bool,
        presented: ReaderProgressQueue.Snapshot? = nil
    ) -> Bool {
        let current = isCurrent(session)
        let accepted = queue.finishCatalogBarrier(
            session.barrier, committed: persisted?.progress, acceptsPresentation: current && acceptsPresentation)
        let progressBinding = queue.currentBindingID
        if active === session { active = nil }
        let waiters = session.waiters
        session.waiters = []
        waiters.forEach { $0.resume() }
        guard current, accepted else { return false }
        if let persisted { publish(persisted) }
        if acceptsPresentation, let presented {
            queue.stage(presented, immediate: true, bindingID: progressBinding)
        }
        return true
    }

    func refresh() async throws -> BookDetailRefreshResult {
        await waitUntilSettled()
        try Task.checkCancellation()
        let session = try begin()
        do {
            let result = try await refresh(session)
            finish(
                session, persisted: ReaderCatalogSnapshot(book: result.book, chapters: result.chapters),
                acceptsPresentation: false)
            return result
        } catch {
            await Task { @MainActor in
                let persisted = try? await self.read(session)
                let unchanged =
                    session.before.flatMap { before in
                        persisted.map {
                            before.hasSameCatalog(as: $0) && (!session.didStartMutation || before.progress == $0.progress)
                        }
                    } ?? false
                self.finish(session, persisted: persisted, acceptsPresentation: unchanged)
            }.value
            throw error
        }
    }
}

private final class ReaderCatalogTerminalRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: FlowSubscription?
    private var cancelled = false
    private var finished = false
    private let cancelOnFinish: Bool
    private var deadline: Task<Void, Never>?

    init(cancelOnFinish: Bool = false) {
        self.cancelOnFinish = cancelOnFinish
    }

    func setDeadline(_ completion: @escaping @Sendable () -> Void) {
        let task = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            self?.finish()
            completion()
        }
        lock.lock()
        if finished {
            task.cancel()
        } else {
            deadline = task
        }
        lock.unlock()
    }

    func install(_ subscription: FlowSubscription) {
        lock.lock()
        let shouldCancel = (cancelled && !finished) || (finished && cancelOnFinish)
        if !finished { self.subscription = subscription }
        lock.unlock()
        if shouldCancel { subscription.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let subscription = subscription
        lock.unlock()
        subscription?.cancel()
    }

    func finish() {
        lock.lock()
        finished = true
        let subscription = cancelOnFinish ? subscription : nil
        self.subscription = nil
        let deadline = deadline
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        subscription?.cancel()
    }
}
