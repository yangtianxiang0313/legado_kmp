import ObjectiveC
import UIKit
import shared

@MainActor
enum SearchScopeDialogSourceLoader {
    private static var requestKey: UInt8 = 0

    static func load(from presenter: UIViewController, onLoaded: @escaping ([BookSource]) -> Void) {
        guard canPresent(from: presenter) else { return }
        activeRequest(for: presenter)?.task?.cancel()
        let request = SearchScopeDialogSourceRequest()
        objc_setAssociatedObject(presenter, &requestKey, request, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        request.task = Task { [weak presenter, weak request] in
            defer {
                if let presenter, let request, activeRequest(for: presenter) === request {
                    objc_setAssociatedObject(presenter, &requestKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                }
            }
            do {
                try Task.checkCancellation()
                let facade = try SharedRuntime.sourceManagementFacade().get()
                let sources = try await facade.getAllSourcesAsync()
                try Task.checkCancellation()
                guard let presenter, let request, activeRequest(for: presenter) === request,
                    canPresent(from: presenter)
                else { return }
                onLoaded(sources)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                    let presenter, let request, activeRequest(for: presenter) === request,
                    canPresent(from: presenter)
                else { return }
                presenter.presentError(error)
            }
        }
    }

    private static func activeRequest(for presenter: UIViewController) -> SearchScopeDialogSourceRequest? {
        objc_getAssociatedObject(presenter, &requestKey) as? SearchScopeDialogSourceRequest
    }

    private static func canPresent(from presenter: UIViewController) -> Bool {
        guard let window = presenter.viewIfLoaded?.window,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, controller.presentedViewController == nil
            else { return false }
            if let navigation = controller.parent as? UINavigationController, navigation.topViewController !== controller {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            current = controller.parent
        }
        return true
    }
}

private final class SearchScopeDialogSourceRequest {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

final class SearchScopeDialogTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    override init() {
        super.init()
    }

    func presentationController(
        forPresented presented: UIViewController,
        presenting: UIViewController?,
        source _: UIViewController
    ) -> UIPresentationController? {
        SearchScopeDialogPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(
        forPresented _: UIViewController,
        presenting _: UIViewController,
        source _: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        SearchScopeDialogAnimator(isPresenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        SearchScopeDialogAnimator(isPresenting: false)
    }
}

private final class SearchScopeDialogPresentationController: UIPresentationController,
    UIAdaptivePresentationControllerDelegate
{
    private let dimmingControl = UIControl()
    private let dialogView = SearchScopeDialogView()
    private var keyboardFrameInScreen: CGRect?
    private var isObservingKeyboard = false
    private var isPresented = false

    override init(presentedViewController: UIViewController, presenting presentingViewController: UIViewController?) {
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
        delegate = self
        dimmingControl.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        dimmingControl.isAccessibilityElement = false
        dimmingControl.isUserInteractionEnabled = false
        dimmingControl.addTarget(self, action: #selector(cancelFromOutside), for: .touchUpInside)
        dialogView.layer.cornerRadius = 8
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        dialogView.onEscape = { [weak self] in self?.cancel() ?? false }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var presentedView: UIView? {
        let contentView = presentedViewController.view!
        if contentView.superview !== dialogView {
            contentView.frame = dialogView.bounds
            contentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dialogView.addSubview(contentView)
        }
        return dialogView
    }

    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        var available = containerView.bounds.inset(by: containerView.safeAreaInsets)
        guard available.width > 0, available.height > 0 else { return .zero }
        if let keyboardFrameInScreen, let window = containerView.window {
            let keyboardFrame = window.screen.coordinateSpace.convert(keyboardFrameInScreen, to: containerView)
            let overlap = available.intersection(keyboardFrame)
            if !overlap.isNull, !overlap.isEmpty {
                // Floating keyboards may leave more usable room below than above.
                let heightAbove = max(0, overlap.minY - available.minY)
                let heightBelow = max(0, available.maxY - overlap.maxY)
                if heightAbove >= heightBelow {
                    available.size.height = heightAbove
                } else {
                    available.origin.y = overlap.maxY
                    available.size.height = heightBelow
                }
            }
        }
        let size = CGSize(width: available.width * 0.9, height: available.height * 0.8)
        return CGRect(
            x: available.midX - size.width / 2,
            y: available.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        guard let containerView else { return }
        dialogView.frame = frameOfPresentedViewInContainerView
        _ = presentedView
        dimmingControl.frame = containerView.bounds
        dimmingControl.alpha = 0
        // Only this sibling behind the dialog handles outside taps.
        containerView.insertSubview(dimmingControl, at: 0)
        observeKeyboard()
        animateDimming(to: 1)
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        isPresented = completed
        dimmingControl.isUserInteractionEnabled = completed
        if completed {
            dimmingControl.alpha = 1
        } else {
            removePresentation()
        }
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        dimmingControl.isUserInteractionEnabled = false
        animateDimming(to: 0)
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed {
            isPresented = false
            removePresentation()
        } else {
            dimmingControl.alpha = 1
            dimmingControl.isUserInteractionEnabled = true
            containerView?.setNeedsLayout()
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        dimmingControl.frame = containerView?.bounds ?? .zero
        dialogView.frame = frameOfPresentedViewInContainerView
    }

    func adaptivePresentationStyle(for _: UIPresentationController) -> UIModalPresentationStyle { .none }

    func adaptivePresentationStyle(
        for _: UIPresentationController,
        traitCollection _: UITraitCollection
    ) -> UIModalPresentationStyle { .none }

    private func animateDimming(to alpha: CGFloat) {
        let coordinated =
            presentedViewController.transitionCoordinator?.animate(
                alongsideTransition: { _ in self.dimmingControl.alpha = alpha }
            ) ?? false
        if !coordinated {
            dimmingControl.alpha = alpha
        }
    }

    private func observeKeyboard() {
        guard !isObservingKeyboard else { return }
        isObservingKeyboard = true
        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardFrameChanged(_:)), name: name, object: nil)
        }
    }

    private func removePresentation() {
        NotificationCenter.default.removeObserver(self)
        isObservingKeyboard = false
        keyboardFrameInScreen = nil
        dimmingControl.removeFromSuperview()
        dialogView.removeFromSuperview()
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        let info = notification.userInfo ?? [:]
        keyboardFrameInScreen =
            notification.name == UIResponder.keyboardWillHideNotification
            ? nil : (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        guard let containerView, !presentedViewController.isBeingDismissed else { return }
        containerView.setNeedsLayout()
        let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        guard duration > 0, !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation { containerView.layoutIfNeeded() }
            return
        }
        let curve = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        let options = UIView.AnimationOptions(rawValue: curve << 16).union([.beginFromCurrentState, .allowUserInteraction])
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            containerView.layoutIfNeeded()
        }
    }

    @objc private func cancelFromOutside() {
        _ = cancel()
    }

    private func cancel() -> Bool {
        guard isPresented, !presentedViewController.isBeingDismissed,
            presentedViewController.presentedViewController == nil
        else { return false }
        dimmingControl.isUserInteractionEnabled = false
        if let scope = presentedViewController as? SearchScopeViewController {
            scope.cancelSelection(animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            presentedViewController.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
        }
        return true
    }
}

private final class SearchScopeDialogView: UIView {
    var onEscape: (() -> Bool)?

    override func accessibilityPerformEscape() -> Bool {
        onEscape?() ?? false
    }
}

private final class SearchScopeDialogAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        transitionContext?.isAnimated == false || UIAccessibility.isReduceMotionEnabled ? 0 : 0.18
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key),
            let view = transitionContext.view(forKey: isPresenting ? .to : .from) ?? controller.presentationController?.presentedView
        else {
            transitionContext.completeTransition(false)
            return
        }
        if isPresenting {
            view.frame =
                controller.presentationController?.frameOfPresentedViewInContainerView
                ?? transitionContext.finalFrame(for: controller)
            transitionContext.containerView.addSubview(view)
            view.alpha = 0
        }
        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: { view.alpha = self.isPresenting ? 1 : 0 },
            completion: { _ in
                let completed = !transitionContext.transitionWasCancelled
                if self.isPresenting ? !completed : completed {
                    view.removeFromSuperview()
                }
                view.alpha = 1
                transitionContext.completeTransition(completed)
            }
        )
    }
}
