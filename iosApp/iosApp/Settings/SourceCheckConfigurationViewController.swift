import UIKit

/// CheckSourceConfig.kt / dialog_check_source_config.xml at Legado 5f5d314.
/// Present a fresh instance directly. The caller owns persistence, only after real detachment.
@MainActor
final class SourceCheckConfigurationViewController: UIViewController,
    UITextViewDelegate, UIAdaptivePresentationControllerDelegate
{
    var canSave: (() -> Bool)? {
        didSet {
            validityGeneration &+= 1
            if attemptID != nil, phase != .detached { revokeDelivery() }
            refreshPresentation()
        }
    }

    /// Once after detachment, after onSave for a still-valid confirmation.
    var onClose: (() -> Void)?

    private enum Phase { case waiting, active, closing, detached }

    private let contentView: SourceCheckConfigurationContentView
    private let outsideControl = UIControl()
    private var onSave: ((SourceCheckSettings) -> Void)?
    private var phase: Phase = .waiting
    private var hasBegunPresentation = false
    private var isVisible = false
    private var isPreparing = false
    private var isForegroundSuspended = false
    private var isCheckingValidity = false
    private var isRefreshing = false
    private var validityGeneration: UInt = 0
    private var foregroundGeneration: UInt = 0
    private var attemptID: UUID?
    private var dismissalID: UUID?
    private var deliveryRevoked = false
    private var pendingSettings: SourceCheckSettings?
    private var refreshTimer: Timer?
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?
    private weak var sourceScene: UIWindowScene?
    private weak var sourceRootController: UIViewController?

    init(settings: SourceCheckSettings, onSave: @escaping (SourceCheckSettings) -> Void) {
        contentView = SourceCheckConfigurationContentView(settings: settings)
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = "校验设置"
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel)),
            UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(cancel)),
        ].map {
            $0.discoverabilityTitle = "取消"
            $0.wantsPriorityOverSystemBehavior = true
            return $0
        }
    }

    override func loadView() {
        let host = SourceCheckConfigurationHostView()
        host.onDetach = { [weak self] in self?.scheduleDetachmentCheck() }
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "sourceCheck.configuration"
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.editor.delegate = self
        contentView.onCancel = { [weak self] in self?.cancel() }
        contentView.onConfirm = { [weak self] in self?.confirm() }
        contentView.onLayoutChange = { [weak self] in self?.view.setNeedsLayout() }
        contentView.canInteract = { [weak self] in
            guard let self else { return false }
            return self.canCancel && !self.isPreparing
        }
        view.addSubview(outsideControl)
        view.addSubview(contentView)
        view.accessibilityElements = [contentView]
        contentView.apply(traits: traitCollection)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(paletteChanged), name: .androidReplicaThemeDidChange, object: nil)
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            center.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(self, selector: #selector(applicationDeactivated), name: name, object: nil)
        }
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification] {
            center.addObserver(self, selector: #selector(sceneDeactivated(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification] {
            center.addObserver(self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
        for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification] {
            center.addObserver(self, selector: #selector(windowInvalidated(_:)), name: name, object: nil)
        }
        applyInteraction(saveAllowed: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        if !hasBegunPresentation, let presenter = presentingViewController {
            hasBegunPresentation = true
            sourcePresenter = presenter
            sourceController = currentSource(from: presenter)
            sourceWindow = viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
            sourceScene = sourceWindow?.windowScene
            sourceRootController = sourceWindow?.rootViewController
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .detached else { return }
        if phase == .closing {
            revokeDelivery()
            isPreparing = false
            attemptID = nil
        }
        dismissalID = nil
        phase = .active
        isVisible = true
        startRefreshTimer()
        refreshPresentation()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPresentation()
            guard self.canCancel else { return }
            if !self.contentView.editor.isFirstResponder { self.becomeFirstResponder() }
            UIAccessibility.post(notification: .screenChanged, argument: self.contentView.accessibilityHeading)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard phase != .detached else { return }
        isVisible = false
        if dismissalID == nil { revokeDelivery() }
        if isPresentationBeingDismissed { phase = .closing }
        applyInteraction(saveAllowed: false)
        transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
            if context.isCancelled {
                revokeDelivery()
                dismissalID = nil
            }
            scheduleDetachmentCheck()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .detached, presentingViewController != nil else {
            finishIfDetached()
            completion?()
            return
        }
        revokeDelivery()
        dismissalID = nil
        phase = .closing
        isVisible = false
        if isViewLoaded {
            view.endEditing(true)
            applyInteraction(saveAllowed: false)
        }
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishIfDetached()
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
        guard phase != .detached else { return }
        revokeDelivery()
        scheduleDetachmentCheck()
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) { cancel() }

    override func accessibilityPerformEscape() -> Bool {
        guard canCancel else { return false }
        cancel()
        return true
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(cancel) || action == #selector(cancelOperation(_:)) { return canCancel }
        return super.canPerformAction(action, withSender: sender)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.apply(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableDialogFrame
        let desired = contentView.sizeThatFits(CGSize(width: available.width, height: .greatestFiniteMagnitude)).height
        let height = min(available.height, desired)
        contentView.frame = CGRect(x: available.minX, y: available.midY - height / 2, width: available.width, height: height)
        contentView.layoutIfNeeded()
    }

    func textViewDidBeginEditing(_: UITextView) {
        contentView.updateInputAppearance()
        requestCaretReveal()
    }

    func textViewDidEndEditing(_: UITextView) { contentView.updateInputAppearance() }

    func textViewDidChange(_: UITextView) {
        contentView.showError(nil)
        requestCaretReveal()
    }

    func textViewDidChangeSelection(_: UITextView) { requestCaretReveal() }

    func textView(_: UITextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
        guard canCancel, !isPreparing else { return false }
        if text == "\n" {
            confirm()
            return false
        }
        return text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private var availableDialogFrame: CGRect {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = max(0, min(safe.width, view.bounds.width * 0.9))
        let margin = min(16, max(0, safe.height / 10))
        var frame = CGRect(x: safe.midX - width / 2, y: safe.minY + margin, width: width, height: max(0, safe.height - margin * 2))
        let keyboard = view.keyboardLayoutGuide.layoutFrame.intersection(view.bounds)
        if !keyboard.isNull, keyboard.height > 0, keyboard.intersects(frame) {
            let above = max(0, min(frame.maxY, keyboard.minY - margin) - frame.minY)
            let belowY = max(frame.minY, keyboard.maxY + margin)
            let below = max(0, frame.maxY - belowY)
            if below > above {
                frame.origin.y = belowY
                frame.size.height = below
            } else {
                frame.size.height = above
            }
        }
        return frame
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
        canDismissOwnPresentation && !isForegroundSuspended
            && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.isKeyWindow == true
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var isPresentationBeingDismissed: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
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
            let window = sourceWindow, let scene = sourceScene, let root = sourceRootController,
            !isForegroundSuspended, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            window.windowScene === scene, window.rootViewController === root,
            currentSource(from: presenter) === source,
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

    private func permitsSaving(allowingDialog: Bool) -> Bool {
        guard !isCheckingValidity, isSourceCurrent(allowingDialog: allowingDialog) else { return false }
        isCheckingValidity = true
        let generation = validityGeneration
        let allowed = canSave?() ?? true
        isCheckingValidity = false
        // Synchronous caller guards may replace themselves or dismiss the dialog.
        return allowed && generation == validityGeneration && isSourceCurrent(allowingDialog: allowingDialog)
    }

    private func attemptIsCurrent(_ id: UUID) -> Bool {
        guard attemptID == id, !deliveryRevoked, canCancel,
            presentingViewController === sourcePresenter, viewIfLoaded?.window === sourceWindow,
            permitsSaving(allowingDialog: true)
        else { return false }
        return attemptID == id && !deliveryRevoked && canCancel
            && presentingViewController === sourcePresenter && viewIfLoaded?.window === sourceWindow
    }

    private func applyInteraction(saveAllowed: Bool) {
        guard isViewLoaded else { return }
        let editable = canCancel && !isPreparing
        outsideControl.isEnabled = canCancel
        contentView.setInteraction(editable: editable, confirmEnabled: editable && saveAllowed)
    }

    private func refreshPresentation() {
        guard isViewLoaded, phase != .detached, !isRefreshing, !isCheckingValidity else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let allowed = permitsSaving(allowingDialog: true)
        if attemptID != nil, !allowed { revokeDelivery() }
        applyInteraction(saveAllowed: allowed && phase == .active)
        if phase == .closing { finishIfDetached() }
    }

    private func revokeDelivery() {
        deliveryRevoked = true
        pendingSettings = nil
    }

    @objc private func cancel() {
        guard canCancel else { return }
        revokeDelivery()
        beginDismissal(delivering: nil)
    }

    @objc private func cancelOperation(_: Any?) { cancel() }

    private func confirm() {
        guard !isPreparing, !isCheckingValidity, canCancel else { return }
        isPreparing = true
        let id = UUID()
        attemptID = id
        deliveryRevoked = false
        guard attemptIsCurrent(id) else {
            abandonPreparation(id)
            return
        }
        contentView.editor.unmarkText()
        view.endEditing(true)
        applyInteraction(saveAllowed: false)
        // Like the established edit-title dialog, read only after UIKit commits composition.
        DispatchQueue.main.async { [self] in
            guard contentView.editor.markedTextRange == nil, attemptIsCurrent(id) else {
                abandonPreparation(id)
                return
            }
            let raw = contentView.rawTimeout
            let message: String?
            let seconds = Int64(raw)
            if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                message = "超时时间不能为空"
            } else if !raw.utf8.allSatisfy({ (48...57).contains($0) }) || seconds == nil {
                message = "请输入有效的正整数秒数"
            } else if let seconds, seconds <= 0 {
                message = "超时时间必须大于0秒"
            } else if let seconds, seconds > SourceCheckSettings.maximumTimeoutSeconds {
                message = "超时时间不能超过\(SourceCheckSettings.maximumTimeoutSeconds)秒"
            } else {
                message = nil
            }
            if let message {
                abandonPreparation(id)
                guard phase == .active else { return }
                contentView.showError(message)
                view.setNeedsLayout()
                UIAccessibility.post(notification: .announcement, argument: message)
                return
            }
            guard let seconds, attemptIsCurrent(id) else {
                abandonPreparation(id)
                return
            }
            var settings = contentView.draft
            settings.timeoutSeconds = seconds
            beginDismissal(delivering: settings.normalized)
        }
    }

    private func abandonPreparation(_ id: UUID) {
        guard attemptID == id else { return }
        isPreparing = false
        attemptID = nil
        refreshPresentation()
    }

    private func beginDismissal(delivering settings: SourceCheckSettings?) {
        guard canDismissOwnPresentation else { return }
        pendingSettings = deliveryRevoked ? nil : settings
        let id = UUID()
        dismissalID = id
        phase = .closing
        isVisible = false
        view.endEditing(true)
        applyInteraction(saveAllowed: false)
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            if dismissalID == id { dismissalID = nil }
            finishIfDetached()
            scheduleDetachmentCheck()
        }
    }

    private func scheduleDetachmentCheck() {
        guard hasBegunPresentation, phase != .detached else { return }
        DispatchQueue.main.async { [self] in finishIfDetached() }
    }

    private var isActuallyDetached: Bool {
        presentingViewController == nil && presentedViewController == nil && parent == nil
            && viewIfLoaded?.window == nil && viewIfLoaded?.superview == nil
    }

    private func finishIfDetached() {
        guard hasBegunPresentation, phase != .detached, dismissalID == nil, isActuallyDetached else { return }
        phase = .detached
        isVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        let settings = pendingSettings
        let saveCallback = onSave
        let closeCallback = onClose
        pendingSettings = nil
        onSave = nil
        onClose = nil
        applyInteraction(saveAllowed: false)
        resignFirstResponder()
        let allowed = settings != nil && !deliveryRevoked && permitsSaving(allowingDialog: false)
        canSave = nil
        attemptID = nil
        NotificationCenter.default.removeObserver(self)
        if let settings, allowed, !deliveryRevoked, isActuallyDetached, isSourceCurrent(allowingDialog: false) {
            saveCallback?(settings)
        }
        closeCallback?()
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, target: RefreshTarget(owner: self), selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func paletteChanged() {
        guard isViewLoaded, phase != .detached else { return }
        contentView.apply(traits: traitCollection)
        requestCaretReveal()
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

    @objc private func applicationDeactivated() {
        foregroundGeneration &+= 1
        isForegroundSuspended = true
        revokeDelivery()
        if isViewLoaded { applyInteraction(saveAllowed: false) }
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === sourceScene else { return }
        applicationDeactivated()
    }

    @objc private func windowInvalidated(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === sourceWindow else { return }
        applicationDeactivated()
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== sourceScene { return }
        if let window = notification.object as? UIWindow, window !== sourceWindow { return }
        let generation = foregroundGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.foregroundGeneration == generation,
                UIApplication.shared.applicationState == .active,
                self.sourceScene?.activationState == .foregroundActive,
                self.sourceWindow?.isKeyWindow == true
            else { return }
            self.isForegroundSuspended = false
            self.refreshPresentation()
        }
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: SourceCheckConfigurationViewController?

        init(owner: SourceCheckConfigurationViewController) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.refreshPresentation()
        }
    }
}

private final class SourceCheckConfigurationHostView: UIView {
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
