import UIKit

/// VariableDialog.kt / dialog_variable.xml at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// Present a fresh instance directly; the caller owns persistence and source identity.
@MainActor
final class BookDetailVariableDialogViewController: UIViewController,
    UITextViewDelegate, UIAdaptivePresentationControllerDelegate
{
    /// Called once after the dialog really detaches, including external dismissal.
    var onDismiss: (() -> Void)?

    /// Optional identity guard (nil permits saving), checked before writing and showing results.
    /// Returning false never prevents cancellation. UIKit hierarchy checks also apply.
    var canSave: (() -> Bool)? {
        didSet {
            if isViewLoaded {
                updateInteraction()
                schedulePresentationRefresh()
            }
        }
    }

    private enum Phase {
        case waiting
        case active
        case closing
        case detached
    }

    private let onSave: (String) async throws -> Void
    private let contentView: BookDetailVariableDialogContentView
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let scrollView = BookDetailVariableDialogScrollView()
    private var phase: Phase = .waiting
    private var isVisible = false
    private var hasBegunPresentation = false
    private var isWriting = false
    private var hasSaved = false
    private var pendingError: String?
    private var needsCaretReveal = false
    private var lastViewportSize: CGSize = .zero
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?

    init(
        title: String, variable: String?, comment: String,
        onSave: @escaping (String) async throws -> Void
    ) {
        self.onSave = onSave
        contentView = BookDetailVariableDialogContentView(title: title, variable: variable, comment: comment)
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
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "取消"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        let root = BookDetailVariableDialogRootView()
        root.onWindowChange = { [weak self] in self?.scheduleDetachmentCheck() }
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
        ] {
            center.addObserver(self, selector: #selector(activationChanged), name: name, object: nil)
        }
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        if !hasBegunPresentation, presentingViewController != nil {
            hasBegunPresentation = true
            captureSource()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .detached else { return }
        // An interrupted external dismissal may bring the same instance back.
        phase = .active
        isVisible = true
        updateInteraction()
        schedulePresentationRefresh()
        // Focus the controller for Escape, never the editor or software keyboard.
        if !contentView.variableEditor.isFirstResponder { becomeFirstResponder() }
        UIAccessibility.post(notification: .screenChanged, argument: contentView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if phase != .detached, isPresentationBeingDismissed { phase = .closing }
        updateInteraction()
        if phase == .closing {
            transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
                guard !context.isCancelled else { return }
                self?.scheduleDetachmentCheck()
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil {
            // UIKit uses this method to dismiss a child too; that is not our detachment.
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .detached, presentingViewController != nil else {
            finishDismissalIfDetached()
            completion?()
            return
        }
        phase = .closing
        isVisible = false
        if isViewLoaded {
            view.endEditing(true)
            updateInteraction()
        }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishDismissalIfDetached()
            completion?()
        }
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        scheduleDetachmentCheck()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canCancel else { return false }
        close()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyFonts(traits: traitCollection)
        needsCaretReveal = true
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableDialogFrame
        guard available.width > 0, available.height > 0 else { return }
        let height = contentView.sizeThatFits(
            CGSize(width: available.width, height: available.height)
        ).height
        let viewportHeight = min(available.height, height)
        dialogView.frame = CGRect(
            x: available.minX, y: available.midY - viewportHeight / 2,
            width: available.width, height: viewportHeight)
        scrollView.frame = dialogView.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: available.width, height: height)
        contentView.layoutIfNeeded()
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = height > viewportHeight
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, height - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsCaretReveal = true
        }
        if needsCaretReveal {
            needsCaretReveal = false
            revealCaret()
        }
    }

    func textViewDidBeginEditing(_: UITextView) {
        contentView.updateEditorFocus()
        requestCaretReveal()
    }

    func textViewDidEndEditing(_: UITextView) {
        contentView.updateEditorFocus()
    }

    func textViewDidChange(_: UITextView) {
        contentView.setNeedsLayout()
        requestCaretReveal()
    }

    func textViewDidChangeSelection(_: UITextView) {
        requestCaretReveal()
    }

    private func configureViews() {
        view.backgroundColor = .clear
        view.tintColor = AndroidReplicaTheme.accent
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "bookDetail.variableDialog"
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = contentView.backgroundColor
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "bookDetail.variableDialog.content"
        contentView.variableEditor.delegate = self
        contentView.onSave = { [weak self] in self?.save() }
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        view.accessibilityElements = [dialogView]
    }

    private var availableDialogFrame: CGRect {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        var available = safe.insetBy(dx: 16, dy: 16)
        let keyboard = view.keyboardLayoutGuide.layoutFrame.intersection(view.bounds)
        if !keyboard.isNull, keyboard.intersects(available) {
            let aboveHeight = max(0, min(available.maxY, keyboard.minY - 16) - available.minY)
            let belowY = max(available.minY, keyboard.maxY + 16)
            let belowHeight = max(0, available.maxY - belowY)
            // An undocked keyboard can leave more usable space below than above.
            if belowHeight > aboveHeight {
                available = CGRect(x: available.minX, y: belowY, width: available.width, height: belowHeight)
            } else {
                available.size.height = aboveHeight
            }
        }
        return available
    }

    private func requestCaretReveal() {
        needsCaretReveal = true
        view.setNeedsLayout()
    }

    private func revealCaret() {
        let editor = contentView.variableEditor
        guard isVisible, editor.isFirstResponder, let selection = editor.selectedTextRange else { return }
        let caret = editor.convert(editor.caretRect(for: selection.end), to: scrollView)
        guard !caret.isNull, !caret.isInfinite else { return }
        scrollView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -8), animated: false)
    }

    @objc private func keyboardChanged() {
        guard isViewLoaded else { return }
        requestCaretReveal()
        // Let UIKeyboardLayoutGuide receive the same frame notification first.
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

    private func schedulePresentationRefresh() {
        // Presentation and scene activation flags may settle after their callbacks.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .active, self.isVisible else { return }
            self.refreshPresentation()
        }
    }

    private func captureSource() {
        guard let presenter = presentingViewController else { return }
        sourcePresenter = presenter
        sourceWindow = viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
        var source = presenter
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

    private var isSourceCurrent: Bool {
        guard let presenter = sourcePresenter, let source = sourceController,
            presentingViewController === presenter, presenter.presentedViewController === self,
            let window = sourceWindow, viewIfLoaded?.window === window,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = source
        var includesPresenter = false
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingDismissed, !controller.isBeingPresented, !controller.isMovingFromParent else {
                return false
            }
            if let presented = controller.presentedViewController, presented !== self { return false }
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

    private var isActuallyVisible: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            !isPresentationBeingDismissed, presentedViewController == nil,
            presentingViewController != nil, let window = viewIfLoaded?.window,
            !window.isHidden, window.alpha > 0,
            window.windowScene?.activationState == .foregroundActive,
            !view.isHidden, view.alpha > 0
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

    private var canCancel: Bool { isActuallyVisible && !isWriting }

    private func isSaveContextCurrent() -> Bool {
        guard isActuallyVisible, isSourceCurrent else { return false }
        let allowed = canSave?() ?? true
        // The caller's identity closure may itself change the presentation.
        return allowed && isActuallyVisible && isSourceCurrent
    }

    private func updateInteraction() {
        let interactive = isActuallyVisible && !isWriting
        outsideControl.isEnabled = interactive
        contentView.setInteraction(
            editable: interactive && !hasSaved,
            saveEnabled: interactive && !hasSaved && pendingError == nil && isSourceCurrent && (canSave?() ?? true),
            saving: isWriting)
    }

    @objc private func cancel() {
        guard canCancel else { return }
        close()
    }

    private func close() {
        guard isActuallyVisible, presentedViewController == nil else { return }
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func save() {
        guard !isWriting, !hasSaved, pendingError == nil, isActuallyVisible, isSourceCurrent else { return }
        // Acquire the gate synchronously, including the interval before Task starts.
        isWriting = true
        view.endEditing(true)
        let draft = contentView.variable
        updateInteraction()
        Task { @MainActor [self] in
            guard isSaveContextCurrent() else {
                isWriting = false
                updateInteraction()
                return
            }
            contentView.showError(nil)
            view.setNeedsLayout()
            // Deliberately not cancellable by dismissal: a started write must settle.
            do {
                try await onSave(draft)
                hasSaved = true
            } catch {
                if phase != .detached { pendingError = error.localizedDescription }
            }
            isWriting = false
            refreshPresentation()
        }
    }

    private func refreshPresentation() {
        updateInteraction()
        guard !isWriting, hasSaved || pendingError != nil, isSaveContextCurrent(), !isWriting else { return }
        if hasSaved {
            close()
            return
        }
        guard let message = pendingError else { return }
        pendingError = nil
        contentView.showError(message)
        updateInteraction()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        if let frame = contentView.errorFrame {
            var target = contentView.convert(frame, to: scrollView)
            target.size.height = min(target.height, scrollView.bounds.height)
            scrollView.scrollRectToVisible(target, animated: false)
        }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func scheduleDetachmentCheck() {
        DispatchQueue.main.async { [self] in finishDismissalIfDetached() }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, phase != .detached,
            presentingViewController == nil, viewIfLoaded?.window == nil
        else { return }
        phase = .detached
        isVisible = false
        NotificationCenter.default.removeObserver(self)
        let callback = onDismiss
        onDismiss = nil
        pendingError = nil
        canSave = nil
        updateInteraction()
        resignFirstResponder()
        callback?()
    }
}

private final class BookDetailVariableDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class BookDetailVariableDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
