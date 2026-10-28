import UIKit

/// ColorPickerDialog 1.1.0 without alpha UI; BgTextConfigDialog defaults to TYPE_CUSTOM.
/// Present a fresh instance directly; selection is delivered once, after detachment, before onClose.
@MainActor
final class ReaderColorPickerDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    /// Side-effect-free host/source identity guard. Rechecked before closing and after actual detachment.
    /// A false result disables confirmation, never cancellation or local color editing.
    var canSubmit: (() -> Bool)? {
        didSet {
            guard isViewLoaded, phase != .finished else { return }
            updateInteraction()
        }
    }

    private enum Phase {
        case appearing
        case active
        case closing
        case finished
    }

    private var phase: Phase = .appearing
    private var onClose: (() -> Void)?
    private var onSelect: ((UIColor) -> Void)?
    private var pendingColor: UIColor?
    private var hasBegunPresentation = false
    private var isVisible = false
    private var ownsDismissalCompletion = false
    private var isUpdatingInteraction = false
    private var isCheckingSubmission = false
    private var interactionTimer: Timer?
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?
    private weak var sourceRootController: UIViewController?

    private let outsideControl = UIControl()
    private let contentView: ReaderColorPickerDialogContentView

    init(
        color: UIColor, startsWithPresets: Bool = false, onClose: (() -> Void)? = nil,
        onSelect: @escaping (UIColor) -> Void
    ) {
        self.onClose = onClose
        self.onSelect = onSelect
        contentView = ReaderColorPickerDialogContentView(color: color, startsWithPresets: startsWithPresets)
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
        guard phase == .active else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = "取消"
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func loadView() {
        let root = ReaderColorDialogRootView()
        root.onWindowChange = { [weak self] in self?.schedulePresentationRefresh() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.tintColor = AndroidReplicaTheme.accent
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.colorPicker.dialog"
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.canBeginEditing = { [weak self] in self?.canClose ?? false }
        contentView.onConfirm = { [weak self] in self?.close(submitting: true) }
        contentView.onStateChange = { [weak self] in
            guard let self, self.isViewLoaded else { return }
            self.view.setNeedsLayout()
            self.updateInteraction()
        }
        view.addSubview(outsideControl)
        view.addSubview(contentView)
        view.accessibilityElements = [contentView]
        contentView.applyFonts(traits: traitCollection)
        let center = NotificationCenter.default
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            center.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(activationChanged), name: name, object: nil)
        }
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        guard !hasBegunPresentation, let presenter = presentingViewController else { return }
        hasBegunPresentation = true
        sourcePresenter = presenter
        sourceController = currentSource(from: presenter)
        sourceWindow = viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
        sourceRootController = sourceWindow?.rootViewController
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        // A cancelled external transition may return to this same instance; it never restores a selection.
        pendingColor = nil
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        updateInteraction()
        startInteractionRefresh()
        // isBeingPresented can remain true inside didAppear. Do not leave controls disabled permanently.
        schedulePresentationRefresh()
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            self?.schedulePresentationRefresh()
        }
        // The controller accepts Escape, but only a deliberate hex edit requests a software keyboard.
        if !contentView.hexInput.editor.isFirstResponder { becomeFirstResponder() }
        UIAccessibility.post(notification: .screenChanged, argument: contentView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard phase != .finished else { return }
        isVisible = false
        stopInteractionRefresh()
        if isPresentationBeingDismissed, !ownsDismissalCompletion {
            pendingColor = nil
            phase = .closing
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                if !context.isCancelled { schedulePresentationRefresh() }
            }
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        schedulePresentationRefresh()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // An editor child can be dismissed without treating it as dismissal of the color dialog.
        guard presentedViewController == nil, phase != .finished else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        pendingColor = nil
        phase = .closing
        isVisible = false
        stopInteractionRefresh()
        if isViewLoaded {
            view.endEditing(true)
            updateInteraction()
        }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishDismissalIfDetached()
            schedulePresentationRefresh()
            completion?()
        }
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        guard phase != .finished else { return }
        if !ownsDismissalCompletion {
            pendingColor = nil
            phase = .closing
        }
        schedulePresentationRefresh()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        close(submitting: false)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyFonts(traits: traitCollection)
        contentView.revealHexOnNextLayout()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableDialogFrame
        guard available.width > 0 else { return }
        let desiredHeight = contentView.sizeThatFits(CGSize(width: available.width, height: .greatestFiniteMagnitude))
            .height
        let height = min(available.height, desiredHeight)
        contentView.frame = CGRect(
            x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
        contentView.layoutIfNeeded()
        updateInteraction()
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

    private var availableDialogFrame: CGRect {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        // Unlike applyTint dialogs, AppCompat's native background retains its 16dp drawable insets.
        let windowWidth = min(safe.width, view.bounds.width * dialogWidthFraction)
        let width = max(1, windowWidth - min(32, max(0, windowWidth - 1)))
        let margin = min(16, max(0, safe.height / 10))
        var available = CGRect(
            x: safe.midX - width / 2, y: safe.minY + margin,
            width: width, height: max(0, safe.height - margin * 2))
        let keyboard = view.keyboardLayoutGuide.layoutFrame.intersection(view.bounds)
        if !keyboard.isNull, keyboard.intersects(available) {
            let aboveHeight = max(0, min(available.maxY, keyboard.minY - margin) - available.minY)
            let belowY = max(available.minY, keyboard.maxY + margin)
            let belowHeight = max(0, available.maxY - belowY)
            if belowHeight > aboveHeight {
                available.origin.y = belowY
                available.size.height = belowHeight
            } else {
                available.size.height = aboveHeight
            }
        }
        return available
    }

    @objc private func keyboardChanged() {
        guard isViewLoaded else { return }
        contentView.revealHexOnNextLayout()
        view.setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.contentView.revealHexOnNextLayout()
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    @objc private func activationChanged() {
        guard isViewLoaded else { return }
        updateInteraction()
        schedulePresentationRefresh()
    }

    private func currentSource(from presenter: UIViewController) -> UIViewController {
        var source = presenter
        while true {
            if let navigation = source as? UINavigationController, let top = navigation.topViewController {
                source = top
            } else if let tabs = source as? UITabBarController, let selected = tabs.selectedViewController {
                source = selected
            } else {
                return source
            }
        }
    }

    private var canClose: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, let presenter = presentingViewController,
            presenter.presentedViewController === self,
            let window = viewIfLoaded?.window, !window.isHidden, window.alpha > 0
        else { return false }
        return true
    }

    private var isPresentationBeingDismissed: Bool {
        if isBeingDismissed { return true }
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.presentingViewController ?? controller.parent
        }
        return false
    }

    private func isSourceCurrent(allowingDialog: Bool) -> Bool {
        guard let presenter = sourcePresenter, let source = sourceController,
            let window = sourceWindow, let root = sourceRootController,
            !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            window.rootViewController === root, currentSource(from: presenter) === source,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window
        else { return false }
        if allowingDialog {
            guard canClose, presentingViewController === presenter, viewIfLoaded?.window === window else {
                return false
            }
        } else {
            guard phase == .finished, presentingViewController == nil, viewIfLoaded?.window == nil else { return false }
        }
        var current: UIViewController? = source
        var expectedPresentation: UIViewController?
        var includesPresenter = false
        var lastController: UIViewController?
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== expectedPresentation, !(allowingDialog && presented === self)
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            lastController = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return includesPresenter && lastController === root
    }

    private func permitsSubmission(allowingDialog: Bool) -> Bool {
        guard !isCheckingSubmission, isSourceCurrent(allowingDialog: allowingDialog) else { return false }
        isCheckingSubmission = true
        let permitted = canSubmit?() ?? true
        isCheckingSubmission = false
        // Recheck because a caller-provided guard can replace or dismiss its own presentation.
        return permitted && isSourceCurrent(allowingDialog: allowingDialog)
    }

    private func updateInteraction() {
        guard isViewLoaded, !isUpdatingInteraction else { return }
        isUpdatingInteraction = true
        defer { isUpdatingInteraction = false }
        let canConfirm = phase == .active && permitsSubmission(allowingDialog: true)
        let interactive = canClose
        outsideControl.isEnabled = interactive
        contentView.setInteraction(editable: interactive, submitEnabled: interactive && canConfirm)
    }

    private func startInteractionRefresh() {
        stopInteractionRefresh()
        guard phase == .active, isVisible else { return }
        // Host identity and UIKit transition flags may change without layout or an activation notification.
        let timer = Timer(
            timeInterval: 0.1, target: InteractionTarget(owner: self),
            selector: #selector(InteractionTarget.tick(_:)), userInfo: nil, repeats: true)
        interactionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopInteractionRefresh() {
        interactionTimer?.invalidate()
        interactionTimer = nil
    }

    @objc private func cancel() {
        close(submitting: false)
    }

    private func close(submitting: Bool) {
        guard canClose else { return }
        if submitting, !contentView.prepareForSubmission() || !permitsSubmission(allowingDialog: true) {
            updateInteraction()
            return
        }
        guard canClose else { return }
        pendingColor = submitting ? contentView.color : nil
        phase = .closing
        ownsDismissalCompletion = true
        isVisible = false
        stopInteractionRefresh()
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            ownsDismissalCompletion = false
            finishDismissalIfDetached()
            schedulePresentationRefresh()
        }
    }

    private func schedulePresentationRefresh() {
        DispatchQueue.main.async { [self] in
            finishDismissalIfDetached()
            if phase == .active { updateInteraction() }
        }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, phase != .finished, !ownsDismissalCompletion,
            presentingViewController == nil, parent == nil, viewIfLoaded?.window == nil
        else { return }
        phase = .finished
        isVisible = false
        stopInteractionRefresh()
        NotificationCenter.default.removeObserver(self)
        let selectedColor = pendingColor
        let selectCallback = onSelect
        let closeCallback = onClose
        pendingColor = nil
        onSelect = nil
        onClose = nil
        updateInteraction()
        let permitted = selectedColor != nil && permitsSubmission(allowingDialog: false)
        canSubmit = nil
        if let selectedColor, permitted, isSourceCurrent(allowingDialog: false) { selectCallback?(selectedColor) }
        closeCallback?()
    }

    @MainActor
    private final class InteractionTarget: NSObject {
        weak var owner: ReaderColorPickerDialogViewController?

        init(owner: ReaderColorPickerDialogViewController) {
            self.owner = owner
        }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.updateInteraction()
        }
    }
}

private final class ReaderColorDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
