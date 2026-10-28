import UIKit

/// WaitDialog.kt / dialog_wait.xml at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// Use a fresh instance per operation; disable cancellation before starting the write.
@MainActor
final class SourceChangeWaitDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private var onCancel: (() -> Void)?
    private var cancellationEnabled = true
    private let contentView = SourceChangeWaitDialogContentView()
    private lazy var dialogView = SourceChangeDialogView(
        content: contentView, wrapsContent: true, identifier: "sourceChange.waitDialog")
    private lazy var lifecycle = SourceChangeDialogLifecycle(
        controller: self,
        dismiss: { [weak self] animated, completion in
            self?.dismissDialog(animated: animated, completion: completion)
        },
        interactionChanged: { [weak self] in self?.updateInteraction() },
        detached: { [weak self] outcome in self?.didDetach(outcome) })

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
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
        // Consume Escape even while writes disable cancellation.
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "取消"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        view = dialogView
        dialogView.onWindowChange = { [weak self] in self?.lifecycle.scheduleDetachmentCheck() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentView.cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.applyFonts(traits: traitCollection)
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        lifecycle.willAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lifecycle.didAppear()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycle.canInteract else { return }
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.contentView.messageLabel)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lifecycle.willDisappear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifecycle.scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        lifecycle.close(.external, animated: flag, completion: completion)
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        lifecycle.externallyDismissed()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard lifecycle.canInteract else { return false }
        if cancellationEnabled { cancel() }
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    func setCancellationEnabled(_ enabled: Bool) {
        cancellationEnabled = enabled
        if !enabled { lifecycle.discardPendingUserAction() }
        if isViewLoaded { updateInteraction() }
    }

    /// Completes only after detachment. Never invokes onCancel, including during an in-flight cancel.
    func finish(animated: Bool, completion: @escaping () -> Void) {
        lifecycle.close(.finished, animated: animated, completion: completion)
    }

    @objc private func cancel() {
        guard cancellationEnabled, lifecycle.canInteract else { return }
        lifecycle.close(.cancelled, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func updateInteraction() {
        contentView.cancelControl.isEnabled = cancellationEnabled && lifecycle.canInteract
    }

    private func dismissDialog(animated: Bool, completion: @escaping () -> Void) {
        resignFirstResponder()
        super.dismiss(animated: animated, completion: completion)
    }

    private func didDetach(_ outcome: SourceChangeDialogLifecycle.Outcome) {
        let callback = onCancel
        onCancel = nil
        contentView.progress.stopAnimating()
        if outcome == .cancelled, cancellationEnabled { callback?() }
    }
}

@MainActor
private final class SourceChangeWaitDialogContentView: UIView {
    let progress = UIActivityIndicatorView(style: .large)
    let messageLabel = UILabel()
    let cancelControl = SourceChangeWaitCancelControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        BookshelfLayoutDialogStyle.configure(messageLabel, text: "加载目录", color: AndroidReplicaTheme.primaryText)
        messageLabel.textAlignment = .center
        messageLabel.accessibilityIdentifier = "sourceChange.waitDialog.message"
        progress.color = AndroidReplicaTheme.accent
        progress.isAccessibilityElement = false
        progress.startAnimating()
        cancelControl.accessibilityIdentifier = "sourceChange.waitDialog.cancel"
        for child in [progress, messageLabel, cancelControl] { addSubview(child) }
        accessibilityElements = [messageLabel, cancelControl]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        messageLabel.font = BookshelfLayoutDialogStyle.font(size: 14, traits: traits)
        cancelControl.apply(font: BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits))
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let messageWidth = ceil(
            messageLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width)
        let width = min(size.width, max(40 + 30 + 12 + messageWidth, 40 + cancelControl.preferredWidth))
        return CGSize(width: width, height: arrange(width: width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, applyFrames: true)
    }

    private func arrange(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(20, max(0, (width - 30) / 2))
        let innerWidth = max(1, width - inset * 2)
        let stacked = innerWidth < 30 + 12 + (messageLabel.font?.pointSize ?? 14)
        let textWidth = max(1, innerWidth - 12 - (stacked ? 0 : 30))
        let textHeight = ceil(
            messageLabel.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            ).height)
        let rowHeight = stacked ? 30 + textHeight + 12 : max(30, textHeight + 12)
        let cancelHeight = cancelControl.sizeThatFits(
            CGSize(width: innerWidth, height: .greatestFiniteMagnitude)
        ).height
        if applyFrames {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let progressX = stacked ? (width - 30) / 2 : (rtl ? width - inset - 30 : inset)
            // The Android progress is 30dp; scaling its native iOS indicator preserves that footprint.
            progress.transform = .identity
            let nativeSize = progress.sizeThatFits(CGSize(width: 30, height: 30))
            progress.bounds = CGRect(origin: .zero, size: nativeSize)
            progress.transform = CGAffineTransform(
                scaleX: 30 / max(1, nativeSize.width), y: 30 / max(1, nativeSize.height))
            progress.center = CGPoint(x: progressX + 15, y: inset + (stacked ? 15 : rowHeight / 2))
            messageLabel.frame = CGRect(
                x: inset + 6 + (stacked || rtl ? 0 : 30),
                y: inset + (stacked ? 36 : (rowHeight - textHeight) / 2),
                width: textWidth, height: textHeight)
            cancelControl.frame = CGRect(
                x: inset, y: inset + rowHeight + 6, width: innerWidth, height: cancelHeight)
        }
        return inset + rowHeight + 6 + cancelHeight + inset
    }
}

