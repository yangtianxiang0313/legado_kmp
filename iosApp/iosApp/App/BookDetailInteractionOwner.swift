import UIKit

@MainActor
enum BookDetailInteractionOwner {
    static func dismissOwnedForAction(
        _ modal: UIViewController, owner: UIViewController, scene: UIWindowScene?, completion: @escaping () -> Void
    ) {
        guard let scene, scene.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            owner.navigationController?.topViewController === owner
        else { return }
        if owner.presentedViewController === modal {
            guard
                modal.presentingViewController === owner
                    || modal.presentingViewController === owner.navigationController
            else { return }
            // UIAlertController may already be dismissing when it invokes its action handler.
            if modal.isBeingDismissed, let transition = modal.transitionCoordinator {
                if transition.animate(
                    alongsideTransition: nil,
                    completion: { context in
                        if !context.isCancelled { completion() }
                    })
                {
                    return
                }
            }
            guard canInteract(owner: owner, scene: scene, ownedModal: modal) else { return }
            modal.dismiss(animated: true, completion: completion)
        } else {
            guard modal.presentingViewController == nil, modal.viewIfLoaded?.window == nil,
                canInteract(owner: owner, scene: scene)
            else { return }
            completion()
        }
    }

    static func canInteract(
        owner: UIViewController, scene: UIWindowScene?, ownedModal: UIViewController? = nil
    ) -> Bool {
        guard let scene, let navigation = owner.navigationController, navigation.topViewController === owner
        else { return false }
        guard let ownedModal else {
            return owner.canPerformNavigationAction && owner.viewIfLoaded?.window?.windowScene === scene
        }
        // A full-screen owned modal may remove the detail's view from its window.
        guard owner.presentedViewController === ownedModal, ownedModal.presentedViewController == nil,
            ownedModal.presentingViewController === owner || ownedModal.presentingViewController === navigation,
            !ownedModal.isBeingPresented, !ownedModal.isBeingDismissed, !ownedModal.isMovingFromParent,
            ownedModal.transitionCoordinator == nil, navigation.transitionCoordinator == nil,
            let window = ownedModal.viewIfLoaded?.window, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.windowScene === scene, scene.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            ownedModal.viewIfLoaded?.isHidden == false, (ownedModal.viewIfLoaded?.alpha ?? 0) > 0
        else { return false }
        var ancestor: UIViewController? = owner
        while let controller = ancestor {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingToParent, !controller.isMovingFromParent,
                controller.presentedViewController == nil || controller.presentedViewController === ownedModal
            else { return false }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            if controller === navigation { return true }
            ancestor = controller.parent
        }
        return false
    }
}
