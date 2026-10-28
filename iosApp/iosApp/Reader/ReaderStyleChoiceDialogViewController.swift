import UIKit

/// Legado 5f5d314 AndroidAlertBuilder.items -> AppCompat 1.7.1 setItems.
/// The presenter supplies overrideUserInterfaceStyle before presenting.
@MainActor
final class ReaderStyleChoiceDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    /// Nil permits selection. Rechecked immediately before delivering a detached choice.
    var canSelect: (() -> Bool)?
    var onClose: (() -> Void)?

    private enum Phase {
        case appearing
        case active
        case closing(UUID)
        case finished
    }

    private let titleText: String
    private let items: [String]
    private var onSelect: ((Int) -> Void)?
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let scrollView = ReaderStyleChoiceScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private var itemControls: [ReaderStyleChoiceControl] = []
    private var phase: Phase = .appearing
    private var pendingSelection: Int?
    private var hasBegunPresentation = false
    private var isVisible = false
    private var isEvaluatingSelection = false
    private var isForegroundSuspended = false
    private var isDetachCheckScheduled = false
    private var isCompletingDismissal = false
    private var hasDeliveredClose = false
    private var deferredDismissalAnimated: Bool?
    private var dismissalCompletions: [() -> Void] = []
    private weak var presentationScene: UIWindowScene?
    private weak var selectionPresenter: UIViewController?
    private weak var selectionWindow: UIWindow?

    init(titleText: String, items: [String], onSelect: @escaping (Int) -> Void) {
        self.titleText = titleText
        self.items = items
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canInteract else { return nil }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel)),
            UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(cancel)),
        ].map { command in
            command.discoverabilityTitle = L10n.Common.cancel
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    override func loadView() {
        let host = ReaderStyleChoiceDialogHostView()
        host.onDetach = { [weak self] in self?.scheduleDismissalCompletion() }
        view = host
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        updateFonts()
        observeForegroundChanges()
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasBegunPresentation = true
        presentationController?.delegate = self
        updateFonts()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if case .finished = phase { return }
        presentationScene = view.window?.windowScene
        isVisible = true
        if case .closing = phase {
            updateInteraction()
            if let animated = deferredDismissalAnimated {
                deferredDismissalAnimated = nil
                DispatchQueue.main.async { [self] in dismissDialog(animated: animated) }
            }
            return
        }
        phase = .active
        // UIKit may clear isBeingPresented after returning from viewDidAppear.
        DispatchQueue.main.async { [self] in
            updateInteraction()
            guard canInteract else { return }
            becomeFirstResponder()
            UIAccessibility.post(
                notification: .screenChanged, argument: titleText.isEmpty ? itemControls.first : titleLabel)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if case .finished = phase { return }
        isVisible = false
        if isPresentationBeingDismissed {
            if isPresenterBeingDismissed { pendingSelection = nil }
            let identifier = beginClosing()
            // A cancelled transition may restore visibility, but never its old choice.
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                if context.isCancelled {
                    restoreAfterCancelledDismissal(identifier)
                } else {
                    scheduleDismissalCompletion()
                }
            }
        }
        updateInteraction()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        scheduleDismissalCompletion()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { scheduleDismissalCompletion() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        if case .finished = phase {
            completion?()
            scheduleDismissalCompletion()
            return
        }
        pendingSelection = nil
        if let completion { dismissalCompletions.append(completion) }
        beginClosing()
        updateInteraction()
        resignFirstResponder()
        dismissDialog(animated: flag)
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool {
        canInteract
    }

    func presentationControllerWillDismiss(_: UIPresentationController) {
        if case .finished = phase { return }
        pendingSelection = nil
        beginClosing()
        updateInteraction()
        resignFirstResponder()
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        if case .finished = phase { return }
        pendingSelection = nil
        beginClosing()
        scheduleDismissalCompletion()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(cancel) || action == #selector(cancelOperation(_:)) {
            return canInteract
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
            previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        updateFonts()
    }

    override func accessibilityPerformEscape() -> Bool {
        finish(selection: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }

        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let textWidth = max(1, width - 48)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            ).height)
        titleLabel.frame = titleText.isEmpty ? .zero : CGRect(x: 24, y: 18, width: textWidth, height: titleHeight)

        var contentHeight: CGFloat = titleText.isEmpty ? 8 : titleLabel.frame.maxY + 8
        for control in itemControls {
            let height = control.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            control.frame = CGRect(x: 0, y: contentHeight, width: width, height: height)
            contentHeight += height
        }
        contentHeight += 8

        // Include the title in the scrollable content so it cannot crowd out
        // the list in a short window or at accessibility text sizes.
        let height = min(safeFrame.height, contentHeight)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)
        scrollView.frame = dialogView.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        let offsetY = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height))
        if scrollView.contentOffset != CGPoint(x: 0, y: offsetY) {
            scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        }
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        // Android Configuration.reduceScreenLayout: large begins at 640x480dp.
        // values-large/xlarge-v4 override min_width, not values-sw600dp's
        // unrelated prefDialogWidth. applyTint removes the background inset.
        if shortSide >= 720 && longSide >= 960 {
            return size.width > size.height ? 0.45 : 0.72
        }
        let isLarge = shortSide >= 480 && longSide >= 640
        if size.width > size.height { return isLarge ? 0.55 : 0.65 }
        return isLarge ? 0.80 : 0.95
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.styleChoice.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        // applyTint uses the current ThemeStore background, not only the default day/night colors.
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true

        titleLabel.text = titleText
        titleLabel.isHidden = titleText.isEmpty
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textAlignment = .natural
        titleLabel.textColor = Self.textColor
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.styleChoice.title"

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true

        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(titleLabel)
        for (index, item) in items.enumerated() {
            let control = ReaderStyleChoiceControl(text: item)
            control.tag = index
            control.accessibilityIdentifier = "reader.styleChoice.item.\(index)"
            control.addTarget(self, action: #selector(selectItem(_:)), for: .touchUpInside)
            control.onActivate = { [weak self] in self?.finish(selection: index) ?? false }
            contentView.addSubview(control)
            itemControls.append(control)
        }
    }

    private static var textColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? .white : UIColor.black.withAlphaComponent(222.0 / 255.0)
        }
    }

    private func updateFonts() {
        // AppCompat v21 Title -> TextAppearance.Material.Title -> sans-serif-medium;
        // Subhead -> sans-serif. These are 20sp and 16sp, respectively.
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let itemFont = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        for control in itemControls {
            control.configure(font: itemFont, textColor: Self.textColor)
        }
        view.setNeedsLayout()
    }

    @objc private func selectItem(_ sender: UIControl) {
        guard items.indices.contains(sender.tag), itemControls[sender.tag] === sender else { return }
        finish(selection: sender.tag)
    }

    @objc private func cancel() {
        finish(selection: nil)
    }

    @objc private func cancelOperation(_ sender: Any?) {
        finish(selection: nil)
    }

    private var canInteract: Bool {
        guard case .active = phase, isVisible, !isEvaluatingSelection, !isForegroundSuspended,
            !isBeingPresented, !isBeingDismissed, !isMovingFromParent,
            presentedViewController == nil, let presenter = presentingViewController,
            presenter.presentedViewController === self,
            let window = viewIfLoaded?.window, viewIfLoaded?.superview != nil,
            !window.isHidden, window.alpha > 0,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window
        else { return false }
        return isStablePresenter(presenter)
    }

    private func isStablePresenter(_ presenter: UIViewController) -> Bool {
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent
            else { return false }
            current = controller.parent
        }
        return true
    }

    private var isPresenterBeingDismissed: Bool {
        var current = presentingViewController
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent
        }
        return false
    }

    private var isPresentationBeingDismissed: Bool {
        isBeingDismissed || isMovingFromParent || isPresenterBeingDismissed
    }

    private func updateInteraction() {
        let enabled = canInteract
        outsideControl.isEnabled = enabled
        scrollView.isUserInteractionEnabled = enabled
        for control in itemControls {
            control.isEnabled = enabled
            if !enabled {
                control.cancelTracking(with: nil)
                control.isHighlighted = false
            }
        }
    }

    @discardableResult
    private func beginClosing() -> UUID {
        isVisible = false
        if case .closing(let identifier) = phase { return identifier }
        let identifier = UUID()
        phase = .closing(identifier)
        return identifier
    }

    @discardableResult
    private func finish(selection: Int?) -> Bool {
        guard canInteract else { return false }
        if let selection, !items.indices.contains(selection) { return false }
        isEvaluatingSelection = true
        let accepted = selection == nil || (canSelect?() ?? true)
        isEvaluatingSelection = false
        // A caller's synchronous guard can dismiss or replace the presentation.
        guard canInteract else { return false }
        pendingSelection = accepted ? selection : nil
        selectionPresenter = presentingViewController
        selectionWindow = viewIfLoaded?.window
        presentationScene = selectionWindow?.windowScene
        beginClosing()
        updateInteraction()
        resignFirstResponder()
        dismissDialog(animated: true)
        return accepted
    }

    private func dismissDialog(animated: Bool) {
        guard case .closing = phase else { return }
        if isBeingPresented {
            deferredDismissalAnimated = animated
            return
        }
        guard !isBeingDismissed, let presenter = presentingViewController,
            presenter.presentedViewController === self
        else {
            scheduleDismissalCompletion()
            return
        }
        // Dismiss this controller only; the reader's presenting style panel stays.
        super.dismiss(animated: animated) { [self] in
            finishDismissalIfDetached()
            scheduleDismissalCompletion()
        }
    }

    private func restoreAfterCancelledDismissal(_ identifier: UUID) {
        guard case .closing(let current) = phase, current == identifier else { return }
        pendingSelection = nil
        deferredDismissalAnimated = nil
        phase = isVisible ? .active : .appearing
        updateInteraction()
        if canInteract { becomeFirstResponder() }
    }

    private func observeForegroundChanges() {
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(suspendInteraction(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(resumeInteraction(_:)), name: name, object: nil)
        }
    }

    private func belongsToPresentation(_ notification: Notification) -> Bool {
        guard let scene = notification.object as? UIScene else { return true }
        return scene === (viewIfLoaded?.window?.windowScene ?? presentationScene)
    }

    @objc private func suspendInteraction(_ notification: Notification) {
        guard belongsToPresentation(notification) else { return }
        isForegroundSuspended = true
        pendingSelection = nil
        updateInteraction()
        resignFirstResponder()
    }

    @objc private func resumeInteraction(_ notification: Notification) {
        guard belongsToPresentation(notification) else { return }
        isForegroundSuspended = false
        updateInteraction()
        if canInteract { becomeFirstResponder() }
        scheduleDismissalCompletion()
    }

    private var isDetached: Bool {
        presentingViewController == nil && presentedViewController == nil && parent == nil
            && viewIfLoaded?.window == nil && viewIfLoaded?.superview == nil
    }

    private var canDeliverSelection: Bool {
        guard !isForegroundSuspended, UIApplication.shared.applicationState == .active,
            let scene = presentationScene, scene.activationState == .foregroundActive,
            let window = selectionWindow, !window.isHidden, window.alpha > 0,
            window.windowScene === scene, let presenter = selectionPresenter,
            presenter.viewIfLoaded?.window === window, presenter.presentedViewController == nil
        else { return false }
        return isStablePresenter(presenter)
    }

    private func scheduleDismissalCompletion() {
        guard hasBegunPresentation, !hasDeliveredClose, !isDetachCheckScheduled else { return }
        isDetachCheckScheduled = true
        // UIKit can clear presentation links after disappearance and host removal.
        DispatchQueue.main.async { [self] in
            isDetachCheckScheduled = false
            finishDismissalIfDetached()
        }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, !hasDeliveredClose, !isCompletingDismissal, isDetached else { return }
        isCompletingDismissal = true
        defer { isCompletingDismissal = false }
        if case .finished = phase {
            // A callback may have synchronously reattached this one-shot instance.
        } else {
            isVisible = false
            let selectionCallback = onSelect
            updateInteraction()
            resignFirstResponder()
            var acceptedSelection: Int?
            if let selection = pendingSelection, canDeliverSelection, canSelect?() ?? true,
                pendingSelection == selection, isDetached, canDeliverSelection
            {
                acceptedSelection = selection
            }
            phase = .finished
            pendingSelection = nil
            canSelect = nil
            onSelect = nil
            deferredDismissalAnimated = nil
            if let selection = acceptedSelection, isDetached, canDeliverSelection {
                selectionCallback?(selection)
            }
        }
        guard isDetached else { return }
        hasDeliveredClose = true
        let closeCallback = onClose
        let completions = dismissalCompletions
        onClose = nil
        dismissalCompletions.removeAll()
        closeCallback?()
        for completion in completions { completion() }
    }
}

@MainActor
private final class ReaderStyleChoiceDialogHostView: UIView {
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

private final class ReaderStyleChoiceScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class ReaderStyleChoiceControl: UIControl {
    var onActivate: (() -> Bool)?
    private let label = UILabel()

    init(text: String) {
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = text
        accessibilityTraits = .button
        label.text = text
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .natural
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = false
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor =
                isHighlighted
                ? UIColor { traits in
                    (traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black)
                        .withAlphaComponent(0.12)
                } : .clear
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textSize = label.sizeThatFits(
            CGSize(width: max(1, size.width - 48), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: max(48, ceil(textSize.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 24, dy: 0)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        return onActivate?() ?? false
    }

    func configure(font: UIFont, textColor: UIColor) {
        label.font = font
        label.textColor = textColor
        setNeedsLayout()
    }
}