private final class SourceChangeWaitCancelControl: UIControl {
    private let label = UILabel()

    var preferredWidth: CGFloat {
        max(
            64,
            ceil(
                label.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                ).width) + 16)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        BookshelfLayoutDialogStyle.configure(label, text: "取消", color: AndroidReplicaTheme.accent)
        label.textAlignment = .center
        label.isAccessibilityElement = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = "取消"
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            label.alpha = isEnabled ? 1 : 0.5
            if !isEnabled { isHighlighted = false }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = ceil(
            label.sizeThatFits(
                CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude)
            ).height)
        return CGSize(width: size.width, height: max(44, height + 12))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: min(8, bounds.width / 2), dy: 6)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}

/// Shared only by the two source-change dialogs; user intent is delivered after UIKit detaches them.
@MainActor
final class SourceChangeDialogLifecycle {
    enum Outcome { case external, cancelled, confirmed, finished }

    private weak var controller: UIViewController?
    private weak var sourcePresenter: UIViewController?
    private weak var sourcePage: UIViewController?
    private weak var sourceWindow: UIWindow?
    private let performDismiss: (Bool, @escaping () -> Void) -> Void
    private let interactionChanged: () -> Void
    private var detached: ((Outcome) -> Void)?
    private var completions: [() -> Void] = []
    private var outcome: Outcome = .external
    private var hasPresented = false
    private var visible = false
    private var closing = false
    private var hasCloseRequest = false
    private var ownsDismissal = false
    private var isDetached = false
    private var requestedAnimation = false

    init(
        controller: UIViewController,
        dismiss: @escaping (Bool, @escaping () -> Void) -> Void,
        interactionChanged: @escaping () -> Void,
        detached: @escaping (Outcome) -> Void
    ) {
        self.controller = controller
        performDismiss = dismiss
        self.interactionChanged = interactionChanged
        self.detached = detached
    }

    var canInteract: Bool {
        guard let controller, visible, !closing, !isDetached,
            controller.presentingViewController != nil, controller.presentedViewController == nil,
            !controller.isBeingPresented, !presentationIsDismissing,
            let window = controller.viewIfLoaded?.window, !window.isHidden
        else { return false }
        return sourceIsCurrent
    }

    func willAppear() {
        guard !hasPresented, let presenter = controller?.presentingViewController else { return }
        hasPresented = true
        sourcePresenter = presenter
        sourceWindow = presenter.viewIfLoaded?.window
        var page = presenter
        while true {
            if let navigation = page as? UINavigationController, let top = navigation.topViewController {
                page = top
            } else if let tabs = page as? UITabBarController, let selected = tabs.selectedViewController {
                page = selected
            } else {
                break
            }
        }
        sourcePage = page
    }

