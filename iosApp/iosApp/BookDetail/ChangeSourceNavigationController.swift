import UIKit

/// The original full-window Dialog keeps the platform drawable's 16dp padding.
final class ChangeSourceNavigationController: UINavigationController, UIViewControllerTransitioningDelegate {
    override init(rootViewController: UIViewController) {
        super.init(rootViewController: rootViewController)
        modalPresentationStyle = .custom
        transitioningDelegate = self
        setNavigationBarHidden(true, animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "changeSource.dialog"
        view.clipsToBounds = true
    }

    func presentationController(
        forPresented presented: UIViewController, presenting: UIViewController?, source _: UIViewController
    ) -> UIPresentationController? {
        ChangeSourceDialogPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(
        forPresented _: UIViewController, presenting _: UIViewController, source _: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        ChangeSourceDialogAnimator(presenting: true)
    }

    func animationController(forDismissed _: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        ChangeSourceDialogAnimator(presenting: false)
    }
}

final class ChangeSourceDialogPresentationController: UIPresentationController,
    UIAdaptivePresentationControllerDelegate
{
    private let dimmingView = UIView()

    override init(presentedViewController: UIViewController, presenting presentingViewController: UIViewController?) {
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
        delegate = self
        dimmingView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        dimmingView.accessibilityElementsHidden = true
        dimmingView.accessibilityIdentifier = "changeSource.dialogBackdrop"
        // The drawable inset is inside Android's full-size window, not an outside-cancel area.
    }

    override var shouldRemovePresentersView: Bool { false }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView else { return .zero }
        let available = containerView.bounds.inset(by: containerView.safeAreaInsets)
        return available.insetBy(
            dx: min(16, max(0, available.width / 2)), dy: min(16, max(0, available.height / 2)))
    }

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        dimmingView.frame = containerView.bounds
        dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmingView.alpha = 0
        containerView.insertSubview(dimmingView, at: 0)
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 1 })
        } else {
            dimmingView.alpha = 1
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { dimmingView.removeFromSuperview() }
    }

    override func dismissalTransitionWillBegin() {
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 0 })
        } else {
            dimmingView.alpha = 0
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { dimmingView.removeFromSuperview() }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        dimmingView.frame = containerView?.bounds ?? .zero
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    func adaptivePresentationStyle(for _: UIPresentationController) -> UIModalPresentationStyle { .none }
}

private final class ChangeSourceDialogAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    private let presenting: Bool

    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using _: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0 : 0.2
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        guard let controller = context.viewController(forKey: key),
            let view = context.view(forKey: presenting ? .to : .from)
        else {
            context.completeTransition(false)
            return
        }
        if presenting {
            view.frame = context.finalFrame(for: controller)
            context.containerView.addSubview(view)
        }
        view.alpha = presenting ? 0 : 1
        UIView.animate(
            withDuration: transitionDuration(using: context), delay: 0, options: [.beginFromCurrentState, .curveEaseInOut],
            animations: { view.alpha = self.presenting ? 1 : 0 },
            completion: { _ in
                view.alpha = 1
                context.completeTransition(!context.transitionWasCancelled)
            })
    }
}
