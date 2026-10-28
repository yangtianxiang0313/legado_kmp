import UIKit

#if canImport(shared)
    import shared
#endif

// Legado 5f5d314: item_arrange_book.xml and ui/book/manage/BookAdapter.kt.
@MainActor
final class BookshelfManageCell: UITableViewCell {
    static let reuseIdentifier = "BookshelfManageCell"
    let checkButton: UIButton = BookshelfManageCellButton(padding: 0)
    let nameButton: UIButton = BookshelfManageCellButton(padding: 3, singleLine: true)
    let groupButton: UIButton = BookshelfManageCellButton(padding: 10)
    let deleteButton: UIButton = BookshelfManageCellButton(padding: 10)

    var onToggle: (() -> Void)?
    var onOpen: (() -> Void)?
    var onGroup: (() -> Void)?
    var onDelete: (() -> Void)?
    // Relative position: -1 moves up, +1 moves down. The owner persists the order.
    var onMove: ((Int) -> Bool)? { didSet { updateMoveActions() } }

    private let rowButton = BookshelfManageCellButton(padding: 0)
    private let authorLabel = BookshelfManageTextLabel()
    private let originLabel = BookshelfManageTextLabel()
    private let groupsLabel = BookshelfManageTextLabel()
    private var bookURL: String?
    private var opensTitle = false
    private var controlsEnabled = false
    private var checked = false
    private var measuredWidth: CGFloat = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessoryType = .none
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        isAccessibilityElement = false
        contentView.isAccessibilityElement = false
        clipsToBounds = true

