import UIKit
import shared

enum BookshelfGroupManagementText {
    // BookGroup.getManageName, Legado 5f5d314 (values-zh). The suffix is not the editable name.
    static func name(_ group: BookGroup) -> String {
        let category: String
        switch group.groupId {
        case -1: category = "全部"
        case -2: category = "本地"
        case -3: category = "音频"
        case -4: category = "网络未分组"
        case -5: category = "本地未分组"
        case -11: category = "更新失败"
        default: return group.groupName
        }
        return "\(group.groupName)(\(category))"
    }

    static func font(
        _ size: CGFloat, weight: UIFont.Weight = .regular, style: UIFont.TextStyle = .body,
        traits: UITraitCollection
    ) -> UIFont {
        BookshelfLayoutDialogStyle.font(size: size, weight: weight, style: style, traits: traits)
    }

    static func singleLine(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    static func size(_ text: String, font: UIFont, width: CGFloat, singleLine: Bool, scale: CGFloat) -> CGSize {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = singleLine ? .byClipping : .byWordWrapping
        let measured = (text as NSString).boundingRect(
            with: CGSize(
                width: singleLine ? .greatestFiniteMagnitude : max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .kern: CGFloat(0), .paragraphStyle: paragraph], context: nil)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
        // Round only after the natural text block and includeFontPadding have been combined.
        return CGSize(
            width: min(width, measured.width),
            height: max(font.lineHeight, measured.height) + padding.top + padding.bottom)
    }
}

// dialog_recycler_view + item_book_group_manage.xml, Legado 5f5d314.
final class BookshelfGroupManagementContentView: UIView {
    let panel = UIView()
    let backdrop = UIControl()
    let tableView: UITableView = BookshelfGroupManagementTableView(frame: .zero, style: .plain)
    let addButton: UIButton = BookshelfGroupManagementIconButton(type: .system)
    let confirmButton = BookshelfGroupManagementAction(title: "确认", padding: 12, color: AndroidReplicaTheme.accent)
    let retryButton = BookshelfGroupManagementAction(title: "重试", padding: 12, color: AndroidReplicaTheme.accent)

