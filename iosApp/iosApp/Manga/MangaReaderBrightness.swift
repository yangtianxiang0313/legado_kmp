import UIKit

/// Android has per-window brightness; iOS requires a screen-scoped lease that is restored on leaving.
@MainActor
final class MangaReaderBrightness {
    private weak var screen: UIScreen?
    private var original: CGFloat?
    private var applied: CGFloat?
    private var value: Int?

    func update(_ filter: MangaColorFilter, window: UIWindow?, active: Bool) {
        // A zero/default config must not darken the device merely by opening a book.
        value = filter.l > 0 ? filter.l : nil
        setActive(active, window: window)
    }

    func setActive(_ active: Bool, window: UIWindow?) {
        guard active, let window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window), let value
        else { restore(); return }
        let target = window.screen
        if screen !== target { restore(); screen = target }
        if original == nil { original = target.brightness }
        let next = CGFloat(min(255, max(0, value))) / 255
        target.brightness = next
        applied = next
    }

    func restore() {
        // A different reader or a manual system adjustment owns any value we did not set.
        if let screen, let original, let applied, abs(screen.brightness - applied) < 0.002 {
            screen.brightness = original
        }
        screen = nil
        original = nil
        applied = nil
    }
}
