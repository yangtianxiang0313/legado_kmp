import UIKit

// Legado 5f5d314: values/arrays.xml book_sort, resolved through values-zh/strings.xml.
enum BookGroupEditorSort {
    static let titles = ["默认", "按阅读时间", "按更新时间", "按书名", "手动排序", "综合排序", "按作者"]

    static func normalized(_ value: Int32) -> Int32 {
        (-1...5).contains(value) ? value : -1
    }
}

final class BookGroupEditorContentView: UIView {
    let nameTextView: UITextView = BookGroupNameTextView()
    let coverButton = UIButton(type: .custom)
    let sortButton: UIButton = BookGroupEditorSortButton(type: .custom)
    let refreshControl = BookGroupEditorRefreshControl()
    let deleteButton = BookshelfGroupManagementAction(title: "删除", padding: 6, color: AndroidReplicaTheme.accent)
    let cancelButton = BookshelfGroupManagementAction(title: "取消", padding: 6, color: AndroidReplicaTheme.accent)
    let confirmButton = BookshelfGroupManagementAction(title: "确认", padding: 6, color: AndroidReplicaTheme.accent)
    var onLayoutChange: (() -> Void)?

    private let toolbar = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private let formBackground = UIView()
    private let coverImageView = UIImageView()
    private let coverIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var nameField = BookInfoEditField(title: "分组名称", editor: nameTextView)
    private let sortLabel = AndroidExploreTextLabel()
    private let errorLabel = AndroidExploreTextLabel()
    private let showsDelete: Bool

