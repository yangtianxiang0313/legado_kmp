import UIKit

/// Reuses the AndroidAlertBuilder yes/no body; cancellation is not the destructive No action.
@MainActor
final class ReaderExitConfirmationDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    var canDecide: (() -> Bool)?

    private enum Phase {
        case appearing
        case active
        case closing
        case finished
    }

    private var phase: Phase = .appearing
    private var pendingDecision: Bool?
    private var onDecision: ((Bool?) -> Void)?
    private var hasBegunPresentation = false
    private var isVisible = false
    private var ownsDismissalCompletion = false
    private var presentationCancelled = false
    private var waitsForDismissalTransition = false
    private weak var sourcePresenter: UIViewController?
    private weak var sourceNavigation: UINavigationController?
    private let outsideControl = UIControl()
    private let body: ReaderRestoreProgressDialogBodyView
    private let accessibilityIdentifierPrefix: String

    init(
        title: String, message: String, confirmTitle: String = "确定",
        accessibilityIdentifierPrefix: String = "reader.exitPreview", onDecision: @escaping (Bool?) -> Void
    ) {
        body = ReaderRestoreProgressDialogBodyView(
            title: title, message: message, confirmTitle: confirmTitle,
            accessibilityIdentifierPrefix: accessibilityIdentifierPrefix)
        self.accessibilityIdentifierPrefix = accessibilityIdentifierPrefix
        self.onDecision = onDecision
        super.init(nibName: nil, bundle: nil)
        self.title = title
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canInteract else { return nil }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel(_:))),
            UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(cancel(_:))),
        ].map { command in
            command.discoverabilityTitle = "取消"
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func loadView() {
        let host = ReaderExitConfirmationHostView()
        host.onDetach = { [weak self] in self?.scheduleDismissalCompletion() }
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityIdentifier = "\(accessibilityIdentifierPrefix).dialog"
        view.accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel(_:)), for: .touchUpInside)
        body.onDecision = { [weak self] in self?.close(decision: $0) }
        view.addSubview(outsideControl)
        view.addSubview(body)
        view.accessibilityElements = [body]
        body.applyFonts(traits: traitCollection)
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !hasBegunPresentation {
            sourcePresenter = presentingViewController
            sourceNavigation = (presentingViewController as? UINavigationController) ?? presentingViewController?.navigationController
        }
        hasBegunPresentation = true
        presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        if presentationCancelled {
            cancelPresentation()
            return
        }
        // An interrupted external dismissal must not replay the old selection.
        pendingDecision = nil
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: body.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard phase != .finished else { return }
        isVisible = false
        if isPresentationBeingDismissed {
            if !ownsDismissalCompletion { pendingDecision = nil }
            phase = .closing
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                if !context.isCancelled { scheduleDismissalCompletion() }
            }
        } else {
            // Being covered by another controller cannot preserve an earlier Yes / No.
            pendingDecision = nil
        }
        updateInteraction()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDismissalCompletion()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // A child modal's dismissal is not a decision about this dialog.
        guard presentedViewController == nil, phase != .finished else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        pendingDecision = nil
        phase = .closing
        isVisible = false
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishDismissalIfDetached()
            scheduleDismissalCompletion()
            completion?()
        }
    }

    func cancelPresentation() {
        presentationCancelled = true
        pendingDecision = nil
        guard phase != .finished else { return }
        phase = .closing
        isVisible = false
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
        guard let presenter = presentingViewController, presenter.presentedViewController === self else {
            scheduleDismissalCompletion()
            return
        }
        // Cancel the owned hierarchy, including a child that would intercept dismiss(on: self).
        ownsDismissalCompletion = true
        presenter.dismiss(animated: false) { [self] in
            ownsDismissalCompletion = false
            finishDismissalIfDetached()
            scheduleDismissalCompletion()
        }
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool { canInteract }

    func presentationControllerWillDismiss(_: UIPresentationController) {
        guard phase != .finished else { return }
        pendingDecision = nil
        phase = .closing
        isVisible = false
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        guard phase != .finished else { return }
        pendingDecision = nil
        phase = .closing
        scheduleDismissalCompletion()
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) { close(decision: nil) }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(decision: nil)
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(cancel(_:)) || action == #selector(cancelOperation(_:)) { return canInteract }
        return super.canPerformAction(action, withSender: sender)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
            previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
                || previousTraitCollection?.displayScale != traitCollection.displayScale
        else { return }
        body.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        let width = min(safe.width, view.bounds.width * dialogWidthFraction)
        let height = min(safe.height, body.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        body.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private var canInteract: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, let presenter = presentingViewController,
            presenter.presentedViewController === self,
            let window = viewIfLoaded?.window, window.isKeyWindow, !window.isHidden, window.alpha > 0,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            current = controller.parent
        }
        return true
    }

    private var isPresentationBeingDismissed: Bool {
        if isBeingDismissed { return true }
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent
        }
        return false
    }

    private func updateInteraction() {
        let enabled = phase == .active && isVisible
        outsideControl.isEnabled = enabled
        body.isEditingEnabled = enabled
    }

    @objc private func cancel(_ sender: Any?) { close(decision: nil) }
    @objc private func cancelOperation(_ sender: Any?) { close(decision: nil) }

    private func close(decision: Bool?) {
        guard canInteract else { return }
        let accepted = decision == nil || (canDecide?() ?? true)
        guard canInteract else { return }
        pendingDecision = accepted ? decision : nil
        phase = .closing
        isVisible = false
        ownsDismissalCompletion = true
        updateInteraction()
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            ownsDismissalCompletion = false
            finishDismissalIfDetached()
            scheduleDismissalCompletion()
        }
    }

    private func scheduleDismissalCompletion() {
        guard hasBegunPresentation, !ownsDismissalCompletion, phase != .finished else { return }
        DispatchQueue.main.async { [self] in finishDismissalIfDetached() }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, !ownsDismissalCompletion, phase != .finished,
            presentingViewController == nil, presentedViewController == nil, parent == nil,
            viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil
        else { return }
        if waitForOwnedDismissalTransition() { return }
        phase = .finished
        isVisible = false
        let decision = pendingDecision
        let validity = canDecide
        let callback = onDecision
        pendingDecision = nil
        canDecide = nil
        onDecision = nil
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
        // UIKit may release the presenter's transition coordinator after the dismiss completion.
        DispatchQueue.main.async { [self] in
            guard presentingViewController == nil, presentedViewController == nil,
                parent == nil, viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil
            else {
                callback?(nil)
                return
            }
            callback?(!presentationCancelled && decision != nil && (validity?() ?? true) ? decision : nil)
        }
    }

    private func waitForOwnedDismissalTransition() -> Bool {
        if waitsForDismissalTransition { return true }
        guard let transition = sourceNavigation?.transitionCoordinator ?? sourcePresenter?.transitionCoordinator else {
            return false
        }
        guard transition.viewController(forKey: .from) === self || transition.viewController(forKey: .to) === self else {
            pendingDecision = nil
            return false
        }
        waitsForDismissalTransition = true
        let registered = transition.animate(alongsideTransition: nil) { [self] _ in
            waitsForDismissalTransition = false
            scheduleDismissalCompletion()
        }
        if !registered {
            waitsForDismissalTransition = false
            return false
        }
        return true
    }
}

@MainActor
private final class ReaderExitConfirmationHostView: UIView {
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
