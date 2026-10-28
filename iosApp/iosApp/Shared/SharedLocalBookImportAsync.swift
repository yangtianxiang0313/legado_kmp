import Foundation
import shared

enum SharedLocalBookImportAsync {
    static func value(
        makeRequest: (@escaping @Sendable (LocalBookImportRequestResult) -> Void) -> LocalBookImportRequest
    ) async throws -> Book {
        try Task.checkCancellation()
        let state = LocalBookImportAsyncState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Book, Error>) in
                guard state.installContinuation(continuation) else { return }
                let request = makeRequest { state.complete($0) }
                if state.installRequest(request) {
                    request.start()
                }
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class LocalBookImportAsyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var completed = false
    private var continuation: CheckedContinuation<Book, Error>?
    private var request: LocalBookImportRequest?

    func installContinuation(_ continuation: CheckedContinuation<Book, Error>) -> Bool {
        lock.lock()
        guard !cancellationRequested else {
            completed = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installRequest(_ request: LocalBookImportRequest) -> Bool {
        lock.lock()
        let shouldStart = !completed && !cancellationRequested
        if !completed { self.request = request }
        lock.unlock()
        if !shouldStart {
            withExtendedLifetime(request) { request.cancel() }
        }
        return shouldStart
    }

    func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        cancellationRequested = true
        let request = self.request
        lock.unlock()
        // Unlike read-only requests, cancellation must wait for Kotlin's terminal callback.
        withExtendedLifetime(request) { request?.cancel() }
    }

    func complete(_ outcome: LocalBookImportRequestResult) {
        let result: Result<Book, Error>
        if let book = outcome.book {
            result = .success(book)
        } else if outcome.isCancelled {
            result = .failure(CancellationError())
        } else {
            result = .failure(
                NSError(
                    domain: outcome.errorCode ?? "io.legado.kmp.ios.local-import",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: outcome.errorMessage ?? L10n.Shared.emptyValue]
                ))
        }
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        request = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
