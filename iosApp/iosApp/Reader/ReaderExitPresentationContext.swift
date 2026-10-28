import UIKit

/// A retained reader must not turn an old dialog callback into navigation in another scene/page.
@MainActor
final class ReaderExitPresentationContext {
    let bookURL: String
    private(set) var origin: String?
    weak var hostWindow: UIWindow?
    weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var navigation: UINavigationController?
    private let revision: UUID
    private var hasObservedBook: Bool

    init(reader: ReaderContainerViewController, revision: UUID) {
        bookURL = reader.bookURL
        origin = reader.book?.origin
        hasObservedBook = reader.book != nil
        self.revision = revision
        hostWindow = reader.viewIfLoaded?.window
        scene = hostWindow?.windowScene
        root = hostWindow?.rootViewController
        navigation = reader.navigationController
    }

    func captureOrigin(_ origin: String) {
        if self.origin == nil { self.origin = origin }
    }

    func observeBook(origin: String) {
        captureOrigin(origin)
        hasObservedBook = true
    }

    func matches(
        _ reader: ReaderContainerViewController, revision: UUID, allowing dialog: UIViewController? = nil,
        allowingMissingBook: Bool = false
    ) -> Bool {
        guard self.revision == revision, reader.bookURL == bookURL,
            let hostWindow, let scene, let root, let navigation,
            reader.viewIfLoaded?.window === hostWindow, reader.navigationController === navigation,
            hostWindow.windowScene === scene, hostWindow.rootViewController === root,
            navigation.topViewController === reader,
            hostWindow.isKeyWindow, !hostWindow.isHidden, hostWindow.alpha > 0,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive
        else { return false }
        if let dialog {
            guard dialog.presentedViewController == nil,
                !dialog.isMovingFromParent, !dialog.isMovingToParent
            else { return false }
            if let presenter = dialog.presentingViewController {
                guard presenter.presentedViewController === dialog,
                    dialog.viewIfLoaded?.window === hostWindow || dialog.isBeingPresented
                else { return false }
            } else {
                guard dialog.parent == nil, dialog.viewIfLoaded?.window == nil,
                    dialog.viewIfLoaded?.superview == nil
                else { return false }
            }
        }
        if let transition = navigation.transitionCoordinator {
            guard let dialog,
                transition.viewController(forKey: .from) === dialog || transition.viewController(forKey: .to) === dialog
            else { return false }
        }
        if let book = reader.book {
            guard book.bookUrl == bookURL, book.origin == origin else { return false }
        } else if !allowingMissingBook && hasObservedBook {
            return false
        }
        if dialog == nil, !reader.canPerformNavigationAction { return false }
        var current: UIViewController? = reader
        var expectedPresentation: UIViewController?
        var last: UIViewController?
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.viewIfLoaded?.window === hostWindow,
                controller.viewIfLoaded?.isHidden == false, (controller.viewIfLoaded?.alpha ?? 0) > 0
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== dialog, presented !== expectedPresentation
            {
                return false
            }
            if let parent = controller.parent as? UINavigationController, parent.topViewController !== controller {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            if let pager = controller.parent as? UIPageViewController,
                pager.viewControllers?.contains(where: { $0 === controller }) != true
            {
                return false
            }
            last = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return last === root
    }
}
