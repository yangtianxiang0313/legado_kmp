import Foundation
import shared

@MainActor
func readerStylePreferenceSnapshot(facade: SettingsFacade) async -> ReaderStylePreferences {
    await withCheckedContinuation { continuation in
        let snapshot = ReaderStylePreferenceSnapshot(continuation: continuation)
        snapshot.attach(facade.watchPreferences { snapshot.receive($0.readerStyle) })
    }
}

/// Handles both an immediate StateFlow value and a later callback without leaking its subscription.
private final class ReaderStylePreferenceSnapshot {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ReaderStylePreferences, Never>?
    private var subscription: FlowSubscription?

    init(continuation: CheckedContinuation<ReaderStylePreferences, Never>) {
        self.continuation = continuation
    }

    func attach(_ subscription: FlowSubscription) {
        lock.lock()
        if continuation == nil {
            lock.unlock()
            subscription.cancel()
        } else {
            self.subscription = subscription
            lock.unlock()
        }
    }

    func receive(_ style: ReaderStylePreferences) {
        lock.lock()
        let continuation = self.continuation
        let subscription = self.subscription
        self.continuation = nil
        self.subscription = nil
        lock.unlock()
        subscription?.cancel()
        continuation?.resume(returning: style)
    }
}
