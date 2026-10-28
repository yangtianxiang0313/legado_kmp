import Foundation
import shared

/// Keeps the exit transaction bound to the same reader after the progress queue drains.
@MainActor
final class ReaderExitClient {
    private let binding: () -> (bookURL: String, generation: UUID)
    private let facade: () -> BookDetailFacade?
    private let flushProgress: () async throws -> Void

    init(
        binding: @escaping () -> (bookURL: String, generation: UUID),
        facade: @escaping () -> BookDetailFacade?, flushProgress: @escaping () async throws -> Void
    ) {
        self.binding = binding
        self.facade = facade
        self.flushProgress = flushProgress
    }

    func resolve() async throws -> Book? {
        let captured = binding()
        guard let facade = facade() else { throw CancellationError() }
        let book: Book? = try await SharedAsync.optionalValue { completion in
            facade.resolvePersistedBook(bookUrl: captured.bookURL, completionHandler: completion)
        }
        try Task.checkCancellation()
        guard binding().bookURL == captured.bookURL, binding().generation == captured.generation else { throw CancellationError() }
        return book
    }

    func complete(bookURL: String, expectedOrigin: String, addToShelf: Bool) async throws -> Book? {
        let captured = binding()
        guard captured.bookURL == bookURL, let facade = facade() else { throw CancellationError() }
        try await flushProgress()
        try Task.checkCancellation()
        guard binding().bookURL == bookURL, binding().generation == captured.generation else { throw CancellationError() }
        let book: Book? = try await SharedAsync.optionalValue { completion in
            facade.completePreviewReadingExit(
                bookUrl: bookURL, expectedOrigin: expectedOrigin, addToShelf: addToShelf, completionHandler: completion)
        }
        guard binding().bookURL == bookURL, binding().generation == captured.generation else { throw CancellationError() }
        return book
    }
}