    init(title: String, name: String, showsDelete: Bool) {
        self.showsDelete = showsDelete
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 2
        clipsToBounds = true
        accessibilityIdentifier = "bookDetail.groups.editor"
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        formBackground.backgroundColor = AndroidReplicaTheme.menuBackground
        titleLabel.text = title
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookDetail.groups.editor.title"
        busyIndicator.color = AndroidReplicaTheme.toolbarText
        busyIndicator.hidesWhenStopped = true
        busyIndicator.isAccessibilityElement = false
        busyIndicator.isUserInteractionEnabled = false
        coverImageView.contentMode = .scaleAspectFill
        coverImageView.clipsToBounds = true
        coverImageView.isUserInteractionEnabled = false
        coverImageView.isAccessibilityElement = false
        coverIndicator.hidesWhenStopped = true
        coverIndicator.color = AndroidReplicaTheme.accent
        coverIndicator.isUserInteractionEnabled = false
        coverButton.accessibilityLabel = "封面"
        coverButton.accessibilityIdentifier = "bookDetail.groups.editor.cover"
        coverButton.addInteraction(UIToolTipInteraction(defaultToolTip: "封面"))
        coverButton.clipsToBounds = true
        coverButton.backgroundColor = AndroidReplicaTheme.coverBackground
        nameTextView.text = name
        nameTextView.textColor = AndroidReplicaTheme.primaryText
        nameTextView.tintColor = AndroidReplicaTheme.accent
        nameTextView.backgroundColor = .clear
        nameTextView.textContainerInset = .zero
        nameTextView.textContainer.lineFragmentPadding = 0
        // Like maxLines=2 on Android EditText, the viewport is two lines; long names remain editable.
        nameTextView.isScrollEnabled = true
        nameTextView.textContainer.lineBreakMode = .byWordWrapping
        nameTextView.autocorrectionType = .no
        nameTextView.accessibilityLabel = "分组名称"
        nameTextView.accessibilityIdentifier = "bookDetail.groups.editor.name"
        sortLabel.text = "排序"
        sortLabel.numberOfLines = 0
        sortLabel.textColor = AndroidReplicaTheme.accent
        sortLabel.isAccessibilityElement = false
        sortButton.contentHorizontalAlignment = .leading
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.accessibilityLabel = "排序"
        sortButton.accessibilityIdentifier = "bookDetail.groups.editor.sort"
        refreshControl.accessibilityIdentifier = "bookDetail.groups.editor.refresh"
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "bookDetail.groups.editor.error"
        for (button, identifier) in [
            (deleteButton, "delete"), (cancelButton, "cancel"), (confirmButton, "confirm"),
        ] {
            button.isExclusiveTouch = true
            button.accessibilityIdentifier = "bookDetail.groups.editor.\(identifier)"
            addSubview(button)
        }
        deleteButton.isHidden = !showsDelete
        for child in [
            toolbar, formBackground, coverButton, nameField, sortLabel,
            sortButton, refreshControl, errorLabel,
        ] {
            addSubview(child)
        }
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(busyIndicator)
        coverButton.addSubview(coverImageView)
        coverButton.addSubview(coverIndicator)
        accessibilityElements =
            [titleLabel, coverButton, nameTextView, sortButton, refreshControl, errorLabel]
            + (showsDelete ? [deleteButton, cancelButton, confirmButton] : [cancelButton, confirmButton])
        setCoverImage(nil)
        refreshTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshTypography()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: max(1, size.width), apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, apply: true)
        coverImageView.frame = coverButton.bounds
        coverIndicator.center = CGPoint(x: coverButton.bounds.midX, y: coverButton.bounds.midY)
    }

    func setNameEditing(_: Bool) {
        nameField.refreshAppearanceAndFields()
        setNeedsLayout()
    }

    func setCoverImage(_ image: UIImage?) {
        coverImageView.image = image ?? UIImage(named: "BookshelfAndroidCoverDefault")
        coverButton.accessibilityValue = image == nil ? "默认封面" : "已设置封面"
    }

    func setCoverLoading(_ loading: Bool) {
        loading ? coverIndicator.startAnimating() : coverIndicator.stopAnimating()
    }

    func setSort(_ value: Int32) {
        let text = BookGroupEditorSort.titles[Int(BookGroupEditorSort.normalized(value) + 1)]
        sortButton.setTitle(text, for: .normal)
        sortButton.accessibilityValue = text
        setNeedsLayout()
        onLayoutChange?()
    }

    func setBusy(_ busy: Bool, importing: Bool) {
        let editable = !busy && !importing
        nameTextView.isEditable = editable
        nameTextView.isSelectable = editable
        coverButton.isEnabled = editable
        sortButton.isEnabled = editable
        refreshControl.isEnabled = editable
        deleteButton.isEnabled = editable
        confirmButton.isEnabled = editable
        cancelButton.isEnabled = !busy
        busy || importing ? busyIndicator.startAnimating() : busyIndicator.stopAnimating()
        nameField.refreshAppearanceAndFields()
    }

    func setError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        setNeedsLayout()
        onLayoutChange?()
    }

    private func refreshTypography() {
        func font(_ size: CGFloat, _ style: UIFont.TextStyle = .body) -> UIFont {
            ReaderAndroidDefaultFont.scaledFont(size: size, textStyle: style, compatibleWith: traitCollection)
        }
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        nameField.refreshAppearanceAndFields()
        sortLabel.font = font(14)
        errorLabel.font = font(14, .footnote)
        for label in [titleLabel, sortLabel, errorLabel] { label.adjustsFontForContentSizeCategory = false }
        (sortButton as? BookGroupEditorSortButton)?.refreshAppearance()
        for button in [deleteButton, cancelButton, confirmButton] {
            button.apply(font: font(14))
        }
        setNeedsLayout()
        onLayoutChange?()
    }

    // The original 90x126 cover and 6dp margins remain fixed; constrained widths reflow, not shrink text.
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func place(_ item: UIView, _ rect: CGRect) {
            guard apply else { return }
            var frame = rect
            if rtl { frame.origin.x = width - frame.maxX }
            item.frame = frame
        }
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: max(1, width - 68), height: .greatestFiniteMagnitude)
        ).height
        let toolbarHeight = max(56, ceil(titleHeight) + 8)
        place(toolbar, CGRect(x: 0, y: 0, width: width, height: toolbarHeight))
        if apply {
            titleLabel.frame = CGRect(
                x: rtl ? 48 : 20, y: (toolbarHeight - titleHeight) / 2,
                width: max(1, width - 68), height: titleHeight)
            busyIndicator.center = CGPoint(x: rtl ? 26 : width - 26, y: toolbarHeight / 2)
        }
        let bodyFont = nameTextView.font ?? .systemFont(ofSize: 18)
        let stacked =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            || width - 108 < max(156, bodyFont.pointSize * 8)
        let fieldsX: CGFloat = stacked ? 6 : 102
        let fieldsWidth = max(1, width - fieldsX - 6)
        let coverY = toolbarHeight + 6
        place(coverButton, CGRect(x: stacked ? (width - 90) / 2 : 6, y: coverY, width: 90, height: 126))
        var y = stacked ? coverY + 132 : toolbarHeight + 6
        let insets = nameTextView.textContainerInset
        let minimumEditorHeight = ceil(bodyFont.lineHeight + insets.top + insets.bottom)
        let maximumEditorHeight = ceil(bodyFont.lineHeight * 2 + insets.top + insets.bottom)
        let naturalEditorHeight = nameTextView.sizeThatFits(
            CGSize(width: fieldsWidth, height: .greatestFiniteMagnitude)
        ).height
        let editorHeight = min(maximumEditorHeight, max(minimumEditorHeight, ceil(naturalEditorHeight)))
        let inputHeight = nameField.minimumContentHeight + editorHeight - minimumEditorHeight
        place(nameField, CGRect(x: fieldsX, y: y, width: fieldsWidth, height: inputHeight))
        y += inputHeight
        let sortFont = sortLabel.font ?? .systemFont(ofSize: 14)
        let labelWidth = min(fieldsWidth, ceil(("排序" as NSString).size(withAttributes: [.font: sortFont]).width) + 6)
        let inlineSortWidth = fieldsWidth - labelWidth - 6
        let inlineSort = inlineSortWidth >= bodyFont.pointSize * 6
        let menuWidth = inlineSort ? inlineSortWidth : fieldsWidth
        let menuHeight = sortButton.sizeThatFits(
            CGSize(width: menuWidth, height: .greatestFiniteMagnitude)
        ).height
        let labelHeight =
            ceil(
                sortLabel.sizeThatFits(
                    CGSize(
                        width: max(1, (inlineSort ? labelWidth : fieldsWidth) - 6), height: .greatestFiniteMagnitude)
                ).height) + 6
        if inlineSort {
            let rowHeight = max(labelHeight, menuHeight)
            place(
                sortLabel,
                CGRect(
                    x: fieldsX + 3, y: y + (rowHeight - labelHeight) / 2,
                    width: max(1, labelWidth - 3), height: labelHeight))
            place(sortButton, CGRect(x: fieldsX + labelWidth + 6, y: y, width: menuWidth, height: rowHeight))
            y += rowHeight
        } else {
            place(sortLabel, CGRect(x: fieldsX + 3, y: y, width: max(1, fieldsWidth - 3), height: labelHeight))
            y += labelHeight
            place(sortButton, CGRect(x: fieldsX, y: y, width: menuWidth, height: menuHeight))
            y += menuHeight
        }
        let refreshHeight = refreshControl.sizeThatFits(
            CGSize(width: fieldsWidth, height: .greatestFiniteMagnitude)
        ).height
        place(refreshControl, CGRect(x: fieldsX, y: y, width: fieldsWidth, height: refreshHeight))
        y = max(y + refreshHeight + 6, coverY + 132)
        place(formBackground, CGRect(x: 0, y: toolbarHeight, width: width, height: y - toolbarHeight))
        if !errorLabel.isHidden {
            let errorHeight = ceil(
                errorLabel.sizeThatFits(
                    CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)
                ).height)
            place(errorLabel, CGRect(x: 12, y: y + 8, width: max(1, width - 24), height: errorHeight))
            y += errorHeight + 16
        }
        let available = max(1, width - 24)
        func buttonSize(_ button: BookshelfGroupManagementAction) -> CGSize {
            button.sizeThatFits(CGSize(width: min(available, button.preferredWidth), height: .greatestFiniteMagnitude))
        }
        let cancelSize = buttonSize(cancelButton)
        let confirmSize = buttonSize(confirmButton)
        let deleteSize = buttonSize(deleteButton)
        let trailingWidth = cancelSize.width + 24 + confirmSize.width
        y += 12
        if showsDelete, deleteSize.width + 24 + trailingWidth > available {
            place(deleteButton, CGRect(origin: CGPoint(x: 12, y: y), size: deleteSize))
            y += deleteSize.height + 12
        }
        if trailingWidth > available {
            place(cancelButton, CGRect(origin: CGPoint(x: width - 12 - cancelSize.width, y: y), size: cancelSize))
            y += cancelSize.height + 12
            place(confirmButton, CGRect(origin: CGPoint(x: width - 12 - confirmSize.width, y: y), size: confirmSize))
            y += confirmSize.height
        } else {
            let rowHeight = max(cancelSize.height, confirmSize.height)
            if showsDelete, deleteSize.width + 24 + trailingWidth <= available {
                place(
                    deleteButton,
                    CGRect(x: 12, y: y, width: deleteSize.width, height: max(rowHeight, deleteSize.height)))
            }
            place(cancelButton, CGRect(x: width - 12 - trailingWidth, y: y, width: cancelSize.width, height: rowHeight))
            place(
                confirmButton,
                CGRect(
                    x: width - 12 - confirmSize.width, y: y,
                    width: confirmSize.width, height: rowHeight))
            y += max(rowHeight, showsDelete ? deleteSize.height : 0)
        }
        return ceil(y + 12)
    }
}

