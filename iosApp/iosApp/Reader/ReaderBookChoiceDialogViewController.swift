import UIKit

/// Shared plain-item UI and dismissal lifecycle for Android's selector at 5f5d314.
@MainActor
class ReaderBookChoiceDialogViewController: UIViewController {
    struct Choice {
        let title: String
        let accessibilityValue: String
    }

    /// Runs once after detachment, after onSelect when an item was chosen.
    var onClose: (() -> Void)?

    private enum Phase {
        case appearing
        case ready
        case closing
        case cancelled
        case finished
    }

    private let titleText: String
    private let choices: [Choice]
    private let identifierPrefix: String
    private var onSelect: ((Int) -> Void)?
    private var phase: Phase = .appearing
    private var isVisible = false
    private var hasAppeared = false
    private let ownership = ReaderBookDialogOwnership()
    private var pendingSelection: Int?
    private var deliveryRevoked = false
    private var scrollHeaderHeight: CGFloat = 0
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let titleLabel = UILabel()
    private let scrollView = ReaderBookChoiceScrollView()
    private let contentView = UIView()
    private var rows: [ReaderBookChoiceRow] = []

    init(
        title: String,
        choices: [Choice],
        identifierPrefix: String,
        onClose: (() -> Void)? = nil,
        onSelect: @escaping (Int) -> Void
    ) {
        titleText = title
        self.choices = choices
        self.identifierPrefix = identifierPrefix
        self.onClose = onClose
        self.onSelect = onSelect
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
        guard canInteract else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        updateFonts()
        for name in ReaderBookDialogOwnership.environmentNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        updateInteraction()
    }

