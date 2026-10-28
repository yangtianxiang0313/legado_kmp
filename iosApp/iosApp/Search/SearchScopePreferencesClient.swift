import Foundation
import shared

enum SearchScopePreferencesCodec {
    struct Source: Equatable {
        let url: String
        let name: String
        let groups: String?
        let enabled: Bool
    }

    static func encode(_ scope: SearchScopeSelection) -> String {
        switch scope {
        case .allEnabled:
            return ""
        case .group(let group):
            return group
        case .groups(let groups):
            return groups.joined(separator: ",")
        case .source(let url, let name):
            return "\(name.replacingOccurrences(of: ":", with: ""))::\(url)"
        }
    }

    static func decode(_ value: String, sources: [Source]) -> SearchScopeSelection {
        guard !value.isEmpty else { return .allEnabled }
        if let separator = value.range(of: "::") {
            // Split only the first delimiter; URLs can contain colons, commas and IPv6.
            let url = String(value[separator.upperBound...])
            guard !url.isEmpty, let source = sources.first(where: { $0.url == url }) else {
                return .allEnabled
            }
            return .source(url: source.url, name: source.name)
        }

        let availableGroups = Set(enabledGroups(sources: sources))
        let groups = split(value, separators: CharacterSet(charactersIn: ","))
            .filter { availableGroups.contains($0) }
        switch groups.count {
        case 0: return .allEnabled
        case 1: return .group(groups[0])
        default: return .groups(groups)
        }
    }

    static func searchGroup(for value: String) -> String {
        guard !value.isEmpty, !value.contains("::"), !value.contains(",") else { return "" }
        return value
    }

    static func enabledGroups(sources: [Source]) -> [String] {
        Set(
            sources.filter(\.enabled).flatMap {
                split($0.groups ?? "", separators: CharacterSet(charactersIn: ",;\u{FF0C}\u{FF1B}"))
            }
        ).sorted()
    }

    static func snapshot(_ sources: [BookSource]) -> [Source] {
        sources.map {
            Source(url: $0.bookSourceUrl, name: $0.bookSourceName, groups: $0.bookSourceGroup, enabled: $0.enabled)
        }.sorted { $0.url < $1.url }
    }

