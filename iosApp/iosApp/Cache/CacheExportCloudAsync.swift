import Foundation
import shared

@MainActor
enum CacheExportCloudAsync {
    static func upload(
        session: BookExportCloudSession, fileName: String, data: KotlinByteArray, overwrite: Bool
    ) async throws -> BookExportCloudUploadResult {
        try Task.checkCancellation()
        let state = CacheCloudRequestState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                let request = session.uploadRequest(fileName: fileName, data: data, overwrite: overwrite) {
                    state.complete($0)
                }
                state.install(request)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

// A terminal server result wins over a late cancellation; uploaded files cannot be rolled back locally.
private final class CacheCloudRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var continuation: CheckedContinuation<BookExportCloudUploadResult, Error>?
    private var request: FlowSubscription?

    func install(_ continuation: CheckedContinuation<BookExportCloudUploadResult, Error>) -> Bool {
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

    func install(_ request: FlowSubscription) {
        lock.lock()
        if !completed { self.request = request }
        let shouldCancel = cancelled && !completed
        lock.unlock()
        if shouldCancel { request.cancel() }
    }

    func cancel() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        cancelled = true
        let request = self.request
        lock.unlock()
        withExtendedLifetime(request) { request?.cancel() }
    }

    func complete(_ result: BookExportCloudUploadResult) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        request = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
