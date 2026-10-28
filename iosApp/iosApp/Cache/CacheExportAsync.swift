import Foundation
import shared

struct CacheExportProgress: Sendable {
    let completed: Int
    let total: Int

    var fraction: Float? {
        guard total > 0 else { return nil }
        return Float(min(max(0, completed), total)) / Float(total)
    }
}

@MainActor
enum CacheExportAsync {
    static func prepareConfigured(
        bookURL: String, format: CacheExportFormat, options: BookExportOptions, facade: BookExportFacade,
        onProgress: @escaping @MainActor (CacheExportProgress) -> Void
    ) async throws -> BookExportBatchResult {
        try Task.checkCancellation()
        let state = CacheExportRequestState<BookExportBatchResult>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BookExportBatchResult, Error>) in
                guard state.installContinuation(continuation) else { return }
                let request = facade.prepareConfiguredRequest(
                    bookUrl: bookURL, format: format.rawValue, options: options,
                    onProgress: { progress in
                        let value = CacheExportProgress(completed: Int(progress.completed), total: Int(progress.total))
                        Task { @MainActor in
                            guard state.acceptsProgress else { return }
                            onProgress(value)
                        }
                    },
                    onResult: { state.complete(value: $0.export_, message: $0.errorMessage, isCancelled: $0.isCancelled) })
                state.installRequest(request)
            }
        } onCancel: {
            state.cancel()
        }
    }

    static func prepare(
        bookURL: String, format: CacheExportFormat, facade: BookExportFacade,
        onProgress: @escaping @MainActor (CacheExportProgress) -> Void
    ) async throws -> BookExportResult {
        try Task.checkCancellation()
        let state = CacheExportRequestState<BookExportResult>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BookExportResult, Error>) in
                guard state.installContinuation(continuation) else { return }
                let request = facade.prepareRequest(
                    bookUrl: bookURL, format: format.rawValue,
                    onProgress: { progress in
                        let value = CacheExportProgress(completed: Int(progress.completed), total: Int(progress.total))
                        Task { @MainActor in
                            guard state.acceptsProgress else { return }
                            onProgress(value)
                        }
                    },
                    onResult: { state.complete(value: $0.export_, message: $0.errorMessage, isCancelled: $0.isCancelled) })
                state.installRequest(request)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

// A cancelled export must retain its continuation until Kotlin has closed all source files.
private final class CacheExportRequestState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var request: FlowSubscription?

    var acceptsProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !completed
    }

    func installContinuation(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        lock.lock()
        guard !cancelled else {
            completed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installRequest(_ request: FlowSubscription) {
        lock.lock()
        if !completed { self.request = request }
        let shouldCancel = cancelled && !completed
        lock.unlock()
        if shouldCancel { request.cancel() }
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancelled = true
        let request = self.request
        lock.unlock()
        withExtendedLifetime(request) { request?.cancel() }
    }

    func complete(value: Value?, message: String?, isCancelled: Bool) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let wasCancelled = cancelled || isCancelled
        let continuation = self.continuation
        self.continuation = nil
        request = nil
        lock.unlock()
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let export = value {
            continuation?.resume(returning: export)
        } else {
            continuation?.resume(
                throwing: NSError(
                    domain: "io.legado.cache.export", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: message ?? "导出失败，请重试"]
                ))
        }
    }
}
