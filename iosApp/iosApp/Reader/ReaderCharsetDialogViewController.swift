import UIKit

/// BaseReadBookActivity.showCharsetConfig / dialog_edit_text.xml at Legado 5f5d314.
/// The caller owns charset persistence; present a fresh instance directly.
@MainActor
final class ReaderCharsetDialogViewController: UIViewController,
    UITextViewDelegate, UIAdaptivePresentationControllerDelegate
{
    /// Called once after detachment, after onConfirm when the user confirmed.
    var onClose: (() -> Void)?

    private enum Phase {
        case waiting
        case active
        case closing
        case finished
    }

    private let contentView: ReaderCharsetDialogContentView
    private let outsideControl = UIControl()
    private var onConfirm: ((String) -> Void)?
    private var phase: Phase = .waiting
    private var isVisible = false
    private var hasBegunPresentation = false
    private var dismissalID: UUID?
    private var pendingConfirmation: String?

    init(charset: String, onClose: (() -> Void)? = nil, onConfirm: @escaping (String) -> Void) {
        contentView = ReaderCharsetDialogContentView(charset: charset)
        self.onClose = onClose
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
        guard phase == .active else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = "取消"
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func loadView() {
        let root = ReaderCharsetDialogRootView()
        root.onWindowChange = { [weak self] in self?.scheduleDetachmentCheck() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.tintColor = AndroidReplicaTheme.accent
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.charset.dialog"
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.editor.delegate = self
        contentView.onCancel = { [weak self] in self?.close(confirming: false) }
        contentView.onConfirm = { [weak self] in self?.close(confirming: true) }
        contentView.onLayoutChange = { [weak self] in self?.view.setNeedsLayout() }
        contentView.applyFonts(traits: traitCollection)
        view.addSubview(outsideControl)
        view.addSubview(contentView)
        view.accessibilityElements = [contentView]
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        if presentingViewController != nil { hasBegunPresentation = true }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished, dismissalID == nil else { return }
        // An interactive external dismissal can be cancelled by UIKit.
        pendingConfirmation = nil
        phase = .active
        isVisible = true
        updateInteraction()
        if !contentView.editor.isFirstResponder { becomeFirstResponder() }
        UIAccessibility.post(notification: .screenChanged, argument: contentView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if phase != .finished, isPresentationBeingDismissed, dismissalID == nil {
            phase = .closing
            pendingConfirmation = nil
        }
        updateInteraction()
        transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
            guard !context.isCancelled else { return }
            scheduleDetachmentCheck()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // The editor can present a child; dismissing that child is not closing this dialog.
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .finished else {
            completion?()
            return
        }
        dismissalID = nil
        pendingConfirmation = nil
        phase = .closing
        isVisible = false
        if isViewLoaded {
            updateInteraction()
            view.endEditing(true)
        }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishIfDetached()
            scheduleDetachmentCheck()
            completion?()
        }
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        guard phase != .finished else { return }
        if dismissalID == nil { pendingConfirmation = nil }
        phase = .closing
        scheduleDetachmentCheck()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(confirming: false)
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
        let desiredHeight = ceil(
            contentView.sizeThatFits(
                CGSize(width: available.width, height: .greatestFiniteMagnitude)
            ).height)
        let height = min(available.height, desiredHeight)
        contentView.frame = CGRect(
            x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
        contentView.layoutIfNeeded()
    }

    func textViewDidBeginEditing(_: UITextView) {
        contentView.beginEditing()
        requestCaretReveal()
    }

    func textViewDidEndEditing(_: UITextView) {
        contentView.endEditing()
        view.setNeedsLayout()
    }

    func textViewDidChange(_: UITextView) {
        contentView.inputDidChange()
        requestCaretReveal()
    }

    func textViewDidChangeSelection(_: UITextView) {
        contentView.refreshInput()
        requestCaretReveal()
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
        let width = max(0, min(safe.width, view.bounds.width * dialogWidthFraction))
        let margin = min(16, max(0, safe.height / 10))
        var available = CGRect(
            x: safe.midX - width / 2, y: safe.minY + margin,
            width: width, height: max(0, safe.height - margin * 2))
        let keyboard = view.keyboardLayoutGuide.layoutFrame.intersection(view.bounds)
        if !keyboard.isNull, keyboard.height > 0, keyboard.intersects(available) {
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

    private var canInteract: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, let presenter = presentingViewController,
            presenter.presentedViewController === self, viewIfLoaded?.window != nil
        else { return false }
        return !isPresentationBeingDismissed
    }

    private var isPresentationBeingDismissed: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        // isBeingPresented can still be true inside viewDidAppear; handlers check it again at action time.
        let enabled = phase == .active && isVisible && !isPresentationBeingDismissed
        outsideControl.isEnabled = enabled
        contentView.setInteraction(enabled: enabled)
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

    @objc private func cancel() {
        close(confirming: false)
    }

    private func close(confirming: Bool) {
        guard canInteract else { return }
        let requestID = UUID()
        dismissalID = requestID
        phase = .closing
        isVisible = false
        updateInteraction()
        // Commit an IME composition only on explicit confirmation, never while filtering.
        if confirming { contentView.editor.unmarkText() }
        view.endEditing(true)
        resignFirstResponder()
        guard dismissalID == requestID, phase == .closing else { return }
        pendingConfirmation = confirming ? contentView.rawText : nil
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            // A later external dismiss invalidates this completion's submission.
            if dismissalID == requestID { dismissalID = nil }
            finishIfDetached()
            scheduleDetachmentCheck()
        }
    }

    private func scheduleDetachmentCheck() {
        DispatchQueue.main.async { [self] in finishIfDetached() }
    }

    private func finishIfDetached() {
        guard hasBegunPresentation, phase != .finished, dismissalID == nil,
            presentingViewController == nil, parent == nil, viewIfLoaded?.window == nil
        else { return }
        phase = .finished
        isVisible = false
        NotificationCenter.default.removeObserver(self)
        let text = pendingConfirmation
        let confirmCallback = onConfirm
        let closeCallback = onClose
        pendingConfirmation = nil
        onConfirm = nil
        onClose = nil
        updateInteraction()
        if let text { confirmCallback?(text) }
        closeCallback?()
    }
}

private final class ReaderCharsetDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
