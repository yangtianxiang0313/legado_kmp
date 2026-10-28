import Foundation
import shared

final class FlowSubscriptionStore {
    private var subscriptions: [FlowSubscription] = []

    func store(_ subscription: FlowSubscription) {
        subscriptions.append(subscription)
    }

    func cancelAll() {
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
    }

    deinit {
        cancelAll()
    }
}

final class ScreenBindingController {
    private let owner: String
    private var persistentSubscriptions: [FlowSubscription] = []
    private var replaceableSubscriptions: [String: FlowSubscription] = [:]

    init(owner: String) {
        self.owner = owner
    }

    var activeCount: Int {
        persistentSubscriptions.count + replaceableSubscriptions.count
    }

    func bind(_ subscription: FlowSubscription) {
        persistentSubscriptions.append(subscription)
        debugLog("bound persistent observer")
    }

    func replaceBinding(key: String, with subscription: FlowSubscription) {
        if let existing = replaceableSubscriptions.updateValue(subscription, forKey: key) {
            existing.cancel()
            debugLog("replaced observer '\(key)'")
        } else {
            debugLog("bound observer '\(key)'")
        }
    }

    func unbind(key: String) {
        guard let existing = replaceableSubscriptions.removeValue(forKey: key) else { return }
        existing.cancel()
        debugLog("unbound observer '\(key)'")
    }

    func cancelAll() {
        persistentSubscriptions.forEach { $0.cancel() }
        replaceableSubscriptions.values.forEach { $0.cancel() }
        persistentSubscriptions.removeAll()
        replaceableSubscriptions.removeAll()
        debugLog("cancelled all observers")
    }

    deinit {
        if activeCount > 0 {
            assertionFailure("[\(owner)] leaked \(activeCount) observer(s)")
            cancelAll()
        }
    }

    private func debugLog(_ message: String) {
#if DEBUG
        SharedRuntime.log("[Bindings:\(owner)] \(message) | active=\(activeCount)")
#endif
    }
}
