import Foundation
import shared

typealias SourceManagementViewController = AndroidReplicaSourceManagementViewController

extension BookSource {
    var hasManagementLoginURL: Bool {
        if !(loginUi?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { return true }
        // BookSourcePart's SQLite projection trims ASCII spaces, not arbitrary whitespace.
        return !(loginUrl?.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty ?? true)
    }

    func hasSameManagementContent(as other: BookSource) -> Bool {
        // BookSource.equals compares only URLs. Every field can affect ordering, filters or a row command.
        bookSourceUrl == other.bookSourceUrl && bookSourceName == other.bookSourceName
            && bookSourceGroup == other.bookSourceGroup && bookSourceType == other.bookSourceType
            && bookUrlPattern == other.bookUrlPattern && customOrder == other.customOrder
            && enabled == other.enabled && enabledExplore == other.enabledExplore
            && jsLib == other.jsLib && enabledCookieJar == other.enabledCookieJar
            && concurrentRate == other.concurrentRate && header == other.header
            && loginUrl == other.loginUrl && loginUi == other.loginUi && loginCheckJs == other.loginCheckJs
            && coverDecodeJs == other.coverDecodeJs && bookSourceComment == other.bookSourceComment
            && variableComment == other.variableComment && lastUpdateTime == other.lastUpdateTime
            && respondTime == other.respondTime && weight == other.weight
            && exploreUrl == other.exploreUrl && exploreScreen == other.exploreScreen
            && searchUrl == other.searchUrl && ruleExplore == other.ruleExplore && ruleSearch == other.ruleSearch
            && ruleBookInfo == other.ruleBookInfo && ruleToc == other.ruleToc
            && ruleContent == other.ruleContent && ruleReview == other.ruleReview
    }

    var hasSourceCheckState: Bool {
        let hasInvalidGroup = (bookSourceGroup ?? "")
            .split(whereSeparator: { ",;，；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { $0.contains("失效") || $0 == "校验超时" }
        let hasErrorComment = (bookSourceComment ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("// Error: ") }
        return hasInvalidGroup || hasErrorComment
    }

    func copyForCustomOrder(_ customOrder: Int32) -> BookSource {
        doCopy(
            bookSourceUrl: bookSourceUrl,
            bookSourceName: bookSourceName,
            bookSourceGroup: bookSourceGroup,
            bookSourceType: bookSourceType,
            bookUrlPattern: bookUrlPattern,
            customOrder: customOrder,
            enabled: enabled,
            enabledExplore: enabledExplore,
            jsLib: jsLib,
            enabledCookieJar: enabledCookieJar,
            concurrentRate: concurrentRate,
            header: header,
            loginUrl: loginUrl,
            loginUi: loginUi,
            loginCheckJs: loginCheckJs,
            coverDecodeJs: coverDecodeJs,
            bookSourceComment: bookSourceComment,
            variableComment: variableComment,
            lastUpdateTime: lastUpdateTime,
            respondTime: respondTime,
            weight: weight,
            exploreUrl: exploreUrl,
            exploreScreen: exploreScreen,
            ruleExplore: ruleExplore,
            searchUrl: searchUrl,
            ruleSearch: ruleSearch,
            ruleBookInfo: ruleBookInfo,
            ruleToc: ruleToc,
            ruleContent: ruleContent,
            ruleReview: ruleReview
        )
    }
}

enum BookSourceEditMode {
    case create
    case edit(String)

    var existingSourceURL: String? {
        switch self {
        case .create: return nil
        case .edit(let sourceURL): return sourceURL
        }
    }
}

protocol BookSourceEditingProviding: AnyObject {
    func exportSource(sourceUrl: String) async throws -> String
    func parseSourcePayload(payload: String) async throws -> [BookSource]
    func saveSource(source: BookSource) async throws -> BookSource
    func deleteSource(sourceUrl: String) async throws
    func clearSourceCookies(sourceUrl: String) async throws
    func executeLogin(sourceUrl: String) async throws -> SourceLoginResult
    func completeEditorSourcePayload(payload: String, enabled: Bool) throws -> String
    func getSourceVariable(sourceUrl: String) async throws -> String?
    func setSourceVariable(sourceUrl: String, value: String) async throws
}

final class SourceManagementScreenAdapter: BookSourceEditingProviding {
    private let bindings = ScreenBindingController(owner: "SourceManagementScreen")
    private var facade: SourceManagementFacade?
    private var runtimeFacade: RuntimeFacade?
    private var lastSources: [BookSource]?

    var onSourcesChange: (([BookSource]) -> Void)?
    var onGroupsChange: (([String]) -> Void)?
    var onSourceCheckStateChange: ((ServiceState) -> Void)?

    deinit {
        bindings.cancelAll()
    }

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()
        lastSources = nil
        runtimeFacade = nil

        switch SharedRuntime.sourceManagementFacade() {
        case .success(let facade):
            self.facade = facade
            if case .success(let runtimeFacade) = SharedRuntime.runtimeFacade() {
                self.runtimeFacade = runtimeFacade
                bindings.bind(
                    runtimeFacade.watchSourceCheckState { [weak self] state in
                        DispatchQueue.main.async {
                            self?.onSourceCheckStateChange?(state)
                        }
                    })
            }
            bindings.bind(
                facade.watchSources { [weak self] sources in
                    DispatchQueue.main.async {
                        self?.handleSources(sources)
                    }
                })
            bindings.bind(
                facade.watchGroups { [weak self] groups in
                    DispatchQueue.main.async {
                        self?.onGroupsChange?(groups)
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

    func loadSources() async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getAllSourcesAsync()
    }

    func importBundledDefaultSources(payload: String) async throws -> SourceImportResult {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.importSourcesIfEmptyAsync(payload: payload)
    }

    func getSource(sourceUrl: String) async throws -> BookSource? {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getSourceAsync(sourceUrl: sourceUrl)
    }

    // Visibility may use the watched full-source snapshot; commands must still re-fetch their click-time URL.
    func cachedSource(sourceUrl: String) -> BookSource? {
        lastSources?.first { $0.bookSourceUrl == sourceUrl }
    }

    func saveSource(source: BookSource) async throws -> BookSource {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.saveSourceAsync(source: source)
    }

    func parseSourcePayload(payload: String) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.parseSourcePayloadAsync(payload: payload)
    }

    func completeEditorSourcePayload(payload: String, enabled: Bool) throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try facade.completeEditorSourcePayload(payload: payload, enabled: enabled)
    }

    func getSourceVariable(sourceUrl: String) async throws -> String? {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.optionalValue { completion in
            facade.getSourceVariable(sourceUrl: sourceUrl, completionHandler: completion)
        }
    }

    func setSourceVariable(sourceUrl: String, value: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void { completion in
            facade.setSourceVariable(sourceUrl: sourceUrl, value: value, completionHandler: completion)
        }
    }

    func setEnabled(sourceUrl: String, enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setEnabledAsync(sourceUrl: sourceUrl, enabled: enabled)
    }

    func setEnabled(sourceUrls: [String], enabled: Bool) async throws {
        for sourceUrl in sourceUrls {
            try await setEnabled(sourceUrl: sourceUrl, enabled: enabled)
        }
    }

    func setEnabledExplore(sourceUrl: String, enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setEnabledExploreAsync(sourceUrl: sourceUrl, enabled: enabled)
    }

    func setEnabledExplore(sourceUrls: [String], enabled: Bool) async throws {
        for sourceUrl in sourceUrls {
            try await setEnabledExplore(sourceUrl: sourceUrl, enabled: enabled)
        }
    }

    func deleteSource(sourceUrl: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.deleteSourceAsync(sourceUrl: sourceUrl)
    }

    func deleteSources(sourceUrls: [String]) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.deleteSourcesAsync(sourceUrls: sourceUrls)
    }

    func addSourcesToGroup(sourceUrls: [String], group: String) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.addSourcesToGroupAsync(sourceUrls: sourceUrls, group: group)
    }

    func addGroup(group: String) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.addGroupAsync(group: group)
    }

    func renameGroup(oldGroup: String, newGroup: String?) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.renameGroupAsync(oldGroup: oldGroup, newGroup: newGroup)
    }

