import UIKit

/// Captures the presenting branch, without treating an owned child dialog as departure.
@MainActor
final class ReaderFontDialogPresentationContext {
    private weak var presenter: UIViewController?
    private weak var source: UIViewController?
    private weak var window: UIWindow?
    private weak var root: UIViewController?

    init?(dialog: UIViewController) {
        guard let presenter = dialog.presentingViewController,
            let window = dialog.viewIfLoaded?.window ?? presenter.viewIfLoaded?.window,
            let root = window.rootViewController
        else { return nil }
        self.presenter = presenter
        source = Self.currentSource(from: presenter)
        self.window = window
        self.root = root
    }

    var isForeground: Bool {
        guard let window else { return false }
        return UIApplication.shared.applicationState == .active && window.isKeyWindow
            && window.windowScene?.activationState == .foregroundActive
    }

    func owns(window: UIWindow) -> Bool { self.window === window }

    func isCurrent(dialog: UIViewController) -> Bool {
        guard let presenter, let source, let window, let root,
            !window.isHidden, window.alpha > 0, window.rootViewController === root,
            Self.currentSource(from: presenter) === source,
            dialog.presentingViewController === presenter, presenter.presentedViewController === dialog,
            !dialog.isBeingDismissed, !dialog.isMovingFromParent
        else { return false }
        var current: UIViewController? = source
        var expectedPresentation: UIViewController?
        var includesPresenter = false
        var lastController: UIViewController?
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingDismissed, !controller.isMovingFromParent,
                !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== expectedPresentation, presented !== dialog
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController,
                tabs.selectedViewController !== controller
            {
                return false
            }
            lastController = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return includesPresenter && lastController === root
    }

    private static func currentSource(from presenter: UIViewController) -> UIViewController {
        var source = presenter
        while true {
            if let navigation = source as? UINavigationController, let top = navigation.topViewController {
                source = top
            } else if let tabs = source as? UITabBarController, let selected = tabs.selectedViewController {
                source = selected
            } else {
                return source
            }
        }
    }
}