    private static func split(_ value: String, separators: CharacterSet) -> [String] {
        value.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
final class SearchScopePreferencesClient {
    private var loadGeneration = UUID()
    private var observationGeneration = UUID()
    private var restoreTask: Task<Void, Never>?
    private var sourceSubscription: FlowSubscription?
    private var catalog: [SearchScopePreferencesCodec.Source]?
    private var persistenceIntent: UUID?
    var onSaveError: ((Error) -> Void)?

    var enabledGroups: [String] {
        SearchScopePreferencesCodec.enabledGroups(sources: catalog ?? [])
    }

    func normalized(_ scope: SearchScopeSelection) -> SearchScopeSelection {
        guard let catalog else { return scope }
        return SearchScopePreferencesCodec.decode(SearchScopePreferencesCodec.encode(scope), sources: catalog)
    }

    func restore(
        initialScope: SearchScopeSelection?,
        onLoaded: @escaping (SearchScopeSelection) throws -> Void,
        onSourcesChanged: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        cancelObservation()
        let generation = observationGeneration
        restoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scope = try await self.load(initialScope: initialScope)
                try Task.checkCancellation()
                guard self.observationGeneration == generation else { return }
                let facade = try SharedRuntime.sourceManagementFacade().get()
                self.sourceSubscription = facade.watchSources { [weak self] sources in
                    let snapshot = SearchScopePreferencesCodec.snapshot(sources)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.observationGeneration == generation, self.catalog != snapshot else {
                            return
                        }
                        self.catalog = snapshot
                        onSourcesChanged()
                    }
                }
                self.restoreTask = nil
                try onLoaded(scope)
            } catch {
                guard !Task.isCancelled, self.observationGeneration == generation else { return }
                if error is CancellationError {
                    self.restore(
                        initialScope: nil, onLoaded: onLoaded,
                        onSourcesChanged: onSourcesChanged, onFailure: onFailure)
                    return
                }
                self.restoreTask = nil
                self.cancelObservation()
                onFailure(error)
            }
        }
    }

    func cancelObservation() {
        observationGeneration = UUID()
        loadGeneration = UUID()
        restoreTask?.cancel()
        restoreTask = nil
        sourceSubscription?.cancel()
        sourceSubscription = nil
    }

    deinit {
        restoreTask?.cancel()
        sourceSubscription?.cancel()
    }

    /// A newer selection invalidates this result with CancellationError, never a late UI update.
    func load(initialScope: SearchScopeSelection? = nil) async throws -> SearchScopeSelection {
        try Task.checkCancellation()
        let generation = UUID()
        loadGeneration = generation
        if initialScope != nil {
            SearchScopePreferencesWrites.intent = UUID()
        }
        let intent = SearchScopePreferencesWrites.intent

        try await SearchScopePreferencesWrites.waitForPendingSave()
        try requireCurrentLoad(generation: generation, intent: intent)
        let settings = try SharedRuntime.settingsFacade().get()
        let runtime = try await SearchScopeRuntimeSnapshot.value(facade: settings)
        try requireCurrentLoad(generation: generation, intent: intent)
        let sourceFacade = try SharedRuntime.sourceManagementFacade().get()
        let localSources = try await sourceFacade.getAllSourcesAsync()
        try requireCurrentLoad(generation: generation, intent: intent)
        let snapshot = SearchScopePreferencesCodec.snapshot(localSources)

        let value = initialScope.map(SearchScopePreferencesCodec.encode) ?? runtime.searchScope
        let scope = SearchScopePreferencesCodec.decode(value, sources: snapshot)
        let normalizedValue = SearchScopePreferencesCodec.encode(scope)
        if initialScope != nil || normalizedValue != runtime.searchScope
            || SearchScopePreferencesCodec.searchGroup(for: normalizedValue) != runtime.searchGroup
        {
            let write = SearchScopePreferencesWrites.enqueue(normalizedValue)
            try await write.value
        }
        try requireCurrentLoad(generation: generation, intent: intent)
        catalog = snapshot
        persistenceIntent = intent
        return scope
    }

    func save(_ scope: SearchScopeSelection) async throws {
        try Task.checkCancellation()
        try await enqueueSave(scope).value
    }

    func enqueueSave(_ scope: SearchScopeSelection) -> Task<Void, Error> {
        SearchScopePreferencesWrites.intent = UUID()
        persistenceIntent = SearchScopePreferencesWrites.intent
        // Once queued, both Kotlin writes must finish even if the caller goes away.
        return SearchScopePreferencesWrites.enqueue(SearchScopePreferencesCodec.encode(scope))
    }

    func persist(_ scope: SearchScopeSelection, automatically: Bool = false) {
        // A covered search may repair its own scope, never overwrite another page's newer choice.
        if automatically, persistenceIntent != SearchScopePreferencesWrites.intent { return }
        let write = enqueueSave(scope)
        Task { @MainActor [weak self] in
            do {
                try await write.value
            } catch {
                self?.onSaveError?(error)
            }
        }
    }

    private func requireCurrentLoad(generation: UUID, intent: UUID) throws {
        try Task.checkCancellation()
        guard loadGeneration == generation, SearchScopePreferencesWrites.intent == intent else {
            throw CancellationError()
        }
    }
}

@MainActor
private enum SearchScopePreferencesWrites {
    static var intent = UUID()
    private static var pending: (id: UUID, task: Task<Void, Error>)?

    static func enqueue(_ value: String) -> Task<Void, Error> {
        let previous = pending?.task
        let task = Task { @MainActor in
            // A failed older save is reported to its caller but cannot block a newer intent.
            if let previous { _ = await previous.result }
            let facade = try SharedRuntime.settingsFacade().get()
            try await SharedAsync.void { completion in
                facade.setSearchScope(scope: value, completionHandler: completion)
            }
            try await SharedAsync.void { completion in
                facade.setSearchGroup(
                    group: SearchScopePreferencesCodec.searchGroup(for: value),
                    completionHandler: completion
                )
            }
        }
        pending = (UUID(), task)
        return task
    }

    static func waitForPendingSave() async throws {
        guard let current = pending else { return }
        defer {
            if pending?.id == current.id { pending = nil }
        }
        try await current.task.value
    }
}

private final class SearchScopeRuntimeSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<AppRuntimeConfig, Error>?
    private var subscription: FlowSubscription?

    static func value(facade: SettingsFacade) async throws -> AppRuntimeConfig {
        let snapshot = SearchScopeRuntimeSnapshot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard snapshot.install(continuation) else { return }
                snapshot.attach(
                    facade.watchRuntimeConfig { config in
                        snapshot.finish(.success(config))
                    })
            }
        } onCancel: {
            snapshot.finish(.failure(CancellationError()))
        }
    }

    private func install(_ continuation: CheckedContinuation<AppRuntimeConfig, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func attach(_ subscription: FlowSubscription) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            subscription.cancel()
            return
        }
        self.subscription = subscription
        lock.unlock()
    }

    private func finish(_ result: Result<AppRuntimeConfig, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        let subscription = self.subscription
        self.continuation = nil
        self.subscription = nil
        lock.unlock()
        subscription?.cancel()
        continuation?.resume(with: result)
    }
}
