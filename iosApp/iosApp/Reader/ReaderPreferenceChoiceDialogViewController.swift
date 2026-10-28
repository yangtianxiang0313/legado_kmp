import UIKit

/// MoreConfigDialog -> NameListPreference -> ListPreferenceDialog at Legado
/// 5f5d31404af9957684703747ecee2b91e7161f1d; AndroidX preference 1.2.1 / AppCompat 1.7.1.
/// The caller owns persistence and supplies overrideUserInterfaceStyle when needed.
/// Create a fresh instance for each presentation; an invalid index leaves every row unchecked.
@MainActor
final class ReaderPreferenceChoiceDialogViewController: UIViewController {
    var canSelect: (() -> Bool)?
    private enum Phase {
        case waiting
        case active
        case closing(UUID)
        case finished
    }

    private let items: [String]
    private let initialSelectedIndex: Int
    private let identifier: String
    private var onSelect: ((Int) -> Void)?
    private var phase: Phase = .waiting
    private var isVisible = false
    private var hasPositionedInitialChoice = false
    private var scrollHeaderHeight: CGFloat = 0

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let titleLabel = UILabel()
    private let scrollView = ReaderPreferenceChoiceDialogScrollView()
    private let contentView = UIView()
    private let cancelControl = ReaderPreferenceChoiceDialogCancelControl()
    private var rows: [ReaderPreferenceChoiceDialogRow] = []

    init(
        title: String, items: [String], selectedIndex: Int, identifier: String,
        onSelect: @escaping (Int) -> Void
    ) {
        self.items = items
        initialSelectedIndex = selectedIndex
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
        guard case .active = phase else { return nil }
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyFonts()
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard case .waiting = phase else { return }
        phase = .active
        isVisible = true
        updateInteraction()
        view.layoutIfNeeded()
        revealInitialChoiceIfNeeded()
        becomeFirstResponder()
        let accessibilityFocus: UIView
        if rows.indices.contains(initialSelectedIndex) {
            accessibilityFocus = rows[initialSelectedIndex]
        } else {
            accessibilityFocus = titleLabel.isHidden ? cancelControl : titleLabel
        }
        UIAccessibility.post(notification: .screenChanged, argument: accessibilityFocus)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        // Only our own dismissal completion may deliver a pending choice.
        if case .closing = phase {
            updateInteraction()
        } else {
            invalidate()
        }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // A caller dismissing this instance invalidates even a choice already in flight.
        invalidate()
        super.dismiss(animated: flag, completion: completion)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(selectedIndex: nil)
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }

        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let titleWidth = max(1, width - 48)
        let titleHeight =
            titleLabel.isHidden
            ? 0
            : ceil(
                titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let headerHeight: CGFloat = titleLabel.isHidden ? 0 : 18 + titleHeight + 8
        let rowHeights = rows.map {
            $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let listHeight = rowHeights.reduce(CGFloat.zero, +)
        let actionWidth = min(cancelControl.preferredWidth, max(1, width - 24))
        let actionHeight = cancelControl.sizeThatFits(
            CGSize(width: actionWidth, height: .greatestFiniteMagnitude)
        ).height
        let footerHeight = actionHeight + 8
        let preferredHeight = headerHeight + listHeight + footerHeight
        let height = min(safeFrame.height * 0.9, preferredHeight)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)

        // Normally the title and cancel action stay fixed. In short windows / huge type,
        // scroll the entire content instead of clipping the title or hiding all choices.
        let scrollsChrome = headerHeight + footerHeight + min(48, listHeight) > height
        let newScrollHeaderHeight = scrollsChrome ? headerHeight : 0
        let headerDelta = hasPositionedInitialChoice ? newScrollHeaderHeight - scrollHeaderHeight : 0
        let oldOffset = scrollView.contentOffset.y + headerDelta
        scrollHeaderHeight = newScrollHeaderHeight
        let chromeParent = scrollsChrome ? contentView : dialogView
        if titleLabel.superview !== chromeParent { chromeParent.addSubview(titleLabel) }
        if cancelControl.superview !== chromeParent { chromeParent.addSubview(cancelControl) }

        titleLabel.frame = CGRect(x: 24, y: 18, width: titleWidth, height: titleHeight)
        scrollView.frame =
            scrollsChrome
            ? dialogView.bounds
            : CGRect(x: 0, y: headerHeight, width: width, height: max(0, height - headerHeight - footerHeight))
        var nextY = newScrollHeaderHeight
        for (row, rowHeight) in zip(rows, rowHeights) {
            row.frame = CGRect(x: 0, y: nextY, width: width, height: rowHeight)
            nextY += rowHeight
        }

        let isRTL = dialogView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        cancelControl.frame = CGRect(
            x: isRTL ? 12 : width - 12 - actionWidth,
            y: scrollsChrome ? nextY + 4 : height - footerHeight + 4,
            width: actionWidth, height: actionHeight)
        let contentHeight = scrollsChrome ? preferredHeight : listHeight
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > scrollView.bounds.height
        let offset = CGPoint(
            x: 0, y: min(max(0, oldOffset), max(0, contentHeight - scrollView.bounds.height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }

        let visibleTitle: [UIView] = titleLabel.isHidden ? [] : [titleLabel]
        let rowElements: [UIView] = rows.map { $0 }
        contentView.accessibilityElements =
            scrollsChrome
            ? visibleTitle + rowElements + [cancelControl] : rowElements
        dialogView.accessibilityElements =
            scrollsChrome
            ? [scrollView] : visibleTitle + [scrollView, cancelControl]
        revealInitialChoiceIfNeeded()
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

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = identifier
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true

        titleLabel.text = title
        titleLabel.isHidden = title?.isEmpty != false
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textAlignment = .natural
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "\(identifier).title"

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "\(identifier).list"
        cancelControl.accessibilityIdentifier = "\(identifier).cancel"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(titleLabel)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        dialogView.addSubview(cancelControl)
        rows = items.enumerated().map { index, item in
            let row = ReaderPreferenceChoiceDialogRow(title: item)
            row.tag = index
            row.isSelected = index == initialSelectedIndex
            row.accessibilityIdentifier = "\(identifier).item.\(index)"
            row.addTarget(self, action: #selector(selectRow(_:)), for: .touchUpInside)
            contentView.addSubview(row)
            return row
        }
    }

    private func applyFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        // select_dialog_singlechoice_material uses textAppearanceMedium, not Subhead.
        let rowFont = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .body, compatibleWith: traitCollection)
        for row in rows { row.apply(font: rowFont) }
        cancelControl.apply(
            font: ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection))
        view.setNeedsLayout()
    }

