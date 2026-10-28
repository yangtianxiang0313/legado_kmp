import UIKit

@MainActor
final class PdfBookmarkPresentationGuard {
    private weak var controller: UIViewController?
    private weak var window: UIWindow?
    private weak var root: UIViewController?
    private var hasBoundWindow = false

    init(controller: UIViewController) { self.controller = controller }

    func bindIfNeeded() {
        guard !hasBoundWindow, let window = controller?.viewIfLoaded?.window else { return }
        hasBoundWindow = true
        self.window = window
        root = window.rootViewController
    }

    func allows(cover: UIViewController? = nil) -> Bool {
        guard let controller, let window, let root,
            isActive(window: window, root: root), controller.viewIfLoaded?.window === window
        else { return false }

        // A presented navigation stack still belongs to the original root. Only its own editor/alert may cover it.
        var chain: [UIViewController] = []
        var candidate: UIViewController? = controller
        while let current = candidate, chain.count < 64 {
            guard !chain.contains(where: { $0 === current }) else { return false }
            chain.append(current)
            candidate = current.parent ?? current.presentingViewController
        }
        guard candidate == nil, chain.last === root else { return false }
        for current in chain {
            guard !current.isBeingPresented, !current.isBeingDismissed,
                !current.isMovingFromParent, !current.isMovingToParent
            else { return false }
            if let parent = current.parent as? UINavigationController, parent.topViewController !== current {
                return false
            }
            if let parent = current.parent as? UITabBarController, parent.selectedViewController !== current {
                return false
            }
            if let presented = current.presentedViewController,
                presented !== cover, !chain.contains(where: { $0 === presented })
            {
                return false
            }
        }
        if let cover {
            guard let presenter = cover.presentingViewController,
                presenter.presentedViewController === cover,
                chain.contains(where: { $0 === presenter }),
                !cover.isBeingPresented, !cover.isBeingDismissed, cover.presentedViewController == nil
            else { return false }
        }
        return true
    }

    func deliverySource(from presenter: UIViewController) -> UIViewController {
        var source = presenter
        for _ in 0..<64 {
            if let navigation = source as? UINavigationController, let top = navigation.topViewController {
                source = top
            } else if let tabs = source as? UITabBarController, let selected = tabs.selectedViewController {
                source = selected
            } else {
                break
            }
        }
        return source
    }

    func allowsDelivery(from presenter: UIViewController, expectedSource: UIViewController) -> Bool {
        guard let window, let root, isActive(window: window, root: root),
            presenter.viewIfLoaded?.window === window, presenter.presentedViewController == nil,
            deliverySource(from: presenter) === expectedSource
        else { return false }
        var current: UIViewController? = expectedSource
        var remaining = 64
        while let candidate = current, remaining > 0 {
            remaining -= 1
            guard !candidate.isBeingPresented, !candidate.isBeingDismissed,
                !candidate.isMovingFromParent, !candidate.isMovingToParent,
                candidate.presentedViewController == nil
            else { return false }
            if let navigation = candidate.parent as? UINavigationController,
                navigation.topViewController !== candidate
            {
                return false
            }
            if let tabs = candidate.parent as? UITabBarController, tabs.selectedViewController !== candidate {
                return false
            }
            if candidate === root { return true }
            current = candidate.parent
        }
        return false
    }

    private func isActive(window: UIWindow, root: UIViewController) -> Bool {
        UIApplication.shared.applicationState == .active && window.isKeyWindow && !window.isHidden
            && window.alpha > 0 && window.rootViewController === root
            && window.windowScene?.activationState == .foregroundActive
            && AppLockManager.shared.isUnlocked(in: window)
    }
}
