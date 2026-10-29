import Foundation
import shared

/// Cancellation requests stop work, but callers wait for the shared operation's real terminal callback.
final class BackupRestoreTerminalRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: FlowSubscription?
    private var cancelled = false
    private var finished = false

    func install(_ subscription: FlowSubscription) {
        lock.lock()
        if !finished { self.subscription = subscription }
        let shouldCancel = cancelled && !finished
        lock.unlock()
        if shouldCancel { subscription.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = finished ? nil : subscription
        lock.unlock()
        active?.cancel()
    }

    func finish() {
        lock.lock()
        finished = true
        subscription = nil
        lock.unlock()
    }
}
