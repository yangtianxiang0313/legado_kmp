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
        guard case .ready = phase else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        updateFonts()
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard case .appearing = phase else { return }
        phase = .ready
        isVisible = true
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if case .closing = phase {
            updateInteraction()
        } else {
            invalidateSelection()
        }
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
        invalidateSelection()
        super.dismiss(animated: flag) { [self] in
            completeClose()
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(selectedIndex: nil)
        return true
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
            let window = viewIfLoaded?.window, presenter.presentedViewController === self
        else { return false }
        return isAvailablePresenter(presenter, in: window)
    }

    private func isAvailablePresenter(_ presenter: UIViewController, in window: UIWindow) -> Bool {
        guard !window.isHidden, presenter.viewIfLoaded?.window === window else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent else { return false }
            current = controller.parent
        }
        return true
    }

    private func updateInteraction() {
        let enabled: Bool
        if case .ready = phase { enabled = isVisible } else { enabled = false }
        outsideControl.isEnabled = enabled
        scrollView.isUserInteractionEnabled = enabled
        for row in rows { row.isEnabled = enabled }
    }

    private func invalidateSelection() {
        if case .finished = phase { return }
        phase = .cancelled
        onSelect = nil
        if isViewLoaded { updateInteraction() }
    }

    @objc private func cancel() {
        close(selectedIndex: nil)
    }

    @objc private func selectRow(_ sender: ReaderBookChoiceRow) {
        guard rows.indices.contains(sender.tag), rows[sender.tag] === sender else { return }
        close(selectedIndex: sender.tag)
    }

    private func close(selectedIndex: Int?) {
        guard canInteract, let presenter = presentingViewController, let window = viewIfLoaded?.window else { return }
        phase = .closing
        if selectedIndex == nil { onSelect = nil }
        updateInteraction()
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self, weak presenter, weak window] in
            let maySelect: Bool
            if case .closing = phase, let presenter, let window,
                presenter.presentedViewController == nil, isAvailablePresenter(presenter, in: window)
            {
                maySelect = true
            } else {
                maySelect = false
            }
            completeClose(selectedIndex: maySelect ? selectedIndex : nil)
        }
    }

    private func completeClose(selectedIndex: Int? = nil) {
        if case .finished = phase { return }
        guard presentingViewController == nil, viewIfLoaded?.window == nil else { return }
        let selectionCallback: ((Int) -> Void)?
        if case .closing = phase { selectionCallback = onSelect } else { selectionCallback = nil }
        phase = .finished
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
            if !isEnabled { isHighlighted = false }
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
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }
}
