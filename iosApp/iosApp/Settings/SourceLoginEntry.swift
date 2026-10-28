import UIKit

@MainActor
enum SourceLoginEntry {
    static func open(sourceURL: String, from presenter: UIViewController) {
        open(sourceURL: sourceURL, from: presenter, rssSource: false)
    }

    static func openRss(sourceURL: String, from presenter: UIViewController) {
        open(sourceURL: sourceURL, from: presenter, rssSource: true)
    }

    private static func open(sourceURL: String, from presenter: UIViewController, rssSource: Bool) {
        guard !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !presenter.isBeingPresented, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            presenter.presentedViewController == nil,
            UIApplication.shared.applicationState == .active,
            presenter.viewIfLoaded?.window?.isKeyWindow == true,
            presenter.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: presenter.viewIfLoaded?.window)
        else { return }
        if presenter.navigationController != nil, !presenter.canPerformNavigationAction { return }
        let controller = SourceLoginFormViewController(
            sourceURL: sourceURL, screen: SourceLoginScreenAdapter(rssSource: rssSource)
        )
        .configuredForDrillDownPresentation()
        controller.returnOwner = presenter
        // SourceLoginActivity owns a full-screen dialog, independently of the caller's navigation stack.
        let navigation = SwipeBackNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .overFullScreen
        navigation.modalTransitionStyle = .crossDissolve
        navigation.modalPresentationCapturesStatusBarAppearance = true
        navigation.view.backgroundColor = .clear
        navigation.view.isOpaque = false
        presenter.present(navigation, animated: true)
    }

    static func close(_ controller: UIViewController, returningTo owner: UIViewController?, message: String? = nil) {
        let navigation = controller.navigationController
        let receiver: UIViewController?
        if let owner {
            receiver = owner
        } else if let navigation,
            let index = navigation.viewControllers.firstIndex(where: { $0 === controller }), index > 0
        {
            receiver = navigation.viewControllers[index - 1]
        } else {
            receiver = nil
        }
        let window = receiver?.viewIfLoaded?.window
        let feedback = { [weak receiver, weak window] in
            guard let message, let receiver, let window,
                receiver.viewIfLoaded?.window === window, window.isKeyWindow,
                window.windowScene?.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active,
                !receiver.isBeingDismissed, receiver.presentedViewController == nil,
                receiver.navigationController == nil || receiver.canPerformNavigationAction
            else { return }
            receiver.showTransientMessage(message)
        }
        if let navigation, navigation.viewControllers.first !== controller {
            navigation.popViewController(animated: true)
            if let transition = navigation.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { context in
                    if !context.isCancelled { feedback() }
                }
            } else {
                feedback()
            }
        } else {
            let dismissingController: UIViewController = navigation ?? controller
            dismissingController.dismiss(animated: true, completion: feedback)
        }
    }
}
