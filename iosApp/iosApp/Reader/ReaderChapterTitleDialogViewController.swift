import UIKit

/// ContentEditDialog.editTitle at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// Use a fresh instance per presentation. Persistence and book/chapter identity belong to the caller.
@MainActor
final class ReaderChapterTitleDialogViewController: UIViewController,
    UITextViewDelegate, UIAdaptivePresentationControllerDelegate
{
    /// Nil permits saving. Called before writing, while awaiting it, and before result delivery.
    /// A false result during an attempt permanently revokes that attempt's onSaved delivery.
    /// Replacing this guard during an attempt also revokes delivery, not the underlying write.
    public var canSave: (() -> Bool)? {
        didSet {
            validityGeneration &+= 1
            if attemptID != nil, phase != .detached { revokeDelivery() }
            if isViewLoaded { refreshPresentation() }
        }
    }

    /// Raw submitted text and the actually persisted display title, once after real detachment.
    /// Cancellation or an expired source never delivers this, even if the write has committed.
    public var onSaved: ((String, String) -> Void)?

    /// Once after real detachment, after onSaved when that result is still deliverable.
    public var onClose: (() -> Void)?

    private enum Phase {
        case waiting
        case active
        case closing
        case detached
    }

    private struct SavedTitle {
        let raw: String
        let display: String
    }

    private let onSave: (String) async throws -> String
    private let bodyView: ReaderChapterTitleDialogBodyView
    private let outsideControl = UIControl()
    private var phase: Phase = .waiting
    private var hasBegunPresentation = false
    private var isVisible = false
    private var isSaving = false
    private var hasSaved = false
    private var attemptID: UUID?
    private var deliveryRevoked = false
    private var pendingSavedTitle: SavedTitle?
    private var pendingError: String?
    private var ownsDismissalCompletion = false
    private var validityGeneration: UInt = 0
    private var isCheckingValidity = false
    private var isRefreshing = false
    private var refreshTimer: Timer?
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?
    private weak var sourceRootController: UIViewController?

    init(text: String, onSave: @escaping (String) async throws -> String) {
        self.onSave = onSave
        bodyView = ReaderChapterTitleDialogBodyView(text: text)
        super.init(nibName: nil, bundle: nil)
        title = "编辑"
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
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape(_:))),
            UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(cancel(_:))),
        ].map { command in
            command.discoverabilityTitle = "取消"
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func loadView() {
        let root = ReaderChapterTitleDialogHostView()
        root.onDetach = { [weak self] in self?.scheduleDetachmentCheck() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.tintColor = AndroidReplicaTheme.accent
        view.accessibilityIdentifier = "reader.chapterTitleDialog"
        view.accessibilityViewIsModal = true
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel(_:)), for: .touchUpInside)
        bodyView.editor.delegate = self
        bodyView.onConfirm = { [weak self] in self?.save() }
        bodyView.applyFonts(traits: traitCollection)
        view.addSubview(outsideControl)
        view.addSubview(bodyView)
        view.accessibilityElements = [bodyView]
        let center = NotificationCenter.default
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            center.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(applicationDeactivated), name: name, object: nil)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(sceneDeactivated(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            center.addObserver(self, selector: #selector(activationChanged), name: name, object: nil)
        }
        for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification] {
            center.addObserver(self, selector: #selector(sourceWindowInvalidated(_:)), name: name, object: nil)
        }
        applyInteraction(saveAllowed: false)
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
        if phase == .closing { revokeDelivery() }
        ownsDismissalCompletion = false
        phase = .active
        isVisible = true
        startRefreshTimer()
        refreshPresentation()
        // Android editTitle does not explicitly request the keyboard or replace the selection.
        if phase == .active, !bodyView.editor.isFirstResponder { becomeFirstResponder() }
        UIAccessibility.post(notification: .screenChanged, argument: bodyView.accessibilityHeading)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard phase != .detached else { return }
        isVisible = false
        if !ownsDismissalCompletion { revokeDelivery() }
        if isPresentationBeingDismissed { phase = .closing }
        applyInteraction(saveAllowed: false)
        transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
            if context.isCancelled { revokeDelivery() }
            scheduleDetachmentCheck()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Dismissing an independent child must not dismiss this dialog or its ancestors.
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .detached, presentingViewController != nil else {
            finishDismissalIfDetached()
            completion?()
            return
        }
        revokeDelivery()
        phase = .closing
        isVisible = false
        ownsDismissalCompletion = false
        if isViewLoaded {
            view.endEditing(true)
            applyInteraction(saveAllowed: false)
        }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishDismissalIfDetached()
            scheduleDetachmentCheck()
            completion?()
        }
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool { canCancel }

    func presentationControllerWillDismiss(_: UIPresentationController) {
        guard phase != .detached else { return }
        revokeDelivery()
        phase = .closing
        isVisible = false
        applyInteraction(saveAllowed: false)
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        revokeDelivery()
        scheduleDetachmentCheck()
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        cancel(nil)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canCancel else { return false }
        cancel(nil)
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(cancel(_:)) || action == #selector(cancelOperation(_:))
            || action == #selector(handleEscape(_:))
        {
            return canCancel
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        bodyView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableDialogFrame
        let height = min(
            available.height,
            bodyView.sizeThatFits(CGSize(width: available.width, height: .greatestFiniteMagnitude)).height)
        bodyView.frame = CGRect(
            x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
    }

    func textViewDidBeginEditing(_: UITextView) {
        bodyView.updateEditorFocus()
        requestCaretReveal()
    }

    func textViewDidEndEditing(_: UITextView) {
        bodyView.updateEditorFocus()
    }

    func textViewDidChange(_: UITextView) {
        requestCaretReveal()
    }

    func textViewDidChangeSelection(_: UITextView) {
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
        bodyView.revealCaretOnNextLayout()
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

    @objc private func applicationDeactivated() {
        revokeDelivery()
        if isViewLoaded { applyInteraction(saveAllowed: false) }
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === sourceWindow?.windowScene else { return }
        applicationDeactivated()
    }

    @objc private func activationChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshPresentation() }
    }

    @objc private func sourceWindowInvalidated(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === sourceWindow else { return }
        revokeDelivery()
        applyInteraction(saveAllowed: false)
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
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            window.rootViewController === root, currentSource(from: presenter) === source,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window
        else { return false }
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

    private var canDismissOwnPresentation: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isBeingDismissed,
            !isPresentationBeingDismissed, presentedViewController == nil,
            let presenter = presentingViewController, presenter.presentedViewController === self,
            let window = viewIfLoaded?.window, !window.isHidden, window.alpha > 0,
            !view.isHidden, view.alpha > 0
        else { return false }
        return true
    }

    private var canCancel: Bool {
        canDismissOwnPresentation && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
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

    private func permitsSaving(allowingDialog: Bool) -> Bool {
        guard !isCheckingValidity, isSourceCurrent(allowingDialog: allowingDialog) else { return false }
        isCheckingValidity = true
        let generation = validityGeneration
        let allowed = canSave?() ?? true
        isCheckingValidity = false
        // The caller's synchronous identity gate may itself dismiss or replace the presentation.
        return allowed && generation == validityGeneration && isSourceCurrent(allowingDialog: allowingDialog)
    }

    private func saveContextIsCurrent(for id: UUID) -> Bool {
        guard attemptID == id, !deliveryRevoked, canCancel,
            presentingViewController === sourcePresenter, viewIfLoaded?.window === sourceWindow,
            permitsSaving(allowingDialog: true)
        else { return false }
        return attemptID == id && !deliveryRevoked && canCancel
            && presentingViewController === sourcePresenter && viewIfLoaded?.window === sourceWindow
    }

    private func applyInteraction(saveAllowed: Bool) {
        guard isViewLoaded else { return }
        let interactive = canCancel
        outsideControl.isEnabled = interactive
        bodyView.setInteraction(
            editable: interactive && !isSaving && !hasSaved,
            confirmEnabled: interactive && !isSaving && !hasSaved && saveAllowed,
            saving: isSaving)
    }

    private func refreshPresentation() {
        guard isViewLoaded, phase != .detached, phase != .closing, !isRefreshing, !isCheckingValidity else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let allowed = permitsSaving(allowingDialog: true)
        if attemptID != nil, !allowed || (phase == .active && !canCancel) { revokeDelivery() }
        applyInteraction(saveAllowed: allowed)
        if hasSaved, canDismissOwnPresentation {
            beginDismissal(delivering: pendingSavedTitle)
            return
        }
        if let message = pendingError, canCancel {
            pendingError = nil
            bodyView.showError(message)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func revokeDelivery() {
        deliveryRevoked = true
        pendingSavedTitle = nil
    }

    @objc private func cancel(_ sender: Any?) {
        guard canCancel else { return }
        revokeDelivery()
        beginDismissal(delivering: nil)
    }

    @objc private func cancelOperation(_ sender: Any?) {
        cancel(sender)
    }

    @objc private func handleEscape(_ sender: Any?) {
        guard canCancel else { return }
        if bodyView.editor.isFirstResponder,
            view.keyboardLayoutGuide.layoutFrame.minY < view.safeAreaLayoutGuide.layoutFrame.maxY
        {
            view.endEditing(true)
            becomeFirstResponder()
            return
        }
        cancel(sender)
    }

    private func save() {
        guard !isSaving, !hasSaved, !isCheckingValidity, canCancel else { return }
        // Acquire the single-flight gate before invoking caller code or committing marked text.
        isSaving = true
        let id = UUID()
        attemptID = id
        deliveryRevoked = false
        guard saveContextIsCurrent(for: id) else {
            abandonPreparation()
            return
        }
        bodyView.editor.unmarkText()
        view.endEditing(true)
        guard bodyView.editor.markedTextRange == nil else {
            abandonPreparation()
            return
        }
        applyInteraction(saveAllowed: false)
        if canCancel { becomeFirstResponder() }
        Task { @MainActor [self] in
            // Read only after UIKit has committed the IME composition and ended editing.
            guard bodyView.editor.markedTextRange == nil, saveContextIsCurrent(for: id) else {
                abandonPreparation()
                return
            }
            let raw = bodyView.rawText
            bodyView.showError(nil)
            pendingError = nil
            view.setNeedsLayout()
            do {
                // No cancellation handle: dismissing UI cannot roll back a write already started.
                let display = try await onSave(raw)
                hasSaved = true
                if saveContextIsCurrent(for: id) {
                    pendingSavedTitle = SavedTitle(raw: raw, display: display)
                } else {
                    revokeDelivery()
                }
            } catch {
                if phase != .detached {
                    let message = error.localizedDescription
                    pendingError = message.isEmpty ? String(describing: error) : message
                }
                attemptID = nil
            }
            isSaving = false
            refreshPresentation()
        }
    }

    private func abandonPreparation() {
        isSaving = false
        attemptID = nil
        refreshPresentation()
    }

    private func beginDismissal(delivering result: SavedTitle?) {
        guard canDismissOwnPresentation else { return }
        pendingSavedTitle = deliveryRevoked ? nil : result
        phase = .closing
        // A successful dismissal is transiently neither editable nor detached; validate again after detachment.
        refreshTimer?.invalidate()
        refreshTimer = nil
        isVisible = false
        ownsDismissalCompletion = true
        view.endEditing(true)
        applyInteraction(saveAllowed: false)
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            ownsDismissalCompletion = false
            finishDismissalIfDetached()
            scheduleDetachmentCheck()
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        // Captured identity values and source navigation changes have no shared UIKit notification.
        let timer = Timer(
            timeInterval: 0.1, target: RefreshTarget(owner: self),
            selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleDetachmentCheck() {
        guard hasBegunPresentation, phase != .detached else { return }
        DispatchQueue.main.async { [self] in finishDismissalIfDetached() }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, phase != .detached, !ownsDismissalCompletion,
            isActuallyDetached
        else { return }
        phase = .detached
        isVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        let result = pendingSavedTitle
        let savedCallback = onSaved
        let closeCallback = onClose
        pendingSavedTitle = nil
        onSaved = nil
        onClose = nil
        pendingError = nil
        applyInteraction(saveAllowed: false)
        resignFirstResponder()
        let allowed = result != nil && !deliveryRevoked && permitsSaving(allowingDialog: false)
        canSave = nil
        NotificationCenter.default.removeObserver(self)
        if let result, allowed, !deliveryRevoked, isActuallyDetached, isSourceCurrent(allowingDialog: false) {
            savedCallback?(result.raw, result.display)
        }
        attemptID = nil
        closeCallback?()
    }

    private var isActuallyDetached: Bool {
        presentingViewController == nil && presentedViewController == nil && parent == nil
            && viewIfLoaded?.window == nil && viewIfLoaded?.superview == nil
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: ReaderChapterTitleDialogViewController?

        init(owner: ReaderChapterTitleDialogViewController) {
            self.owner = owner
        }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.refreshPresentation()
        }
    }
}

@MainActor
private final class ReaderChapterTitleDialogHostView: UIView {
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