    func didAppear() {
        guard !isDetached else { return }
        visible = true
        if closing, hasCloseRequest {
            startDismissalIfPossible()
        } else if !ownsDismissal {
            // Interactive external dismissals may be cancelled by UIKit.
            closing = false
            outcome = .external
        }
        interactionChanged()
        // UIKit may clear isBeingPresented only after viewDidAppear returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.visible, !self.isDetached else { return }
            self.interactionChanged()
        }
    }

    func willDisappear() {
        visible = false
        if presentationIsDismissing, !ownsDismissal {
            closing = true
            if outcome != .finished { outcome = .external }
        }
        interactionChanged()
        controller?.transitionCoordinator?.animate(alongsideTransition: nil) { [self, controller] context in
            withExtendedLifetime(controller) {
                guard !context.isCancelled else { return }
                scheduleDetachmentCheck()
            }
        }
    }

    func externallyDismissed() {
        if !ownsDismissal, outcome != .finished { outcome = .external }
        scheduleDetachmentCheck()
    }

    func discardPendingUserAction() {
        if outcome == .cancelled || outcome == .confirmed { outcome = .external }
    }

    func close(_ requestedOutcome: Outcome, animated: Bool, completion: (() -> Void)? = nil) {
        if isDetached {
            completion?()
            return
        }
        if let completion { completions.append(completion) }
        // finish wins over an earlier click; subsequent external dismissals cannot turn it into cancellation.
        if outcome != .finished { outcome = requestedOutcome }
        closing = true
        hasCloseRequest = true
        requestedAnimation = animated
        interactionChanged()
        if completeIfDetached(allowUnpresented: true) { return }
        startDismissalIfPossible()
    }

    func scheduleDetachmentCheck() {
        // UIKit can remove the view and clear its presentation links in either order.
        guard let controller else { return }
        DispatchQueue.main.async { [self, controller] in
            withExtendedLifetime(controller) { _ = completeIfDetached() }
        }
    }

    private func startDismissalIfPossible() {
        guard let controller, closing, !ownsDismissal, !isDetached else { return }
        if controller.isBeingPresented {
            controller.transitionCoordinator?.animate(alongsideTransition: nil) { [self, controller] _ in
                DispatchQueue.main.async { [self, controller] in
                    withExtendedLifetime(controller) {
                        startDismissalIfPossible()
                        scheduleDetachmentCheck()
                    }
                }
            }
            return
        }
        guard controller.presentingViewController != nil else {
            scheduleDetachmentCheck()
            return
        }
        // Never ask an ancestor already dismissing to dismiss again, or dismiss its next page later.
        guard !presentationIsDismissing else {
            scheduleDetachmentCheck()
            return
        }
        ownsDismissal = true
        performDismiss(requestedAnimation) { [self, controller] in
            withExtendedLifetime(controller) {
                ownsDismissal = false
                if !completeIfDetached() { scheduleDetachmentCheck() }
            }
        }
    }

    @discardableResult
    private func completeIfDetached(allowUnpresented: Bool = false) -> Bool {
        guard !isDetached, !ownsDismissal, hasPresented || allowUnpresented,
            let controller, controller.presentingViewController == nil,
            controller.viewIfLoaded?.window == nil
        else { return false }
        isDetached = true
        visible = false
        closing = true
        let result: Outcome
        if outcome == .cancelled || outcome == .confirmed, !sourceIsCurrent {
            result = .external
        } else {
            result = outcome
        }
        let callback = detached
        detached = nil
        interactionChanged()
        controller.resignFirstResponder()
        callback?(result)
        drainCompletions()
        return true
    }

    private func drainCompletions() {
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks { callback() }
    }

    private var presentationIsDismissing: Bool {
        if controller?.isBeingDismissed == true { return true }
        var current = controller?.presentingViewController
        while let parent = current {
            if parent.isBeingDismissed || parent.isMovingFromParent { return true }
            current = parent.parent
        }
        return false
    }

    private var sourceIsCurrent: Bool {
        guard let presenter = sourcePresenter, let page = sourcePage, let window = sourceWindow,
            presenter.viewIfLoaded?.window === window, page.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = page
        var includesPresenter = false
        while let parent = current {
            if parent === presenter { includesPresenter = true }
            if parent.isBeingDismissed || parent.isMovingFromParent { return false }
            if let presented = parent.presentedViewController, presented !== controller { return false }
            if let navigation = parent.parent as? UINavigationController,
                navigation.topViewController !== parent
            {
                return false
            }
            if let tabs = parent.parent as? UITabBarController,
                tabs.selectedViewController !== parent
            {
                return false
            }
            current = parent.parent
        }
        return includesPresenter
    }
}

@MainActor
final class SourceChangeDialogView: UIView {
    var onWindowChange: (() -> Void)?
    let outsideControl = UIControl()
    private let panel = UIView()
    private let scrollView = SourceChangeDialogScrollView()
    private let content: UIView
    private let wrapsContent: Bool

    init(content: UIView, wrapsContent: Bool, identifier: String) {
        self.content = content
        self.wrapsContent = wrapsContent
        super.init(frame: .zero)
        backgroundColor = .clear
        tintColor = AndroidReplicaTheme.accent
        accessibilityViewIsModal = true
        accessibilityIdentifier = identifier
        keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 3
        panel.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = identifier + ".content"
        addSubview(outsideControl)
        addSubview(panel)
        panel.addSubview(scrollView)
        scrollView.addSubview(content)
        accessibilityElements = [panel]
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        let available = availableFrame
        panel.isHidden = available.width <= 0 || available.height <= 0
        guard !panel.isHidden else { return }
        let maxWidth = min(available.width, bounds.width * widthFraction)
        let width =
            wrapsContent
            ? min(
                maxWidth,
                content.sizeThatFits(
                    CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
                ).width) : maxWidth
        let contentHeight = content.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(available.height, contentHeight)
        panel.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        scrollView.frame = panel.bounds
        content.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = content.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
    }

    private var widthFraction: CGFloat {
        let short = min(bounds.width, bounds.height)
        let long = max(bounds.width, bounds.height)
        let landscape = bounds.width > bounds.height
        if short >= 720, long >= 960 { return landscape ? 0.45 : 0.72 }
        if short >= 480, long >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private var availableFrame: CGRect {
        let safe = safeAreaLayoutGuide.layoutFrame
        var available = safe.insetBy(dx: min(8, safe.width / 2), dy: min(8, safe.height / 2))
        let keyboard = keyboardLayoutGuide.layoutFrame.intersection(bounds)
        if !keyboard.isNull, keyboard.intersects(available) {
            let above = max(0, min(available.maxY, keyboard.minY - 8) - available.minY)
            let belowY = max(available.minY, keyboard.maxY + 8)
            let below = max(0, available.maxY - belowY)
            if below > above {
                available = CGRect(x: available.minX, y: belowY, width: available.width, height: below)
            } else {
                available.size.height = above
            }
        }
        return available
    }

    @objc private func keyboardChanged() {
        setNeedsLayout()
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsLayout()
            self?.layoutIfNeeded()
        }
    }
}

private final class SourceChangeDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