        // A background control owns plain-row taps; sibling buttons consume their own
        // touches and never bubble a group/delete/title action into row selection.
        rowButton.isAccessibilityElement = false
        rowButton.addTarget(self, action: #selector(toggleBook), for: .touchUpInside)
        contentView.addSubview(rowButton)
        for button in [checkButton, nameButton, groupButton, deleteButton] {
            contentView.addSubview(button)
        }
        nameButton.contentHorizontalAlignment = .leading
        nameButton.titleLabel?.textAlignment = .natural
        nameButton.setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        for button in [groupButton, deleteButton] {
            button.setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
        }
        checkButton.addTarget(self, action: #selector(toggleBook), for: .touchUpInside)
        nameButton.addTarget(self, action: #selector(tapTitle), for: .touchUpInside)
        groupButton.addTarget(self, action: #selector(tapGroup), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(tapDelete), for: .touchUpInside)
        for label in [authorLabel, originLabel, groupsLabel] {
            label.textColor = AndroidReplicaTheme.secondaryText
            label.lineBreakMode = .byTruncatingTail
            label.isUserInteractionEnabled = false
            label.adjustsFontSizeToFitWidth = false
            label.adjustsFontForContentSizeCategory = false
            contentView.addSubview(label)
        }
        originLabel.numberOfLines = 0
        originLabel.lineBreakMode = .byWordWrapping
        applyFonts()
        clearPresentation()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(book: Book, groupNames: String, selected: Bool, openTitle: Bool, enabled: Bool) {
        if bookURL != book.bookUrl || !enabled {
            for button in [rowButton, checkButton, nameButton, groupButton, deleteButton] {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
        }
        bookURL = book.bookUrl
        checked = selected
        opensTitle = openTitle
        controlsEnabled = enabled
        super.setSelected(false, animated: false)
        nameButton.setTitle(singleLineText(book.name), for: .normal)
        authorLabel.text = singleLineText(book.author)
        authorLabel.isHidden = book.author.isEmpty
        originLabel.text = book.isLocal ? "本地书籍" : book.originName
        let rawGroups = groupNames.isEmpty ? "未分组" : groupNames
        groupsLabel.text = singleLineText(rawGroups)
        groupButton.setTitle("分组", for: .normal)
        deleteButton.setTitle("删除", for: .normal)
        checkButton.setImage(
            UIImage(named: selected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
                .withRenderingMode(.alwaysTemplate), for: .normal)
        checkButton.isSelected = selected
        checkButton.tintColor = selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText

        accessibilityIdentifier = "bookshelf.manage.cell.\(book.bookUrl)"
        let identity = [book.name, book.author].filter { !$0.isEmpty }.joined(separator: "，")
        configureAccessibility(checkButton, action: selected ? "取消选择" : "选择", identity: identity, id: "check")
        configureAccessibility(
            nameButton, action: openTitle ? "书籍详情" : (selected ? "取消选择" : "选择"), identity: identity, id: "name")
        configureAccessibility(groupButton, action: "分组", identity: identity, id: "bookGroup")
        configureAccessibility(deleteButton, action: "删除", identity: identity, id: "delete")
        checkButton.accessibilityValue = selected ? "已选中" : "未选中"
        groupButton.accessibilityValue = rawGroups
        authorLabel.accessibilityLabel = book.author
        originLabel.accessibilityLabel = originLabel.text
        groupsLabel.accessibilityLabel = rawGroups
        for (label, id) in [(authorLabel, "author"), (originLabel, "origin"), (groupsLabel, "groups")] {
            label.isAccessibilityElement = true
            label.accessibilityIdentifier = "bookshelf.manage.\(id).\(book.bookUrl)"
        }
        for button in [rowButton, checkButton, nameButton, groupButton, deleteButton] {
            button.isEnabled = enabled
            button.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        }
        var selectionTraits: UIAccessibilityTraits = .button
        if selected { selectionTraits.insert(.selected) }
        if !enabled { selectionTraits.insert(.notEnabled) }
        checkButton.accessibilityTraits = selectionTraits
        var elements: [UIView] = [checkButton, nameButton]
        if !authorLabel.isHidden { elements.append(authorLabel) }
        elements += [originLabel, groupsLabel, groupButton, deleteButton]
        accessibilityElements = elements
        updateMoveActions()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        onOpen = nil
        onGroup = nil
        onDelete = nil
        onMove = nil
        clearPresentation()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
        checkButton.tintColor = checked ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric, height: arrange(width: bounds.width > 0 ? bounds.width : 390, apply: false)
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width, apply: false))
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width > 0 ? targetSize.width : (bounds.width > 0 ? bounds.width : 390)
        let accessoryWidth = max(0, bounds.width - contentView.bounds.width)
        return CGSize(width: width, height: arrange(width: max(1, width - accessoryWidth), apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rowButton.frame = contentView.bounds
        if measuredWidth != contentView.bounds.width {
            measuredWidth = contentView.bounds.width
            invalidateIntrinsicContentSize()
        }
        _ = arrange(width: contentView.bounds.width, apply: true)
    }

    private func applyFonts() {
        func font(_ size: CGFloat) -> UIFont {
            BookshelfLayoutDialogStyle.font(size: size, traits: traitCollection)
        }
        (nameButton as? BookshelfManageCellButton)?.apply(font: font(15))
        for label in [authorLabel, originLabel, groupsLabel] { label.font = font(12) }
        // Unspecified TextView textSize inherits Widget.TextView's 14sp small appearance.
        for button in [groupButton, deleteButton] { (button as? BookshelfManageCellButton)?.apply(font: font(14)) }
    }

    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        // tv_name targets checkbox.right: its unconnected end margin adds no gap.
        let textX: CGFloat = min(48, max(0, width - 6))
        let available = max(1, width - textX - 6)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ view: UIView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            if apply { view.frame = CGRect(x: rtl ? width - x - w : x, y: y, width: max(0, w), height: max(0, h)) }
        }
        func labelHeight(_ label: UILabel, width: CGFloat) -> CGFloat {
            label.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height
        }
        var y: CGFloat = 6
        // tv_name is wrap_content; tv_author alone consumes the remaining width.
        let nameWidth = min(nameButton.intrinsicContentSize.width, available)
        let authorWidth = authorLabel.isHidden ? 0 : max(0, available - nameWidth - 20)
        let nameHeight = nameButton.intrinsicContentSize.height
        let authorHeight = authorLabel.isHidden ? 0 : labelHeight(authorLabel, width: authorWidth)
        let identityHeight = max(nameHeight, authorHeight)
        place(nameButton, textX, y, nameWidth, identityHeight)
        place(
            authorLabel, textX + nameWidth + min(12, max(0, available - nameWidth)),
            y + (identityHeight - authorHeight) / 2, authorWidth, authorHeight)
        y += identityHeight

        let groupSize = groupButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude))
        let deleteSize = deleteButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude))
        let actionWidth = groupSize.width + deleteSize.width
        let separateActions = actionWidth > available
        let metadataWidth = separateActions ? available : max(1, available - actionWidth)
        let lowerTop = y
        // Only origin is multiline in the resource. Keep names/authors/groups single-line at every size.
        let originWidth = min(metadataWidth, ceil(originLabel.intrinsicContentSize.width + 6))
        let groupsWidth = max(0, metadataWidth - originWidth)
        let originHeight = labelHeight(originLabel, width: originWidth - 6)
        let groupsHeight = labelHeight(groupsLabel, width: groupsWidth - 6)
        let metadataHeight = max(originHeight, groupsHeight) + 6
        let lowerHeight = max(8 + metadataHeight, separateActions ? 0 : max(groupSize.height, deleteSize.height))
        let originTop = lowerTop + 8 + (lowerHeight - 8 - originHeight - 6) / 2
        let groupsTop = lowerTop + 8 + (lowerHeight - 8 - groupsHeight - 6) / 2
        place(originLabel, textX + min(3, originWidth), originTop + 3, max(0, originWidth - 6), originHeight)
        place(
            groupsLabel, textX + originWidth + min(3, groupsWidth), groupsTop + 3,
            max(0, groupsWidth - 6), groupsHeight)
        y = lowerTop + lowerHeight

        if separateActions {
            var x = max(0, available - actionWidth)
            var rowHeight: CGFloat = 0
            for (button, size) in [(groupButton, groupSize), (deleteButton, deleteSize)] {
                if x > 0 && x + size.width > available {
                    y += rowHeight
                    x = 0
                    rowHeight = 0
                }
                place(button, textX + x, y, size.width, size.height)
                rowHeight = max(rowHeight, size.height)
                x += size.width
            }
            y += rowHeight
        } else {
            let actionHeight = max(groupSize.height, deleteSize.height)
            let height = max(lowerHeight, actionHeight)
            place(
                groupButton, textX + available - actionWidth, lowerTop + (height - groupSize.height) / 2,
                groupSize.width, groupSize.height)
            place(
                deleteButton, textX + available - deleteSize.width, lowerTop + (height - deleteSize.height) / 2,
                deleteSize.width, deleteSize.height)
            y = lowerTop + height
        }
        // 6dp outer padding, 10dp checkbox margins, original 32dp drawable.
        let height = max(64, ceil(y + 6))
        place(checkButton, 16, (height - 32) / 2, min(32, max(0, width - 32)), 32)
        return height
    }

