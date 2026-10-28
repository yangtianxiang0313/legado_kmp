import UIKit

/// BookInfoActivity.deleteBook at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// The caller owns persistence and supplies overrideUserInterfaceStyle when needed.
/// Use a fresh instance per presentation. onDismiss restores the caller's interaction
/// before onConfirm; overFullScreen does not make the caller appear again.
@MainActor
final class BookDetailDeleteDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    /// Set before presenting. Called once for confirmation, cancellation or external dismissal,
    /// after detachment and before any confirmation callback, even if the source is no longer current.
    var onDismiss: (() -> Void)?

    private enum Phase {
        case waiting
        case active
        case closing
        case finished
    }

    private var phase: Phase = .waiting
    private var onConfirm: ((Bool) -> Void)?
    private var pendingConfirmation: Bool?
    private var isVisible = false
    private var hasBegunPresentation = false
    private var ownsDismissalCompletion = false
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let scrollView = BookDetailDeleteDialogScrollView()
    private let contentView: BookDetailDeleteDialogContentView

    init(showsFileOption: Bool, deleteOriginal: Bool, onConfirm: @escaping (Bool) -> Void) {
        contentView = BookDetailDeleteDialogContentView(
            showsFileOption: showsFileOption, deleteOriginal: deleteOriginal)
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
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
        guard case .active = phase else { return nil }
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "否"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        contentView.applyFonts(traits: traitCollection)
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        guard !hasBegunPresentation else { return }
        hasBegunPresentation = true
        captureSource()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .finished = phase { return }
        // A cancelled external transition may return to the same dialog.
        pendingConfirmation = nil
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: contentView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if case .finished = phase { return }
        isVisible = false
        if isPresentationBeingDismissed, !ownsDismissalCompletion {
            pendingConfirmation = nil
            phase = .closing
            // Presenter/ancestor dismissals do not necessarily call our dismiss override.
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                guard !context.isCancelled else { return }
                scheduleExternalDismissalCompletion()
            }
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Also covers nonanimated external dismissals, which have no coordinator.
        scheduleExternalDismissalCompletion()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Dismissing a child is not dismissal of this confirmation dialog.
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        if case .finished = phase {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        pendingConfirmation = nil
        phase = .closing
        isVisible = false
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishDismissalIfDetached()
            completion?()
        }
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        if case .finished = phase { return }
        if !ownsDismissalCompletion {
            pendingConfirmation = nil
            phase = .closing
        }
        scheduleExternalDismissalCompletion()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        close(confirming: false)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }
        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let contentHeight = contentView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let height = min(safeFrame.height * 0.9, contentHeight)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)
        // Scroll title, body and footer together when the window cannot fit the chrome.
        scrollView.frame = dialogView.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        // Same AppCompat minor/major buckets as BookshelfLayoutDialogViewController.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "bookDetail.deleteDialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "bookDetail.deleteDialog.content"
        contentView.onCancel = { [weak self] in self?.close(confirming: false) }
        contentView.onConfirm = { [weak self] in self?.close(confirming: true) }
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        view.accessibilityElements = [dialogView]
        dialogView.accessibilityElements = [scrollView]
    }

    private func captureSource() {
        guard let presenter = presentingViewController else { return }
        sourcePresenter = presenter
        sourceWindow = presenter.viewIfLoaded?.window
        var source = presenter
        // UIKit may promote presentation from the detail page to its navigation/tab container.
        while true {
            if let navigation = source as? UINavigationController, let top = navigation.topViewController {
                source = top
            } else if let tabs = source as? UITabBarController, let selected = tabs.selectedViewController {
                source = selected
            } else {
                break
            }
        }
        sourceController = source
    }

    private func isSourceCurrent(allowingDialog: Bool) -> Bool {
        guard let presenter = sourcePresenter, let source = sourceController, let window = sourceWindow,
            !window.isHidden, window.windowScene?.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = source
        var includesPresenter = false
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingDismissed, !controller.isBeingPresented, !controller.isMovingFromParent else {
                return false
            }
            if let presented = controller.presentedViewController,
                !allowingDialog || presented !== self
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController,
                tabs.selectedViewController !== controller
            {
                return false
            }
            current = controller.parent
        }
        return includesPresenter
    }

    private var canClose: Bool {
        guard case .active = phase, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, presentingViewController != nil, viewIfLoaded?.window != nil
        else { return false }
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
        contentView.isEditingEnabled = enabled
    }

    @objc private func cancel() {
        close(confirming: false)
    }

    private func close(confirming: Bool) {
        guard canClose else { return }
        if confirming, !isSourceCurrent(allowingDialog: true) { return }
        pendingConfirmation = confirming ? contentView.deleteOriginal : nil
        phase = .closing
        ownsDismissalCompletion = true
        updateInteraction()
        resignFirstResponder()
        // Only this completion may deliver confirmation, never viewDidDisappear.
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            ownsDismissalCompletion = false
            finishDismissalIfDetached()
        }
    }

    private func scheduleExternalDismissalCompletion() {
        guard !ownsDismissalCompletion else { return }
        // UIKit releases presentation links after disappearance/coordinator callbacks.
        DispatchQueue.main.async { [self] in finishDismissalIfDetached() }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, !ownsDismissalCompletion,
            presentingViewController == nil, viewIfLoaded?.window == nil
        else { return }
        if case .finished = phase { return }
        phase = .finished
        isVisible = false
        let confirmedValue = pendingConfirmation
        let confirmCallback = onConfirm
        let dismissCallback = onDismiss
        pendingConfirmation = nil
        onConfirm = nil
        onDismiss = nil
        updateInteraction()
        resignFirstResponder()

        // Always release the caller's operation gate, even when the source became stale.
        dismissCallback?()
        guard let confirmedValue, isSourceCurrent(allowingDialog: false) else { return }
        confirmCallback?(confirmedValue)
    }
}

private final class BookDetailDeleteDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
