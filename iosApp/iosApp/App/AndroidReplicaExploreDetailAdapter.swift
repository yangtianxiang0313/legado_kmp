import Foundation
import shared

final class AndroidReplicaExploreDetailAdapter {
    private let bindings = ScreenBindingController(owner: "AndroidReplicaExploreDetail")
    private var facade: DiscoveryFacade?
    private var bookshelfFacade: BookshelfFacade?
    private var bindGeneration = UUID()

    var onBookshelfKeysChange: ((Set<String>) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        unbind()
        let generation = bindGeneration
        switch SharedRuntime.discoveryFacade() {
        case .success(let facade):
            self.facade = facade
            if case .success(let bookshelfFacade) = SharedRuntime.bookshelfFacade() {
                self.bookshelfFacade = bookshelfFacade
                bindings.bind(
                    bookshelfFacade.watchBookshelfKeys { [weak self] keys in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.bindGeneration == generation else { return }
                            self.onBookshelfKeysChange?(keys)
                        }
                    })
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindGeneration = UUID()
        bindings.cancelAll()
        facade = nil
        bookshelfFacade = nil
    }

    func loadExploreKinds(sourceURL: String, forceRefresh: Bool) async throws -> [ExploreKind] {
        try Task.checkCancellation()
        guard let facade else { throw runtimeNotReadyError() }
        let kinds = try await facade.loadExploreKindsAsync(sourceUrl: sourceURL, forceRefresh: forceRefresh)
        // The shared completion bridge has no cancellation handle; discard cancelled results here.
        try Task.checkCancellation()
        return kinds
    }

    func loadExploreBooks(sourceURL: String, exploreURL: String, page: Int32) async throws -> [SearchBook] {
        try Task.checkCancellation()
        guard let facade else { throw runtimeNotReadyError() }
        let books = try await facade.loadExploreBooksAsync(sourceUrl: sourceURL, exploreUrl: exploreURL, page: page)
        try Task.checkCancellation()
        return books
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios", code: -1, userInfo: [NSLocalizedDescriptionKey: L10n.Discovery.unavailable])
    }
}
