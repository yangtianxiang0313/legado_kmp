import UIKit

/// ReadBookActivity.restoreLastBookProcess at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// Use a fresh instance per presentation; the caller owns progress and presentation styling.
@MainActor
final class ReaderRestoreProgressDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    enum ActionLayout {
        case yesNo
        /// LoadMoreView only declares a neutral Retry; outside / Escape cancellation reports false.
        case retry
    }

    /// Nil permits confirmation. Checked at selection and again immediately before delivery.
    var canConfirm: (() -> Bool)?

    /// Runs once after onDecision, only after the dialog has actually detached.
    var onClose: (() -> Void)?

    private enum Phase {
        case appearing
        case active
        case closing
        case finished
    }

    private var phase: Phase = .appearing
    private var onDecision: ((Bool) -> Void)?
    private var pendingDecision = false
    private var hasBegunPresentation = false
    private var isVisible = false
    private var ownsDismissalCompletion = false
    private let outsideControl = UIControl()
    private let dialogView: ReaderRestoreProgressDialogBodyView
    private let accessibilityIdentifierPrefix: String
    private let actionLayout: ActionLayout

    init(
        title: String = "提醒",
        message: String = "是否恢复到跳转前的阅读进度？",
        accessibilityIdentifierPrefix: String = "reader.restoreProgress",
        actionLayout: ActionLayout = .yesNo,
        onDecision: @escaping (Bool) -> Void
    ) {
        self.onDecision = onDecision
        self.accessibilityIdentifierPrefix = accessibilityIdentifierPrefix
        self.actionLayout = actionLayout
        dialogView = ReaderRestoreProgressDialogBodyView(
            title: title, message: message, accessibilityIdentifierPrefix: accessibilityIdentifierPrefix,
            actionLayout: actionLayout)
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
            command.discoverabilityTitle = actionLayout == .yesNo ? "否" : "取消"
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func loadView() {
        let host = ReaderRestoreProgressDialogHostView()
        host.onDetach = { [weak self] in self?.scheduleDismissalCompletion() }
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Base.Theme.AppCompat.Dialog inherits backgroundDimAmount=0.6.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityIdentifier = "\(accessibilityIdentifierPrefix).dialog"
        view.accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel(_:)), for: .touchUpInside)
        dialogView.onDecision = { [weak self] in self?.close(decision: $0) }
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        view.accessibilityElements = [dialogView]
        dialogView.applyFonts(traits: traitCollection)
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasBegunPresentation = true
        presentationController?.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .finished = phase { return }
        // An interrupted external dismissal can make the same dialog visible again.
        pendingDecision = false
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: dialogView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if case .finished = phase { return }
        isVisible = false
        if isPresentationBeingDismissed {
            if !ownsDismissalCompletion { pendingDecision = false }
            phase = .closing
            // Dismissal through the presenter/ancestor bypasses our dismiss override.
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                if !context.isCancelled { scheduleDismissalCompletion() }
            }
        }
        updateInteraction()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDismissalCompletion()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Removing an independently presented child is not a decision about this dialog.
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        if case .finished = phase {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        pendingDecision = false
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

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
        canInteract
    }

    func presentationControllerWillDismiss(_: UIPresentationController) {
        if case .finished = phase { return }
        pendingDecision = false
        phase = .closing
        isVisible = false
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        if case .finished = phase { return }
        pendingDecision = false
        phase = .closing
        scheduleDismissalCompletion()
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        close(decision: false)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(decision: false)
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(cancel(_:)) || action == #selector(cancelOperation(_:)) {
            return canInteract
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
            previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
                || previousTraitCollection?.displayScale != traitCollection.displayScale
        else { return }
        dialogView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }
        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let contentHeight = dialogView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let height = min(safeFrame.height, contentHeight)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        // AppCompat minor/major buckets, also used by ReaderBookChoiceDialogViewController.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private var canInteract: Bool {
        guard case .active = phase, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, let presenter = presentingViewController,
            presenter.presentedViewController === self,
            let window = viewIfLoaded?.window, !window.isHidden,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent
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
        let enabled: Bool
        if case .active = phase { enabled = isVisible } else { enabled = false }
        outsideControl.isEnabled = enabled
        dialogView.isEditingEnabled = enabled
    }

    @objc private func cancel(_ sender: Any?) {
        close(decision: false)
    }

    // Supports responder-chain Cancel actions as well as Escape / Command-period.
    @objc private func cancelOperation(_ sender: Any?) {
        close(decision: false)
    }

    private func close(decision: Bool) {
        guard canInteract else { return }
        let accepted = decision && (canConfirm?() ?? true)
        // The caller's synchronous validity closure may itself dismiss this controller.
        guard canInteract else { return }
        pendingDecision = accepted
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
        guard hasBegunPresentation, !ownsDismissalCompletion else { return }
        if case .finished = phase { return }
        // UIKit can release presentation links after viewDidDisappear / didMoveToWindow.
        DispatchQueue.main.async { [self] in finishDismissalIfDetached() }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, !ownsDismissalCompletion,
            presentingViewController == nil, presentedViewController == nil,
            parent == nil, viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil
        else { return }
        if case .finished = phase { return }
        phase = .finished
        isVisible = false
        let selectedYes = pendingDecision
        let validity = canConfirm
        let decisionCallback = onDecision
        let closeCallback = onClose
        pendingDecision = false
        canConfirm = nil
        onDecision = nil
        onClose = nil
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
        decisionCallback?(selectedYes && (validity?() ?? true))
        closeCallback?()
    }
}

@MainActor
private final class ReaderRestoreProgressDialogHostView: UIView {
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
