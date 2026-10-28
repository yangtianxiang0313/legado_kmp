import Foundation
import shared

/// Keeps cancellable WebDAV work separate from chapter/page persistence.
@MainActor
final class ReaderSyncClient {
    typealias Binding = (bookURL: String, generation: UUID)
    private let binding: () -> Binding
    private let reader: () -> ReaderFacade?
    private let settings: () -> SettingsFacade?
    private let books: () -> BookDetailFacade?
    private let queue: ReaderProgressQueue

    init(
        binding: @escaping () -> Binding, reader: @escaping () -> ReaderFacade?,
        settings: @escaping () -> SettingsFacade?, books: @escaping () -> BookDetailFacade?, queue: ReaderProgressQueue
    ) {
        self.binding = binding
        self.reader = reader
        self.settings = settings
        self.books = books
        self.queue = queue
    }

    func sync() async throws -> SyncProgressResult {
        let selected = binding()
        let book = try await snapshot()
        try check(selected)
        let client = try sharedClient()
        let response = try await response { client.syncExpectedRequest(book: book, onResult: $0) }
        try check(selected)
        guard let result = response.result else { throw unavailable() }
        return result
    }

    func read(book: Book) async throws -> BookProgress? {
        let selected = binding()
        guard selected.bookURL == book.bookUrl, !book.isNotShelf else { return nil }
        let client = try sharedClient()
        let result = try await response { client.readRequest(book: book, onResult: $0) }
        try check(selected)
        return result.progress
    }

    func upload(book: Book) async throws {
        let selected = binding()
        guard selected.bookURL == book.bookUrl, !book.isNotShelf else { throw CancellationError() }
        let client = try sharedClient()
        _ = try await response { client.uploadRequest(book: book, onResult: $0) }
        try check(selected)
    }

    func uploadCurrent() async throws {
        let book = try await snapshot()
        try await upload(book: book)
    }

    func snapshot() async throws -> Book {
        let selected = binding()
        try await queue.flushForExit()
        try check(selected)
        guard let facade = books(), let book = try await facade.resolveBookAsync(bookUrl: selected.bookURL) else {
            throw unavailable()
        }
        try check(selected)
        return book
    }

    func apply(
        _ progress: BookProgress, expected: Book,
        register: @escaping (FlowSubscription) -> Void
    ) async throws -> ReaderChapterPayload? {
        let selected = binding()
        guard selected.bookURL == expected.bookUrl else { throw CancellationError() }
        let client = try sharedClient()
        let result = try await response { completion in
            let subscription = client.applyRequest(expected: expected, progress: progress, onResult: completion)
            register(subscription)
            return subscription
        }
        try check(selected)
        return result.payload
    }

    /// Captures dependencies before unbind. A departure must flush local writes even after the VC dies.
    func makePauseWork(expected: Book, enhanced: Bool) throws -> @MainActor () async throws -> Void {
        let client = try sharedClient()
        guard let books = books() else { throw unavailable() }
        let queue = queue
        let generation = queue.currentBindingID
        return {
            try await queue.flushForExit()
            try Task.checkCancellation()
            guard generation == queue.currentBindingID,
                let latest = try await books.resolveBookAsync(bookUrl: expected.bookUrl),
                Self.sameIdentity(expected, latest), !latest.isNotShelf
            else { throw CancellationError() }
            try Task.checkCancellation()
            if enhanced {
                _ = try await self.response { client.syncBookRequest(book: latest, onResult: $0) }
            } else {
                _ = try await self.response { client.uploadRequest(book: latest, onResult: $0) }
            }
        }
    }

    static func sameIdentity(_ lhs: Book, _ rhs: Book) -> Bool {
        lhs.bookUrl == rhs.bookUrl && lhs.origin == rhs.origin && lhs.tocUrl == rhs.tocUrl
            && lhs.config.reverseToc == rhs.config.reverseToc && lhs.name == rhs.name && lhs.author == rhs.author
    }

    private func sharedClient() throws -> ReaderProgressSyncClient {
        guard let reader = reader(), let settings = settings() else { throw unavailable() }
        return ReaderProgressSyncClient(reader: reader, settings: settings)
    }

    private func check(_ selected: Binding) throws {
        try Task.checkCancellation()
        let current = binding()
        guard selected.bookURL == current.bookURL, selected.generation == current.generation else {
            throw CancellationError()
        }
    }

    private func response(
        _ start: (@escaping (ReaderProgressSyncResponse) -> Void) -> FlowSubscription
    ) async throws -> ReaderProgressSyncResponse {
        try Task.checkCancellation()
        let result: ReaderProgressSyncResponse = try await SharedCancellableAsync.value { completion in
            start { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if let code = result.errorCode {
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.readerProgressSync", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: result.errorMessage ?? code, "errorCode": code]))
                } else {
                    completion(result, nil)
                }
            }
        }
        try Task.checkCancellation()
        return result
    }

    private func unavailable() -> NSError {
        NSError(
            domain: "io.legado.readerProgressSync", code: 1,
            userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
    }
}
