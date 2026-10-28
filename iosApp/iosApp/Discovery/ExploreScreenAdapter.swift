import Foundation
import shared

final class ExploreScreenAdapter {
    private let bindings = ScreenBindingController(owner: "AndroidReplicaDiscovery")
    private var facade: DiscoveryFacade?
    private var generation = UUID()
    private var previous: [BookSourcePart]?
    var onSourcesChange: (([BookSourcePart]) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        unbind()
        let generation = self.generation
        switch SharedRuntime.discoveryFacade() {
        case .success(let facade):
            self.facade = facade
            bindings.bind(
                facade.watchEnabledSourceParts { [weak self] sources in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == generation else { return }
                        let ordered = ExploreSourceListPolicy.apply(sources, query: "")
                        guard self.previous != ordered else { return }
                        self.previous = ordered
                        self.onSourcesChange?(ordered)
                    }
                })
            return .success(())
        case .failure(let error): return .failure(error)
        }
    }

    func loadKinds(sourceURL: String, forceRefresh: Bool) async throws -> [ExploreKind] {
        try Task.checkCancellation()
        guard let facade else { throw NSError(domain: "Discovery unavailable", code: 1) }
        let kinds = try await facade.loadExploreKindsAsync(sourceUrl: sourceURL, forceRefresh: forceRefresh)
        try Task.checkCancellation()
        return kinds
    }

    func clearKinds(sourceURL: String) async throws {
        guard let facade else { throw NSError(domain: "Discovery unavailable", code: 1) }
        try await SharedAsync.void { completion in
            facade.clearExploreKinds(sourceUrl: sourceURL, completionHandler: completion)
        }
    }

    func unbind() {
        generation = UUID()
        previous = nil
        bindings.cancelAll()
        facade = nil
    }
}