    private func configureAccessibility(_ button: UIButton, action: String, identity: String, id: String) {
        button.isAccessibilityElement = true
        button.accessibilityIdentifier = "bookshelf.manage.\(id).\(bookURL ?? "")"
        button.accessibilityLabel = "\(action)，\(identity)"
        for tooltip in button.interactions.compactMap({ $0 as? UIToolTipInteraction }) {
            button.removeInteraction(tooltip)
        }
        button.addInteraction(UIToolTipInteraction(defaultToolTip: "\(action)，\(identity)"))
    }

    private func singleLineText(_ text: String) -> String {
        // Android SingleLineTransformationMethod changes display only, never the raw AX text.
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    private func updateMoveActions() {
        for button in [checkButton, nameButton] {
            button.accessibilityCustomActions =
                controlsEnabled && bookURL != nil && onMove != nil
                ? [
                    UIAccessibilityCustomAction(name: "上移", target: self, selector: #selector(moveUp)),
                    UIAccessibilityCustomAction(name: "下移", target: self, selector: #selector(moveDown)),
                ] : nil
        }
    }

    private func clearPresentation() {
        bookURL = nil
        opensTitle = false
        controlsEnabled = false
        checked = false
        measuredWidth = 0
        super.setHighlighted(false, animated: false)
        super.setSelected(false, animated: false)
        accessibilityElements = []
        for view in [
            self, contentView, rowButton, checkButton, nameButton, authorLabel, originLabel, groupsLabel, groupButton,
            deleteButton,
        ] {
            view.isAccessibilityElement = false
            view.accessibilityIdentifier = nil
            view.accessibilityLabel = nil
            view.accessibilityValue = nil
            view.accessibilityHint = nil
            view.accessibilityCustomActions = nil
            for tooltip in view.interactions.compactMap({ $0 as? UIToolTipInteraction }) {
                view.removeInteraction(tooltip)
            }
        }
        for button in [rowButton, checkButton, nameButton, groupButton, deleteButton] {
            button.cancelTracking(with: nil)
            button.isEnabled = false
            button.isSelected = false
            button.isHighlighted = false
            button.accessibilityTraits = [.button, .notEnabled]
            button.setTitle(nil, for: .normal)
            button.setImage(nil, for: .normal)
        }
        for label in [authorLabel, originLabel, groupsLabel] { label.text = nil }
        authorLabel.isHidden = true
        checkButton.tintColor = AndroidReplicaTheme.secondaryText
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func toggleBook() { if controlsEnabled && bookURL != nil { onToggle?() } }
    @objc private func tapTitle() {
        guard controlsEnabled, bookURL != nil else { return }
        if opensTitle { onOpen?() } else { onToggle?() }
    }
    @objc private func tapGroup() { if controlsEnabled && bookURL != nil { onGroup?() } }
    @objc private func tapDelete() { if controlsEnabled && bookURL != nil { onDelete?() } }
    @objc private func moveUp() -> Bool { controlsEnabled && bookURL != nil ? (onMove?(-1) ?? false) : false }
    @objc private func moveDown() -> Bool { controlsEnabled && bookURL != nil ? (onMove?(1) ?? false) : false }
}

@MainActor
private final class BookshelfManageCellButton: UIButton {
    private let padding: CGFloat
    private let singleLine: Bool
    private var textFont = UIFont.systemFont(ofSize: 14)
    private var fontPadding = UIEdgeInsets.zero

    init(padding: CGFloat, singleLine: Bool = false) {
        self.padding = padding
        self.singleLine = singleLine
        super.init(frame: .zero)
        configuration = nil
        clipsToBounds = true
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.adjustsFontForContentSizeCategory = false
        titleLabel?.numberOfLines = singleLine ? 1 : 0
        titleLabel?.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        imageView?.contentMode = .scaleAspectFit
        setTitleColor(AndroidReplicaTheme.secondaryText, for: .disabled)
        apply(font: BookshelfLayoutDialogStyle.font(size: 14, traits: traitCollection))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func apply(font: UIFont) {
        textFont = font
        fontPadding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        titleLabel?.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let size = textSize(width: .greatestFiniteMagnitude)
        return CGSize(width: ceil(size.width + padding * 2), height: ceil(size.height + verticalPadding))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(max(1, size.width), intrinsicContentSize.width)
        let text = textSize(width: max(1, width - padding * 2))
        return CGSize(width: width, height: ceil(text.height + verticalPadding))
    }

    private var verticalPadding: CGFloat { padding * 2 + fontPadding.top + fontPadding.bottom }

    private func textSize(width: CGFloat) -> CGSize {
        guard let title = currentTitle else { return .zero }
        if singleLine {
            return CGSize(
                width: min(width, (title as NSString).size(withAttributes: [.font: textFont]).width),
                height: textFont.lineHeight)
        }
        if width == CGFloat.greatestFiniteMagnitude {
            let size = (title as NSString).size(withAttributes: [.font: textFont])
            return CGSize(width: size.width, height: max(textFont.lineHeight, size.height))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let size = (title as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont, .paragraphStyle: paragraph], context: nil
        ).size
        return CGSize(width: size.width, height: max(textFont.lineHeight, size.height))
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        // UIButton may ask while creating titleLabel: use only the cached font insets here.
        let x = min(padding, max(0, contentRect.width / 2))
        let top = min(padding + fontPadding.top, max(0, contentRect.height))
        return CGRect(
            x: contentRect.minX + x, y: contentRect.minY + top,
            width: max(0, contentRect.width - x * 2),
            height: max(0, contentRect.height - top - padding - fontPadding.bottom))
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        let size = min(32, max(0, min(contentRect.width, contentRect.height) - padding * 2))
        return CGRect(x: contentRect.midX - size / 2, y: contentRect.midY - size / 2, width: size, height: size)
    }

    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelTracking(with: nil) }
            updateAppearance()
        }
    }

    private func updateAppearance() {
        if !isEnabled && isHighlighted { isHighlighted = false }
        alpha = isEnabled ? 1 : 0.38
        backgroundColor = isEnabled && isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear
    }
}

@MainActor
private final class BookshelfManageTextLabel: AndroidExploreTextLabel {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let measured = super.sizeThatFits(size)
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }
}
