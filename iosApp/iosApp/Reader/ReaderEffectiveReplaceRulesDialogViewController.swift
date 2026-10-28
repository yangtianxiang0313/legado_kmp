import UIKit
import shared

/// EffectiveReplacesDialog.kt / dialog_recycler_view.xml / item_1line_text.xml
/// at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// The caller supplies effective rules, actual conversion-mode visibility and reader traits,
/// presents the real editor from this dialog, and refreshes the snapshot after saving.
@MainActor
final class ReaderEffectiveReplaceRulesDialogViewController: UIViewController {
    private enum Phase {
        case waiting
        case active
        case closing
        case finished
    }

    private var rules: [ReplaceRule]
    private var showsChineseConversion: Bool
    private var onSelect: ((ReplaceRule) -> Void)?
    private var onSelectChineseConversion: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var phase: Phase = .waiting
    private var isVisible = false
    private var isBusy = false
    private var selectionID: UUID?
    private var snapshotID = UUID()
    private var scrollHeaderHeight: CGFloat = 0
    private var hasLaidOutContent = false

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let toolbar = UIView()
    private let titleLabel = ReaderEffectiveReplaceLabel()
    private let scrollView = ReaderEffectiveReplaceScrollView()
    private let contentView = UIView()
    private var rows: [ReaderEffectiveReplaceRuleRow] = []

