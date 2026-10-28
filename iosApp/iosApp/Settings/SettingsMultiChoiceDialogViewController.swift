import UIKit

/// BackupConfigFragment.backupIgnore() at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// Choices change only in memory. Every dismissal delivers the final set, not a cancelable draft.
/// Present a fresh instance directly; the caller owns persistence and the owner/session identity.
@MainActor
final class SettingsMultiChoiceDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    /// A pure owner/session guard. Once false, this presentation can never deliver a selection.
    /// An expired owner disables choices but does not prevent closing this dialog itself.
    var canCommit: (() -> Bool)? {
        didSet {
            if isViewLoaded { updateInteraction() }
        }
    }

    private enum Phase {
        case waiting
        case active
        case closing
        case finished
    }

    private let identifier: String
    private let outsideControl = UIControl()
    private let body: SettingsMultiChoiceDialogContentView
    private var onDismissSelection: ((Set<Int>) -> Void)?
    private var dismissalCompletions: [() -> Void] = []
    private var phase: Phase = .waiting
    private var hasStarted = false
    private var isVisible = false
    private var requestedDismissal = false
    private var hasIssuedDismissal = false
    private var dismissalAnimated = true
    private var ownerExpired = false
    private var isCheckingOwner = false
    private var isUpdatingInteraction = false
    private var refreshScheduled = false
    private weak var originalPresenter: UIViewController?
    private weak var originalSource: UIViewController?
    private weak var originalWindow: UIWindow?
    private weak var originalScene: UIWindowScene?
    private weak var originalRoot: UIViewController?

    init(
        titleText: String, items: [String], selectedIndices: Set<Int>, identifier: String,
        onDismissSelection: @escaping (Set<Int>) -> Void
    ) {
        self.identifier = identifier
        self.onDismissSelection = onDismissSelection
        body = SettingsMultiChoiceDialogContentView(
            titleText: titleText, items: items, selectedIndices: selectedIndices, identifier: identifier)
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
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
        command.discoverabilityTitle = "关闭"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        let root = SettingsMultiChoiceDialogRootView()
        root.onWindowChange = { [weak self] in self?.scheduleRefresh() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = identifier
        view.accessibilityViewIsModal = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(close), for: .touchUpInside)
        body.canToggle = { [weak self] in
            guard let self else { return false }
            let allowed = self.mayToggle
            if !allowed { self.updateInteraction() }
            return allowed
        }
        view.addSubview(outsideControl)
        view.addSubview(body)
        view.accessibilityElements = [body]
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: name, object: nil)
        }
        body.applyAppearance()
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        captureOriginIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        captureOriginIfNeeded()
        if requestedDismissal {
            issueDismissalIfReady()
            scheduleRefresh()
            return
        }
        isVisible = true
        phase = .active
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: body.initialAccessibilityFocus)
        // UIKit clears isBeingPresented after the appearance callback returns.
        scheduleRefresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        updateInteraction()
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.scheduleRefresh() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleRefresh()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        captureOriginIfNeeded()
        if phase != .finished, requestedDismissal || isBeingDismissed {
            if let completion { dismissalCompletions.append(completion) }
            scheduleRefresh()
            return
        }
        // A stale instance must never forward dismiss into a replacement presentation.
        guard phase != .finished, ownsPresentation else {
            finishIfDetached()
            completion?()
            return
        }
        if presentedViewController != nil {
            // Preserve UIKit's child-only dismissal semantics; the choices remain in this dialog.
            super.dismiss(animated: flag) { [weak self] in
                self?.scheduleRefresh()
                completion?()
            }
            return
        }
        if let completion { dismissalCompletions.append(completion) }
        requestedDismissal = true
        dismissalAnimated = flag
        phase = .closing
        isVisible = false
        updateInteraction()
        resignFirstResponder()
        issueDismissalIfReady()
    }

    func presentationControllerDidDismiss(_: UIPresentationController) { scheduleRefresh() }

    override func accessibilityPerformEscape() -> Bool {
        guard mayClose else { return false }
        close()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        body.applyAppearance()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        let width = min(safe.width, view.bounds.width * dialogWidthFraction)
        let preferred = body.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(safe.height * 0.9, preferred.height)
        body.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        body.layoutIfNeeded()
        updateInteraction()
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        // AppCompat values[-large/-xlarge]-v4 abc_dialog_min_width_minor/major.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private var ownsPresentation: Bool {
        guard let presenter = originalPresenter else { return false }
        return presentingViewController === presenter && presenter.presentedViewController === self
    }

    private var mayClose: Bool {
        phase == .active && isVisible && ownsPresentation && presentedViewController == nil
            && !isBeingPresented && !isBeingDismissed && environmentIsActive
    }

    private var mayToggle: Bool {
        guard mayClose, originIsCurrent, ownerAllowsCommit() else { return false }
        return mayClose && originIsCurrent
    }

    private var environmentIsActive: Bool {
        guard let window = originalWindow, let scene = originalScene else { return false }
        return viewIfLoaded?.window === window && !window.isHidden && window.alpha > 0
            && window.isKeyWindow && window.windowScene === scene && scene.activationState == .foregroundActive
    }

    private var originIsCurrent: Bool {
        guard let presenter = originalPresenter, let source = originalSource,
            let window = originalWindow, let scene = originalScene, let root = originalRoot,
            window.windowScene === scene, window.rootViewController === root,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window,
            currentLeaf(presenter) === source
        else { return false }
        var current: UIViewController? = source
        var expectedPresentation: UIViewController?
        var includesPresenter = false
        var last: UIViewController?
        while let controller = current {
            if controller === presenter { includesPresenter = true }
            guard !controller.isBeingDismissed, !controller.isBeingPresented,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== self, presented !== expectedPresentation
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
            last = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return includesPresenter && last === root
    }

    private func currentLeaf(_ controller: UIViewController) -> UIViewController {
        if let navigation = controller as? UINavigationController, let top = navigation.topViewController {
            return currentLeaf(top)
        }
        if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
            return currentLeaf(selected)
        }
        return controller
    }

    private func captureOriginIfNeeded() {
        guard !hasStarted, phase != .finished, let presenter = presentingViewController,
            let window = viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
        else { return }
        hasStarted = true
        originalPresenter = presenter
        originalSource = currentLeaf(presenter)
        originalWindow = window
        originalScene = window.windowScene
        originalRoot = window.rootViewController
    }

    private func ownerAllowsCommit() -> Bool {
        guard !ownerExpired, !isCheckingOwner else { return false }
        isCheckingOwner = true
        let allowed = canCommit?() ?? true
        isCheckingOwner = false
        if !allowed { ownerExpired = true }
        return allowed && !ownerExpired
    }

    private func updateInteraction() {
        guard isViewLoaded, !isUpdatingInteraction else { return }
        isUpdatingInteraction = true
        defer { isUpdatingInteraction = false }
        outsideControl.isEnabled = mayClose
        body.setSelectionEnabled(mayToggle)
    }

    @objc private func environmentChanged() { scheduleRefresh() }

    private func scheduleRefresh() {
        guard !refreshScheduled, phase != .finished else { return }
        refreshScheduled = true
        // UIKit can release its last reference immediately after didMoveToWindow/viewDidDisappear.
        // Retain this instance through this one turn, without retaining its original owner.
        DispatchQueue.main.async { [self] in
            refreshScheduled = false
            finishIfDetached()
            issueDismissalIfReady()
            updateInteraction()
        }
    }

    private func issueDismissalIfReady() {
        guard requestedDismissal, !hasIssuedDismissal, phase == .closing, ownsPresentation,
            presentedViewController == nil, !isBeingPresented, !isBeingDismissed,
            originalPresenter?.isBeingDismissed != true
        else { return }
        hasIssuedDismissal = true
        super.dismiss(animated: dismissalAnimated) { [self] in
            finishIfDetached()
            scheduleRefresh()
        }
    }

    @objc private func close() {
        guard mayClose else { return }
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func finishIfDetached() {
        guard hasStarted, phase != .finished, presentingViewController == nil,
            parent == nil, viewIfLoaded?.window == nil, !isBeingPresented, !isBeingDismissed
        else { return }
        // Both UIKit's links and the actual window must be detached before business code can run.
        let permitted = originIsCurrent && ownerAllowsCommit() && originIsCurrent
        let callback = onDismissSelection
        let selection = body.selectedIndices
        let completions = dismissalCompletions
        phase = .finished
        isVisible = false
        onDismissSelection = nil
        dismissalCompletions.removeAll()
        canCommit = nil
        body.canToggle = nil
        NotificationCenter.default.removeObserver(self)
        updateInteraction()
        if permitted { callback?(selection) }
        for completion in completions { completion() }
    }
}
