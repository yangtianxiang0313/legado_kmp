import UIKit

enum BookshelfLayoutDialogStyle {
    static func font(
        size: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body,
        traits: UITraitCollection
    ) -> UIFont {
        let fontWeight =
            weight.rawValue >= UIFont.Weight.bold.rawValue
            ? 700
            : (weight.rawValue >= UIFont.Weight.semibold.rawValue
                ? 600
                : (weight.rawValue >= UIFont.Weight.medium.rawValue ? 500 : 400))
        return ReaderAndroidDefaultFont.scaledFont(
            size: size, textStyle: style, weight: fontWeight, compatibleWith: traits)
    }

    static func configure(_ label: UILabel, text: String, color: UIColor) {
        label.text = text
        label.textColor = color
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .natural
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = false
        label.isUserInteractionEnabled = false
    }
}

final class BookshelfLayoutDialogBodyView: UIView {
    // Keep configBookshelf's resource order: these indices are the persistence contract.
    static let groupStyleTitles = ["标签", "文件夹"]
    static let layoutTitles = ["列表", "网格三列", "网格四列", "网格五列", "网格六列"]
    static let sortTitles = ["按阅读时间", "按更新时间", "按书名", "手动排序", "综合排序", "按作者"]

    var onChange: ((BookshelfLayoutDraft) -> Void)?
    var isEditingEnabled = true {
        didSet {
            groupStyleRow.isEnabled = isEditingEnabled
            unreadRow.isEnabled = isEditingEnabled
            updateTimeRow.isEnabled = isEditingEnabled
            waitUpCountRow.isEnabled = isEditingEnabled
            fastScrollerRow.isEnabled = isEditingEnabled
            for control in layoutControls + sortControls { control.isEnabled = isEditingEnabled }
        }
    }

    private var draft: BookshelfLayoutDraft
    private let groupStyleRow: BookshelfLayoutDialogGroupStyleRow
    private let unreadRow = BookshelfLayoutDialogSwitchRow(title: "显示未读标志")
    private let updateTimeRow = BookshelfLayoutDialogSwitchRow(title: "显示上次更新时间")
    private let waitUpCountRow = BookshelfLayoutDialogSwitchRow(title: "显示等待更新数量")
    private let fastScrollerRow = BookshelfLayoutDialogSwitchRow(title: "显示快速滚动条")
    private let layoutLabel = UILabel()
    private let sortLabel = UILabel()
    private let layoutControls: [BookshelfLayoutDialogRadioRow]
    private let sortControls: [BookshelfLayoutDialogRadioRow]

