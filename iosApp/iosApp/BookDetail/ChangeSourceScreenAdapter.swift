import Foundation
import shared

enum ChangeSourceOption: String, CaseIterable {
    case checkAuthor, loadWordCount, loadInfo, loadToc

    var title: String {
        switch self {
        case .checkAuthor: return "校验作者"
        case .loadWordCount: return "加载字数"
        case .loadInfo: return "加载详情"
        case .loadToc: return "加载目录"
        }
    }

    func value(in config: AppRuntimeConfig) -> Bool {
        switch self {
        case .checkAuthor: return config.changeSourceCheckAuthor
        case .loadWordCount: return config.changeSourceLoadWordCount
        case .loadInfo: return config.changeSourceLoadInfo
        case .loadToc: return config.changeSourceLoadToc
        }
    }
}

struct ChangeSourceScreenState {
    let config: AppRuntimeConfig
    let sources: [BookSource]

    var groups: [String] {
        var seen = Set<String>()
        return sources.filter(\.enabled).flatMap {
            ($0.bookSourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    var sourceOrders: [String: Int] {
        Dictionary(sources.map { ($0.bookSourceUrl, Int($0.customOrder)) }, uniquingKeysWith: { _, last in last })
    }

    func includes(_ candidate: BookSourceChangeCandidate) -> Bool {
        guard let source = sources.first(where: { $0.bookSourceUrl == candidate.sourceUrl }), source.enabled else {
            return false
        }
        guard !config.searchGroup.isEmpty else { return true }
        return (source.bookSourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.contains(config.searchGroup)
    }
}

@MainActor
final class ChangeSourceScreenAdapter {
    private let bindings = FlowSubscriptionStore()
    private var settings: SettingsFacade?
    private var sourcesFacade: SourceManagementFacade?
    private var config: AppRuntimeConfig?
    private var sources: [BookSource]?
    private var generation = UUID()
    var onState: ((ChangeSourceScreenState) -> Void)?

    func bind() throws {
        unbind()
        let settings = try SharedRuntime.settingsFacade().get()
        let sourcesFacade = try SharedRuntime.sourceManagementFacade().get()
        self.settings = settings
        self.sourcesFacade = sourcesFacade
        let id = generation
        bindings.store(
            settings.watchRuntimeConfig { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.config = value
                    self.emit()
                }
            })
        bindings.store(
            sourcesFacade.watchSources { [weak self] value in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.sources = value
                    self.emit()
                }
            })
    }

    func unbind() {
        generation = UUID()
        bindings.cancelAll()
        config = nil
        sources = nil
    }

    func set(_ option: ChangeSourceOption, enabled: Bool) async throws {
        let facade = try settings ?? SharedRuntime.settingsFacade().get()
        try await SharedAsync.void { completion in
            switch option {
            case .checkAuthor: facade.setChangeSourceCheckAuthor(enabled: enabled, completionHandler: completion)
            case .loadWordCount: facade.setChangeSourceLoadWordCount(enabled: enabled, completionHandler: completion)
            case .loadInfo: facade.setChangeSourceLoadInfo(enabled: enabled, completionHandler: completion)
            case .loadToc: facade.setChangeSourceLoadToc(enabled: enabled, completionHandler: completion)
            }
        }
    }

    func setGroup(_ group: String) async throws {
        try await SearchScopePreferencesClient().save(group.isEmpty ? .allEnabled : .group(group))
    }

    func move(_ candidate: BookSourceChangeCandidate, toTop: Bool) async throws {
        let facade = try sourcesFacade ?? SharedRuntime.sourceManagementFacade().get()
        let sources = try await facade.getAllSourcesAsync()
        guard sources.contains(where: { $0.bookSourceUrl == candidate.sourceUrl }) else { throw missingSource() }
        let edge = toTop ? sources.map(\.customOrder).min() : sources.map(\.customOrder).max()
        let (order, overflow) = (edge ?? 0).addingReportingOverflow(toTop ? -1 : 1)
        guard !overflow else {
            throw NSError(domain: "io.legado.sourceChange", code: 2, userInfo: [NSLocalizedDescriptionKey: "书源排序已到边界"])
        }
        try await facade.updateSourceOrderAsync(sourceUrl: candidate.sourceUrl, order: order)
    }

    func disable(_ candidate: BookSourceChangeCandidate) async throws {
        let facade = try sourcesFacade ?? SharedRuntime.sourceManagementFacade().get()
        try await facade.setEnabledAsync(sourceUrl: candidate.sourceUrl, enabled: false)
    }

    func delete(_ candidate: BookSourceChangeCandidate) async throws {
        let facade = try sourcesFacade ?? SharedRuntime.sourceManagementFacade().get()
        guard try await facade.getSourceAsync(sourceUrl: candidate.sourceUrl) != nil else { throw missingSource() }
        try await facade.deleteSourceAsync(sourceUrl: candidate.sourceUrl)
    }

    private func emit() {
        guard let config, let sources else { return }
        onState?(.init(config: config, sources: sources))
    }

    private func missingSource() -> NSError {
        NSError(domain: "io.legado.sourceChange", code: 1, userInfo: [NSLocalizedDescriptionKey: "书源不存在"])
    }
}
