import Foundation
import shared

final class RssScreenAdapter {
    private let bindings = ScreenBindingController(owner: "RssScreen")
    private var facade: RssFacade?
    private var lastFavoritesSignature: String?
    private(set) var currentFavorites: [RssStar] = []
    private(set) var hasFavoritesSnapshot = false

    var onSourcesChange: (([RssSource]) -> Void)?
    var onFavoritesChange: (([RssStar]) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        hasFavoritesSnapshot = false
        bindings.cancelAll()
        lastFavoritesSignature = nil

        switch SharedRuntime.rssFacade() {
        case .success(let facade):
            self.facade = facade
            bindings.bind(
                facade.watchSources { [weak self] sources in
                    DispatchQueue.main.async {
                        self?.handleSources(sources)
                    }
                })
            bindings.bind(
                facade.watchFavorites { [weak self] favorites in
                    DispatchQueue.main.async {
                        self?.handleFavorites(favorites)
                    }
                })
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindings.cancelAll()
    }

    func loadSorts(source: RssSource, forceRefresh: Bool) async throws -> [(name: String, url: String)] {
        guard let facade else { throw runtimeNotReadyError() }
        let pairs = try await facade.loadSortsAsync(source: source, forceRefresh: forceRefresh)
        return pairs.map { pair in
            (
                name: pair.first as String? ?? "",
                url: pair.second as String? ?? ""
            )
        }
    }

    func loadArticles(sortName: String, sortUrl: String, source: RssSource, page: Int32) async throws -> RssArticlesPayload {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadArticlesAsync(sortName: sortName, sortUrl: sortUrl, source: source, page: page)
    }

    func loadContent(article: RssArticle, source: RssSource) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadContentAsync(article: article, source: source)
    }

    func loadSource(sourceURL: String) async throws -> RssSource? {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getSourceAsync(sourceUrl: sourceURL)
    }

    func toggleFavorite(article: RssArticle) async throws -> Bool {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.toggleFavoriteAsync(article: article)
    }

    func clearReadRecords() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.clearReadRecordsAsync()
    }

    func updateFavorite(star: RssStar) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.updateFavoriteAsync(star: star)
    }

    func loadAllSources() async throws -> [RssSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getAllSourcesAsync()
    }

    func addSources(sourceUrls: [String], toGroup group: String) async throws -> Int32 {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.addRssSourcesToGroupAsync(sourceUrls: sourceUrls, group: group)
    }

    func renameGroup(oldName: String, newName: String) async throws -> Int32 {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.renameRssSourceGroupAsync(oldName: oldName, newName: newName)
    }

    func deleteGroup(name: String) async throws -> Int32 {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.deleteRssSourceGroupAsync(group: name)
    }

    func watchFavoriteGroups(onUpdate: @escaping ([String]) -> Void) {
        guard let facade else { return }
        bindings.bind(
            facade.watchFavoriteGroups { groups in
                DispatchQueue.main.async {
                    onUpdate(groups)
                }
            })
    }

    func watchFavoritesByGroup(group: String, onUpdate: @escaping ([RssStar]) -> Void) {
        guard let facade else { return }
        bindings.bind(
            facade.watchFavoritesByGroup(group: group) { favorites in
                DispatchQueue.main.async {
                    onUpdate(favorites)
                }
            })
    }

    private func handleSources(_ sources: [RssSource]) {
        let sorted = sources.sorted { $0.sourceName.localizedCompare($1.sourceName) == .orderedAscending }
        onSourcesChange?(sorted)
    }

    private func handleFavorites(_ favorites: [RssStar]) {
        let sorted = favorites.sorted { $0.starTime > $1.starTime }
        currentFavorites = sorted
        hasFavoritesSnapshot = true
        let signature = sorted.map { "\($0.origin)#\($0.link)#\($0.title)#\($0.group)" }.joined(separator: "|")
        guard signature != lastFavoritesSignature else { return }
        lastFavoritesSignature = signature
        onFavoritesChange?(sorted)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.RSS.unavailable]
        )
    }
}
