import UIKit

/// Owns only deletion confirmation lifetime; selection and deletion remain with the host.
@MainActor
final class SourceManagementDeletionCoordinator: NSObject {
    @MainActor
    private final class Request {
        let generation: UUID
        let sourceURLs: [String]
        let isCurrent: () -> Bool
        let onConfirm: ([String]) -> Void
        weak var window: UIWindow?
        weak var scene: UIWindowScene?
        weak var navigation: UINavigationController?
        weak var presentationOwner: UIViewController?
        let ancestry: [ObjectIdentifier]
        var dialog: ReaderRestoreProgressDialogViewController?

        init(
            generation: UUID, sourceURLs: [String], isCurrent: @escaping () -> Bool,
            onConfirm: @escaping ([String]) -> Void, window: UIWindow,
            scene: UIWindowScene, presenter: UIViewController
        ) {
            self.generation = generation
            self.sourceURLs = sourceURLs
            self.isCurrent = isCurrent
            self.onConfirm = onConfirm
            self.window = window
            self.scene = scene
            navigation = presenter.navigationController
            var ancestry: [ObjectIdentifier] = []
            var current: UIViewController? = presenter
            while let controller = current {
                ancestry.append(ObjectIdentifier(controller))
                current = controller.parent
            }
            self.ancestry = ancestry
        }
    }

    private weak var presenter: UIViewController?
    private let canStart: () -> Bool
    private var generation = UUID()
    private var request: Request?

