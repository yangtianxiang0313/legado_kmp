import UIKit
import shared

// GroupSelectDialog / dialog_book_group_picker / item_group_select, Legado 5f5d314.
final class BookGroupPickerContentView: UIView {
    let addButton = UIButton(type: .custom)
    let cancelButton = BookshelfGroupManagementAction(
        title: L10n.Common.cancel, padding: 12, color: AndroidReplicaTheme.primaryText)
    let confirmButton = BookshelfGroupManagementAction(
        title: L10n.Common.confirm, padding: 12, color: AndroidReplicaTheme.accent)
    let tableView: UITableView = BookGroupPickerTableView(frame: .zero, style: .plain)
    let statusStack = UIStackView()
    let statusLabel = AndroidExploreTextLabel()
    let spinner = UIActivityIndicatorView(style: .medium)
    let retryButton = BookshelfGroupManagementAction(
        title: L10n.Common.retry, padding: 12, color: AndroidReplicaTheme.accent)
    let panel = UIView()
    let backdrop = UIControl()
    private let titleLabel = AndroidExploreTextLabel()
    private let toolbar = UIView()
    private let header = UIView()
    private let footer = UIView()
    private let footerScrollView = BookGroupPickerFooterScrollView()
    private var rowLayoutWidth: CGFloat = 0
    private var rowContentSizeCategory: UIContentSizeCategory?
    private var rowDisplayScale: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityViewIsModal = true
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        backdrop.accessibilityElementsHidden = true
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 2
        panel.clipsToBounds = true
        panel.accessibilityIdentifier = "bookDetail.groups.dialog"
        for item in [backdrop, panel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor), backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.widthAnchor.constraint(equalTo: safeAreaLayoutGuide.widthAnchor, multiplier: 0.9),
            panel.heightAnchor.constraint(equalTo: safeAreaLayoutGuide.heightAnchor, multiplier: 0.9),
            panel.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
        ])
        configureToolbar()
        configureStatus()
        configureList()
        cancelButton.accessibilityIdentifier = "bookDetail.groups.cancel"
        confirmButton.accessibilityIdentifier = "bookDetail.groups.confirm"
        footerScrollView.contentInsetAdjustmentBehavior = .never
        footerScrollView.showsHorizontalScrollIndicator = false
        footerScrollView.scrollsToTop = false
        footerScrollView.delaysContentTouches = false
        footerScrollView.canCancelContentTouches = true
        footerScrollView.addSubview(footer)
        footer.addSubview(cancelButton)
        footer.addSubview(confirmButton)
        for item in [toolbar, tableView, footerScrollView] { panel.addSubview(item) }
        header.addSubview(statusStack)
        updateFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
    }

    private func configureToolbar() {
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.text = "分组选择"
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookDetail.groups.title"
        addButton.setImage(UIImage(named: "BookshelfAndroidAdd")?.withRenderingMode(.alwaysTemplate), for: .normal)
        addButton.imageView?.contentMode = .center
        addButton.tintColor = AndroidReplicaTheme.toolbarText
        addButton.accessibilityLabel = "添加分组"
        addButton.accessibilityIdentifier = "bookDetail.groups.add"
        addButton.addInteraction(UIToolTipInteraction(defaultToolTip: "添加分组"))
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(addButton)
    }

    private func configureStatus() {
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 6
        statusStack.isLayoutMarginsRelativeArrangement = true
        statusStack.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "bookDetail.groups.status"
        retryButton.accessibilityIdentifier = "bookDetail.groups.retry"
        for item in [spinner, statusLabel, retryButton] { statusStack.addArrangedSubview(item) }
        statusLabel.widthAnchor.constraint(equalTo: statusStack.layoutMarginsGuide.widthAnchor).isActive = true
        retryButton.widthAnchor.constraint(lessThanOrEqualTo: statusStack.layoutMarginsGuide.widthAnchor).isActive =
            true
    }

    private func configureList() {
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.sectionHeaderTopPadding = 0
        tableView.tableFooterView = UIView()
        tableView.delaysContentTouches = false
        tableView.canCancelContentTouches = true
        tableView.scrollsToTop = false
        tableView.accessibilityIdentifier = "bookDetail.groups.table"
        tableView.register(BookGroupPickerRowCell.self, forCellReuseIdentifier: BookGroupPickerRowCell.reuseIdentifier)
    }

    private func updateFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traitCollection)
        statusLabel.font = font
        for button in [cancelButton, confirmButton, retryButton] { button.apply(font: font) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = panel.bounds.width
        let height = panel.bounds.height
        guard width > 0, height > 0 else { return }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let tablet = min(bounds.width, bounds.height) >= 600
        let toolbarPadding: CGFloat = tablet ? 8 : 0
        let minimumToolbarHeight: CGFloat = tablet ? 64 : (bounds.width > bounds.height ? 48 : 56)
        // AppCompat Toolbar: 16dp content inset + 4dp titleMargin; 48dp menu action.
        let titleWidth = max(1, width - toolbarPadding * 2 - 20 - 48 - 4)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let toolbarHeight = max(minimumToolbarHeight, titleHeight + 8)
        let footerHeight = layoutFooter(width: width)
        // Keep cancel reachable independently of long errors, rows and oversized toolbar text.
        let visibleFooterHeight = min(footerHeight, height / 2)
        let scrollToolbar = toolbarHeight + visibleFooterHeight + 48 > height
        let toolbarParent = scrollToolbar ? header : panel
        if toolbar.superview !== toolbarParent { toolbarParent.addSubview(toolbar) }
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        titleLabel.frame = CGRect(
            x: rtl ? toolbarPadding + 52 : toolbarPadding + 20,
            y: (toolbarHeight - titleHeight) / 2, width: titleWidth, height: titleHeight)
        addButton.frame = CGRect(
            x: rtl ? toolbarPadding : width - toolbarPadding - 48,
            y: (toolbarHeight - 48) / 2, width: 48, height: 48)
        let tableTop: CGFloat = scrollToolbar ? 0 : toolbarHeight
        tableView.frame = CGRect(
            x: 0, y: tableTop, width: width, height: max(0, height - tableTop - visibleFooterHeight))
        footerScrollView.frame = CGRect(
            x: 0, y: height - visibleFooterHeight, width: width, height: visibleFooterHeight)
        footer.frame = CGRect(x: 0, y: 0, width: width, height: footerHeight)
        footerScrollView.contentSize = footer.bounds.size
        footerScrollView.isScrollEnabled = footerHeight > visibleFooterHeight
        let footerOffset = min(max(0, footerScrollView.contentOffset.y), max(0, footerHeight - visibleFooterHeight))
        footerScrollView.contentOffset = CGPoint(x: 0, y: footerOffset)

        let statusHeight =
            statusStack.isHidden
            ? 0
            : ceil(
                statusStack.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
                ).height)
        let headerTop: CGFloat = scrollToolbar ? toolbarHeight : 0
        statusStack.frame = CGRect(x: 0, y: headerTop, width: width, height: statusHeight)
        let headerSize = CGSize(width: width, height: headerTop + statusHeight)
        if headerSize.height > 0 {
            let changed = header.frame.size != headerSize
            header.frame = CGRect(origin: .zero, size: headerSize)
            if tableView.tableHeaderView !== header || changed { tableView.tableHeaderView = header }
        } else if tableView.tableHeaderView != nil {
            tableView.tableHeaderView = nil
        }
        if rowLayoutWidth != width || rowContentSizeCategory != traitCollection.preferredContentSizeCategory
            || rowDisplayScale != traitCollection.displayScale
        {
            // Never replace the live row presentation while a drag/drop owns it.
            if !tableView.hasActiveDrag, !tableView.hasActiveDrop {
                rowLayoutWidth = width
                rowContentSizeCategory = traitCollection.preferredContentSizeCategory
                rowDisplayScale = traitCollection.displayScale
                tableView.reloadData()
            }
        }
    }

    private func layoutFooter(width: CGFloat) -> CGFloat {
        // Both TextViews have 12dp padding and their own 16dp right margin, no UIButton minimum.
        let available = max(1, width - 32)
        let fits = cancelButton.preferredWidth + confirmButton.preferredWidth <= available
        let cancelWidth = fits ? cancelButton.preferredWidth : available / 2
        let confirmWidth = fits ? confirmButton.preferredWidth : available / 2
        let cancelHeight = cancelButton.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude))
            .height
        let confirmHeight = confirmButton.sizeThatFits(CGSize(width: confirmWidth, height: .greatestFiniteMagnitude))
            .height
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        cancelButton.frame = CGRect(
            x: rtl ? 32 + confirmWidth : width - 32 - confirmWidth - cancelWidth,
            y: 0, width: cancelWidth, height: cancelHeight)
        confirmButton.frame = CGRect(
            x: rtl ? 16 : width - 16 - confirmWidth, y: 0, width: confirmWidth, height: confirmHeight)
        return max(cancelHeight, confirmHeight)
    }
}

