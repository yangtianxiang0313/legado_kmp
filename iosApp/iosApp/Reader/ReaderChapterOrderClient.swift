import Foundation
import shared

final class ReaderChapterOrderClient {
    private let binding: () -> (bookURL: String, generation: UUID)
    private let facade: () -> ReaderFacade?
    private let flushProgress: () async -> Void

    init(
        binding: @escaping () -> (bookURL: String, generation: UUID),
        facade: @escaping () -> ReaderFacade?,
        flushProgress: @escaping () async -> Void
    ) {
        self.binding = binding
        self.facade = facade
        self.flushProgress = flushProgress
    }

    @MainActor
    func loadState() async throws -> [ReaderChapterListItem] {
        try await requireFacade().loadChapterListStateAsync(bookUrl: binding().bookURL)
    }

    @MainActor
    func reverse() async throws -> BookDetailRefreshResult {
        let snapshot = binding()
        try Task.checkCancellation()
        let facade = try requireFacade()
        await flushProgress()
        try Task.checkCancellation()
        let current = binding()
        guard current.bookURL == snapshot.bookURL, current.generation == snapshot.generation else { throw CancellationError() }
        // Once committed, the result must reach the reader even if its panel task was cancelled.
        return try await facade.reverseChapterList(bookUrl: snapshot.bookURL)
    }

    private func requireFacade() throws -> ReaderFacade {
        guard let facade = facade() else {
            throw NSError(domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable])
        }
        return facade
    }
}
