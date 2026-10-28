import UIKit

/// ClickActionConfigDialog -> selector -> AndroidAlertBuilder.setItems at 5f5d31404.
/// This is a plain list: no checked item, radio column, or dialog action buttons.
@MainActor
final class ReaderTapZoneActionSelectorViewController: UIViewController {
    private enum Phase {
        case appearing
        case ready
        case closing
        case finished
    }

    private let items: [String]
    private let identifier: String
    private var onSelect: ((Int) -> Void)?
    private var phase: Phase = .appearing
    private var isVisible = false
    private var scrollHeaderHeight: CGFloat = 0
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let scrollView = ReaderTapZoneSelectorScrollView()
    private let contentView = UIView()
    private var rows: [ReaderTapZoneSelectorRow] = []

    init(title: String, items: [String], identifier: String, onSelect: @escaping (Int) -> Void) {
        self.items = items
        self.identifier = identifier
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        self.title = title
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
        applyFonts()
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
            invalidate()
        }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        invalidate()
        super.dismiss(animated: flag, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(selectedIndex: nil)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }
        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let textInset = min(24, max(0, (width - 1) / 2))
        let titleWidth = max(1, width - textInset * 2)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        // AppCompat 1.7.1: title padding 24/18 + divider 8; no-buttons list bottom padding 8.
        let headerHeight = 18 + titleHeight + 8
        let rowHeights = rows.map {
            $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let listHeight = rowHeights.reduce(CGFloat.zero, +)
        let preferredHeight = headerHeight + listHeight + 8
        let height = min(safeFrame.height, preferredHeight)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2, width: width, height: height)

        // In short windows or very large type, keep the title and choices reachable together.
        let scrollsTitle = headerHeight + (rowHeights.first ?? 0) + 8 > height
        let newScrollHeaderHeight = scrollsTitle ? headerHeight : 0
        let oldOffset = scrollsTitle == (scrollHeaderHeight > 0) ? scrollView.contentOffset.y : 0
        scrollHeaderHeight = newScrollHeaderHeight
        let titleParent = scrollsTitle ? contentView : dialogView
        if titleLabel.superview !== titleParent { titleParent.addSubview(titleLabel) }
        titleLabel.frame = CGRect(x: textInset, y: 18, width: titleWidth, height: titleHeight)
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
            x: 0, y: min(max(0, oldOffset), max(0, contentView.bounds.height - scrollView.bounds.height)))
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
        // AppCompat abc_dialog_min_width_minor/major, including large/xlarge resources.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func configureViews() {
        // AppCompat's Platform/Material themes inherit backgroundDimAmount = 0.6.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityIdentifier = identifier
        view.accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        titleLabel.text = title
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityLabel = title
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "\(identifier).title"
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        scrollView.accessibilityIdentifier = "\(identifier).list"
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(titleLabel)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        rows = items.enumerated().map { index, item in
            let row = ReaderTapZoneSelectorRow(title: item)
            row.tag = index
            row.accessibilityIdentifier = "\(identifier).item.\(index)"
            row.addTarget(self, action: #selector(selectRow(_:)), for: .touchUpInside)
            contentView.addSubview(row)
            return row
        }
    }

    private func applyFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        titleLabel.invalidateIntrinsicContentSize()
        titleLabel.setNeedsDisplay()
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
        return isActivePresenter(presenter, in: window)
    }

    private func isActivePresenter(_ presenter: UIViewController, in window: UIWindow) -> Bool {
        guard !window.isHidden, window.windowScene?.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent else { return false }
            current = controller.parent
        }
        return true
    }

    private func updateInteraction() {
        // Do not cache transient presentation/scene flags; close() checks the current owner.
        let enabled: Bool
        if case .ready = phase { enabled = isVisible } else { enabled = false }
        outsideControl.isEnabled = enabled
        scrollView.isUserInteractionEnabled = enabled
        for row in rows { row.isEnabled = enabled }
    }

    private func invalidate() {
        phase = .finished
        onSelect = nil
        if isViewLoaded { updateInteraction() }
    }

    @objc private func cancel() {
        close(selectedIndex: nil)
    }

    @objc private func selectRow(_ sender: ReaderTapZoneSelectorRow) {
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
            guard case .closing = phase else { return }
            let callback = onSelect
            invalidate()
            guard let selectedIndex, items.indices.contains(selectedIndex),
                presentingViewController == nil, viewIfLoaded?.window == nil,
                let presenter, let window, presenter.presentedViewController == nil,
                isActivePresenter(presenter, in: window)
            else { return }
            callback?(selectedIndex)
        }
    }
}

private final class ReaderTapZoneSelectorScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }
}

private final class ReaderTapZoneSelectorRow: UIControl {
    private let label = AndroidExploreTextLabel()

    init(title: String) {
        super.init(frame: .zero)
        label.text = title
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .natural
        label.textColor = AndroidReplicaTheme.primaryText
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
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { isHighlighted = false }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textInset = min(24, max(0, (size.width - 1) / 2))
        let textHeight = ceil(
            label.sizeThatFits(
                CGSize(width: max(1, size.width - textInset * 2), height: .greatestFiniteMagnitude)
            ).height)
        // select_dialog_item_material: minHeight 48, plain text with dialog-theme 24dp side padding.
        return CGSize(width: size.width, height: max(48, textHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textInset = min(24, max(0, (bounds.width - 1) / 2))
        label.frame = CGRect(x: textInset, y: 0, width: max(0, bounds.width - textInset * 2), height: bounds.height)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(font: UIFont) {
        label.font = font
        label.invalidateIntrinsicContentSize()
        label.setNeedsDisplay()
        setNeedsLayout()
    }
}
