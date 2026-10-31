import Foundation
import shared

enum SharedCancellableAsync {
    static func value<T>(
        awaitCancellationCompletion: Bool = false,
        start: (@escaping @Sendable (T?, Error?) -> Void) -> FlowSubscription
    ) async throws -> T {
        let state = SharedCancellableAsyncState<T>(awaitCancellationCompletion: awaitCancellationCompletion)
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
        case cancelling
        case completed
        case cancelled
    }

    private let lock = NSLock()
    private let awaitCancellationCompletion: Bool
    private var phase = Phase.pending
    private var continuation: CheckedContinuation<T, Error>?
    private var subscription: FlowSubscription?

    init(awaitCancellationCompletion: Bool) {
        self.awaitCancellationCompletion = awaitCancellationCompletion
    }

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
        guard phase == .pending || phase == .cancelling else {
            let shouldCancel = phase == .cancelled
            lock.unlock()
            if shouldCancel {
                subscription.cancel()
            }
            return
        }
        self.subscription = subscription
        let shouldCancel = phase == .cancelling
        lock.unlock()
        if shouldCancel { subscription.cancel() }
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
        lock.lock()
        guard phase == .pending || phase == .cancelling else {
            lock.unlock()
            return
        }
        let wasCancelled = phase == .cancelling
        phase = .completed
        let continuation = self.continuation
        let subscription = self.subscription
        self.continuation = nil
        self.subscription = nil
        lock.unlock()
        withExtendedLifetime(subscription) {
            continuation?.resume(with: wasCancelled ? .failure(CancellationError()) : result)
        }
    }

    func cancel() {
        lock.lock()
        guard phase == .pending else {
            lock.unlock()
            return
        }
        let waitForTerminal = awaitCancellationCompletion && continuation != nil
        phase = waitForTerminal ? .cancelling : .cancelled
        let continuation = self.continuation
        let subscription = self.subscription
        if !waitForTerminal {
            self.continuation = nil
            self.subscription = nil
        }
        lock.unlock()

        // Kotlin cancellation can synchronously call back into this state.
        withExtendedLifetime(subscription) {
            if !waitForTerminal { continuation?.resume(throwing: CancellationError()) }
            subscription?.cancel()
        }
    }
}
