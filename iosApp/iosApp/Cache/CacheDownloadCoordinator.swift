import Foundation
import shared

// Process-scoped work survives page removal, but does not request iOS background execution.
@MainActor
final class CacheDownloadCoordinator {
    static let shared = CacheDownloadCoordinator(backend: SharedCacheDownloadBackend())

    enum Phase: Equatable, Sendable {
        case running
        case stopping
        case completed
        case failed
        case stopped
    }

    struct Snapshot: Sendable {
        let bookURL: String
        let phase: Phase
        let cached: Int
        let total: Int
        let message: String?
        // True only after this request receives measured progress or a final summary.
        let hasProgress: Bool

        var isActive: Bool { phase == .running || phase == .stopping }
    }

    private final class Job {
        let id = UUID()
        let progress = CacheDownloadProgressBuffer()
        var task: Task<Void, Never>?
        var stopMonitor: Task<Void, Never>?
        var stopRequested = false
        var progressError: String?
    }

    private struct Notification {
        let snapshots: [String: Snapshot]
        let observerIDs: [UUID]
    }

    private let backend: any CacheDownloadBackend
    private var jobs: [String: Job] = [:]
    private var observers: [UUID: ([String: Snapshot]) -> Void] = [:]
    private var notifications: [Notification] = []
    private var isNotifying = false

    private(set) var snapshots: [String: Snapshot] = [:]

    init(backend: any CacheDownloadBackend) {
        self.backend = backend
    }

    func observe(_ handler: @escaping ([String: Snapshot]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        handler(snapshots)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    @discardableResult
    func start(book: Book, startIndex: Int, endIndex: Int = Int(Int32.max)) -> Bool {
        let bookURL = book.bookUrl
        guard !book.isLocal,
            !bookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            startIndex >= 0, endIndex >= startIndex,
            let start = Int32(exactly: startIndex), let end = Int32(exactly: endIndex),
            jobs[bookURL] == nil
        else { return false }

        let job = Job()
        let previous = snapshots[bookURL]
        jobs[bookURL] = job
        // Until real progress arrives these are last-known counts, never the range length.
        snapshots[bookURL] = Snapshot(
            bookURL: bookURL,
            phase: .running,
            cached: previous?.cached ?? 0,
            total: previous?.total ?? max(0, Int(book.totalChapterNum)),
            message: "正在准备下载…",
            hasProgress: false
        )
        let id = job.id
        let progress = job.progress
        // Install the task before notifying: an observer may synchronously request stop.
        job.task = Task { @MainActor [self] in
            do {
                try Task.checkCancellation()
                let summary = try await backend.download(
                    bookURL: bookURL, startIndex: start, endIndex: end,
                    onProgress: { @Sendable [weak self] update in
                        guard progress.record(update, bookURL: bookURL) else { return }
                        Task { @MainActor [weak self] in
                            self?.consumeProgress(bookURL: bookURL, id: id)
                        }
                    }
                )
                finish(bookURL: bookURL, id: id, result: .success(summary))
            } catch {
                finish(bookURL: bookURL, id: id, result: .failure(error))
            }
        }
        notifyObservers()
        return true
    }

    func stop(bookURL: String) {
        guard let job = jobs[bookURL], !job.stopRequested,
            let current = snapshots[bookURL]
        else { return }
        job.stopRequested = true
        snapshots[bookURL] = Snapshot(
            bookURL: bookURL, phase: .stopping,
            cached: current.cached, total: current.total,
            message: stoppingMessage(error: job.progressError),
            hasProgress: current.hasProgress
        )
        let id = job.id
        // The Kotlin bridge may still be preparing, before downloadJobs registration.
        // Keep stopping this exact job until download() actually returns.
        job.stopMonitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                guard let self, let current = self.jobs[bookURL],
                    current.id == id, current.stopRequested
                else { return }
                self.backend.stop(bookURL: bookURL)
            }
        }
        job.task?.cancel()
        backend.stop(bookURL: bookURL)
        notifyObservers()
    }

    func stopAll() {
        for bookURL in Array(jobs.keys) {
            stop(bookURL: bookURL)
        }
    }

