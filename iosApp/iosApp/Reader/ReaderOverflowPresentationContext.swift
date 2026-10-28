import UIKit

/// PopupMenu belongs to the anchor's visible window/controller, not merely a retained view.
@MainActor
final class ReaderOverflowPresentationContext {
    private weak var anchor: UIView?
    private weak var host: UIView?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var owner: UIViewController?
    private let hadOwner: Bool

    init(anchor: UIView, host: UIView) {
        self.anchor = anchor
        self.host = host
        window = host.window
        scene = host.window?.windowScene
        var responder: UIResponder? = anchor
        var controller: UIViewController?
        while let current = responder {
            if let found = current as? UIViewController {
                controller = found
                break
            }
            responder = current.next
        }
        owner = controller
        hadOwner = controller != nil
    }

    var isCurrent: Bool {
        guard let anchor, let host, let window, let scene,
            host.window === window, anchor.window === window, window.windowScene === scene,
            scene.activationState == .foregroundActive, window.isKeyWindow,
            UIApplication.shared.applicationState == .active,
            anchor === host || anchor.isDescendant(of: host),
            Self.isVisible(anchor, in: window), Self.isVisible(host, in: window)
        else { return false }
        if hadOwner, owner == nil { return false }
        var child = owner
        while let controller = child {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.presentedViewController == nil,
                controller.viewIfLoaded?.window === window
            else { return false }
            if let navigation = controller.parent as? UINavigationController {
                guard navigation.topViewController === controller, navigation.transitionCoordinator == nil else {
                    return false
                }
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            if let pager = controller.parent as? UIPageViewController,
                pager.viewControllers?.contains(where: { $0 === controller }) != true
            {
                return false
            }
            child = controller.parent
        }
        return true
    }

    private static func isVisible(_ view: UIView, in window: UIWindow) -> Bool {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return false }
        var visible = view.convert(view.bounds, to: window)
        guard !visible.isNull, !visible.isInfinite, visible.minX.isFinite, visible.minY.isFinite,
            visible.width.isFinite, visible.height.isFinite
        else { return false }
        var current: UIView? = view
        while let candidate = current {
            guard !candidate.isHidden, candidate.alpha > 0.01, candidate.isUserInteractionEnabled else { return false }
            if let control = candidate as? UIControl, !control.isEnabled { return false }
            if candidate.clipsToBounds || candidate === window {
                visible = visible.intersection(candidate.convert(candidate.bounds, to: window))
                guard !visible.isNull, visible.width > 0, visible.height > 0 else { return false }
            }
            current = candidate.superview
        }
        return true
    }
}
