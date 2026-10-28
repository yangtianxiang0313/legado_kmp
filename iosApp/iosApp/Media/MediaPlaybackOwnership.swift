import Foundation

/// A single foreground media intent owns the app's audio session and lock-screen controls.
@MainActor
final class MediaPlaybackOwnership {
    static let shared = MediaPlaybackOwnership()
    private weak var owner: AnyObject?
    private var onReplaced: (@MainActor () -> Void)?

    func claim(owner candidate: AnyObject, onReplaced: @escaping @MainActor () -> Void) {
        if owner === candidate {
            self.onReplaced = onReplaced
            return
        }
        let prior = self.onReplaced
        owner = nil
        self.onReplaced = nil
        prior?()
        owner = candidate
        self.onReplaced = onReplaced
    }

    func owns(_ candidate: AnyObject) -> Bool { owner === candidate }
    var hasOwner: Bool { owner != nil }

    func release(owner candidate: AnyObject) {
        guard owner === candidate else { return }
        owner = nil
        onReplaced = nil
    }
}