    func deleteGroup(group: String) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.deleteGroupAsync(group: group)
    }

    func removeSourcesFromGroup(sourceUrls: [String], group: String) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.removeSourcesFromGroupAsync(sourceUrls: sourceUrls, group: group)
    }

    func clearSourceCheckState(sourceUrls: [String]) async throws -> [BookSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.value { completion in
            facade.clearSourceCheckState(sourceUrls: sourceUrls, completionHandler: completion)
        }
    }

    func updateSourceOrders(sources: [BookSource]) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.updateSourceOrdersAsync(sources: sources)
    }

    func updateSourceOrder(sourceUrl: String, order: Int32) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.updateSourceOrderAsync(sourceUrl: sourceUrl, order: order)
    }

    func exportSources(sourceUrls: [String]) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.exportSourcesAsync(sourceUrls: sourceUrls)
    }

    func exportSource(sourceUrl: String) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.exportSourceAsync(sourceUrl: sourceUrl)
    }

    func executeLogin(sourceUrl: String) async throws -> SourceLoginResult {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.executeLoginAsync(sourceUrl: sourceUrl)
    }

    func clearSourceCookies(sourceUrl: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.clearSourceCookiesAsync(sourceUrl: sourceUrl)
    }

    func startSourceCheck() async throws {
        guard let runtimeFacade else { throw runtimeNotReadyError() }
        try await runtimeFacade.startSourceCheckAsync()
    }

    func startSourceCheck(sourceURLs: [String], config: SourceCheckConfig) async throws {
        guard let runtimeFacade else { throw runtimeNotReadyError() }
        try await SharedAsync.void { completion in
            runtimeFacade.startSelectedSourceCheck(sourceUrls: sourceURLs, config: config, completionHandler: completion)
        }
    }

    func pauseSourceCheck() async throws {
        guard let runtimeFacade else { throw runtimeNotReadyError() }
        try await runtimeFacade.pauseSourceCheckAsync()
    }

    func resumeSourceCheck() async throws {
        guard let runtimeFacade else { throw runtimeNotReadyError() }
        try await runtimeFacade.resumeSourceCheckAsync()
    }

    func cancelSourceCheck() async throws {
        guard let runtimeFacade else { throw runtimeNotReadyError() }
        try await runtimeFacade.cancelSourceCheckAsync()
    }

    func importSources(payload: String) async throws -> SourceImportResult {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.importSourcesAsync(payload: payload)
    }

    func importSourcesByUrl(url: String) async throws -> SourceImportResult {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.importSourcesByUrlAsync(url: url)
    }

    private func handleSources(_ sources: [BookSource]) {
        if let lastSources, lastSources.count == sources.count,
            zip(lastSources, sources).allSatisfy({ $0.0.hasSameManagementContent(as: $0.1) })
        {
            return
        }
        lastSources = sources
        onSourcesChange?(sources)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.SourceManagement.unavailable]
        )
    }
}