    private let toolbar = UIView()
    private let titleLabel = BookshelfGroupManagementLabel()
    private let footer = UIView()
    private let body = UIView()
    private let spinner = BookshelfBookStatusLoadingView()
    private let header = UIView()
    private let errorLabel = BookshelfGroupManagementLabel()
    private let statusScrollView = BookshelfGroupManagementStatusScrollView()
    private let statusContent = UIView()
    private var errorMessage: String?
    private var hasRows = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityViewIsModal = true
        accessibilityIdentifier = "bookshelf.groupManage"
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        backdrop.accessibilityElementsHidden = true
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 2
        panel.clipsToBounds = true
        body.clipsToBounds = true
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.setText("分组管理", singleLine: true)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.accessibilityTraits = [.header, .staticText]
        titleLabel.accessibilityIdentifier = "bookshelf.groupManage.title"
        addButton.setImage(UIImage(named: "BookshelfAndroidAdd")?.withRenderingMode(.alwaysTemplate), for: .normal)
        addButton.tintColor = AndroidReplicaTheme.toolbarText
        addButton.accessibilityLabel = "添加分组"
        addButton.accessibilityIdentifier = "bookshelf.groupManage.add"
        addButton.addInteraction(UIToolTipInteraction(defaultToolTip: "添加分组"))
        confirmButton.accessibilityIdentifier = "bookshelf.groupManage.confirm"
        errorLabel.textColor = AndroidReplicaTheme.secondaryText
        errorLabel.accessibilityIdentifier = "bookshelf.groupManage.error"
        retryButton.accessibilityIdentifier = "bookshelf.groupManage.retry"
        spinner.loadingWidth = 2
        spinner.accessibilityIdentifier = "bookshelf.groupManage.loading"
        statusScrollView.contentInsetAdjustmentBehavior = .never
        statusScrollView.showsHorizontalScrollIndicator = false
        statusScrollView.scrollsToTop = false
        statusScrollView.delaysContentTouches = false
        statusScrollView.canCancelContentTouches = true
        tableView.backgroundColor = AndroidReplicaTheme.background
        // VerticalDivider decorates actual rows, including the last one; never draw empty-row rules.
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.showsVerticalScrollIndicator = false
        tableView.alwaysBounceVertical = false
        tableView.scrollsToTop = false
        tableView.delaysContentTouches = false
        tableView.canCancelContentTouches = true
        tableView.accessibilityIdentifier = "bookshelf.groupManage.list"
        tableView.register(BookshelfGroupManagementCell.self, forCellReuseIdentifier: BookshelfGroupManagementCell.reuseID)
        addSubview(backdrop)
        addSubview(panel)
        for child in [body, toolbar, footer] { panel.addSubview(child) }
        body.addSubview(tableView)
        body.addSubview(statusScrollView)
        body.addSubview(spinner)
        statusScrollView.addSubview(statusContent)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(addButton)
        footer.addSubview(confirmButton)
        statusContent.addSubview(errorLabel)
        statusContent.addSubview(retryButton)
        refreshFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func render(loading: Bool, error: String?, hasRows: Bool, canAct: Bool, canRetry: Bool, canClose: Bool) {
        if errorMessage != error {
            errorMessage = error
            errorLabel.setText(error)
            statusScrollView.contentOffset = .zero
        }
        self.hasRows = hasRows
        addButton.isEnabled = canAct
        retryButton.isEnabled = canRetry
        confirmButton.isEnabled = canClose
        backdrop.isEnabled = canClose
        spinner.setPresentationActive(!panel.accessibilityElementsHidden)
        spinner.setRefreshing(loading && error == nil)
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshFonts()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            // A drag owns its live row order until the controller's normal readback/reload.
            if !tableView.hasActiveDrag, !tableView.hasActiveDrop { tableView.reloadData() }
        }
        setNeedsLayout()
    }

