import shared
import UIKit

struct RssArticleListIdentity: Hashable {
    let origin: Data
    let link: Data

    init(_ article: RssArticle) {
        origin = Data(article.origin.utf8)
        link = Data(article.link.utf8)
    }
}

@MainActor
enum RssArticleListPresentation {
    static func isActive(_ host: UIViewController) -> Bool {
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
            let window = host.viewIfLoaded?.window, window.isKeyWindow, !window.isHidden, window.alpha > 0.01,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            window.windowScene?.activationState == .foregroundActive, AppLockManager.shared.isUnlocked(in: window),
            host.navigationController?.topViewController === host
        else { return false }
        var child: UIViewController?
        var ancestor: UIViewController? = host
        while let controller = ancestor {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent, controller.transitionCoordinator == nil,
                controller.presentedViewController == nil, let content = controller.viewIfLoaded,
                content.window === window, !content.isHidden, content.alpha > 0.01, content.isUserInteractionEnabled
            else { return false }
            if let navigation = controller as? UINavigationController, navigation.topViewController !== child {
                return false
            }
            if let tabs = controller as? UITabBarController, tabs.selectedViewController !== child { return false }
            if controller === window.rootViewController { return true }
            child = controller
            ancestor = controller.parent
        }
        return false
    }
}