    init(presenter: UIViewController, canStart: @escaping () -> Bool) {
        self.presenter = presenter
        self.canStart = canStart
        super.init()
        let center = NotificationCenter.default
        for name in [
            UIApplication.willResignActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
        ] {
            center.addObserver(self, selector: #selector(lifecycleWillLeave(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification,
            UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(lifecycleDidActivate(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func confirm(
        sourceURLs: [String], sourceName: String?, isCurrent: @escaping () -> Bool,
        onConfirm: @escaping ([String]) -> Void
    ) {
        invalidateIfNeeded()
        guard request == nil, !sourceURLs.isEmpty, canStart(), isCurrent(), let presenter,
            let window = presenter.viewIfLoaded?.window, let scene = window.windowScene
        else { return }
        let pending = Request(
            generation: UUID(), sourceURLs: sourceURLs, isCurrent: isCurrent,
            onConfirm: onConfirm, window: window, scene: scene, presenter: presenter)
        guard ownsLifecycle(pending), presenter.presentedViewController == nil else { return }
        generation = pending.generation
        request = pending
        let message = sourceName.map { "是否确认删除？\n" + $0 } ?? "是否确认删除？"
        let dialog = ReaderRestoreProgressDialogViewController(
            title: "提醒", message: message,
            accessibilityIdentifierPrefix: "sourceManagement.delete"
        ) { [weak self, weak pending] confirmed in
            guard let self, let pending, self.matches(pending) else { return }
            let accepted = confirmed && self.permitsConfirmation(pending, detachedOnly: true)
            // Consume before invoking host code, including any reentrant presentation.
            self.request = nil
            self.generation = UUID()
            if accepted { pending.onConfirm(pending.sourceURLs) }
        }
        pending.dialog = dialog
        dialog.canConfirm = { [weak self, weak pending] in
            guard let self, let pending else { return false }
            return self.permitsConfirmation(pending, detachedOnly: false)
        }
        dialog.onClose = { [weak self, weak pending] in
            guard let self, let pending, self.matches(pending) else { return }
            self.request = nil
            self.generation = UUID()
        }
        presenter.present(dialog, animated: true) { [weak self, pending] in
            self?.finishPresentation(pending)
        }
        // A host may forward presentation after the current menu-delivery stack unwinds.
        // Keep the request until UIKit has had a chance to attach the actual owner.
        _ = bindPresentationOwner(pending)
        DispatchQueue.main.async { [weak self, pending] in self?.finishPresentation(pending) }
    }

    func invalidateIfNeeded() {
        guard let request else { return }
        guard matches(request), ownsLifecycle(request), request.isCurrent(),
            let presenter, let dialog = request.dialog
        else {
            cancelPresentation()
            return
        }
        if isAttached(dialog, to: presenter, request: request) { return }
        if isDetached(dialog), presenter.presentedViewController == nil, canStart() { return }
        cancelPresentation()
    }

    func cancelPresentation() {
        let previous = request
        request = nil
        generation = UUID()
        if let previous { dismissOwnedDialog(previous) }
    }

    private func finishPresentation(_ pending: Request) {
        guard matches(pending) else {
            dismissOwnedDialog(pending)
            return
        }
        guard pending.dialog?.isBeingPresented != true else { return }
        guard bindPresentationOwner(pending) else {
            cancelPresentation()
            return
        }
        invalidateIfNeeded()
    }

    private func bindPresentationOwner(_ pending: Request) -> Bool {
        guard let dialog = pending.dialog, let owner = dialog.presentingViewController,
            pending.ancestry.contains(ObjectIdentifier(owner)), owner.presentedViewController === dialog,
            pending.presentationOwner == nil || pending.presentationOwner === owner
        else { return false }
        pending.presentationOwner = owner
        return true
    }

    private func dismissOwnedDialog(_ previous: Request) {
        // Never let a stale callback dismiss a replacement or an independent child modal.
        guard let dialog = previous.dialog, !dialog.isBeingPresented,
            let owner = dialog.presentingViewController,
            previous.ancestry.contains(ObjectIdentifier(owner)),
            previous.presentationOwner == nil || previous.presentationOwner === owner,
            owner.presentedViewController === dialog,
            dialog.presentedViewController == nil
        else { return }
        dialog.dismiss(animated: false)
    }

    private func matches(_ pending: Request) -> Bool {
        request === pending && generation == pending.generation
    }

    private func permitsConfirmation(_ pending: Request, detachedOnly: Bool) -> Bool {
        guard matches(pending), ownsLifecycle(pending), pending.isCurrent(),
            let presenter, let dialog = pending.dialog
        else { return false }
        if !detachedOnly, isAttached(dialog, to: presenter, request: pending) { return true }
        return isDetached(dialog) && presenter.presentedViewController == nil && canStart()
    }

    private func isAttached(
        _ dialog: UIViewController, to presenter: UIViewController, request: Request
    ) -> Bool {
        presenter.presentedViewController === dialog
            && request.presentationOwner != nil
            && dialog.presentingViewController === request.presentationOwner
            && request.presentationOwner?.presentedViewController === dialog
            && dialog.parent == nil && dialog.presentedViewController == nil
            && dialog.viewIfLoaded?.window === request.window
            && dialog.viewIfLoaded?.superview != nil
    }

    private func isDetached(_ dialog: UIViewController) -> Bool {
        dialog.presentingViewController == nil && dialog.parent == nil
            && dialog.viewIfLoaded?.window == nil && dialog.viewIfLoaded?.superview == nil
            && dialog.presentedViewController == nil
    }

    private func ownsLifecycle(_ pending: Request) -> Bool {
        guard let presenter, let window = pending.window, let scene = pending.scene,
            UIApplication.shared.applicationState == .active,
            window.isKeyWindow, !window.isHidden, window.alpha > 0.01, window.windowScene === scene,
            scene.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window,
            presenter.navigationController === pending.navigation
        else { return false }
        if let navigation = pending.navigation, navigation.topViewController !== presenter {
            return false
        }
        var ancestry: [ObjectIdentifier] = []
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let transition = controller.transitionCoordinator {
                // The owned over-full-screen dialog also exposes its transition on the host.
                // Navigation, tab and unrelated presentation transitions still invalidate it.
                guard let dialog = pending.dialog,
                    transition.viewController(forKey: .from) === dialog
                        || transition.viewController(forKey: .to) === dialog
                else { return false }
            }
            if let modal = controller.presentedViewController, modal !== pending.dialog { return false }
            if let tabs = controller as? UITabBarController,
                let child = ancestry.last, tabs.selectedViewController.map(ObjectIdentifier.init) != child
            {
                return false
            }
            ancestry.append(ObjectIdentifier(controller))
            current = controller.parent
        }
        return ancestry == pending.ancestry
    }

    @objc private func lifecycleWillLeave(_ notification: Notification) {
        guard let request else { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification:
            cancelPresentation()
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification:
            if let scene = notification.object as? UIWindowScene, scene === request.scene {
                cancelPresentation()
            }
        case UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification:
            if let window = notification.object as? UIWindow, window === request.window {
                cancelPresentation()
            }
        default:
            break
        }
    }

    @objc private func lifecycleDidActivate(_ notification: Notification) {
        guard let request else { return }
        if let scene = notification.object as? UIWindowScene, scene !== request.scene { return }
        if let window = notification.object as? UIWindow, window !== request.window { return }
        invalidateIfNeeded()
    }
}
