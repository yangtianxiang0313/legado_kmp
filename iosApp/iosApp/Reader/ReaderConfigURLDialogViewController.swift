import UIKit

/// BgTextConfigDialog URL/style-name and ThemeConfigFragment theme-name editors at Legado 5f5d314.
/// Present a fresh instance directly. The caller owns importing or applying the unchanged name.
@MainActor
final class ReaderConfigURLDialogViewController: UIViewController,
    UITextViewDelegate, UIAdaptivePresentationControllerDelegate
{
    /// Called once after detachment, including cancellation, and before onSubmit.
    var onDismiss: (() -> Void)?

    /// Optional, side-effect-free source-identity gate, not a text validator.
    /// Polled while visible; false never disables cancellation.
    /// Checked while visible, before dismissal and again after onDismiss.
    var canSubmit: (() -> Bool)? {
        didSet {
            guard isViewLoaded, phase != .finished else { return }
            updateInteraction()
        }
    }

    private enum Phase {
        case waiting
        case active
        case closing
        case finished
    }

    private var onSubmit: ((String) -> Void)?
    private var pendingSubmission: String?
    private var phase: Phase = .waiting
    private var isVisible = false
    private var hasBegunPresentation = false
    private var ownsDismissalCompletion = false
    private var isUpdatingInteraction = false
    private var isCheckingSubmission = false
    private var interactionTimer: Timer?
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?
    private weak var sourceRootController: UIViewController?

    private let outsideControl = UIControl()
    private let contentView: ReaderConfigURLDialogContentView

    convenience init(onSubmit: @escaping (String) -> Void) {
        self.init(configuration: .url, onSubmit: onSubmit)
    }

    /// Android's name editor accepts empty, unchanged and whitespace-only names verbatim.
    convenience init(name: String, onSubmit: @escaping (String) -> Void) {
        self.init(configuration: .rename(name: name), onSubmit: onSubmit)
    }

    convenience init(themeName: String, onSubmit: @escaping (String) -> Void) {
        self.init(configuration: .themeName(name: themeName), onSubmit: onSubmit)
    }

    private init(
        configuration: ReaderConfigURLDialogContentView.Configuration,
        onSubmit: @escaping (String) -> Void
    ) {
        contentView = ReaderConfigURLDialogContentView(frame: .zero, configuration: configuration)
        self.onSubmit = onSubmit
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
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "取消"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        let root = ReaderConfigURLDialogRootView()
        root.onWindowChange = { [weak self] in self?.schedulePresentationRefresh() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
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
        guard !hasBegunPresentation, presentingViewController != nil else { return }
        hasBegunPresentation = true
        captureSource()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        // An interrupted external dismissal may return to the same dialog.
        pendingSubmission = nil
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        updateInteraction()
        startInteractionRefresh()
        schedulePresentationRefresh()
        if !contentView.editor.isFirstResponder { becomeFirstResponder() }
        UIAccessibility.post(notification: .screenChanged, argument: contentView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard phase != .finished else { return }
        isVisible = false
        stopInteractionRefresh()
        if isPresentationBeingDismissed, !ownsDismissalCompletion {
            pendingSubmission = nil
            phase = .closing
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                guard !context.isCancelled else { return }
                schedulePresentationRefresh()
            }
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        schedulePresentationRefresh()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Dismissing an editor's child controller does not dismiss this dialog.
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .finished else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        pendingSubmission = nil
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
            pendingSubmission = nil
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
        requestCaretReveal()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableDialogFrame
        guard available.width > 0 else { return }
        let desiredHeight = contentView.sizeThatFits(
            CGSize(width: available.width, height: .greatestFiniteMagnitude)
        ).height
        let scale = max(1, traitCollection.displayScale)
        let height = min(floor(available.height * scale) / scale, ceil(desiredHeight * scale) / scale)
        // Keep the form's pixel-ceiled line boxes and underline on the same display pixel grid.
        contentView.frame = CGRect(
            x: (available.minX * scale).rounded() / scale,
            y: ((available.midY - height / 2) * scale).rounded() / scale,
            width: available.width, height: height)
        contentView.layoutIfNeeded()
        updateInteraction()
    }

    func textViewDidBeginEditing(_: UITextView) {
        contentView.updateEditorFocus()
        requestCaretReveal()
    }

    func textViewDidEndEditing(_: UITextView) {
        contentView.updateEditorFocus()
        updateInteraction()
    }

    func textViewDidChange(_: UITextView) {
        contentView.updateEditorFocus()
        requestCaretReveal()
        updateInteraction()
    }

    func textViewDidChangeSelection(_: UITextView) {
        contentView.updateEditorFocus()
        requestCaretReveal()
    }

    private func configureViews() {
        view.backgroundColor = .clear
        view.tintColor = AndroidReplicaTheme.accent
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = contentView.dialogAccessibilityIdentifier
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.editor.delegate = self
        contentView.onCancel = { [weak self] in self?.close(submitting: false) }
        contentView.onSubmit = { [weak self] in self?.close(submitting: true) }
        view.addSubview(outsideControl)
        view.addSubview(contentView)
        view.accessibilityElements = [contentView]
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
        let scale = max(1, traitCollection.displayScale)
        let width = floor(min(safe.width, view.bounds.width * dialogWidthFraction) * scale) / scale
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

    private func requestCaretReveal() {
        contentView.revealCaretOnNextLayout()
        view.setNeedsLayout()
    }

    @objc private func keyboardChanged() {
        guard isViewLoaded else { return }
        requestCaretReveal()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.requestCaretReveal()
            self.view.layoutIfNeeded()
        }
    }

    @objc private func activationChanged() {
        guard isViewLoaded else { return }
        updateInteraction()
        schedulePresentationRefresh()
    }

    private func captureSource() {
        guard let presenter = presentingViewController else { return }
        sourcePresenter = presenter
        sourceController = currentSource(from: presenter)
        sourceWindow = viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
        sourceRootController = sourceWindow?.rootViewController
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

    private func isSourceCurrent(allowingDialog: Bool) -> Bool {
        guard let presenter = sourcePresenter, let source = sourceController,
            let window = sourceWindow, let root = sourceRootController,
            !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            window.rootViewController === root, currentSource(from: presenter) === source,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window
        else { return false }
        if allowingDialog {
            guard canClose, presentingViewController === presenter,
                presenter.presentedViewController === self, viewIfLoaded?.window === window
            else { return false }
        } else {
            guard phase == .finished, presentingViewController == nil, viewIfLoaded?.window == nil else {
                return false
            }
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
                presented !== expectedPresentation,
                !(allowingDialog && presented === self)
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

    private var canClose: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, presentingViewController != nil,
            let window = viewIfLoaded?.window, !window.isHidden, window.alpha > 0
        else { return false }
        return true
    }

    private var isPresentationBeingDismissed: Bool {
        if isBeingDismissed { return true }
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func permitsSubmission(allowingDialog: Bool) -> Bool {
        guard !isCheckingSubmission, isSourceCurrent(allowingDialog: allowingDialog) else { return false }
        isCheckingSubmission = true
        let allowed = canSubmit?() ?? true
        isCheckingSubmission = false
        // The caller's gate may itself cancel or replace the presentation.
        return allowed && isSourceCurrent(allowingDialog: allowingDialog)
    }

    private func updateInteraction() {
        guard isViewLoaded, !isUpdatingInteraction else { return }
        isUpdatingInteraction = true
        defer { isUpdatingInteraction = false }
        let submitEnabled = phase == .active && permitsSubmission(allowingDialog: true)
        let interactive = canClose
        outsideControl.isEnabled = interactive
        contentView.setInteraction(editable: interactive, submitEnabled: interactive && submitEnabled)
    }

    private func startInteractionRefresh() {
        stopInteractionRefresh()
        guard phase == .active, isVisible else { return }
        // Navigation changes and captured canSubmit values have no common UIKit notification.
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
        if submitting, !permitsSubmission(allowingDialog: true) {
            updateInteraction()
            return
        }
        guard canClose else { return }
        // Keep the exact input, including empty text, whitespace and line breaks.
        pendingSubmission = submitting ? contentView.rawText : nil
        phase = .closing
        ownsDismissalCompletion = true
        isVisible = false
        stopInteractionRefresh()
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        // Only our dismissal completion may release a pending submission.
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
        let text = pendingSubmission
        let submitCallback = onSubmit
        let dismissCallback = onDismiss
        pendingSubmission = nil
        onSubmit = nil
        onDismiss = nil
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        dismissCallback?()
        let permitted = text != nil && permitsSubmission(allowingDialog: false)
        canSubmit = nil
        guard let text, permitted, isSourceCurrent(allowingDialog: false) else { return }
        submitCallback?(text)
    }

    @MainActor
    private final class InteractionTarget: NSObject {
        weak var owner: ReaderConfigURLDialogViewController?

        init(owner: ReaderConfigURLDialogViewController) {
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

private final class ReaderConfigURLDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