// AppCompat's original 32dp checkbox drawable, shared with the search-scope dialog.
final class BookGroupEditorRefreshControl: UIControl {
    private let mark = UIImageView()
    private let label = AndroidExploreTextLabel()

    override var isSelected: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.45
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
            updateAppearance()
        }
    }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = "允许下拉刷新"
        mark.contentMode = .scaleAspectFit
        mark.isUserInteractionEnabled = false
        label.text = "允许下拉刷新"
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textColor = AndroidReplicaTheme.primaryText
        label.isUserInteractionEnabled = false
        for child in [mark, label] {
            child.isAccessibilityElement = false
            addSubview(child)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = label.sizeThatFits(
            CGSize(width: max(1, size.width - 32), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: max(44, ceil(height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        mark.frame = CGRect(x: rtl ? bounds.width - 32 : 0, y: (bounds.height - 32) / 2, width: 32, height: 32)
        let textWidth = max(0, bounds.width - 32)
        let height = min(
            bounds.height,
            label.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            ).height)
        label.frame = CGRect(
            x: rtl ? 0 : 32, y: (bounds.height - height) / 2, width: textWidth, height: height)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, window != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func updateAppearance() {
        mark.image = UIImage(named: isSelected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
            .withRenderingMode(.alwaysTemplate)
        mark.tintColor = isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        label.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
        label.adjustsFontForContentSizeCategory = false
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = isSelected ? "已选中" : "未选中"
        setNeedsLayout()
    }
}

private final class BookGroupEditorSortButton: UIButton {
    private var textFont = UIFont.systemFont(ofSize: 16)
    private var textPadding = UIEdgeInsets.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byClipping
        titleLabel?.textAlignment = .natural
        titleLabel?.adjustsFontForContentSizeCategory = false
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func refreshAppearance() {
        textFont = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        textPadding = AndroidExploreTextMetrics.padding(font: textFont, scale: traitCollection.displayScale)
        titleLabel?.font = textFont
        setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .disabled)
        setBackgroundImage(BookInfoEditTypeButton.spinnerBackground(compatibleWith: traitCollection), for: .normal)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearance()
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width =
            BookGroupEditorSort.titles.map {
                ($0 as NSString).size(withAttributes: [.font: textFont]).width
            }.max() ?? 0
        return CGSize(width: min(max(0, size.width), ceil(width) + 36), height: max(44, visualHeight))
    }

    private var visualHeight: CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return max(32, ceil((textFont.lineHeight + textPadding.top + textPadding.bottom + 15) * scale) / scale)
    }

    override func backgroundRect(forBounds bounds: CGRect) -> CGRect {
        let height = min(bounds.height, visualHeight)
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        let visual = backgroundRect(forBounds: contentRect)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return CGRect(
            x: visual.minX + (rtl ? 24 : 12), y: visual.minY + 7 + textPadding.top,
            width: max(0, visual.width - 36),
            height: max(0, visual.height - 15 - textPadding.top - textPadding.bottom))
    }
}

private final class BookGroupNameTextView: UITextView {
    private let textClip = CAShapeLayer()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        layer.mask = textClip
    }

    convenience init() { self.init(frame: .zero, textContainer: nil) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Match TextView's extended-padding clip without limiting TextKit's editable text layout.
        let textRect = CGRect(
            x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - textContainerInset.bottom))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textClip.frame = bounds
        textClip.path = CGPath(rect: textRect, transform: nil)
        CATransaction.commit()
    }
}