    init(
        rules: [ReplaceRule], showsChineseConversion: Bool,
        onSelect: @escaping (ReplaceRule) -> Void,
        onSelectChineseConversion: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.rules = rules
        self.showsChineseConversion = showsChineseConversion
        self.onSelect = onSelect
        self.onSelectChineseConversion = onSelectChineseConversion
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString(
            "reader.effective_replace.dialog.title", value: "起效的替换", comment: "Legado effective_replaces")
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    /// No loading or persistence: replace the complete, caller-owned effective-rule snapshot.
    func updateRules(_ rules: [ReplaceRule], showsChineseConversion: Bool? = nil) {
        guard phase != .closing, phase != .finished else { return }
        self.rules = rules
        if let showsChineseConversion { self.showsChineseConversion = showsChineseConversion }
        snapshotID = UUID()
        guard isViewLoaded else { return }
        rebuildRows()
        applyAppearance()
        updateInteraction()
    }

    func refreshRules(_ rules: [ReplaceRule], showsChineseConversion: Bool? = nil) {
        updateRules(rules, showsChineseConversion: showsChineseConversion)
    }

    /// Optional host-side busy gate, e.g. while preparing an editor. It adds no loading UI.
    func setBusy(_ busy: Bool) {
        guard phase != .closing, phase != .finished else { return }
        isBusy = busy
        if isViewLoaded { updateInteraction() }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canCancel, selectionID == nil else { return nil }
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        rebuildRows()
        applyAppearance()
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .closing, phase != .finished else { return }
        phase = .active
        isVisible = true
        updateInteraction()
        guard presentedViewController == nil else { return }
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        // Full-screen editors cover this controller; covering is not dismissal.
        if isLeavingPresentation {
            beginClosing()
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                if context.isCancelled { resumeCancelledDismissal() }
            }
        }
        updateInteraction()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard phase == .closing else { return }
        if let coordinator = transitionCoordinator {
            let scheduled = coordinator.animate(alongsideTransition: nil) { [self] context in
                if context.isCancelled {
                    resumeCancelledDismissal()
                } else {
                    finishDismissal()
                }
            }
            if !scheduled { finishDismissal() }
        } else {
            finishDismissal()
        }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // UIKit may route an editor's dismissal through its presenting dialog.
        // Dismissing that child must neither invalidate this snapshot nor notify onDismiss.
        if presentedViewController != nil, !isLeavingPresentation {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .closing, phase != .finished else {
            completion?()
            return
        }
        beginClosing()
        super.dismiss(animated: flag) { [self] in
            finishDismissal()
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canCancel, selectionID == nil else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        let inset = min(16, max(0, (safeFrame.height - 1) / 2))
        let available = safeFrame.insetBy(dx: 0, dy: inset)
        guard available.width > 0, available.height > 0 else { return }

        let width = min(available.width, view.bounds.width * 0.9)
        // Toolbar.onMeasure reserves 16dp contentInsetStart plus 4dp title margins at both ends.
        let titleWidth = max(0, width - 24)
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
        ).height
        let toolbarHeight = max(56, titleHeight)
        let rowHeights = rows.map {
            $0.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        let listHeight = rowHeights.reduce(CGFloat.zero, +)
        let height = min(available.height, toolbarHeight + listHeight)
        dialogView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2,
            width: width, height: height)

        // Keep the toolbar fixed unless a short window / AX type leaves no usable row.
        let scrollsToolbar = toolbarHeight + (rowHeights.first ?? 0) > height
        let newHeaderHeight = scrollsToolbar ? toolbarHeight : 0
        let headerDelta = hasLaidOutContent ? newHeaderHeight - scrollHeaderHeight : 0
        let oldOffset = scrollView.contentOffset.y + headerDelta
        scrollHeaderHeight = newHeaderHeight
        hasLaidOutContent = true
        let toolbarParent = scrollsToolbar ? contentView : dialogView
        if toolbar.superview !== toolbarParent { toolbarParent.addSubview(toolbar) }
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        let isRTL = toolbar.effectiveUserInterfaceLayoutDirection == .rightToLeft
        // Toolbar.onLayout collapses titleMarginStart against the unused inset (no navigation icon):
        // 16 + max(0, 4 - 16) = 16dp, while the measured title width still excludes 24dp.
        titleLabel.frame = CGRect(
            x: isRTL ? width - 16 - titleWidth : 16, y: (toolbarHeight - titleHeight) / 2,
            width: titleWidth, height: titleHeight)
        scrollView.frame =
            scrollsToolbar
            ? dialogView.bounds
            : CGRect(x: 0, y: toolbarHeight, width: width, height: max(0, height - toolbarHeight))
        var rowY = newHeaderHeight
        for (row, rowHeight) in zip(rows, rowHeights) {
            row.frame = CGRect(
                x: 0, y: rowY,
                width: width, height: rowHeight)
            rowY += rowHeight
        }
        let contentHeight = newHeaderHeight + listHeight
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > scrollView.bounds.height
        let offset = CGPoint(
            x: 0, y: min(max(0, oldOffset), max(0, contentHeight - scrollView.bounds.height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        let rowElements: [UIView] = rows.map { $0 }
        contentView.accessibilityElements = scrollsToolbar ? [toolbar] + rowElements : rowElements
        dialogView.accessibilityElements = scrollsToolbar ? [scrollView] : [toolbar, scrollView]
    }

    private var rowFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traitCollection)
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.effectiveReplace.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        titleLabel.text = title
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.effectiveReplace.title"
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "reader.effectiveReplace.list"
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(toolbar)
        toolbar.addSubview(titleLabel)
        toolbar.accessibilityElements = [titleLabel]
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
    }

    private func rebuildRows() {
        for row in rows {
            row.isEnabled = false
            row.removeFromSuperview()
        }
        let titles =
            rules.map(\.name)
            + (showsChineseConversion
                ? [
                    NSLocalizedString(
                        "reader.effective_replace.chinese_conversion", value: "繁简转换", comment: "Legado conversion row")
                ] : [])
        rows = titles.enumerated().map { index, title in
            let row = ReaderEffectiveReplaceRuleRow(title: title, snapshotID: snapshotID)
            row.tag = index
            row.accessibilityIdentifier =
                index < rules.count
                ? "reader.effectiveReplace.rule.\(rules[index].id)"
                : "reader.effectiveReplace.chineseConversion"
            row.addTarget(self, action: #selector(selectRow(_:)), for: .touchUpInside)
            contentView.addSubview(row)
            return row
        }
        view.setNeedsLayout()
    }

    private func applyAppearance() {
        let palette = ReaderTocPalette(traits: traitCollection)
        dialogView.backgroundColor = palette.background
        toolbar.backgroundColor = palette.titleBackground
        titleLabel.textColor = palette.toolbarText
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        for row in rows { row.apply(font: rowFont, textColor: palette.primaryText) }
        view.setNeedsLayout()
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private var canCancel: Bool {
        guard phase == .active, isVisible, !isBeingPresented, !isLeavingPresentation,
            presentedViewController == nil, transitionCoordinator == nil,
            let window = viewIfLoaded?.window, !window.isHidden,
            window.windowScene?.activationState == .foregroundActive,
            let presenter = presentingViewController, presenter.viewIfLoaded?.window === window
        else { return false }
        var controller: UIViewController? = presenter
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return false }
            controller = current.parent ?? current.presentingViewController
        }
        return true
    }

    private func updateInteraction() {
        let active = phase == .active && isVisible
        outsideControl.isEnabled = active && selectionID == nil
        // Do not gate on presentedViewController here: sheets need not cause another
        // appearance callback. Input handlers independently reject every covered selection.
        for row in rows { row.isEnabled = active && !isBusy && selectionID == nil }
        scrollView.isUserInteractionEnabled = active
    }

    @objc private func selectRow(_ sender: ReaderEffectiveReplaceRuleRow) {
        guard canCancel, !isBusy, selectionID == nil, sender.isEnabled,
            sender.snapshotID == snapshotID, rows.indices.contains(sender.tag), rows[sender.tag] === sender
        else { return }
        let index = sender.tag
        let id = UUID()
        selectionID = id
        updateInteraction()
        // Keep the dialog alive. The host synchronously presents an editor / conversion picker.
        if rules.indices.contains(index) {
            onSelect?(rules[index])
        } else if showsChineseConversion, index == rules.count {
            onSelectChineseConversion?()
        }
        // Cover both reentrant callbacks and a rapid second tap when no child was presented.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.selectionID == id, self.phase == .active else { return }
            self.selectionID = nil
            self.updateInteraction()
        }
    }

    @objc private func cancel() {
        guard canCancel, selectionID == nil else { return }
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func beginClosing() {
        guard phase != .finished else { return }
        phase = .closing
        selectionID = nil
        if isViewLoaded { updateInteraction() }
        resignFirstResponder()
    }

    private func resumeCancelledDismissal() {
        guard phase == .closing else { return }
        phase = .active
        isVisible = viewIfLoaded?.window != nil
        updateInteraction()
        if canCancel { becomeFirstResponder() }
    }

    private func finishDismissal() {
        guard phase != .finished else { return }
        beginClosing()
        phase = .finished
        onSelect = nil
        onSelectChineseConversion = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }
}