    override func loadView() {
        let root = ReaderBookChoiceRootView()
        root.onDetach = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.completeClose() }
        }
        view = root
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished, phase != .closing else { return }
        ownership.capture(from: self)
        hasAppeared = true
        // A covering child/external cancelled transition revokes only the old attempt.
        // Its return starts a fresh ready phase with the original selection callback intact.
        phase = .ready
        isVisible = true
        updateInteraction()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateInteraction()
            guard self.canInteract else { return }
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.titleLabel)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if phase != .closing { invalidateSelection() }
        updateInteraction()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard case .cancelled = phase else { return }
        // A presenter can dismiss us without invoking this controller's dismiss override.
        if let coordinator = transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { [self] context in
                if !context.isCancelled { completeClose() }
            }
        }
        DispatchQueue.main.async { [self] in completeClose() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        invalidateSelection()
        super.dismiss(animated: flag) { [self] in
            completeClose()
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        close(selectedIndex: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded,
            previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        else { return }
        updateFonts()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }

        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let textWidth = max(1, width - 48)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        // AppCompat 1.7.1: title 24dp sides / 18dp top / 8dp divider; list bottom 8dp.
        let headerHeight = 18 + titleHeight + 8
        let rowHeights = rows.map {
            $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let listHeight = rowHeights.reduce(CGFloat.zero, +)
        let height = min(safeFrame.height, headerHeight + listHeight + 8)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2, width: width, height: height)

        // Scroll the title too when a short window cannot fit the header and a complete first row.
        let scrollsTitle = headerHeight + (rowHeights.first ?? 0) + 8 > height
        let newScrollHeaderHeight = scrollsTitle ? headerHeight : 0
        let offsetY = newScrollHeaderHeight == scrollHeaderHeight ? scrollView.contentOffset.y : 0
        scrollHeaderHeight = newScrollHeaderHeight
        let titleParent = scrollsTitle ? contentView : dialogView
        if titleLabel.superview !== titleParent { titleParent.addSubview(titleLabel) }
        titleLabel.frame = CGRect(x: 24, y: 18, width: textWidth, height: titleHeight)
        scrollView.frame = CGRect(
            x: 0, y: scrollsTitle ? 0 : headerHeight,
            width: width, height: scrollsTitle ? height : max(0, height - headerHeight))
        var nextY = newScrollHeaderHeight
        for (row, rowHeight) in zip(rows, rowHeights) {
            row.frame = CGRect(x: 0, y: nextY, width: width, height: rowHeight)
            nextY += rowHeight
        }
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: nextY + 8)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentView.bounds.height > scrollView.bounds.height
        let offset = CGPoint(
            x: 0, y: min(max(0, offsetY), max(0, contentView.bounds.height - scrollView.bounds.height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        let rowElements: [UIView] = rows.map { $0 }
        contentView.accessibilityElements = scrollsTitle ? [titleLabel] + rowElements : rowElements
        dialogView.accessibilityElements = scrollsTitle ? [scrollView] : [titleLabel, scrollView]
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        // abc_dialog_min_width_minor/major, with values-large/xlarge-v4 overrides.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityIdentifier = "\(identifierPrefix).dialog"
        view.accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        // applyTint replaces the inset AppCompat drawable with filletBackground (3dp).
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        titleLabel.text = titleText
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textAlignment = .natural
        titleLabel.textColor = Self.textColor
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "\(identifierPrefix).title"
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        scrollView.accessibilityIdentifier = "\(identifierPrefix).list"
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(titleLabel)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        rows = choices.enumerated().map { index, choice in
            let row = ReaderBookChoiceRow(title: choice.title)
            row.tag = index
            row.accessibilityIdentifier = "\(identifierPrefix).value.\(choice.accessibilityValue)"
            row.addTarget(self, action: #selector(selectRow(_:)), for: .touchUpInside)
            row.onActivate = { [weak self, weak row] in
                guard let self, let row, self.rows.indices.contains(row.tag), self.rows[row.tag] === row else {
                    return false
                }
                return self.close(selectedIndex: row.tag)
            }
            contentView.addSubview(row)
            return row
        }
    }

    fileprivate static var textColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? .white : UIColor.black.withAlphaComponent(222.0 / 255.0)
        }
    }

    private func updateFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let rowFont = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        for row in rows { row.apply(font: rowFont) }
        view.setNeedsLayout()
    }

    private var canInteract: Bool {
        guard case .ready = phase, isVisible, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, let presenter = presentingViewController,
            let window = viewIfLoaded?.window, presenter.presentedViewController === self,
            window === ownership.window, ownership.isCurrent(allowing: self)
        else { return false }
        return true
    }

    private func updateInteraction() {
        let enabled = canInteract
        outsideControl.isEnabled = enabled
        scrollView.isUserInteractionEnabled = enabled
        for row in rows { row.isEnabled = enabled && ownership.matchesReaderIdentity }
    }

    private func invalidateSelection() {
        if case .finished = phase { return }
        phase = .cancelled
        pendingSelection = nil
        deliveryRevoked = true
        if isViewLoaded { updateInteraction() }
    }

    @objc private func cancel() {
        close(selectedIndex: nil)
    }

    @objc private func selectRow(_ sender: ReaderBookChoiceRow) {
        guard rows.indices.contains(sender.tag), rows[sender.tag] === sender else { return }
        close(selectedIndex: sender.tag)
    }

    @discardableResult
    private func close(selectedIndex: Int?) -> Bool {
        guard canInteract else { return false }
        if let selectedIndex, !choices.indices.contains(selectedIndex) { return false }
        if selectedIndex != nil, !ownership.matchesReaderIdentity { return false }
        phase = .closing
        pendingSelection = selectedIndex
        deliveryRevoked = false
        updateInteraction()
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            completeClose()
        }
        return true
    }

    @objc private func environmentChanged(_ notification: Notification) {
        guard ownership.belongs(notification) else { return }
        ownership.receive(notification)
        if ReaderBookDialogOwnership.interruptionNotifications.contains(notification.name) {
            pendingSelection = nil
            deliveryRevoked = true
        }
        updateInteraction()
        DispatchQueue.main.async { [weak self] in self?.updateInteraction() }
    }

    private func completeClose() {
        if case .finished = phase { return }
        guard hasAppeared, presentingViewController == nil, presentedViewController == nil, parent == nil,
            viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil
        else { return }
        let selectedIndex =
            !deliveryRevoked && ownership.isCurrent() && ownership.matchesReaderIdentity
            ? pendingSelection : nil
        let selectionCallback: ((Int) -> Void)?
        if case .closing = phase { selectionCallback = onSelect } else { selectionCallback = nil }
        phase = .finished
        pendingSelection = nil
        NotificationCenter.default.removeObserver(self)
        onSelect = nil
        let closeCallback = onClose
        onClose = nil
        if isViewLoaded { updateInteraction() }
        if let selectedIndex { selectionCallback?(selectedIndex) }
        closeCallback?()
    }
}

