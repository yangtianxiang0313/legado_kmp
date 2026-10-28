import Foundation
import shared

enum LocalBookArchivePreparation {
    static func prepare(path: String, facade: ArchiveBookImportFacade) async throws -> ArchiveBookListing {
        try Task.checkCancellation()
        let state = ArchivePreparationState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ArchiveBookListing, Error>) in
                guard state.installContinuation(continuation) else { return }
                let request = facade.prepareArchiveRequest(path: path) { state.complete($0) }
                state.installRequest(request)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

// Do not release the staged archive until Kotlin acknowledges cancellation and closes its source.
private final class ArchivePreparationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var continuation: CheckedContinuation<ArchiveBookListing, Error>?
    private var request: FlowSubscription?

    func installContinuation(_ continuation: CheckedContinuation<ArchiveBookListing, Error>) -> Bool {
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
        cancelled = true
        let request = self.request
        lock.unlock()
        request?.cancel()
    }

    func complete(_ outcome: ArchiveBookPreparationResult) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let wasCancelled = cancelled || outcome.isCancelled
        let continuation = self.continuation
        self.continuation = nil
        request = nil
        lock.unlock()
        if wasCancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let archive = outcome.archive {
            continuation?.resume(returning: archive)
        } else {
            continuation?.resume(
                throwing: NSError(
                    domain: "io.legado.local-book-archive", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: outcome.errorMessage ?? "压缩包导入失败"]
                ))
        }
    }
}
