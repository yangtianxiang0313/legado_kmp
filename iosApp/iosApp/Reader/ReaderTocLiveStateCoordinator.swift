import Foundation
import shared

/// Coalesces SAVE_CONTENT and database changes without interrupting a TOC gesture.
@MainActor
final class ReaderTocLiveStateCoordinator {
    typealias Subscribe = (@escaping () -> Void) throws -> FlowSubscription

    struct Snapshot {
        let book: Book?
        let items: [ReaderChapterListItem]
    }

    var canApply: () -> Bool = { true }
    var onSnapshot: (Snapshot) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }

    private let subscribe: Subscribe
    private let load: () async throws -> Snapshot
    private var subscription: FlowSubscription?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var isActive = false
    private var needsReload = false
    private var pendingSnapshot: Snapshot?

    init(subscribe: @escaping Subscribe, load: @escaping () async throws -> Snapshot) {
        self.subscribe = subscribe
        self.load = load
    }

    static func forBook(_ bookURL: String) -> ReaderTocLiveStateCoordinator {
        ReaderTocLiveStateCoordinator(
            subscribe: { onChange in
                try SharedRuntime.readerFacade().get().watchChapterListChanges(bookUrl: bookURL, onChange: onChange)
            },
            load: {
                let facade = try SharedRuntime.bookDetailFacade().get()
                let book: Book? = try await SharedAsync.optionalValue { completion in
                    facade.resolvePersistedBook(bookUrl: bookURL, completionHandler: completion)
                }
                try Task.checkCancellation()
                guard let book else { return Snapshot(book: nil, items: []) }
                let items = try await SharedRuntime.readerFacade().get().loadChapterListStateAsync(bookUrl: bookURL)
                return Snapshot(book: book, items: items)
            })
    }

    deinit {
        subscription?.cancel()
        task?.cancel()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        let generation = UUID()
        self.generation = generation
        do {
            subscription = try subscribe { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.isActive, self.generation == generation else { return }
                    self.reload()
                }
            }
        } catch {
            onError(error)
        }
        reload()
    }

    func deactivate() {
        isActive = false
        generation = UUID()
        subscription?.cancel()
        subscription = nil
        task?.cancel()
        task = nil
        needsReload = false
        pendingSnapshot = nil
    }

    func reload() {
        guard isActive else { return }
        pendingSnapshot = nil
        needsReload = true
        guard task == nil else { return }
        let generation = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation { self.task = nil }
            }
            while self.isActive, self.generation == generation, self.needsReload, !Task.isCancelled {
                self.needsReload = false
                do {
                    let snapshot = try await self.load()
                    guard self.isActive, self.generation == generation, !Task.isCancelled else { return }
                    // A save during this read makes its snapshot obsolete; retain only the next result.
                    if self.needsReload { continue }
                    self.pendingSnapshot = snapshot
                    self.resumeUpdates()
                } catch {
                    guard self.isActive, self.generation == generation, !Task.isCancelled,
                        !(error is CancellationError)
                    else { return }
                    if !self.needsReload { self.onError(error) }
                }
            }
        }
    }

    func resumeUpdates() {
        guard isActive, canApply(), let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        onSnapshot(snapshot)
    }
}