private final class ReaderBookChoiceScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class ReaderBookChoiceRow: UIControl {
    var onActivate: (() -> Bool)?
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        label.text = title
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .natural
        label.textColor = ReaderBookChoiceDialogViewController.textColor
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
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
                    (traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black).withAlphaComponent(0.12)
                } : .clear
        }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = ceil(
            label.sizeThatFits(CGSize(width: max(1, size.width - 48), height: .greatestFiniteMagnitude)).height)
        // select_dialog_item_material: 48dp minimum, 24dp sides, no radio or accessory column.
        return CGSize(width: size.width, height: max(48, height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 24, y: 0, width: max(0, bounds.width - 48), height: bounds.height)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        return onActivate?() ?? false
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }
}

private final class ReaderBookChoiceRootView: UIView {
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

/// Original presenter and reader identity for the three per-book setting dialogs.
@MainActor
final class ReaderBookDialogOwnership {
    static let interruptionNotifications: [Notification.Name] = [
        UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
        UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
    ]
    static let environmentNotifications =
        interruptionNotifications + [
            UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification,
        ]

    private(set) weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var presenter: UIViewController?
    private weak var source: UIViewController?
    private weak var root: UIViewController?
    private var matchesReader: (() -> Bool)?
    private var hasCaptured = false
    private var appSuspended = false
    private var sceneSuspended = false
    private var keyWindowSuspended = false
    private var windowHidden = false

    func capture(from dialog: UIViewController) {
        guard !hasCaptured, let presenter = dialog.presentingViewController,
            let window = dialog.viewIfLoaded?.window
        else { return }
        hasCaptured = true
        self.presenter = presenter
        self.window = window
        scene = window.windowScene
        root = window.rootViewController
        let source = currentSource(presenter)
        self.source = source
        if let reader = source as? ReaderContainerViewController {
            let bookURL = reader.bookURL
            let origin = reader.book?.origin
            let index = reader.readerActionChapterIndex
            let url = reader.readerActionChapterURL
            matchesReader = { [weak reader] in
                guard let reader else { return false }
                return reader.bookURL == bookURL && reader.book?.origin == origin
                    && reader.readerActionChapterIndex == index && reader.readerActionChapterURL == url
            }
        }
    }

    func belongs(_ notification: Notification) -> Bool {
        if let changed = notification.object as? UIWindow { return changed === window }
        if let changed = notification.object as? UIScene { return changed === scene }
        return true
    }

    var matchesReaderIdentity: Bool { matchesReader?() ?? true }

    func receive(_ notification: Notification) {
        guard belongs(notification) else { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification:
            appSuspended = true
        case UIApplication.didBecomeActiveNotification:
            appSuspended = false
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification:
            sceneSuspended = true
        case UIScene.didActivateNotification:
            sceneSuspended = false
        case UIWindow.didResignKeyNotification:
            keyWindowSuspended = true
        case UIWindow.didBecomeKeyNotification:
            keyWindowSuspended = false
        case UIWindow.didBecomeHiddenNotification:
            windowHidden = true
        case UIWindow.didBecomeVisibleNotification:
            windowHidden = false
        default: break
        }
    }

    var isEnvironmentAvailable: Bool {
        guard !appSuspended, !sceneSuspended, !keyWindowSuspended, !windowHidden,
            let window, let scene, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.windowScene === scene, scene.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active, AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    func isCurrent(allowing dialog: UIViewController? = nil) -> Bool {
        guard let window, let scene, let presenter, let source, let root,
            isEnvironmentAvailable,
            !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.windowScene === scene, scene.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active, AppLockManager.shared.isUnlocked(in: window),
            window.rootViewController === root, currentSource(presenter) === source,
            presenter.viewIfLoaded?.window === window, source.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = source
        var expected: UIViewController?
        var last: UIViewController?
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            // UIKit can forward the same owned modal through its navigation container.
            if let presented = controller.presentedViewController,
                presented !== expected, presented !== dialog
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
            last = controller
            if let parent = controller.parent {
                expected = nil
                current = parent
            } else {
                expected = controller
                current = controller.presentingViewController
            }
        }
        return last === root
    }

    private func currentSource(_ presenter: UIViewController) -> UIViewController {
        var current = presenter
        while true {
            if let navigation = current as? UINavigationController, let top = navigation.topViewController {
                current = top
            } else if let tabs = current as? UITabBarController, let selected = tabs.selectedViewController {
                current = selected
            } else {
                return current
            }
        }
    }
}