    private func refreshFonts() {
        titleLabel.font = BookshelfGroupManagementText.font(
            20, weight: .medium, style: .headline, traits: traitCollection)
        let font = BookshelfGroupManagementText.font(14, traits: traitCollection)
        errorLabel.font = font
        confirmButton.apply(font: font)
        retryButton.apply(font: font)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        let safe = safeAreaLayoutGuide.layoutFrame
        panel.frame = CGRect(
            x: safe.minX + safe.width * 0.05, y: safe.minY + safe.height * 0.05,
            width: safe.width * 0.9, height: safe.height * 0.9)
        let width = panel.bounds.width
        guard width > 0 else { return }
        let tablet = min(bounds.width, bounds.height) >= 600
        let toolbarPadding: CGFloat = tablet ? 8 : 0
        let minimumToolbarHeight: CGFloat = tablet ? 64 : (bounds.width > bounds.height ? 48 : 56)
        // Base.V7.Widget.AppCompat.Toolbar: 16dp content inset + 4dp titleMargin, no navigation.
        let titleWidth = max(0, width - toolbarPadding * 2 - 16 - 4 - 48 - 4)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height
        let toolbarHeight = max(minimumToolbarHeight, titleHeight + 8)
        let actionWidth = min(max(0, width - 24), confirmButton.preferredWidth)
        let footerHeight = confirmButton.sizeThatFits(CGSize(width: actionWidth, height: .greatestFiniteMagnitude))
            .height
        // Preserve reachable chrome on exceptionally short viewports or large accessibility text.
        let compact = toolbarHeight + footerHeight + 64 > panel.bounds.height
        let toolbarParent = compact ? header : panel
        if toolbar.superview !== toolbarParent { toolbarParent.addSubview(toolbar) }
        if !compact, tableView.tableFooterView === footer { tableView.tableFooterView = nil }
        let footerParent = compact ? tableView : panel
        if footer.superview !== footerParent { footerParent.addSubview(footer) }
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        titleLabel.frame = CGRect(
            x: rtl ? toolbarPadding + 52 : toolbarPadding + 20, y: (toolbarHeight - titleHeight) / 2,
            width: titleWidth, height: titleHeight)
        addButton.frame = CGRect(
            x: rtl ? toolbarPadding : width - toolbarPadding - 48,
            y: (toolbarHeight - 48) / 2, width: 48, height: 48)
        body.frame =
            compact
            ? panel.bounds
            : CGRect(
                x: 0, y: toolbarHeight, width: width, height: max(0, panel.bounds.height - toolbarHeight - footerHeight)
            )
        tableView.frame = body.bounds
        let centeredError = !hasRows && !compact && errorMessage != nil
        statusScrollView.isHidden = !centeredError
        statusScrollView.frame = body.bounds
        let errorParent = centeredError ? statusContent : header
        for child in [errorLabel, retryButton] where child.superview !== errorParent { errorParent.addSubview(child) }
        errorLabel.isHidden = errorMessage == nil
        retryButton.isHidden = errorMessage == nil
        var headerHeight = compact ? toolbarHeight : 0
        if errorMessage != nil {
            let statusHeight = layoutError(width: width, y: centeredError ? 0 : headerHeight)
            if centeredError {
                let contentHeight = max(body.bounds.height, statusHeight)
                statusContent.frame = CGRect(
                    x: 0, y: max(0, (body.bounds.height - statusHeight) / 2), width: width, height: statusHeight)
                statusScrollView.contentSize = CGSize(width: width, height: contentHeight)
                statusScrollView.isScrollEnabled = statusHeight > body.bounds.height
                let offset = min(statusScrollView.contentOffset.y, max(0, contentHeight - body.bounds.height))
                statusScrollView.contentOffset = CGPoint(x: 0, y: max(0, offset))
            } else {
                headerHeight = statusHeight
            }
        }
        let headerSize = CGSize(width: width, height: headerHeight)
        if headerHeight > 0 {
            let changed = header.frame.size != headerSize
            header.frame = CGRect(origin: .zero, size: headerSize)
            if tableView.tableHeaderView !== header || changed { tableView.tableHeaderView = header }
        } else if tableView.tableHeaderView != nil {
            tableView.tableHeaderView = nil
        }
        let oldFooterSize = footer.frame.size
        footer.frame = CGRect(x: 0, y: compact ? footer.frame.minY : panel.bounds.height - footerHeight, width: width, height: footerHeight)
        confirmButton.frame = CGRect(
            x: rtl ? 12 : width - 12 - actionWidth, y: 0, width: actionWidth, height: footerHeight)
        if compact, tableView.tableFooterView !== footer || oldFooterSize != footer.frame.size {
            tableView.tableFooterView = footer
        }
        let loadingArea =
            compact
            ? body.bounds.inset(by: UIEdgeInsets(top: toolbarHeight, left: 0, bottom: footerHeight, right: 0))
            : body.bounds
        // dialog_recycler_view: centered 36dp RotateLoading, 6dp margins and 2dp strokes.
        let loadingSize = max(0, min(36, loadingArea.width - 12, loadingArea.height - 12))
        spinner.frame = CGRect(
            x: loadingArea.midX - loadingSize / 2, y: loadingArea.midY - loadingSize / 2, width: loadingSize,
            height: loadingSize)
    }

    private func layoutError(width: CGFloat, y: CGFloat) -> CGFloat {
        // tv_msg keeps its 16dp padding; retry is the existing iOS recovery action, not an empty-state row.
        let labelHeight = errorLabel.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude))
            .height
        errorLabel.frame = CGRect(x: 16, y: y + 16, width: max(0, width - 32), height: labelHeight)
        let retryWidth = min(max(0, width - 32), retryButton.preferredWidth)
        let retryHeight = retryButton.sizeThatFits(CGSize(width: retryWidth, height: .greatestFiniteMagnitude)).height
        retryButton.frame = CGRect(
            x: effectiveUserInterfaceLayoutDirection == .rightToLeft ? 16 : width - 16 - retryWidth,
            y: errorLabel.frame.maxY + 16, width: retryWidth, height: retryHeight)
        return retryButton.frame.maxY + 8
    }
}