final class BookGroupPickerRowCell: UITableViewCell {
    static let reuseIdentifier = "BookGroupPickerRow"
    let toggleButton = UIButton(type: .custom)
    let editButton = BookshelfGroupManagementAction(
        title: L10n.Common.edit, padding: 8, color: AndroidReplicaTheme.primaryText)
    var onToggle: (() -> Void)?
    var onEdit: (() -> Void)?
    var onMove: ((Int) -> Bool)?
    private let mark = UIImageView()
    private let groupLabel = AndroidExploreTextLabel()
    private let divider = UIView()
    private var rawName = ""
    private var checked = false

    static func rowHeight(group: BookGroup, width: CGFloat, traits: UITraitCollection) -> CGFloat {
        let font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        let editWidth = Self.editWidth(width: width, font: font, scale: traits.displayScale)
        let editSize = BookshelfGroupManagementText.size(
            L10n.Common.edit, font: font, width: max(1, editWidth - 16), singleLine: false, scale: traits.displayScale)
        let nameSize = BookshelfGroupManagementText.size(
            BookshelfGroupManagementText.singleLine(group.groupName), font: font,
            width: max(1, width - 16 - editWidth - 32), singleLine: true, scale: traits.displayScale)
        return ceil(max(32, nameSize.height, ceil(editSize.height + 16)) + 16) + 1 / max(1, traits.displayScale)
    }

