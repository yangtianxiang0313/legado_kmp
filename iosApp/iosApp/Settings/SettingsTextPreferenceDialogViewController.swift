import UIKit

/// Legado EditTextPreferenceDialog / OtherConfigFragment.showUserAgentDialog at 5f5d314.
/// Present a fresh instance directly. The owner normalizes values and owns persistence.
@MainActor
final class SettingsTextPreferenceDialogViewController: UIViewController,
    UITextViewDelegate, UIAdaptivePresentationControllerDelegate
{
    /// A side-effect-free owner/session gate, not text validation. Replacing it revokes in-flight work.
    var canSubmit: (() -> Bool)? {
        didSet {
            epoch &+= 1
            invalidateWork()
            if isViewLoaded { refreshPresentation() }
        }
    }

    /// Exactly once after actual detachment, including cancellation or an external dismissal.
    var onDismiss: (() -> Void)?

    private enum Phase { case waiting, active, closing, finished }
    private enum Outcome { case saved, failed, cancelled }

    private final class Work {
        let epoch: UInt64
        var editingState: SettingsTextPreferenceDialogContentView.EditingState?
        var invalidated = false
        var task: Task<Void, Never>?

        init(epoch: UInt64) { self.epoch = epoch }
    }

    private var onSave: (@MainActor (String) async throws -> Void)?
    private let body: SettingsTextPreferenceDialogContentView
    private let context = ThemeListDialogPresentationContext()
    private let outsideControl = UIControl()
    private weak var sourceWindow: UIWindow?
    private var phase: Phase = .waiting
    private var hasStarted = false
    private var isVisible = false
    private var hasSaved = false
    private var didSetInitialFocus = false
    private var ownsDismissalCompletion = false
    private var isEnvironmentSuspended = false
    private var isRefreshing = false
    private var isCheckingIdentity = false
    private var epoch: UInt64 = 0
    private var work: Work?
    private var pendingEditingState: SettingsTextPreferenceDialogContentView.EditingState?
    private var pendingStatus: String?
    private var refreshTimer: Timer?

    init(
        titleText: String, value: String?, placeholder: String, isSecure: Bool,
        keyboardType: UIKeyboardType = .default, usesUserAgentLayout: Bool = false,
        onSave: @escaping @MainActor (String) async throws -> Void
    ) {
        self.onSave = onSave
        body = SettingsTextPreferenceDialogContentView(
            titleText: titleText, value: value, placeholder: placeholder, isSecure: isSecure,
            keyboardType: keyboardType, usesUserAgentLayout: usesUserAgentLayout)
        super.init(nibName: nil, bundle: nil)
        title = titleText
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
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "取消"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        let root = SettingsPreferenceDialogRootView()
        root.onWindowChange = { [weak self] in self?.schedulePresentationRefresh() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.tintColor = AndroidReplicaTheme.accent
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "settings.textPreferenceDialog"
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        // AppCompat 1.7.1 Base.V7.Theme[.Light].
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        body.editor.delegate = self
        body.onCancel = { [weak self] in self?.cancel() }
        body.onSubmit = { [weak self] in self?.save() }
        body.applyFonts(traits: traitCollection)
        view.addSubview(outsideControl)
        view.addSubview(body)
        view.accessibilityElements = [body]
        let center = NotificationCenter.default
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            center.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeHiddenNotification,
        ] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        refreshPresentation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        if !hasStarted, let presenter = presentingViewController {
            hasStarted = true
            context.capture(dialog: self)
            sourceWindow = viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        startRefreshTimer()
        refreshPresentation()
        body.revealCaretOnNextLayout()
        UIAccessibility.post(notification: .screenChanged, argument: body.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard phase != .finished else { return }
        isVisible = false
        if !ownsDismissalCompletion { invalidateWork() }
        if ancestorIsLeaving { phase = .closing }
        applyInteraction(permitted: false)
        transitionCoordinator?.animate(alongsideTransition: nil) { [self] _ in
            schedulePresentationRefresh()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        schedulePresentationRefresh()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // UIKit may be asked to dismiss an independent child; never take its ancestors with it.
        if presentedViewController != nil {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .finished, presentingViewController != nil else {
            finishIfDetached()
            completion?()
            return
        }
        beginClosing()
        ownsDismissalCompletion = true
        super.dismiss(animated: flag) { [self] in
            ownsDismissalCompletion = false
            finishIfDetached()
            schedulePresentationRefresh()
            completion?()
        }
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool { canClose }

    func presentationControllerWillDismiss(_: UIPresentationController) {
        beginClosing()
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        schedulePresentationRefresh()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        body.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableDialogFrame
        let scale = max(1, traitCollection.displayScale)
        let desired = body.sizeThatFits(CGSize(width: available.width, height: .greatestFiniteMagnitude)).height
        let height = max(0, min(floor(available.height * scale) / scale, ceil(desired * scale) / scale))
        body.frame = CGRect(
            x: (available.minX * scale).rounded() / scale,
            y: ((available.midY - height / 2) * scale).rounded() / scale,
            width: available.width, height: height)
        body.layoutIfNeeded()
    }

    func textViewDidBeginEditing(_: UITextView) { editorChanged() }
    func textViewDidEndEditing(_: UITextView) { editorChanged() }
    func textViewDidChange(_: UITextView) { editorChanged() }
    func textViewDidChangeSelection(_: UITextView) { editorChanged() }

    private func editorChanged() {
        body.updateEditorFocus()
        body.revealCaretOnNextLayout()
        view.setNeedsLayout()
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
        let width = floor(max(0, min(safe.width, view.bounds.width * dialogWidthFraction)) * scale) / scale
        let margin = min(16, max(0, safe.height / 10))
        var available = CGRect(
            x: safe.midX - width / 2, y: safe.minY + margin,
            width: width, height: max(0, safe.height - margin * 2))
        let keyboard = view.keyboardLayoutGuide.layoutFrame.intersection(view.bounds)
        if !keyboard.isNull, keyboard.intersects(available) {
            let above = max(0, min(available.maxY, keyboard.minY - margin) - available.minY)
            let belowY = max(available.minY, keyboard.maxY + margin)
            let below = max(0, available.maxY - belowY)
            if below > above {
                available.origin.y = belowY
                available.size.height = below
            } else {
                available.size.height = above
            }
        }
        return available
    }

    private var canClose: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            !ancestorIsLeaving, presentedViewController == nil,
            let presenter = presentingViewController, presenter.presentedViewController === self,
            let window = viewIfLoaded?.window, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            !view.isHidden, view.alpha > 0, UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        return true
    }

    private var ancestorIsLeaving: Bool {
        if isBeingDismissed { return true }
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func permitsSubmission() -> Bool {
        guard hasStarted, canClose, !isEnvironmentSuspended, !isCheckingIdentity,
            context.isCurrent(dialog: self, allowing: nil)
        else { return false }
        isCheckingIdentity = true
        let expectedEpoch = epoch
        let allowed = canSubmit?() ?? true
        isCheckingIdentity = false
        // A caller's gate may reenter, replace itself or dismiss the presentation.
        return allowed && expectedEpoch == epoch && canClose && !isEnvironmentSuspended
            && context.isCurrent(dialog: self, allowing: nil)
    }

    private func accepts(_ attempt: Work) -> Bool {
        guard work === attempt, !attempt.invalidated, attempt.epoch == epoch, permitsSubmission() else {
            return false
        }
        return work === attempt && !attempt.invalidated && attempt.epoch == epoch && canClose
    }

    private func invalidateWork() {
        guard let work, !work.invalidated else { return }
        work.invalidated = true
        work.task?.cancel()
        // Cancellation cannot undo persistence. Retain single-flight until the callback really returns.
    }

    private func applyInteraction(permitted: Bool) {
        guard isViewLoaded else { return }
        let interactive = canClose
        outsideControl.isEnabled = interactive
        body.setInteraction(
            editable: interactive && work == nil && !hasSaved,
            cancelEnabled: interactive, submitEnabled: interactive && permitted && work == nil && !hasSaved,
            busy: work != nil)
    }

    private func refreshPresentation() {
        finishIfDetached()
        guard isViewLoaded, phase != .finished, !isRefreshing, !isCheckingIdentity else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let permitted = permitsSubmission()
        if !permitted { invalidateWork() }
        applyInteraction(permitted: permitted)
        if hasSaved, permitted {
            closeOwnPresentation()
            return
        }
        if !didSetInitialFocus, canClose, work == nil, !hasSaved {
            didSetInitialFocus = true
            // Preference.needInputMethod=true; showUserAgentDialog does not request the IME.
            if !body.usesUserAgentLayout {
                body.editor.becomeFirstResponder()
            } else if !body.editor.isFirstResponder {
                becomeFirstResponder()
            }
        }
        if work == nil, canClose {
            if let state = pendingEditingState {
                pendingEditingState = nil
                body.restoreEditingState(state)
            }
            if let message = pendingStatus {
                pendingStatus = nil
                body.showStatus(message)
                view.setNeedsLayout()
                view.layoutIfNeeded()
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    private func save() {
        guard work == nil, !hasSaved, !isCheckingIdentity, canClose, let save = onSave else { return }
        // Lock before invoking owner code or committing IME; either can reenter this controller.
        let attempt = Work(epoch: epoch)
        work = attempt
        guard accepts(attempt) else {
            complete(attempt, outcome: .cancelled)
            return
        }
        body.editor.unmarkText()
        attempt.editingState = body.captureEditingState()
        guard body.editor.markedTextRange == nil, accepts(attempt) else {
            complete(attempt, outcome: .cancelled)
            return
        }
        let raw = body.rawText
        pendingStatus = nil
        body.showStatus(nil)
        applyInteraction(permitted: false)
        view.setNeedsLayout()
        if canClose { becomeFirstResponder() }
        attempt.task = Task { @MainActor [weak self, attempt] in
            guard !Task.isCancelled, self?.accepts(attempt) == true else {
                self?.complete(attempt, outcome: .cancelled)
                return
            }
            do {
                // Raw String, including whitespace/newlines/empty input; normalization is the owner's job.
                // The owner must also honor cancellation and recheck its identity before an awaited commit.
                try await save(raw)
                self?.complete(attempt, outcome: .saved)
            } catch {
                // Error descriptions may contain credentials. Never log, expose or announce them.
                self?.complete(attempt, outcome: Task.isCancelled ? .cancelled : .failed)
            }
        }
    }

    private func complete(_ attempt: Work, outcome: Outcome) {
        guard work === attempt else { return }
        let current = accepts(attempt)
        attempt.task = nil
        work = nil
        guard phase != .finished, phase != .closing else { return }
        pendingEditingState = attempt.editingState
        switch outcome {
        case .saved where current:
            hasSaved = true
            pendingEditingState = nil
            closeOwnPresentation()
            return
        case .failed where current:
            pendingStatus = "保存失败，请重试。"
        case .saved, .failed:
            pendingStatus = "保存状态已变化，请核对设置。"
        case .cancelled:
            pendingStatus = attempt.editingState == nil ? nil : "保存已中断，请核对设置。"
        }
        body.showStatus(nil)
        refreshPresentation()
        view.setNeedsLayout()
    }

    @objc private func cancel() {
        guard canClose else { return }
        closeOwnPresentation()
    }

    private func closeOwnPresentation() {
        guard canClose else { return }
        beginClosing()
        ownsDismissalCompletion = true
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            ownsDismissalCompletion = false
            finishIfDetached()
            schedulePresentationRefresh()
        }
    }

    private func beginClosing() {
        guard phase != .finished else { return }
        phase = .closing
        isVisible = false
        epoch &+= 1
        invalidateWork()
        pendingEditingState = nil
        pendingStatus = nil
        if isViewLoaded {
            view.endEditing(true)
            applyInteraction(permitted: false)
        }
        resignFirstResponder()
    }

    @objc private func keyboardChanged() {
        guard isViewLoaded else { return }
        editorChanged()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.editorChanged()
            self.view.layoutIfNeeded()
        }
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard hasStarted, phase != .finished else { return }
        let sourceScene = sourceWindow?.windowScene
        let relatedScene = sourceScene != nil && (notification.object as? UIScene) === sourceScene
        let relatedWindow = sourceWindow != nil && (notification.object as? UIWindow) === sourceWindow
        let inactive =
            notification.name == UIApplication.willResignActiveNotification
            || notification.name == UIApplication.didEnterBackgroundNotification
            || (relatedScene
                && (notification.name == UIScene.willDeactivateNotification
                    || notification.name == UIScene.didEnterBackgroundNotification))
            || (relatedWindow
                && (notification.name == UIWindow.didResignKeyNotification
                    || notification.name == UIWindow.didBecomeHiddenNotification))
        if inactive {
            isEnvironmentSuspended = true
            epoch &+= 1
            invalidateWork()
        } else if notification.name == UIApplication.didBecomeActiveNotification
            || (relatedScene && notification.name == UIScene.didActivateNotification)
            || (relatedWindow && notification.name == UIWindow.didBecomeKeyNotification)
        {
            isEnvironmentSuspended = false
        }
        refreshPresentation()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        // Owner/navigation mutations have no shared UIKit notification.
        let timer = Timer(
            timeInterval: 0.1, target: RefreshTarget(owner: self),
            selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func schedulePresentationRefresh() {
        guard hasStarted, phase != .finished else { return }
        DispatchQueue.main.async { [self] in refreshPresentation() }
    }

    private func finishIfDetached() {
        guard hasStarted, phase != .finished, !ownsDismissalCompletion,
            presentingViewController == nil, presentedViewController == nil, parent == nil,
            viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil,
            !isBeingPresented, !isBeingDismissed
        else { return }
        phase = .finished
        isVisible = false
        epoch &+= 1
        invalidateWork()
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
        pendingEditingState = nil
        pendingStatus = nil
        onSave = nil
        canSubmit = nil
        body.onCancel = nil
        body.onSubmit = nil
        body.editor.delegate = nil
        applyInteraction(permitted: false)
        resignFirstResponder()
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: SettingsTextPreferenceDialogViewController?

        init(owner: SettingsTextPreferenceDialogViewController) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.refreshPresentation()
        }
    }
}

private final class SettingsPreferenceDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
