import Foundation
import shared

enum SharedCancellableAsync {
    static func value<T>(start: (@escaping @Sendable (T?, Error?) -> Void) -> FlowSubscription) async throws -> T {
        let state = SharedCancellableAsyncState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                guard state.installContinuation(continuation) else { return }
                let subscription = start { value, error in
                    state.complete(value: value, error: error)
                }
                state.installSubscription(subscription)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

private final class SharedCancellableAsyncState<T>: @unchecked Sendable {
    private enum Phase {
        case pending
        case completed
        case cancelled
    }

    private let lock = NSLock()
    private var phase = Phase.pending
    private var continuation: CheckedContinuation<T, Error>?
    private var subscription: FlowSubscription?

    func installContinuation(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        guard phase == .pending else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func installSubscription(_ subscription: FlowSubscription) {
        lock.lock()
        guard phase == .pending else {
            let shouldCancel = phase == .cancelled
            lock.unlock()
            if shouldCancel {
                subscription.cancel()
            }
            return
        }
        self.subscription = subscription
        lock.unlock()
    }

    func complete(value: T?, error: Error?) {
        let result: Result<T, Error>
        if let error {
            result = .failure(error)
        } else if let value {
            result = .success(value)
        } else {
            result = .failure(
                NSError(
                    domain: "io.legado.kmp.ios",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.Shared.emptyValue]
                ))
        }
        finish(with: result, cancelled: false)
    }

    func cancel() {
        finish(with: .failure(CancellationError()), cancelled: true)
    }

    private func finish(with result: Result<T, Error>, cancelled: Bool) {
        lock.lock()
        guard phase == .pending else {
            lock.unlock()
            return
        }
        phase = cancelled ? .cancelled : .completed
        let continuation = self.continuation
        let subscription = self.subscription
        self.continuation = nil
        self.subscription = nil
        lock.unlock()

        // Kotlin cancellation can synchronously call back into this state.
        withExtendedLifetime(subscription) {
            continuation?.resume(with: result)
            if cancelled {
                subscription?.cancel()
            }
        }
    }
}
