import UIKit

/// AppCompat 1.7.1 AlertDialog + select_dialog_multichoice_material, without a button panel.
@MainActor
final class SettingsMultiChoiceDialogContentView: UIView, UITableViewDataSource, UITableViewDelegate {
    var canToggle: (() -> Bool)?
    private(set) var selectedIndices: Set<Int>
    private let items: [String]
    private let identifier: String
    private let titleLabel = AndroidExploreTextLabel()
    private let table = SettingsMultiChoiceDialogTableView(frame: .zero, style: .plain)
    private let scrollingHeader = UIView()
    private let measurementRow = SettingsMultiChoiceDialogRowControl(frame: .zero)
    private var rowHeights: [CGFloat] = []
    private var measuredWidth: CGFloat = -1
    private var needsTableReload = true
    private var selectionEnabled = false
    private var rowFont: UIFont = .systemFont(ofSize: 18)

    init(titleText: String, items: [String], selectedIndices: Set<Int>, identifier: String) {
        self.items = items
        self.selectedIndices = selectedIndices.filter { items.indices.contains($0) }
        self.identifier = identifier
        super.init(frame: .zero)
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        titleLabel.text = titleText
        titleLabel.isHidden = titleText.isEmpty
        titleLabel.accessibilityLabel = titleText
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "\(identifier).title"
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.isUserInteractionEnabled = false
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        table.sectionHeaderHeight = 0
        table.sectionFooterHeight = 0
        table.sectionHeaderTopPadding = 0
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.allowsSelection = false
        table.alwaysBounceVertical = false
        table.showsHorizontalScrollIndicator = false
        table.scrollsToTop = false
        table.delaysContentTouches = false
        table.canCancelContentTouches = true
        table.accessibilityIdentifier = "\(identifier).list"
        table.register(
            SettingsMultiChoiceDialogCell.self, forCellReuseIdentifier: SettingsMultiChoiceDialogCell.reuseID)
        table.dataSource = self
        table.delegate = self
        addSubview(table)
        addSubview(titleLabel)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    var initialAccessibilityFocus: UIView {
        if !titleLabel.isHidden { return titleLabel }
        if let cell = table.visibleCells.first as? SettingsMultiChoiceDialogCell { return cell.control }
        return table
    }

    func applyAppearance() {
        backgroundColor = AndroidReplicaTheme.background
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        // CheckedTextView uses textAppearanceMedium (18sp), not a preference's 16sp subhead.
        rowFont = ReaderAndroidDefaultFont.scaledFont(size: 18, textStyle: .body, compatibleWith: traitCollection)
        measurementRow.apply(font: rowFont)
        measuredWidth = -1
        needsTableReload = true
        setNeedsLayout()
    }

    func setSelectionEnabled(_ enabled: Bool) {
        guard selectionEnabled != enabled else { return }
        selectionEnabled = enabled
        for case let cell as SettingsMultiChoiceDialogCell in table.visibleCells { cell.control.isEnabled = enabled }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        measureRows(width: size.width)
        return CGSize(width: size.width, height: max(48, headerHeight(width: size.width) + rowHeights.reduce(0, +) + 8))
    }

    private func headerHeight(width: CGFloat) -> CGFloat {
        guard !titleLabel.isHidden else { return 8 }  // paddingTopNoTitle.
        let text = titleLabel.sizeThatFits(CGSize(width: max(1, width - 48), height: .greatestFiniteMagnitude))
        return 18 + ceil(text.height) + 8
    }

    private func measureRows(width: CGFloat) {
        guard width != measuredWidth else { return }
        measuredWidth = width
        rowHeights = items.map { title in
            measurementRow.setTitle(title)
            return measurementRow.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
        needsTableReload = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let wasAtTop = table.contentOffset.y <= 0
        let anchor = table.indexPathsForVisibleRows?.min()
        let anchorDelta = anchor.map { table.rectForRow(at: $0).minY - table.contentOffset.y }
        measureRows(width: width)
        let headerHeight = headerHeight(width: width)
        // Keep the title fixed normally; in a short landscape window the title joins the list.
        let scrollsTitle = !titleLabel.isHidden && headerHeight + min(48, rowHeights.reduce(0, +)) > bounds.height
        let fixedHeight = titleLabel.isHidden || scrollsTitle ? 0 : headerHeight
        let scrollHeaderHeight = titleLabel.isHidden || scrollsTitle ? headerHeight : 0
        let headerChanged = (table.tableHeaderView?.bounds.height ?? 0) != scrollHeaderHeight
        let titleParent: UIView = scrollsTitle ? scrollingHeader : self
        if titleLabel.superview !== titleParent { titleParent.addSubview(titleLabel) }
        titleLabel.frame = CGRect(
            x: min(24, width / 2), y: 18, width: max(0, width - 48), height: max(0, headerHeight - 26))
        table.frame = CGRect(x: 0, y: fixedHeight, width: width, height: max(0, bounds.height - fixedHeight))
        if scrollHeaderHeight > 0 {
            scrollingHeader.frame = CGRect(x: 0, y: 0, width: width, height: scrollHeaderHeight)
            if table.tableHeaderView !== scrollingHeader || headerChanged { table.tableHeaderView = scrollingHeader }
        } else if table.tableHeaderView != nil {
            table.tableHeaderView = nil
        }
        if needsTableReload || headerChanged {
            needsTableReload = false
            table.reloadData()
            table.layoutIfNeeded()
            let offset: CGFloat
            if !wasAtTop, let anchor, let anchorDelta, items.indices.contains(anchor.row) {
                offset = table.rectForRow(at: anchor).minY - anchorDelta
            } else {
                offset = 0
            }
            let maximum = max(0, table.contentSize.height + table.contentInset.bottom - table.bounds.height)
            table.setContentOffset(CGPoint(x: 0, y: min(maximum, max(0, offset))), animated: false)
        }
        accessibilityElements = titleLabel.isHidden || scrollsTitle ? [table] : [titleLabel, table]
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { items.count }

    func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeights.indices.contains(indexPath.row) ? rowHeights[indexPath.row] : 48
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard items.indices.contains(indexPath.row),
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsMultiChoiceDialogCell.reuseID, for: indexPath) as? SettingsMultiChoiceDialogCell
        else { return UITableViewCell() }
        let index = indexPath.row
        cell.configure(
            index: index, title: items[index], font: rowFont,
            selected: selectedIndices.contains(index), enabled: selectionEnabled,
            identifier: "\(identifier).item.\(index)")
        cell.control.canActivate = { [weak self] in self?.mayToggle == true }
        cell.onToggle = { [weak self, weak cell] in
            guard let self, let cell, self.mayToggle,
                cell.representedIndex == index, self.table.indexPath(for: cell)?.row == index,
                self.items.indices.contains(index)
            else { return }
            if !self.selectedIndices.insert(index).inserted { self.selectedIndices.remove(index) }
            cell.control.isSelected = self.selectedIndices.contains(index)
        }
        return cell
    }

    private var mayToggle: Bool {
        selectionEnabled && window != nil && canToggle?() == true
    }
}

@MainActor
private final class SettingsMultiChoiceDialogCell: UITableViewCell {
    static let reuseID = "SettingsMultiChoiceDialogCell"
    let control = SettingsMultiChoiceDialogRowControl(frame: .zero)
    private(set) var representedIndex: Int?
    var onToggle: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        isAccessibilityElement = false
        contentView.addSubview(control)
        contentView.accessibilityElements = [control]
        control.addTarget(self, action: #selector(toggle), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(index: Int, title: String, font: UIFont, selected: Bool, enabled: Bool, identifier: String) {
        representedIndex = index
        control.cancelTracking(with: nil)
        control.isHighlighted = false
        control.setTitle(title)
        control.apply(font: font)
        control.isSelected = selected
        control.isEnabled = enabled
        control.accessibilityIdentifier = identifier
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedIndex = nil
        onToggle = nil
        control.canActivate = nil
        control.setTitle("")
        control.accessibilityIdentifier = nil
        control.isSelected = false
        control.isEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        control.frame = contentView.bounds
    }