    private func revealInitialChoiceIfNeeded() {
        guard isVisible, !hasPositionedInitialChoice, scrollView.bounds.height > 0 else { return }
        hasPositionedInitialChoice = true
        guard rows.indices.contains(initialSelectedIndex) else { return }
        let rowFrame = rows[initialSelectedIndex].frame
        let visiblePart = CGRect(
            x: 0, y: rowFrame.minY, width: rowFrame.width,
            height: min(rowFrame.height, scrollView.bounds.height))
        scrollView.scrollRectToVisible(visiblePart, animated: false)
    }

    private var canInteract: Bool {
        guard case .active = phase, isVisible, !isBeingDismissed, !isBeingPresented,
            presentedViewController == nil, let window = viewIfLoaded?.window,
            let presenter = presentingViewController
        else { return false }
        return isCurrentPresenter(presenter, in: window)
    }

    private func isCurrentPresenter(_ presenter: UIViewController, in window: UIWindow) -> Bool {
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
        let enabled: Bool
        if case .active = phase { enabled = isVisible } else { enabled = false }
        outsideControl.isEnabled = enabled
        cancelControl.isEnabled = enabled
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

    @objc private func selectRow(_ sender: ReaderPreferenceChoiceDialogRow) {
        guard canInteract, canSelect?() != false, rows.indices.contains(sender.tag), rows[sender.tag] === sender else { return }
        for (index, row) in rows.enumerated() { row.isSelected = index == sender.tag }
        close(selectedIndex: sender.tag)
    }

    private func close(selectedIndex: Int?) {
        guard canInteract, let presenter = presentingViewController, let window = viewIfLoaded?.window else { return }
        let dismissalID = UUID()
        phase = .closing(dismissalID)
        if selectedIndex == nil { onSelect = nil }
        updateInteraction()
        resignFirstResponder()
        // Keep this dialog alive only through its dismissal, never retain its presenter.
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self, weak presenter, weak window] in
            guard case .closing(let currentID) = phase, currentID == dismissalID else { return }
            let callback = onSelect
            invalidate()
            guard let selectedIndex, items.indices.contains(selectedIndex),
                presentingViewController == nil, viewIfLoaded?.window == nil,
                let presenter, let window, presenter.presentedViewController == nil,
                isCurrentPresenter(presenter, in: window), canSelect?() != false
            else { return }
            callback?(selectedIndex)
        }
    }
}