    private func consumeProgress(bookURL: String, id: UUID, notify: Bool = true) {
        guard let job = jobs[bookURL], job.id == id,
            let update = job.progress.take()
        else { return }
        if let error = update.error { job.progressError = error }
        snapshots[bookURL] = Snapshot(
            bookURL: bookURL,
            phase: job.stopRequested ? .stopping : .running,
            cached: update.cached,
            total: update.total,
            message: job.stopRequested ? stoppingMessage(error: job.progressError) : job.progressError,
            hasProgress: true
        )
        if notify { notifyObservers() }
    }

    private func finish(bookURL: String, id: UUID, result: Result<BookDownloadSummary, Error>) {
        guard let job = jobs[bookURL], job.id == id else { return }
        // A callback's main-actor delivery may still be queued behind this completion.
        consumeProgress(bookURL: bookURL, id: id, notify: false)
        guard let current = snapshots[bookURL] else { return }
        var cached = current.cached
        var total = current.total
        var hasProgress = current.hasProgress
        let phase: Phase
        let message: String
        switch result {
        case .success(let summary):
            cached = max(0, Int(summary.downloaded))
            total = max(0, Int(summary.totalChapters))
            hasProgress = true
            var issues: [String] = []
            if total == 0 { issues.append("暂无章节，请先更新目录") }
            if summary.errors > 0 { issues.append("\(summary.errors) 章下载失败") }
            if let error = job.progressError { issues.append(error) }
            if summary.pending > 0 || summary.active > 0 {
                issues.append("仍有 \(summary.pending) 章等待、\(summary.active) 章下载中")
            }
            if job.stopRequested {
                phase = .stopped
                message = (["下载已停止，已缓存章节已保留"] + issues).joined(separator: "；")
            } else if !issues.isEmpty {
                phase = .failed
                message = issues.joined(separator: "；")
            } else {
                phase = .completed
                message = "所选范围缓存完成"
            }
        case .failure(let error):
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if job.stopRequested {
                phase = .stopped
                var details = ["下载已停止，已缓存章节已保留"]
                if let error = job.progressError { details.append(error) }
                let cancelled =
                    error is CancellationError || (error as NSError).code == NSURLErrorCancelled
                    || detail.lowercased().contains("cancelled") || detail.lowercased().contains("canceled")
                if !cancelled, !detail.isEmpty { details.append(detail) }
                message = details.joined(separator: "；")
            } else {
                phase = .failed
                var details = [detail.isEmpty ? "下载失败，未返回错误详情" : "下载失败：\(detail)"]
                if let error = job.progressError, error != detail { details.append(error) }
                message = details.joined(separator: "；")
            }
        }

        job.stopMonitor?.cancel()
        job.stopMonitor = nil
        job.task = nil
        jobs[bookURL] = nil
        snapshots[bookURL] = Snapshot(
            bookURL: bookURL, phase: phase, cached: cached, total: total, message: message,
            hasProgress: hasProgress
        )
        notifyObservers()
    }

    private func stoppingMessage(error: String?) -> String {
        guard let error else { return "正在停止下载" }
        return "正在停止下载；\(error)"
    }

    private func notifyObservers() {
        notifications.append(Notification(snapshots: snapshots, observerIDs: Array(observers.keys)))
        guard !isNotifying else { return }
        isNotifying = true
        defer { isNotifying = false }
        // Serialize reentrant observer mutations without delivering older state to new observers.
        while !notifications.isEmpty {
            let notification = notifications.removeFirst()
            for id in notification.observerIDs {
                observers[id]?(notification.snapshots)
            }
        }
    }
}

private final class CacheDownloadProgressBuffer: @unchecked Sendable {
    struct Update: Sendable {
        let cached: Int
        let total: Int
        let error: String?
    }

    private let lock = NSLock()
    private var pending: Update?
    private var lastError: String?

    func record(_ progress: CacheProgress, bookURL: String) -> Bool {
        guard progress.bookUrl == bookURL else { return false }
        let error = progress.error.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "下载返回了未说明的错误" : $0
        }
        lock.lock()
        defer { lock.unlock() }
        if let error { lastError = error }
        pending = Update(
            cached: max(0, Int(progress.cached)),
            total: max(0, Int(progress.total)),
            error: lastError
        )
        return true
    }

    func take() -> Update? {
        lock.lock()
        defer { lock.unlock() }
        let update = pending
        pending = nil
        return update
    }
}