    @objc private func toggle() {
        guard control.isEnabled else { return }
        onToggle?()
    }
}

@MainActor
private final class SettingsMultiChoiceDialogRowControl: UIControl {
    var canActivate: (() -> Bool)?
    private let label = AndroidExploreTextLabel()
    private let indicator = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        isExclusiveTouch = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .natural
        label.adjustsFontForContentSizeCategory = false
        for child in [label, indicator] {
            child.isAccessibilityElement = false
            child.isUserInteractionEnabled = false
            addSubview(child)
        }
        indicator.contentMode = .scaleAspectFit
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isSelected: Bool { didSet { updateAppearance() } }
    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
            updateAppearance()
        }
    }

    func setTitle(_ title: String) {
        label.text = title
        accessibilityLabel = title
        setNeedsLayout()
    }

    func apply(font: UIFont) {
        label.font = font
        updateAppearance()
        setNeedsLayout()
    }

    private func metrics(width: CGFloat) -> (inset: CGFloat, textWidth: CGFloat, stacked: Bool) {
        // Original row: start 20dp, 32dp drawable, drawablePadding 20dp, end 24dp.
        let stacked = width - 96 < label.font.pointSize
        return (min(20, width / 4), max(1, width - (stacked ? min(44, width / 2) : 96)), stacked)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let layout = metrics(width: size.width)
        let textHeight = ceil(
            label.sizeThatFits(CGSize(width: layout.textWidth, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: size.width, height: max(48, layout.stacked ? 32 + textHeight : max(32, textHeight)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = metrics(width: bounds.width)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let indicatorWidth = min(32, max(0, bounds.width - layout.inset * 2))
        indicator.frame = CGRect(
            x: rtl ? bounds.width - layout.inset - indicatorWidth : layout.inset,
            y: layout.stacked ? 0 : (bounds.height - 32) / 2, width: indicatorWidth, height: 32)
        let textHeight = ceil(
            label.sizeThatFits(CGSize(width: layout.textWidth, height: .greatestFiniteMagnitude)).height)
        label.frame = CGRect(
            x: layout.stacked ? layout.inset : (rtl ? 24 : 72),
            y: layout.stacked ? 32 : (bounds.height - textHeight) / 2,
            width: layout.textWidth, height: textHeight)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, window != nil, canActivate?() == true else { return false }
        return super.beginTracking(touch, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, window != nil, canActivate?() == true else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func updateAppearance() {
        // Reuse AppCompat's square checkbox, not the reader's circular SmoothCheckBox.
        indicator.image = isSelected ? ReplaceRuleEditorIcons.checked : ReplaceRuleEditorIcons.unchecked
        indicator.tintColor = isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        label.textColor = AndroidReplicaTheme.primaryText
        backgroundColor = isEnabled && isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear
        alpha = isEnabled ? 1 : 0.38
        accessibilityValue = isSelected ? "已勾选" : "未勾选"
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }
}

private final class SettingsMultiChoiceDialogTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

final class SettingsMultiChoiceDialogRootView: UIView {
    var onWindowChange: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}