final class BookshelfGroupManagementCell: UITableViewCell {
    static let reuseID = "BookshelfGroupManagementCell"
    var onEdit: (() -> Void)?
    var onToggle: ((Bool) -> Void)?
    var onMove: ((Int) -> Bool)?

    private let groupLabel = BookshelfGroupManagementLabel()
    private let editButton = BookshelfGroupManagementAction(
        title: "编辑", padding: 8, color: AndroidReplicaTheme.secondaryText)
    private let visibilityControl = ReaderAndroidSwitchControl()
    private let divider = UIView()
    private var canMoveUp = false
    private var canMoveDown = false
    private var actionsEnabled = false

    static func rowHeight(group: BookGroup, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = BookshelfGroupManagementText.font(14, traits: traits)
        let scale = max(1, traits.displayScale)
        let editSize = BookshelfGroupManagementText.size(
            "编辑", font: font, width: .greatestFiniteMagnitude, singleLine: false, scale: scale)
        let editWidth = ceil(editSize.width + 16)
        let groupSize = BookshelfGroupManagementText.size(
            BookshelfGroupManagementText.name(group), font: font, width: max(1, width - 16 - editWidth - 48),
            singleLine: false, scale: scale)
        return ceil(max(48, groupSize.height, editSize.height + 16) + 16) + 1 / scale
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = AndroidReplicaTheme.background
        isAccessibilityElement = false
        groupLabel.textColor = AndroidReplicaTheme.secondaryText
        groupLabel.isAccessibilityElement = true
        editButton.addTarget(self, action: #selector(edit), for: .touchUpInside)
        visibilityControl.onTintColor = AndroidReplicaTheme.accent
        visibilityControl.canInteract = { [weak self] in self?.actionsEnabled == true }
        visibilityControl.addTarget(self, action: #selector(toggle), for: .valueChanged)
        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        for child in [groupLabel, editButton, visibilityControl, divider] { contentView.addSubview(child) }
        contentView.accessibilityElements = [groupLabel, editButton, visibilityControl]
        refreshFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(group: BookGroup, index: Int, count: Int, enabled: Bool) {
        let name = BookshelfGroupManagementText.name(group)
        // tv_group has no singleLine/maxLines in the Android resource. Keep raw names and wrapping.
        groupLabel.setText(name)
        groupLabel.accessibilityValue = "第\(index + 1)项，共\(count)项"
        groupLabel.accessibilityIdentifier = "bookshelf.groupManage.name.\(group.groupId)"
        editButton.accessibilityLabel = "编辑 \(name)"
        editButton.accessibilityIdentifier = "bookshelf.groupManage.edit.\(group.groupId)"
        visibilityControl.accessibilityLabel = "显示 \(name)"
        visibilityControl.accessibilityIdentifier = "bookshelf.groupManage.show.\(group.groupId)"
        visibilityControl.setOn(group.show, animated: false)
        canMoveUp = index > 0
        canMoveDown = index + 1 < count
        setActionsEnabled(enabled)
        setNeedsLayout()
    }

    func setActionsEnabled(_ enabled: Bool) {
        actionsEnabled = enabled
        editButton.isEnabled = enabled
        visibilityControl.isEnabled = enabled
        groupLabel.accessibilityCustomActions =
            enabled
            ? [
                canMoveUp ? UIAccessibilityCustomAction(name: "上移") { [weak self] _ in self?.onMove?(-1) ?? false } : nil,
                canMoveDown ? UIAccessibilityCustomAction(name: "下移") { [weak self] _ in self?.onMove?(1) ?? false } : nil,
            ].compactMap { $0 } : nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onEdit = nil
        onToggle = nil
        onMove = nil
        setActionsEnabled(false)
        groupLabel.setText(nil)
        groupLabel.accessibilityValue = nil
        groupLabel.accessibilityIdentifier = nil
        editButton.accessibilityLabel = nil
        editButton.accessibilityIdentifier = nil
        visibilityControl.accessibilityLabel = nil
        visibilityControl.accessibilityIdentifier = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshFonts()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let ruleHeight = 1 / max(1, traitCollection.displayScale)
        let centerY = max(0, contentView.bounds.height - ruleHeight) / 2
        let available = max(0, width - 16)
        let switchWidth = min(48, available)
        let editWidth = min(editButton.preferredWidth, max(0, available - switchWidth))
        let nameWidth = max(0, available - switchWidth - editWidth)
        let labelHeight = groupLabel.sizeThatFits(CGSize(width: nameWidth, height: .greatestFiniteMagnitude)).height
        let editHeight = editButton.sizeThatFits(CGSize(width: editWidth, height: .greatestFiniteMagnitude)).height
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        groupLabel.frame = CGRect(
            x: rtl ? 8 + switchWidth + editWidth : 8, y: centerY - labelHeight / 2, width: nameWidth,
            height: labelHeight)
        editButton.frame = CGRect(
            x: rtl ? 8 + switchWidth : 8 + nameWidth, y: centerY - editHeight / 2, width: editWidth, height: editHeight)
        visibilityControl.frame = CGRect(
            x: rtl ? 8 : width - 8 - switchWidth, y: centerY - 24, width: switchWidth, height: 48)
        divider.frame = CGRect(x: 0, y: contentView.bounds.height - ruleHeight, width: width, height: ruleHeight)
    }

    private func refreshFonts() {
        let font = BookshelfGroupManagementText.font(14, traits: traitCollection)
        groupLabel.font = font
        editButton.apply(font: font)
        setNeedsLayout()
    }

    @objc private func edit() { if actionsEnabled { onEdit?() } }
    @objc private func toggle() { if actionsEnabled { onToggle?(visibilityControl.isOn) } }
}

private final class BookshelfGroupManagementLabel: UILabel {
    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        lineBreakMode = .byWordWrapping
        textAlignment = .natural
        adjustsFontForContentSizeCategory = false
        adjustsFontSizeToFitWidth = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func setText(_ raw: String?, singleLine: Bool = false) {
        numberOfLines = singleLine ? 1 : 0
        lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        text = raw.map { singleLine ? BookshelfGroupManagementText.singleLine($0) : $0 }
        accessibilityLabel = raw
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let natural = BookshelfGroupManagementText.size(
            text ?? "", font: font, width: size.width, singleLine: numberOfLines == 1,
            scale: traitCollection.displayScale)
        return CGSize(width: ceil(natural.width), height: ceil(natural.height))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(
            in: rect.inset(by: AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }
}

final class BookshelfGroupManagementAction: UIButton {
    private let label = BookshelfGroupManagementLabel()
    private let padding: CGFloat

    var preferredWidth: CGFloat {
        ceil(
            label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                .width
                + padding * 2)
    }

    init(title: String, padding: CGFloat, color: UIColor) {
        self.padding = padding
        super.init(frame: .zero)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        label.setText(title)
        label.textColor = color
        label.textAlignment = .center
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isEnabled: Bool {
        didSet {
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: preferredWidth, height: .greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(max(0, size.width), preferredWidth)
        let natural = BookshelfGroupManagementText.size(
            label.text ?? "", font: label.font, width: max(1, width - padding * 2), singleLine: false,
            scale: traitCollection.displayScale)
        return CGSize(width: width, height: ceil(natural.height + padding * 2))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: min(padding, bounds.width / 2), dy: min(padding, bounds.height / 2))
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, window != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(font: UIFont) {
        label.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}

private final class BookshelfGroupManagementIconButton: UIButton {
    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        let size = max(0, min(24, contentRect.width, contentRect.height))
        return CGRect(x: contentRect.midX - size / 2, y: contentRect.midY - size / 2, width: size, height: size)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }
}

private final class BookshelfGroupManagementTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class BookshelfGroupManagementStatusScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
