import Foundation
import shared

enum SearchScopeSelection: Equatable {
    case allEnabled
    case group(String)
    case groups([String])
    case source(url: String, name: String)

    var displayName: String {
        switch self {
        case .allEnabled:
            return L10n.Search.scopeAllEnabled
        case let .group(group):
            return group
        case let .groups(groupList):
            return groupList.joined(separator: ",")
        case let .source(_, name):
            return name
        }
    }

    var summaryText: String {
        switch self {
        case .allEnabled:
            return L10n.Search.scopeAllEnabled
        case let .group(group):
            return "\(L10n.Search.scopeGroupPrefix)：\(group)"
        case let .groups(groupList):
            return "\(L10n.Search.scopeMultiGroupPrefix)：\(groupList.joined(separator: "、"))"
        case let .source(_, name):
            return "\(L10n.Search.scopeSourcePrefix)：\(name)"
        }
    }
}

final class SearchScreenAdapter {
    private let bindings = ScreenBindingController(owner: "SearchScreen")
    private var searchFacade: SearchFacade?
    private var settingsFacade: SettingsFacade?
    private var lastSourcesSignature: String?
    private var lastGroupsSignature: String?
    private var lastSessionSignature: String?
    private(set) var precisionSearch: Bool = false
    private var bookshelfFacade: BookshelfFacade?

    var onSourcesChange: (([BookSource]) -> Void)?
    var onGroupsChange: (([String]) -> Void)?
    var onSearchSessionChange: ((SearchSessionState) -> Void)?
    var onPrecisionSearchChange: ((Bool) -> Void)?
    var onBookshelfKeysChange: ((Set<String>) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()
        searchFacade = nil
        settingsFacade = nil
        bookshelfFacade = nil
        lastSourcesSignature = nil
        lastGroupsSignature = nil
        lastSessionSignature = nil

        switch SharedRuntime.searchFacade() {
        case let .success(searchFacade):
            self.searchFacade = searchFacade
            bindings.bind(searchFacade.watchEnabledSources { [weak self] sources in
                DispatchQueue.main.async {
                    self?.handleSources(sources)
                }
            })
            bindings.bind(searchFacade.watchEnabledGroups { [weak self] groups in
                DispatchQueue.main.async {
                    self?.handleGroups(groups)
                }
            })
            bindings.bind(searchFacade.watchSearchSession { [weak self] session in
                DispatchQueue.main.async {
                    self?.handleSession(session)
                }
            })
            if case let .success(sf) = SharedRuntime.settingsFacade() {
                settingsFacade = sf
                bindings.bind(sf.watchRuntimeConfig { [weak self] config in
                    DispatchQueue.main.async {
                        let newValue = config.precisionSearch
                        if self?.precisionSearch != newValue {
                            self?.precisionSearch = newValue
                            self?.onPrecisionSearchChange?(newValue)
                        }
                    }
                })
            }
            if case let .success(bookshelfFacade) = SharedRuntime.bookshelfFacade() {
                self.bookshelfFacade = bookshelfFacade
                bindings.bind(bookshelfFacade.watchBookshelfKeys { [weak self] keys in
                    DispatchQueue.main.async {
                        self?.onBookshelfKeysChange?(keys)
                    }
                })
            }
            return .success(())
        case let .failure(error):
            return .failure(error)
        }
    }

    func startSearch(scope: SearchScopeSelection, keyword: String) async throws {
        guard let searchFacade else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Search.unavailable]
            )
        }
        try await searchFacade.startSearchAsync(searchScope: scope.toSharedScope(), keyword: keyword)
    }

    func cancelSearch() {
        searchFacade?.cancelSearch()
    }

    func loadSearchHistory(keyword: String) async throws -> [SearchKeyword] {
        guard let searchFacade else {
            return []
        }
        return try await searchFacade.loadSearchHistoryAsync(keyword: keyword)
    }

    func clearSearchHistory() async throws {
        guard let searchFacade else { return }
        try await searchFacade.clearSearchHistoryAsync()
    }

    func deleteSearchHistory(word: String) async throws {
        guard let searchFacade else { return }
        try await searchFacade.deleteSearchHistoryAsync(word: word)
    }

    func loadNextPage() async throws {
        guard let searchFacade else { return }
        try await searchFacade.loadNextPageAsync()
    }

    func pauseSearch() async throws {
        guard let searchFacade else { return }
        try await searchFacade.pauseSearchAsync()
    }

    func resumeSearch() async throws {
        guard let searchFacade else { return }
        try await searchFacade.resumeSearchAsync()
    }

    func togglePrecisionSearch() async throws {
        guard let settingsFacade else { return }
        try await settingsFacade.setPrecisionSearchAsync(enabled: !precisionSearch)
    }

    func searchBookshelf(query: String) async throws -> [Book] {
        guard let bookshelfFacade else { return [] }
        return try await bookshelfFacade.searchBooksAsync(query: query)
    }

    func unbind() {
        bindings.cancelAll()
    }

    private func handleSources(_ sources: [BookSource]) {
        let sortedSources = sources.sorted { lhs, rhs in
            lhs.bookSourceName.localizedCompare(rhs.bookSourceName) == .orderedAscending
        }
        let signature = sortedSources.map {
            "\($0.bookSourceUrl)#\($0.bookSourceName)#\($0.enabled ? 1 : 0)#\($0.bookSourceGroup ?? "")"
        }.joined(separator: "|")
        guard signature != lastSourcesSignature else { return }
        lastSourcesSignature = signature
        onSourcesChange?(sortedSources)
    }

    private func handleGroups(_ groups: [String]) {
        let sortedGroups = groups.sorted()
        let signature = sortedGroups.joined(separator: "|")
        guard signature != lastGroupsSignature else { return }
        lastGroupsSignature = signature
        onGroupsChange?(sortedGroups)
    }

    private func handleSession(_ session: SearchSessionState) {
        let signature = [
            session.keyword,
            String(session.page),
            session.isRunning ? "1" : "0",
            session.isPaused ? "1" : "0",
            String(session.sourceTotalCount),
            String(session.completedSourceCount),
            String(session.failedSourceCount),
            session.error ?? "",
            session.results.map { "\($0.bookUrl)#\($0.name)#\($0.latestChapterTitle ?? "")" }.joined(separator: "|"),
        ].joined(separator: "::")
        guard signature != lastSessionSignature else { return }
        lastSessionSignature = signature
        onSearchSessionChange?(session)
    }
}

extension SearchScopeSelection {
    func toSharedScope() -> SearchScope {
        switch self {
        case .allEnabled:
            return SearchScopeAllEnabled()
        case let .group(group):
            return SearchScopeGroup(group: group)
        case let .groups(groupList):
            return SearchScopeGroup(group: groupList.joined(separator: ","))
        case let .source(url, _):
            return SearchScopeSource(sourceUrl: url)
        }
    }
}
