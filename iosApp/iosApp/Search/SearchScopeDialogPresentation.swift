import ObjectiveC
import UIKit
import shared

/// Captures the caller's visible source, not the container UIKit forwards `present` to.
@MainActor
final class SearchScopeDialogOwnership {
    private weak var source: UIViewController?
    private weak var leaf: UIViewController?
    private weak var root: UIViewController?
    private(set) weak var window: UIWindow?

    init?(source: UIViewController) {
        guard let window = source.viewIfLoaded?.window, let root = window.rootViewController else { return nil }
        self.source = source
        leaf = Self.visibleSource(from: source)
        self.window = window
        self.root = root
    }

    var hasSameSource: Bool {
        guard let source, let leaf, let window, let root, window.rootViewController === root,
            Self.visibleSource(from: source) === leaf,
            let chain = Self.chain(from: leaf), chain.contains(where: { $0 === source }), chain.last === root
        else { return false }
        return Self.hasSelectedContainers(chain)
    }

    func isCurrent(allowing dialog: UIViewController? = nil, completing dismissal: UIViewController? = nil) -> Bool {
        guard hasSameSource, let source, let leaf, let window,
            Self.isActive(window), let host = source.viewIfLoaded, let leafView = leaf.viewIfLoaded,
            host.window === window, leafView.window === window,
            !host.isHidden, host.alpha > 0, !leafView.isHidden, leafView.alpha > 0,
            let chain = Self.chain(from: leaf)
        else { return false }
        for controller in chain {
            guard Self.isStable(controller, allowing: dialog ?? dismissal) else { return false }
            // A navigation controller may be the actual presenter while its visible child
            // also reports that modal. Both must allow this same dialog, not require nil.
            if let presented = controller.presentedViewController,
                presented !== dialog, !chain.contains(where: { $0 === presented })
            {
                return false
            }
        }
        if let dialog, let presenter = dialog.presentingViewController {
            return presenter.presentedViewController === dialog && chain.contains(where: { $0 === presenter })
        }
        return true
    }

    static func ownsPresentation(_ dialog: UIViewController) -> Bool {
        guard let host = dialog.viewIfLoaded, let window = host.window, isActive(window),
            !host.isHidden, host.alpha > 0, host.superview != nil,
            let presenter = dialog.presentingViewController, presenter.presentedViewController === dialog,
            let chain = Self.chain(from: dialog), chain.last === window.rootViewController, hasSelectedContainers(chain)
        else { return false }
        for controller in chain {
            guard isStable(controller, allowing: nil) else { return false }
            if let presented = controller.presentedViewController, !chain.contains(where: { $0 === presented }) {
                return false
            }
        }
        return true
    }

    private static func isActive(_ window: UIWindow) -> Bool {
        !window.isHidden && window.alpha > 0 && window.isKeyWindow
            && UIApplication.shared.applicationState == .active
            && window.windowScene?.activationState == .foregroundActive
            && AppLockManager.shared.isUnlocked(in: window)
    }

    private static func isStable(_ controller: UIViewController, allowing dialog: UIViewController?) -> Bool {
        guard !controller.isBeingPresented, !controller.isBeingDismissed,
            !controller.isMovingFromParent, !controller.isMovingToParent
        else { return false }
        guard let transition = controller.transitionCoordinator else { return true }
        guard let dialog else { return false }
        return transition.viewController(forKey: .from) === dialog || transition.viewController(forKey: .to) === dialog
    }

    private static func hasSelectedContainers(_ chain: [UIViewController]) -> Bool {
        for controller in chain {
            if let navigation = controller.parent as? UINavigationController, navigation.topViewController !== controller {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
        }
        return true
    }

    private static func chain(from controller: UIViewController) -> [UIViewController]? {
        var result: [UIViewController] = []
        var current: UIViewController? = controller
        while let candidate = current, result.count < 64 {
            guard !result.contains(where: { $0 === candidate }) else { return nil }
            result.append(candidate)
            current = candidate.parent ?? candidate.presentingViewController
        }
        return current == nil ? result : nil
    }

    private static func visibleSource(from controller: UIViewController) -> UIViewController {
        var current = controller
        for _ in 0..<64 {
            if let navigation = current as? UINavigationController, let top = navigation.topViewController {
                current = top
            } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else {
                break
            }
        }
        return current
    }
}

@MainActor
enum SearchScopeDialogSourceLoader {
    private static var requestKey: UInt8 = 0

    static func load(from presenter: UIViewController, onLoaded: @escaping ([BookSource]) -> Void) {
        guard let ownership = SearchScopeDialogOwnership(source: presenter), ownership.isCurrent() else { return }
        activeRequest(for: presenter)?.cancel()
        let request = SearchScopeDialogSourceRequest(ownership: ownership)
        objc_setAssociatedObject(presenter, &requestKey, request, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        request.task = Task { [weak presenter, weak request] in
            defer {
                request?.stopObserving()
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
                    !request.isCancelled, request.ownership.isCurrent()
                else { return }
                onLoaded(sources)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                    let presenter, let request, activeRequest(for: presenter) === request,
                    !request.isCancelled, request.ownership.isCurrent()
                else { return }
                presenter.presentError(error)
            }
        }
    }

    private static func activeRequest(for presenter: UIViewController) -> SearchScopeDialogSourceRequest? {
        objc_getAssociatedObject(presenter, &requestKey) as? SearchScopeDialogSourceRequest
    }
}

@MainActor
private final class SearchScopeDialogSourceRequest: NSObject {
    let ownership: SearchScopeDialogOwnership
    private(set) var isCancelled = false
    var task: Task<Void, Never>?

    init(ownership: SearchScopeDialogOwnership) {
        self.ownership = ownership
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(invalidated(_:)), name: name, object: nil)
        }
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
        stopObserving()
    }

    func stopObserving() { NotificationCenter.default.removeObserver(self) }

    @objc private func invalidated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== ownership.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== ownership.window { return }
        cancel()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        source: UIViewController
    ) -> UIPresentationController? {
        (presented as? SearchScopeViewController)?.bindSource(source)
        return SearchScopeDialogPresentationController(presentedViewController: presented, presenting: presenting)
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
    private var isRemoved = false

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
        guard !isRemoved else { return dialogView }
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
        isRemoved = false
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
        (presentedViewController as? SearchScopeViewController)?.presentationTransitionEnded(completed: completed)
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
        (presentedViewController as? SearchScopeViewController)?.dismissalTransitionEnded(completed: completed)
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
        isRemoved = true
        NotificationCenter.default.removeObserver(self)
        isObservingKeyboard = false
        keyboardFrameInScreen = nil
        dimmingControl.removeFromSuperview()
        if presentedViewController.viewIfLoaded?.superview === dialogView {
            presentedViewController.viewIfLoaded?.removeFromSuperview()
        }
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
        guard isPresented, let scope = presentedViewController as? SearchScopeViewController
        else { return false }
        let accepted = scope.cancelSelection(animated: !UIAccessibility.isReduceMotionEnabled)
        if accepted { dimmingControl.isUserInteractionEnabled = false }
        return accepted
    }
}

private final class SearchScopeDialogView: UIView {
    var onEscape: (() -> Bool)?

    override func accessibilityPerformEscape() -> Bool {
        onEscape?() ?? false
    }
}

@MainActor
final class SearchScopeDialogHostView: UIView {
    var onDetach: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { onDetach?() }
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { onDetach?() }
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
