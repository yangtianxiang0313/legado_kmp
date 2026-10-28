import Foundation
import shared

@MainActor
protocol BookshelfUpdateBackend: AnyObject {
    func prepare(concurrencyDidChange: @escaping (Int) -> Void) throws
    func update(bookURL: String) async throws -> BookshelfBatchUpdateResult
}

// Like MainViewModel's queue, submitted work outlives a bookshelf page, not the iOS process.
@MainActor
final class BookshelfUpdateCoordinator {
    static let shared = BookshelfUpdateCoordinator(backend: SharedBookshelfUpdateBackend())

    struct Snapshot: Equatable {
        let queuedURLs: [String]
        let activeURLs: Set<String>
        let completionRevision: UInt64

        var pendingCount: Int { queuedURLs.count + activeURLs.count }
    }

    private final class Job {
        let id = UUID()
        var task: Task<Void, Never>?
    }

    private struct Notification {
        let snapshot: Snapshot
        let observers: [UUID]
    }

    private let backend: any BookshelfUpdateBackend
    private var isPrepared = false
    private var concurrencyLimit = 0
    private var queued: [String] = []
    private var active: [String: Job] = [:]
    private var completionRevision: UInt64 = 0
    private var observers: [UUID: (Snapshot) -> Void] = [:]
    private var notifications: [Notification] = []
    private var isNotifying = false
    private var isPumping = false
    private(set) var snapshot = Snapshot(queuedURLs: [], activeURLs: [], completionRevision: 0)

    init(backend: any BookshelfUpdateBackend) { self.backend = backend }

    func observe(_ handler: @escaping (Snapshot) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(snapshot)
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    @discardableResult
    func enqueue(books: [Book]) throws -> Int {
        let eligible = books.filter { $0.shouldUpdate() && !$0.isNotShelf && !$0.bookUrl.isEmpty }
        guard !eligible.isEmpty else { return 0 }
        if !isPrepared {
            isPrepared = true
            do {
                try backend.prepare { [weak self] count in
                    guard let self else { return }
                    self.concurrencyLimit = min(64, max(1, count))
                    self.pump()
                }
            } catch {
                isPrepared = false
                throw error
            }
        }
        var known = Set(queued).union(active.keys)
        var added = 0
        for book in eligible where known.insert(book.bookUrl).inserted {
            queued.append(book.bookUrl)
            added += 1
        }
        pump()
        return added
    }

    private func pump() {
        guard !isPumping else { return }
        isPumping = true
        while concurrencyLimit > 0, active.count < concurrencyLimit, !queued.isEmpty {
            let url = queued.removeFirst()
            let job = Job()
            active[url] = job
            let id = job.id
            // Register the job before callbacks can enqueue the same book again.
            job.task = Task { @MainActor [self] in
                do {
                    let result = try await backend.update(bookURL: url)
                    if result.failedCount > 0 { SharedRuntime.log("书架目录更新失败: \(url)") }
                } catch {
                    SharedRuntime.log("书架目录更新失败: \(url): \(error.userFacingMessage)")
                }
                finish(bookURL: url, id: id)
            }
        }
        isPumping = false
        publish()
    }

    private func finish(bookURL: String, id: UUID) {
        guard active[bookURL]?.id == id else { return }
        active[bookURL] = nil
        completionRevision &+= 1
        pump()
    }

    private func publish() {
        let next = Snapshot(
            queuedURLs: queued, activeURLs: Set(active.keys), completionRevision: completionRevision)
        guard next != snapshot else { return }
        snapshot = next
        notifications.append(Notification(snapshot: next, observers: Array(observers.keys)))
        guard !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        while !notifications.isEmpty {
            let notification = notifications.removeFirst()
            for id in notification.observers { observers[id]?(notification.snapshot) }
        }
    }
}

@MainActor
private final class SharedBookshelfUpdateBackend: BookshelfUpdateBackend {
    private var facade: BookshelfFacade?
    private var runtimeSubscription: FlowSubscription?

    deinit { runtimeSubscription?.cancel() }

    func prepare(concurrencyDidChange: @escaping (Int) -> Void) throws {
        let facade = try SharedRuntime.bookshelfFacade().get()
        let settings = try SharedRuntime.settingsFacade().get()
        self.facade = facade
        runtimeSubscription = settings.watchRuntimeConfig { config in
            DispatchQueue.main.async { concurrencyDidChange(Int(config.threadCount)) }
        }
    }

    func update(bookURL: String) async throws -> BookshelfBatchUpdateResult {
        guard let facade else {
            throw SharedRuntimeError(operation: "updateBookToc", message: "书架更新不可用", underlying: nil)
        }
        return try await facade.updateBookTocAsync(bookUrl: bookURL)
    }
}