    private static func editWidth(width: CGFloat, font: UIFont, scale: CGFloat) -> CGFloat {
        let textSize = BookshelfGroupManagementText.size(
            L10n.Common.edit, font: font, width: .greatestFiniteMagnitude, singleLine: false, scale: scale)
        return min(ceil(textSize.width + 16), max(1, (width - 16) / 2))
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = AndroidReplicaTheme.background
        isAccessibilityElement = false
        toggleButton.configuration = nil
        toggleButton.automaticallyUpdatesConfiguration = false
        toggleButton.isAccessibilityElement = true
        toggleButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(edit), for: .touchUpInside)
        groupLabel.numberOfLines = 1
        groupLabel.lineBreakMode = .byClipping
        groupLabel.adjustsFontSizeToFitWidth = false
        groupLabel.textColor = AndroidReplicaTheme.primaryText
        mark.contentMode = .scaleAspectFit
        for child in [mark, groupLabel] {
            child.isAccessibilityElement = false
            child.isUserInteractionEnabled = false
            toggleButton.addSubview(child)
        }
        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        for item in [toggleButton, editButton, divider] { contentView.addSubview(item) }
        contentView.accessibilityElements = [toggleButton, editButton]
        updateFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(group: BookGroup, checked: Bool, enabled: Bool) {
        self.checked = checked
        rawName = group.groupName
        // cb_group is singleLine, unlike the multiline management row. No getManageName suffix here.
        groupLabel.text = BookshelfGroupManagementText.singleLine(rawName)
        mark.image = UIImage(named: checked ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
            .withRenderingMode(.alwaysTemplate)
        mark.tintColor = checked ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        toggleButton.accessibilityIdentifier = "bookDetail.groups.row.\(group.groupId)"
        toggleButton.accessibilityLabel = rawName
        toggleButton.accessibilityValue = checked ? "已选择" : "未选择"
        editButton.accessibilityIdentifier = "bookDetail.groups.edit.\(group.groupId)"
        editButton.accessibilityLabel = "\(L10n.Common.edit) \(rawName)"
        toggleButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "上移") { [weak self] _ in self?.onMove?(-1) ?? false },
            UIAccessibilityCustomAction(name: "下移") { [weak self] _ in self?.onMove?(1) ?? false },
        ]
        setEnabled(enabled)
        setNeedsLayout()
    }

    func setEnabled(_ enabled: Bool) {
        toggleButton.isEnabled = enabled
        editButton.isEnabled = enabled
        toggleButton.accessibilityTraits = checked ? [.button, .selected] : .button
        if !enabled { toggleButton.accessibilityTraits.insert(.notEnabled) }
        toggleButton.alpha = enabled ? 1 : 0.38
        editButton.alpha = enabled ? 1 : 0.38
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        onEdit = nil
        onMove = nil
        rawName = ""
        checked = false
        groupLabel.text = nil
        mark.image = nil
        toggleButton.accessibilityIdentifier = nil
        toggleButton.accessibilityLabel = nil
        toggleButton.accessibilityValue = nil
        toggleButton.accessibilityCustomActions = nil
        editButton.accessibilityIdentifier = nil
        editButton.accessibilityLabel = nil
        setEnabled(false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = contentView.bounds.width
        let ruleHeight = 1 / max(1, traitCollection.displayScale)
        let centerY = max(0, contentView.bounds.height - ruleHeight) / 2
        let font = groupLabel.font!
        let editWidth = Self.editWidth(width: width, font: font, scale: traitCollection.displayScale)
        let toggleWidth = max(0, width - 16 - editWidth)
        let textWidth = max(0, toggleWidth - 32)
        let textHeight = ceil(
            BookshelfGroupManagementText.size(
                BookshelfGroupManagementText.singleLine(rawName), font: font, width: max(1, textWidth),
                singleLine: true, scale: traitCollection.displayScale
            ).height)
        let toggleHeight = max(32, textHeight)
        let editHeight = editButton.sizeThatFits(CGSize(width: editWidth, height: .greatestFiniteMagnitude)).height
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        toggleButton.frame = CGRect(
            x: rtl ? 8 + editWidth : 8, y: centerY - toggleHeight / 2, width: toggleWidth, height: toggleHeight)
        mark.frame = CGRect(x: rtl ? toggleWidth - 32 : 0, y: (toggleHeight - 32) / 2, width: 32, height: 32)
        groupLabel.frame = CGRect(
            x: rtl ? 0 : 32, y: (toggleHeight - textHeight) / 2, width: textWidth, height: textHeight)
        editButton.frame = CGRect(
            x: rtl ? 8 : width - 8 - editWidth, y: centerY - editHeight / 2, width: editWidth, height: editHeight)
        divider.frame = CGRect(x: 0, y: contentView.bounds.height - ruleHeight, width: width, height: ruleHeight)
    }

    private func updateFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traitCollection)
        groupLabel.font = font
        editButton.apply(font: font)
        setNeedsLayout()
    }

    @objc private func toggle() { if toggleButton.isEnabled { onToggle?() } }
    @objc private func edit() { if editButton.isEnabled { onEdit?() } }
}

private final class BookGroupPickerTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

private final class BookGroupPickerFooterScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