    init(draft: BookshelfLayoutDraft) {
        self.draft = draft
        groupStyleRow = BookshelfLayoutDialogGroupStyleRow(titles: Self.groupStyleTitles)
        layoutControls = Self.layoutTitles.map { BookshelfLayoutDialogRadioRow(title: $0) }
        sortControls = Self.sortTitles.map { BookshelfLayoutDialogRadioRow(title: $0) }
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(layoutLabel, text: "视图", color: AndroidReplicaTheme.accent)
        BookshelfLayoutDialogStyle.configure(sortLabel, text: "排序", color: AndroidReplicaTheme.accent)
        layoutLabel.accessibilityTraits = .header
        sortLabel.accessibilityTraits = .header
        layoutLabel.accessibilityIdentifier = "bookshelf.layoutDialog.layoutHeading"
        sortLabel.accessibilityIdentifier = "bookshelf.layoutDialog.sortHeading"
        groupStyleRow.selectedIndex = draft.groupStyleIndex
        groupStyleRow.accessibilityIdentifier = "bookshelf.layoutDialog.groupStyle"
        groupStyleRow.addTarget(self, action: #selector(changeGroupStyle), for: .valueChanged)
        unreadRow.isOn = draft.showUnread
        updateTimeRow.isOn = draft.showLastUpdateTime
        waitUpCountRow.isOn = draft.showWaitUpCount
        fastScrollerRow.isOn = draft.showBookshelfFastScroller
        unreadRow.toggleIdentifier = "bookshelf.layoutDialog.showUnread"
        updateTimeRow.toggleIdentifier = "bookshelf.layoutDialog.showLastUpdateTime"
        waitUpCountRow.toggleIdentifier = "bookshelf.layoutDialog.showWaitUpCount"
        fastScrollerRow.toggleIdentifier = "bookshelf.layoutDialog.showBookshelfFastScroller"
        unreadRow.addTarget(self, action: #selector(changeUnread), for: .valueChanged)
        updateTimeRow.addTarget(self, action: #selector(changeUpdateTime), for: .valueChanged)
        waitUpCountRow.addTarget(self, action: #selector(changeWaitUpCount), for: .valueChanged)
        fastScrollerRow.addTarget(self, action: #selector(changeFastScroller), for: .valueChanged)
        for item in [
            groupStyleRow, unreadRow, updateTimeRow, waitUpCountRow, fastScrollerRow,
            layoutLabel, sortLabel,
        ] {
            addSubview(item)
        }
        for (index, control) in layoutControls.enumerated() {
            control.tag = index
            control.isSelected = index == draft.layoutIndex
            control.accessibilityIdentifier = "bookshelf.layoutDialog.layout.\(index)"
            control.addTarget(self, action: #selector(selectLayout(_:)), for: .touchUpInside)
            addSubview(control)
        }
        for (index, control) in sortControls.enumerated() {
            control.tag = index
            control.isSelected = index == draft.sortIndex
            control.accessibilityIdentifier = "bookshelf.layoutDialog.sort.\(index)"
            control.addTarget(self, action: #selector(selectSort(_:)), for: .touchUpInside)
            addSubview(control)
        }
        var elements: [Any] = [
            groupStyleRow, unreadRow, updateTimeRow, waitUpCountRow, fastScrollerRow, layoutLabel,
        ]
        elements.append(contentsOf: layoutControls)
        elements.append(sortLabel)
        elements.append(contentsOf: sortControls)
        accessibilityElements = elements
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        let font = BookshelfLayoutDialogStyle.font(size: 14, traits: traits)
        groupStyleRow.apply(
            labelFont: font, valueFont: BookshelfLayoutDialogStyle.font(size: 16, traits: traits))
        unreadRow.apply(font: font)
        updateTimeRow.apply(font: font)
        waitUpCountRow.apply(font: font)
        fastScrollerRow.apply(font: font)
        let headingFont = BookshelfLayoutDialogStyle.font(size: 16, traits: traits)
        layoutLabel.font = headingFont
        sortLabel.font = headingFont
        for control in layoutControls + sortControls { control.apply(font: font) }
        setNeedsLayout()
    }

    @discardableResult
    func dismissGroupStyleMenu() -> Bool {
        groupStyleRow.dismissMenu()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, applyFrames: true)
    }

    private func arrange(width: CGFloat, applyFrames: Bool) -> CGFloat {
        var y: CGFloat = 0
        for row in [groupStyleRow, unreadRow, updateTimeRow, waitUpCountRow, fastScrollerRow] {
            let height = row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            if applyFrames { row.frame = CGRect(x: 0, y: y, width: width, height: height) }
            y += height
        }
        let gap: CGFloat = 0
        let columnWidth = max(1, (width - gap) / 2)
        let minimumColumnWidth = (layoutControls + sortControls).map(\.preferredWidth).max() ?? 0
        let singleColumn =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            || columnWidth < minimumColumnWidth
        if singleColumn {
            y = arrangeColumn(
                label: layoutLabel, controls: layoutControls, x: 0, y: y, width: width,
                applyFrames: applyFrames)
            return arrangeColumn(
                label: sortLabel, controls: sortControls, x: 0, y: y, width: width, applyFrames: applyFrames
            )
        }
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let layoutX = isRTL ? columnWidth + gap : 0
        let sortX = isRTL ? 0 : columnWidth + gap
        return max(
            arrangeColumn(
                label: layoutLabel, controls: layoutControls, x: layoutX, y: y, width: columnWidth,
                applyFrames: applyFrames),
            arrangeColumn(
                label: sortLabel, controls: sortControls, x: sortX, y: y, width: columnWidth,
                applyFrames: applyFrames))
    }

    private func arrangeColumn(
        label: UILabel, controls: [BookshelfLayoutDialogRadioRow], x: CGFloat, y: CGFloat,
        width: CGFloat, applyFrames: Bool
    ) -> CGFloat {
        let labelHeight = ceil(
            label.sizeThatFits(
                CGSize(width: max(1, width - 12), height: .greatestFiniteMagnitude)
            ).height)
        if applyFrames {
            label.frame = CGRect(x: x + 6, y: y + 6, width: max(1, width - 12), height: labelHeight)
        }
        var nextY = y + labelHeight + 12
        for control in controls {
            let height = control.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
                .height
            if applyFrames { control.frame = CGRect(x: x, y: nextY, width: width, height: height) }
            nextY += height
        }
        return nextY
    }

    @objc private func changeUnread() {
        guard isEditingEnabled else { return }
        draft.showUnread = unreadRow.isOn
        onChange?(draft)
    }

    @objc private func changeGroupStyle() {
        guard isEditingEnabled, Self.groupStyleTitles.indices.contains(groupStyleRow.selectedIndex)
        else { return }
        draft.groupStyleIndex = groupStyleRow.selectedIndex
        onChange?(draft)
    }

    @objc private func changeUpdateTime() {
        guard isEditingEnabled else { return }
        draft.showLastUpdateTime = updateTimeRow.isOn
        onChange?(draft)
    }

    @objc private func changeWaitUpCount() {
        guard isEditingEnabled else { return }
        draft.showWaitUpCount = waitUpCountRow.isOn
        onChange?(draft)
    }

    @objc private func changeFastScroller() {
        guard isEditingEnabled else { return }
        draft.showBookshelfFastScroller = fastScrollerRow.isOn
        onChange?(draft)
    }

    @objc private func selectLayout(_ sender: UIControl) {
        guard isEditingEnabled, Self.layoutTitles.indices.contains(sender.tag) else { return }
        draft.layoutIndex = sender.tag
        for (index, control) in layoutControls.enumerated() { control.isSelected = index == sender.tag }
        onChange?(draft)
    }

    @objc private func selectSort(_ sender: UIControl) {
        guard isEditingEnabled, Self.sortTitles.indices.contains(sender.tag) else { return }
        draft.sortIndex = sender.tag
        for (index, control) in sortControls.enumerated() { control.isSelected = index == sender.tag }
        onChange?(draft)
    }
}

private final class BookshelfLayoutDialogGroupStyleRow: UIControl {
    var selectedIndex = 0 {
        didSet {
            let title = titles.indices.contains(selectedIndex) ? titles[selectedIndex] : titles[0]
            valueLabel.text = title
            accessibilityValue = title
            setNeedsLayout()
        }
    }

    private let titles: [String]
    private let label = UILabel()
    private let valueLabel = UILabel()
    private let indicator = UIImageView(image: UIImage(systemName: "arrowtriangle.down.fill"))
    private let selectionView = UIView()
    private var menu: BookshelfLayoutDialogGroupStyleMenu?

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(
            label, text: "分组样式", color: AndroidReplicaTheme.primaryText)
        BookshelfLayoutDialogStyle.configure(
            valueLabel, text: titles[0], color: AndroidReplicaTheme.primaryText)
        label.isAccessibilityElement = false
        valueLabel.isAccessibilityElement = false
        indicator.contentMode = .scaleAspectFit
        indicator.tintColor = AndroidReplicaTheme.secondaryText
        indicator.isAccessibilityElement = false
        selectionView.isUserInteractionEnabled = false
        selectionView.isAccessibilityElement = false
        addSubview(label)
        addSubview(selectionView)
        selectionView.addSubview(valueLabel)
        selectionView.addSubview(indicator)
        isAccessibilityElement = true
        accessibilityLabel = "分组样式"
        accessibilityValue = titles[0]
        accessibilityTraits = .button
        addTarget(self, action: #selector(showMenu), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if !isEnabled { dismissMenu() }
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { dismissMenu() }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let selectionWidth = min(preferredSelectionWidth, max(1, size.width - 12))
        let stacked = usesStackedLayout(width: size.width)
        let labelWidth = max(1, size.width - 12 - (stacked ? 0 : selectionWidth + 6))
        let labelHeight = ceil(
            label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
        let valueHeight = ceil(
            valueLabel.sizeThatFits(
                CGSize(width: max(1, selectionWidth - 40), height: .greatestFiniteMagnitude)
            ).height)
        let selectionHeight = max(32, valueHeight + 12)
        let height =
            stacked ? labelHeight + 6 + selectionHeight + 12 : max(labelHeight + 12, selectionHeight)
        return CGSize(width: size.width, height: max(48, height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let stacked = usesStackedLayout(width: bounds.width)
        let selectionWidth = min(preferredSelectionWidth, max(1, bounds.width - 12))
        let labelWidth = max(1, bounds.width - 12 - (stacked ? 0 : selectionWidth + 6))
        let labelHeight = ceil(
            label.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
        let valueHeight = ceil(
            valueLabel.sizeThatFits(
                CGSize(width: max(1, selectionWidth - 40), height: .greatestFiniteMagnitude)
            ).height)
        let selectionHeight = max(32, valueHeight + 12)
        label.frame = CGRect(
            x: stacked || !isRTL ? 6 : selectionWidth + 12,
            y: stacked ? 6 : (bounds.height - labelHeight) / 2,
            width: labelWidth, height: labelHeight)
        selectionView.frame = CGRect(
            x: isRTL ? 6 : bounds.width - 6 - selectionWidth,
            y: stacked ? label.frame.maxY + 6 : (bounds.height - selectionHeight) / 2,
            width: selectionWidth, height: selectionHeight)
        valueLabel.frame = CGRect(
            x: isRTL ? 32 : 8, y: 6, width: max(1, selectionWidth - 40), height: valueHeight)
        indicator.frame = CGRect(
            x: isRTL ? 12 : selectionWidth - 20, y: selectionHeight / 2 - 4, width: 8, height: 8)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, window != nil else { return false }
        showMenu()
        return true
    }

    func apply(labelFont: UIFont, valueFont: UIFont) {
        dismissMenu()
        label.font = labelFont
        valueLabel.font = valueFont
        setNeedsLayout()
    }

    @discardableResult
    func dismissMenu() -> Bool {
        guard let menu else { return false }
        self.menu = nil
        menu.dismiss()
        return true
    }

    private var preferredSelectionWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: valueLabel.font ?? UIFont.systemFont(ofSize: 16)
        ]
        return ceil(titles.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0)
            + 40
    }

    private func usesStackedLayout(width: CGFloat) -> Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory || width < 240
    }

    @objc private func showMenu() {
        guard isEnabled, let host = window else { return }
        dismissMenu()
        let menu = BookshelfLayoutDialogGroupStyleMenu(
            titles: titles, selectedIndex: selectedIndex, anchorView: selectionView,
            font: label.font ?? .systemFont(ofSize: 14),
            interfaceStyle: traitCollection.userInterfaceStyle)
        menu.onSelect = { [weak self] index in
            guard let self, self.isEnabled, self.window != nil, self.menu != nil,
                self.titles.indices.contains(index)
            else { return }
            self.dismissMenu()
            guard self.selectedIndex != index else { return }
            self.selectedIndex = index
            self.sendActions(for: .valueChanged)
        }
        menu.onDismiss = { [weak self] in self?.menu = nil }
        self.menu = menu
        menu.present(in: host)
    }
}

private final class BookshelfLayoutDialogGroupStyleMenu: UIView {
    var onSelect: ((Int) -> Void)?
    var onDismiss: (() -> Void)?

    private weak var anchorView: UIView?
    private let outsideControl = UIControl()
    private let panelView = UIView()
    private let scrollView = BookshelfLayoutDialogGroupStyleMenuScrollView()
    private let rows: [BookshelfLayoutDialogGroupStyleOption]

    init(
        titles: [String], selectedIndex: Int, anchorView: UIView, font: UIFont,
        interfaceStyle: UIUserInterfaceStyle
    ) {
        self.anchorView = anchorView
        rows = titles.map { BookshelfLayoutDialogGroupStyleOption(title: $0, font: font) }
        super.init(frame: .zero)
        overrideUserInterfaceStyle = interfaceStyle
        accessibilityIdentifier = "bookshelf.layoutDialog.groupStyleMenu"
        accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = true
        outsideControl.accessibilityLabel = L10n.Common.cancel
        outsideControl.accessibilityIdentifier = "bookshelf.layoutDialog.groupStyleMenu.dismiss"
        outsideControl.accessibilityTraits = .button
        outsideControl.addTarget(self, action: #selector(dismissFromOutside), for: .touchUpInside)
        addSubview(outsideControl)
        panelView.backgroundColor = AndroidReplicaTheme.background
        panelView.layer.cornerRadius = 2
        panelView.layer.shadowColor = UIColor.black.cgColor
        panelView.layer.shadowOpacity = 0.22
        panelView.layer.shadowRadius = 6
        panelView.layer.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(panelView)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.bounces = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.scrollsToTop = false
        panelView.addSubview(scrollView)
        for (index, row) in rows.enumerated() {
            row.tag = index
            row.isSelected = index == selectedIndex
            row.accessibilityIdentifier = "bookshelf.layoutDialog.groupStyle.\(index)"
            row.addTarget(self, action: #selector(selectOption(_:)), for: .touchUpInside)
            scrollView.addSubview(row)
        }
        accessibilityElements = [scrollView, outsideControl]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func present(in host: UIView) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(self)
        setNeedsLayout()
        layoutIfNeeded()
        UIAccessibility.post(
            notification: .screenChanged, argument: rows.first(where: \.isSelected) ?? rows.first)
    }

    func dismiss() {
        guard superview != nil else { return }
        let restoreFocus = window != nil && anchorView?.window != nil
        isUserInteractionEnabled = false
        accessibilityViewIsModal = false
        removeFromSuperview()
        if restoreFocus {
            UIAccessibility.post(notification: .screenChanged, argument: anchorView?.superview)
        }
        onDismiss?()
    }

    override func accessibilityPerformEscape() -> Bool {
        dismiss()
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        guard let anchorView, anchorView.window === window, window != nil else {
            dismiss()
            return
        }
        let safeBounds = bounds.inset(by: safeAreaInsets)
        guard safeBounds.width > 0, safeBounds.height > 0 else { return }
        let anchorRect = anchorView.convert(anchorView.bounds, to: self)
        let width = min(safeBounds.width, max(anchorRect.width, rows.map(\.preferredWidth).max() ?? 0))
        var contentHeight: CGFloat = 0
        for row in rows {
            let height = row.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            row.frame = CGRect(x: 0, y: contentHeight, width: width, height: height)
            contentHeight += height
        }
        let belowY = min(max(anchorRect.maxY, safeBounds.minY), safeBounds.maxY)
        let aboveBottom = min(max(anchorRect.minY, safeBounds.minY), safeBounds.maxY)
        let belowHeight = safeBounds.maxY - belowY
        let aboveHeight = aboveBottom - safeBounds.minY
        let opensAbove = belowHeight < min(contentHeight, aboveHeight)
        let height = min(contentHeight, opensAbove ? aboveHeight : belowHeight)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let preferredX = isRTL ? anchorRect.maxX - width : anchorRect.minX
        panelView.frame = CGRect(
            x: min(max(preferredX, safeBounds.minX), safeBounds.maxX - width),
            y: opensAbove ? aboveBottom - height : belowY, width: width, height: height)
        panelView.layer.shadowPath = UIBezierPath(roundedRect: panelView.bounds, cornerRadius: 2).cgPath
        scrollView.frame = panelView.bounds
        scrollView.contentSize = CGSize(width: width, height: contentHeight)
        scrollView.isScrollEnabled = contentHeight > height
        scrollView.showsVerticalScrollIndicator = scrollView.isScrollEnabled
        let offset = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height))
        if scrollView.contentOffset.y != offset { scrollView.contentOffset = CGPoint(x: 0, y: offset) }
    }

    @objc private func dismissFromOutside() {
        dismiss()
    }

    @objc private func selectOption(_ sender: UIControl) {
        guard isUserInteractionEnabled, superview != nil, rows.indices.contains(sender.tag) else {
            return
        }
        onSelect?(sender.tag)
    }
}

private final class BookshelfLayoutDialogGroupStyleOption: UIControl {
    private let label = UILabel()

    var preferredWidth: CGFloat {
        ceil(
            label.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width) + 16
    }

    init(title: String, font: UIFont) {
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(label, text: title, color: AndroidReplicaTheme.primaryText)
        label.font = font
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

    override var isSelected: Bool {
        didSet { accessibilityTraits = isSelected ? [.button, .selected] : .button }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = ceil(
            label.sizeThatFits(CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude))
                .height)
        return CGSize(width: size.width, height: max(48, height + 16))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}

private final class BookshelfLayoutDialogGroupStyleMenuScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

final class BookshelfLayoutDialogAction: UIControl {
    private let label = AndroidExploreTextLabel()
    private let pressedBackground = UIView()
    private let contentInsets = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    var preferredWidth: CGFloat {
        max(
            64,
            ceil(
                label.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                ).width + contentInsets.left + contentInsets.right))
    }

    init(title: String) {
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(
            label, text: title.uppercased(with: Locale.current), color: AndroidReplicaTheme.accent)
        label.textAlignment = .center
        label.isAccessibilityElement = false
        pressedBackground.isUserInteractionEnabled = false
        pressedBackground.isAccessibilityElement = false
        pressedBackground.layer.cornerRadius = 2
        addSubview(pressedBackground)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = ceil(
            label.sizeThatFits(
                CGSize(
                    width: max(1, size.width - contentInsets.left - contentInsets.right),
                    height: .greatestFiniteMagnitude)
            ).height)
        return CGSize(width: size.width, height: max(48, height + contentInsets.top + contentInsets.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: contentInsets)
        // AppCompat's Material ripple mask is inset from the full touch target.
        pressedBackground.frame = bounds.insetBy(dx: min(4, bounds.width / 2), dy: min(6, bounds.height / 2))
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
        setNeedsLayout()
    }

    private func updateAppearance() {
        // applyTint's Selector leaves disabled text accent-colored and darkens a pressed action by 0.9.
        let pressed = isHighlighted && isEnabled
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        if pressed, accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            label.textColor = UIColor(hue: hue, saturation: saturation, brightness: brightness * 0.9, alpha: alpha)
        } else {
            label.textColor = accent
        }
        pressedBackground.backgroundColor = pressed ? AndroidReplicaTheme.activeIndicator : .clear
    }
}

private final class BookshelfLayoutDialogRadioRow: UIControl {
    private let label = UILabel()
    private let indicator = UIImageView()

    var preferredWidth: CGFloat {
        ceil(
            label.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            )
            .width) + 38
    }

    init(title: String) {
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(label, text: title, color: AndroidReplicaTheme.primaryText)
        label.isAccessibilityElement = false
        indicator.isAccessibilityElement = false
        indicator.isUserInteractionEnabled = false
        indicator.contentMode = .scaleAspectFit
        addSubview(label)
        addSubview(indicator)
        isAccessibilityElement = true
        accessibilityLabel = title
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var isEnabled: Bool {
        didSet {
            label.alpha = isEnabled ? 1 : 0.5
            indicator.alpha = isEnabled ? 1 : 0.5
            updateSelection()
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textHeight = ceil(
            label.sizeThatFits(
                CGSize(width: max(1, size.width - 38), height: .greatestFiniteMagnitude)
            ).height)
        return CGSize(width: size.width, height: max(32, textHeight + 8))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        indicator.frame = CGRect(
            x: isRTL ? bounds.width - 24 : 2, y: bounds.midY - 11, width: 22, height: 22)
        label.frame = CGRect(
            x: isRTL ? 6 : 32, y: 4, width: max(1, bounds.width - 38), height: max(0, bounds.height - 8))
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

    private func updateSelection() {
        // Same radio symbols as SearchScopeOptionCell, not layout preview artwork.
        indicator.image = UIImage(systemName: isSelected ? "largecircle.fill.circle" : "circle")
        indicator.tintColor =
            isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }
}

private final class BookshelfLayoutDialogSwitchRow: UIControl {
    private let label = UILabel()
    private let toggle = UISwitch()

    var isOn: Bool {
        get { toggle.isOn }
        set { toggle.isOn = newValue }
    }

    var toggleIdentifier: String? {
        get { toggle.accessibilityIdentifier }
        set { toggle.accessibilityIdentifier = newValue }
    }

    init(title: String) {
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(label, text: title, color: AndroidReplicaTheme.primaryText)
        label.isAccessibilityElement = false
        toggle.accessibilityLabel = title
        toggle.onTintColor = AndroidReplicaTheme.accent
        toggle.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        addTarget(self, action: #selector(toggleFromRow), for: .touchUpInside)
        addSubview(label)
        addSubview(toggle)
        isAccessibilityElement = false
        accessibilityElements = [toggle]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            toggle.isEnabled = isEnabled
            label.alpha = isEnabled ? 1 : 0.5
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let toggleSize = toggle.sizeThatFits(size)
        let stacked = usesStackedLayout(width: size.width)
        let textWidth = max(1, size.width - 12 - (stacked ? 0 : toggleSize.width + 12))
        let textHeight = ceil(
            label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let height =
            stacked ? textHeight + 6 + toggleSize.height + 12 : max(textHeight, toggleSize.height) + 12
        return CGSize(width: size.width, height: max(48, height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let toggleSize = toggle.sizeThatFits(bounds.size)
        let stacked = usesStackedLayout(width: bounds.width)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let textWidth = max(1, bounds.width - 12 - (stacked ? 0 : toggleSize.width + 12))
        let textHeight = ceil(
            label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        label.frame = CGRect(
            x: stacked || !isRTL ? 6 : toggleSize.width + 18,
            y: stacked ? 6 : (bounds.height - textHeight) / 2,
            width: textWidth, height: textHeight)
        toggle.frame = CGRect(
            x: isRTL ? 6 : bounds.width - 6 - toggleSize.width,
            y: stacked ? label.frame.maxY + 6 : (bounds.height - toggleSize.height) / 2,
            width: toggleSize.width, height: toggleSize.height)
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    private func usesStackedLayout(width: CGFloat) -> Bool {
        traitCollection.preferredContentSizeCategory.isAccessibilityCategory || width < 240
    }

    @objc private func toggleFromRow() {
        guard isEnabled else { return }
        toggle.setOn(!toggle.isOn, animated: true)
        sendActions(for: .valueChanged)
    }

    @objc private func switchChanged() {
        guard isEnabled else { return }
        sendActions(for: .valueChanged)
    }
}
