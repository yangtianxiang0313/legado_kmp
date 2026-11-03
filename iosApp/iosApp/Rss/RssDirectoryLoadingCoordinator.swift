import shared
import UIKit

@MainActor
final class RssDirectoryLoadingCoordinator {
    private let screen: RssScreenAdapter
    private var requestID: UUID?
    private var task: Task<Void, Never>?

    var isLoading: Bool { task != nil }

    init(screen: RssScreenAdapter) {
        self.screen = screen
    }

    deinit { task?.cancel() }

    func cancel() {
        requestID = nil
        task?.cancel()
        task = nil
    }

    func load(
        source: RssSource, sort: (name: String, url: String), requestURL: String, page: Int32, showSaved: Bool,
        onSaved: @escaping ([RssArticle]) -> Void,
        onSuccess: @escaping (RssDirectoryResult) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        cancel()
        let id = UUID()
        requestID = id
        task = Task { @MainActor [weak self, screen] in
            defer {
                if self?.requestID == id { self?.task = nil; self?.requestID = nil }
            }
            do {
                if showSaved {
                    do {
                        let saved = try await screen.cachedArticles(
                            source: source, sortName: sort.name, sortURL: sort.url)
                        try Task.checkCancellation()
                        guard self?.requestID == id else { return }
                        if !saved.isEmpty { onSaved(saved) }
                    } catch {
                        try Task.checkCancellation()
                        // An unavailable local snapshot must not prevent a fresh network request.
                    }
                }
                try Task.checkCancellation()
                let result = try await screen.loadDirectoryPage(
                    source: source, sortName: sort.name, requestURL: requestURL, categoryURL: sort.url, page: page)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                self.requestID = nil
                self.task = nil
                onSuccess(result)
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.requestID = nil
                self.task = nil
                onFailure(error)
            }
        }
    }
}
