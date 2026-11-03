import Foundation
import shared

final class RssScreenAdapter {
    private let bindings = ScreenBindingController(owner: "RssScreen")
    private var facade: RssFacade?
    private var directory: RssDirectoryFacade?
    private var bindingID: UUID?
    private var lastFavoritesSignature: String?
    private(set) var currentFavorites: [RssStar] = []
    private(set) var hasFavoritesSnapshot = false
    private(set) var currentReadRecords: [RssReadRecord] = []
    private(set) var hasReadRecordsSnapshot = false
    private(set) var readRecordsRevision: UInt64 = 0

    var onSourcesChange: (([RssSource]) -> Void)?
    var onFavoritesChange: (([RssStar]) -> Void)?
    var onReadRecordsChange: (([RssReadRecord]) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        unbind()
        hasFavoritesSnapshot = false
        lastFavoritesSignature = nil
        facade = nil
        directory = nil
        let id = UUID()
        bindingID = id

        switch SharedRuntime.rssFacade() {
        case .success(let facade):
            self.facade = facade
            do {
                directory = try RssDirectoryFacade.companion.create()
            } catch {
                self.facade = nil
                return .failure(
                    SharedRuntimeError(
                        operation: "RssDirectoryFacade.create", message: L10n.RSS.unavailable, underlying: error))
            }
            bindings.bind(
                facade.watchSources { [weak self] sources in
                    DispatchQueue.main.async {
                        guard let self, self.bindingID == id else { return }
                        self.handleSources(sources)
                    }
                })
            bindings.bind(
                facade.watchFavorites { [weak self] favorites in
                    DispatchQueue.main.async {
                        guard let self, self.bindingID == id else { return }
                        self.handleFavorites(favorites)
                    }
                })
            if let directory {
                bindings.bind(
                    directory.watchReadRecords { [weak self] records in
                        DispatchQueue.main.async {
                            guard let self, self.bindingID == id else { return }
                            self.handleReadRecords(records)
                        }
                    })
            }
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindingID = nil
        bindings.cancelAll()
        currentReadRecords = []
        hasReadRecordsSnapshot = false
        readRecordsRevision &+= 1
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

    func loadArticles(sortName: String, sortUrl: String, source: RssSource, page: Int32) async throws
        -> RssArticlesPayload
    {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadArticlesAsync(sortName: sortName, sortUrl: sortUrl, source: source, page: page)
    }

    func cachedSorts(source: RssSource) async throws -> [(name: String, url: String)] {
        guard let facade else { throw runtimeNotReadyError() }
        let pairs: [KotlinPair<NSString, NSString>] = try await SharedAsync.value {
            facade.cachedSorts(source: source, completionHandler: $0)
        }
        return pairs.map { (name: $0.first as String? ?? "", url: $0.second as String? ?? "") }
    }

    func cachedArticles(source: RssSource, sortName: String, sortURL: String) async throws -> [RssArticle] {
        guard let directory else { throw runtimeNotReadyError() }
        return try await SharedAsync.value {
            directory.cachedArticles(source: source, sortName: sortName, sortUrl: sortURL, completionHandler: $0)
        }
    }

    func loadDirectoryPage(
        source: RssSource, sortName: String, requestURL: String, categoryURL: String, page: Int32
    ) async throws -> RssDirectoryResult {
        guard let directory else { throw runtimeNotReadyError() }
        return try await SharedAsync.value {
            directory.loadArticles(
                source: source, sortName: sortName, sortUrl: requestURL, categoryUrl: categoryURL, page: page,
                completionHandler: $0)
        }
    }

    func markRead(article: RssArticle) async throws {
        guard let directory else { throw runtimeNotReadyError() }
        try await SharedAsync.void { directory.markRead(article: article, completionHandler: $0) }
    }

    func readRecords() async throws -> [RssReadRecord] {
        guard let directory else { throw runtimeNotReadyError() }
        return try await SharedAsync.value { directory.readRecords(completionHandler: $0) }
    }

    func clearArticles(source: RssSource) async throws {
        guard let directory else { throw runtimeNotReadyError() }
        try await SharedAsync.void { directory.clearArticles(source: source, completionHandler: $0) }
    }

    func loadContent(article: RssArticle, source: RssSource) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadContentAsync(article: article, source: source)
    }

    func loadSource(sourceURL: String) async throws -> RssSource? {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getSourceAsync(sourceUrl: sourceURL)
    }

    func setArticleStyle(sourceURL: String, style: Int32) async throws -> RssSource? {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.optionalValue { completion in
            facade.setArticleStyle(sourceUrl: sourceURL, articleStyle: style, completionHandler: completion)
        }
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

    private func handleReadRecords(_ records: [RssReadRecord]) {
        let changed =
            !hasReadRecordsSnapshot || records.count != currentReadRecords.count
            || zip(records, currentReadRecords).contains { lhs, rhs in
                !lhs.record.utf8.elementsEqual(rhs.record.utf8) || lhs.title != rhs.title
                    || lhs.readTime != rhs.readTime || lhs.read != rhs.read
            }
        currentReadRecords = records
        hasReadRecordsSnapshot = true
        guard changed else { return }
        readRecordsRevision &+= 1
        onReadRecordsChange?(records)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.RSS.unavailable]
        )
    }
}
