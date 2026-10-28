import UIKit

// Legado 5f5d314: activity_arrange_book.xml, view_search.xml, bookshelf_manage.xml
// and BookshelfManageActivity.upTitle(). No separate title competes with the query.
@MainActor
final class BookshelfManageToolbar: UIView {
    let backButton = UIButton(type: .custom)
    let groupButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    let searchField: UITextField = BookshelfManageSearchField()
    var queryHint: String? { didSet { setGroupName(groupName) } }

    private let searchBackground = UIView()
    private let clearButton = UIButton(type: .custom)
    private let submitButton = UIButton(type: .custom)
    private let groupToolTip = UIToolTipInteraction(defaultToolTip: "分组")
    private var groupName = "未分组"
    private var controlsEnabled = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "bookshelf.manage.toolbar"
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        configureIcon(backButton, asset: "ReaderMenuAndroidBack", label: "返回", id: "back")
        configureIcon(groupButton, asset: "BookDetailAndroidGroups", label: "分组", id: "group")
        groupButton.addInteraction(groupToolTip)
        configureIcon(moreButton, asset: "ReaderMenuAndroidMore", label: "更多选项", id: "more")
        configureIcon(clearButton, asset: "SearchScopeAndroidClear", label: "清空筛选", id: "clearSearch")
        clearButton.addTarget(self, action: #selector(clearQuery), for: .touchUpInside)
        configureIcon(submitButton, asset: "SearchToolbarAndroidGo", label: "提交筛选", id: "submitSearch")
        submitButton.addTarget(self, action: #selector(submitFromButton), for: .touchUpInside)

        searchBackground.isUserInteractionEnabled = false
        searchBackground.isAccessibilityElement = false
        searchBackground.layer.borderWidth = 0.5
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.clipsToBounds = true
        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.smartQuotesType = .no
        searchField.smartDashesType = .no
        searchField.clearButtonMode = .never
        searchField.adjustsFontSizeToFitWidth = false
        searchField.adjustsFontForContentSizeCategory = false
        searchField.accessibilityIdentifier = "bookshelf.manage.searchField"
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchField.addTarget(self, action: #selector(queryChanged), for: [.editingDidBegin, .editingDidEnd])
        searchField.addTarget(self, action: #selector(submitQuery), for: .editingDidEndOnExit)

        for item in [searchBackground, backButton, searchField, clearButton, submitButton, groupButton, moreButton] {
            addSubview(item)
        }
        applyAppearance()
        setGroupName(groupName)
        updateQueryControls()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(56, queryHeight + 20))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: intrinsicContentSize.height)
    }

    func setGroupName(_ name: String) {
        groupName = name
        let hint = queryHint ?? "筛选 • \(name)"
        searchField.accessibilityLabel = hint
        let font = searchField.font ?? BookshelfManageChromeStyle.font(14, traits: traitCollection)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.baseWritingDirection =
            effectiveUserInterfaceLayoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        paragraph.alignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: AndroidReplicaTheme.toolbarText.withAlphaComponent(0.5),
            .paragraphStyle: paragraph,
        ]
        let placeholder = NSMutableAttributedString(string: "", attributes: attributes)
        // SearchView.kt decorates the hint, not the editable text, with an integer-size ImageSpan.
        let iconSize = floor(font.pointSize)
        if let image = BookshelfManageChromeStyle.icon("SearchToolbarAndroidHint", size: iconSize) {
            let attachment = NSTextAttachment()
            attachment.image = image.withTintColor(
                UIColor(white: 192.0 / 255, alpha: 1), renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(
                x: 0, y: (font.ascender + font.descender - iconSize) / 2, width: iconSize, height: iconSize)
            placeholder.append(NSAttributedString(string: " ", attributes: attributes))
            placeholder.append(NSAttributedString(attachment: attachment))
            placeholder.append(NSAttributedString(string: " ", attributes: attributes))
        }
        placeholder.append(NSAttributedString(string: hint, attributes: attributes))
        placeholder.addAttributes(attributes, range: NSRange(location: 0, length: placeholder.length))
        searchField.attributedPlaceholder = placeholder
        groupButton.accessibilityValue = name
        groupToolTip.defaultToolTip = "分组：\(name)"
    }

    func setEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        for button in [backButton, groupButton, moreButton, clearButton, submitButton] {
            if !enabled {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.38
        }
        searchField.isEnabled = enabled
        searchField.alpha = enabled ? 1 : 0.38
        if !enabled { searchField.resignFirstResponder() }
        updateQueryControls()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
        setGroupName(groupName)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateQueryControls()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let leading = safeAreaInsets.left
        let width = max(0, bounds.width - leading - safeAreaInsets.right)
        func place(_ view: UIView, x: CGFloat, width itemWidth: CGFloat, height: CGFloat) {
            let height = min(max(0, height), bounds.height)
            view.frame = CGRect(
                x: leading + (rtl ? width - x - itemWidth : x),
                y: max(0, (bounds.height - height) / 2), width: max(0, itemWidth), height: height)
        }
        // Toolbar menu is measured first; text yields space, never the icon targets.
        // AppCompat 1.7.1: navigation 56dp, action item 48dp, overflow 24 + 6 + 10dp.
        let preferredButtons: CGFloat = 56 + (groupButton.isHidden ? 0 : 48) + 40
        let buttonScale = min(1, width / preferredButtons)
        let backWidth = 56 * buttonScale
        let groupWidth: CGFloat = groupButton.isHidden ? 0 : 48 * buttonScale
        let moreWidth = 40 * buttonScale
        let searchLeading = backWidth
        let searchWidth = max(0, width - backWidth - groupWidth - moreWidth)
        let editMargin = min(8, searchWidth / 2)
        let editWidth = max(0, searchWidth - editMargin * 2)
        // abc_search_view has 8dp edit-frame margins, 8dp field padding and separate close/submit slots.
        let preferredQueryButtons: CGFloat = (clearButton.isHidden ? 0 : 40) + (submitButton.isHidden ? 0 : 56)
        let queryButtonScale = preferredQueryButtons > 0 ? min(1, editWidth / preferredQueryButtons) : 1
        let clearWidth: CGFloat = clearButton.isHidden ? 0 : 40 * queryButtonScale
        let submitWidth: CGFloat = submitButton.isHidden ? 0 : 56 * queryButtonScale
        let fieldWidth = max(0, editWidth - clearWidth - submitWidth)
        let fieldLeading = searchLeading + editMargin
        let controlHeight = max(36, queryHeight)
        place(backButton, x: 0, width: backWidth, height: 56)
        place(groupButton, x: width - moreWidth - groupWidth, width: groupWidth, height: 48)
        place(moreButton, x: width - moreWidth, width: moreWidth, height: 48)
        place(searchBackground, x: searchLeading, width: searchWidth, height: queryHeight)
        place(searchField, x: fieldLeading, width: fieldWidth, height: controlHeight)
        place(clearButton, x: fieldLeading + fieldWidth, width: clearWidth, height: queryHeight)
        place(submitButton, x: fieldLeading + fieldWidth + clearWidth, width: submitWidth, height: queryHeight)
        searchBackground.layer.cornerRadius = min(35, queryHeight / 2)
    }

    private var queryHeight: CGFloat {
        let font = searchField.font ?? BookshelfManageChromeStyle.font(14, traits: traitCollection)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        return max(30, ceil(font.lineHeight + padding.top + padding.bottom + 8))
    }

    private func configureIcon(_ button: UIButton, asset: String, label: String, id: String) {
        button.configuration = nil
        button.setImage(BookshelfManageChromeStyle.icon(asset), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "bookshelf.manage.\(id)"
        if button !== groupButton { button.addInteraction(UIToolTipInteraction(defaultToolTip: label)) }
    }

    private func applyAppearance() {
        (searchField as? BookshelfManageSearchField)?.apply(
            font: BookshelfManageChromeStyle.font(14, traits: traitCollection))
        searchField.textColor = AndroidReplicaTheme.toolbarText
        searchField.tintColor = AndroidReplicaTheme.toolbarText
        for button in [backButton, groupButton, moreButton, clearButton, submitButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
        }
        // bg_searchview.xml: transparent10 fill, 0.5dp stroke and 35dp corner radius.
        let fill = UIColor(white: traitCollection.userInterfaceStyle == .dark ? 1 : 0, alpha: 16.0 / 255)
        searchBackground.backgroundColor = fill
        searchBackground.layer.borderColor = fill.cgColor
    }

    private func updateQueryControls() {
        let hasQuery = !(searchField.text ?? "").isEmpty
        clearButton.isHidden = !hasQuery
        clearButton.isEnabled = controlsEnabled && hasQuery
        clearButton.alpha = controlsEnabled ? 1 : 0.38
        // isSubmitButtonEnabled=true; with no voice button, focus alone shows the go icon.
        let showsSubmit = searchField.isFirstResponder
        submitButton.isHidden = !showsSubmit
        submitButton.isEnabled = controlsEnabled && showsSubmit
        submitButton.alpha = controlsEnabled ? 1 : 0.38
        var elements: [UIView] = [backButton, searchField]
        if hasQuery { elements.append(clearButton) }
        if showsSubmit { elements.append(submitButton) }
        if !groupButton.isHidden { elements.append(groupButton) }
        elements.append(moreButton)
        accessibilityElements = elements
    }

    @objc private func queryChanged() {
        updateQueryControls()
        setNeedsLayout()
    }

    @objc private func clearQuery() {
        guard controlsEnabled else { return }
        searchField.text = ""
        searchField.becomeFirstResponder()
        searchField.sendActions(for: .editingChanged)
    }

    @objc private func submitQuery() { searchField.resignFirstResponder() }

    @objc private func submitFromButton() {
        guard controlsEnabled else { return }
        searchField.sendActions(for: .editingDidEndOnExit)
    }
}

// view_select_action_bar.xml + SelectActionBar.upCountView/setMenuClickable.
@MainActor
final class BookshelfManageSelectionBar: UIView {
    let allButton: UIButton = BookshelfManageBarButton(kind: .all)
    let invertButton: UIButton = BookshelfManageBarButton(kind: .stroke)
    let groupButton: UIButton = BookshelfManageBarButton(kind: .stroke)
    let moreButton = UIButton(type: .custom)

    private let divider = UIView()
    private var measuredWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.bottomBackground
        accessibilityIdentifier = "bookshelf.manage.selectionBar"
        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        invertButton.setTitle("反选", for: .normal)
        groupButton.setTitle("移入分组", for: .normal)
        moreButton.setImage(BookshelfManageChromeStyle.icon("ReaderMenuAndroidMore"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.primaryText
        let entries: [(UIButton, String, String)] = [
            (allButton, "全选", "selectAll"), (invertButton, "反选", "invertSelection"),
            (groupButton, "移入分组", "moveToGroup"), (moreButton, "更多选中操作", "selectionMore"),
        ]
        for (button, title, id) in entries {
            button.accessibilityLabel = title
            button.accessibilityIdentifier = "bookshelf.manage.\(id)"
            button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
            addSubview(button)
        }
        addSubview(divider)
        accessibilityElements = [allButton, invertButton, groupButton, moreButton]
        configure(selected: 0, total: 0, enabled: true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

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
        return sizeThatFits(CGSize(width: width, height: targetSize.height))
    }

    func configure(selected: Int, total: Int, enabled: Bool) {
        let selected = max(0, selected)
        let total = max(0, total)
        let allSelected = selected > 0 && selected >= total
        let title = allSelected ? "取消全选" : "全选"
        allButton.setTitle("\(title)（\(selected)/\(total)）", for: .normal)
        allButton.isSelected = allSelected
        allButton.setImage(
            BookshelfManageChromeStyle.icon(
                allSelected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff", size: 32),
            for: .normal)
        allButton.accessibilityLabel = title
        allButton.accessibilityValue = "\(selected)/\(total)"
        for tooltip in allButton.interactions.compactMap({ $0 as? UIToolTipInteraction }) {
            tooltip.defaultToolTip = title
        }
        setEnabled(enabled && total > 0, for: allButton)
        // Android deliberately disables inversion as well when the selection is empty.
        for button in [invertButton, groupButton, moreButton] { setEnabled(enabled && selected > 0, for: button) }
        updateAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        _ = arrange(width: bounds.width, apply: true)
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 0.5)
    }

    private func updateAppearance() {
        for button in [allButton, invertButton, groupButton] {
            (button as? BookshelfManageBarButton)?.apply(
                font: BookshelfManageChromeStyle.font(14, traits: traitCollection))
            (button as? BookshelfManageBarButton)?.updateAppearance()
        }
        moreButton.tintColor =
            moreButton.isEnabled
            ? AndroidReplicaTheme.primaryText : BookshelfManageChromeStyle.disabledColor(traits: traitCollection)
    }

    private func setEnabled(_ enabled: Bool, for button: UIButton) {
        if !enabled {
            button.cancelTracking(with: nil)
            button.isHighlighted = false
        }
        button.isEnabled = enabled
    }

    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let left = (rtl ? safeAreaInsets.right : safeAreaInsets.left) + 16
        let right = (rtl ? safeAreaInsets.left : safeAreaInsets.right) + 8
        let available = max(1, width - left - right)
        func place(_ view: UIView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            if apply {
                view.frame = CGRect(x: rtl ? width - left - x - w : left + x, y: y, width: w, height: h)
            }
        }
        let actions = [invertButton, groupButton, moreButton]
        let margin = min(5, available / 2)
        let sizes = actions.map { button -> CGSize in
            button === moreButton
                ? CGSize(width: min(36, available), height: 36)
                : button.sizeThatFits(CGSize(width: max(1, available - margin * 2), height: .greatestFiniteMagnitude))
        }
        let actionWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width } + margin * 4
        var y: CGFloat = 6
        // LinearLayout gives the checkbox all remaining width; its count may wrap in that slot.
        if 42 + actionWidth <= available {
            let allWidth = available - actionWidth
            let allHeight = allButton.sizeThatFits(CGSize(width: allWidth, height: .greatestFiniteMagnitude)).height
            let rowHeight = max(
                allHeight, max(sizes[0].height + margin * 2, max(sizes[1].height + margin * 2, sizes[2].height)))
            place(allButton, 0, y + (rowHeight - allHeight) / 2, allWidth, allHeight)
            var x = allWidth
            for (button, size) in zip(actions, sizes) {
                let gap: CGFloat = button === moreButton ? 0 : margin
                x += gap
                place(button, x, y + (rowHeight - size.height) / 2, size.width, size.height)
                x += size.width + gap
            }
            y += rowHeight
        } else {
            // Only split when even the 32dp mark and its padding cannot fit beside the actions.
            let allHeight = allButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
            place(allButton, 0, y, available, allHeight)
            y += allHeight
            var x = max(0, available - actionWidth)
            var rowHeight: CGFloat = 0
            for (button, size) in zip(actions, sizes) {
                let gap: CGFloat = button === moreButton ? 0 : margin
                let outerWidth = min(available, size.width + gap * 2)
                let itemWidth = max(0, outerWidth - gap * 2)
                if x > 0 && x + outerWidth > available {
                    y += rowHeight
                    x = 0
                    rowHeight = 0
                }
                place(button, x + gap, y + gap, itemWidth, size.height)
                rowHeight = max(rowHeight, size.height + gap * 2)
                x += outerWidth
            }
            y += rowHeight
        }
        return ceil(y + 6 + safeAreaInsets.bottom)
    }
}

@MainActor
private enum BookshelfManageChromeStyle {
    static func font(_ size: CGFloat, traits: UITraitCollection) -> UIFont {
        BookshelfLayoutDialogStyle.font(size: size, traits: traits)
    }

    static func icon(_ name: String, size: CGFloat = 24) -> UIImage? {
        guard let source = UIImage(named: name) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }.withRenderingMode(.alwaysTemplate)
    }

    static func disabledColor(traits: UITraitCollection) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        AndroidReplicaTheme.bottomBackground.resolvedColor(with: traits).getRed(
            &red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let light = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) >= 0.5
        return UIColor(white: light ? 0 : 1, alpha: light ? 97.0 / 255 : 77.0 / 255)
    }
}

@MainActor
private final class BookshelfManageBarButton: UIButton {
    enum Kind { case all, stroke }
    private let kind: Kind
    private var textFont = UIFont.systemFont(ofSize: 14)
    private var fontPadding = UIEdgeInsets.zero

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        configuration = nil
        clipsToBounds = true
        titleLabel?.numberOfLines = 0
        titleLabel?.lineBreakMode = .byWordWrapping
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.adjustsFontForContentSizeCategory = false
        apply(font: BookshelfManageChromeStyle.font(14, traits: traitCollection))
        imageView?.contentMode = .scaleAspectFit
        layer.cornerRadius = kind == .stroke ? 3 : 0
        layer.borderWidth = kind == .stroke ? 1 : 0
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isEnabled: Bool { didSet { updateAppearance() } }
    override var isSelected: Bool { didSet { updateAppearance() } }
    override var isHighlighted: Bool { didSet { updateAppearance() } }

    func apply(font: UIFont) {
        textFont = font
        fontPadding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        titleLabel?.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let text = textSize(width: .greatestFiniteMagnitude)
        return CGSize(
            width: max(kind == .stroke ? 72 : 42, ceil(text.width + 10 + (kind == .all ? 32 : 0))),
            height: textHeight(text.height))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(max(1, size.width), intrinsicContentSize.width)
        let text = textSize(width: max(1, width - 10 - (kind == .all ? 32 : 0)))
        return CGSize(width: width, height: textHeight(text.height))
    }

    private func textHeight(_ height: CGFloat) -> CGFloat {
        max(kind == .all ? 42 : 0, ceil(max(textFont.lineHeight, height) + 10 + fontPadding.top + fontPadding.bottom))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        titleLabel?.textAlignment = kind == .all ? (rtl ? .right : .left) : .center
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let inset = min(5, max(0, contentRect.width / 2))
        let markWidth: CGFloat = kind == .all ? min(32, max(0, contentRect.width - inset * 2)) : 0
        let top = min(5 + fontPadding.top, max(0, contentRect.height))
        return CGRect(
            x: contentRect.minX + inset + (rtl ? 0 : markWidth), y: contentRect.minY + top,
            width: max(0, contentRect.width - inset * 2 - markWidth),
            height: max(0, contentRect.height - top - 5 - fontPadding.bottom))
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        guard kind == .all else { return .zero }
        let inset = min(5, max(0, contentRect.width / 2))
        let size = min(32, max(0, min(contentRect.width - inset * 2, contentRect.height)))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        return CGRect(
            x: rtl ? contentRect.maxX - inset - size : contentRect.minX + inset,
            y: contentRect.midY - size / 2, width: size, height: size)
    }

    private func textSize(width: CGFloat) -> CGSize {
        if width == CGFloat.greatestFiniteMagnitude {
            return ((currentTitle ?? "") as NSString).size(withAttributes: [.font: textFont])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return ((currentTitle ?? "") as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: textFont, .paragraphStyle: paragraph], context: nil
        ).size
    }

    func updateAppearance() {
        if !isEnabled && isHighlighted { isHighlighted = false }
        let disabled = BookshelfManageChromeStyle.disabledColor(traits: traitCollection)
        let normal = kind == .all ? AndroidReplicaTheme.primaryText : AndroidReplicaTheme.accent
        setTitleColor(normal, for: .normal)
        setTitleColor(disabled, for: .disabled)
        tintColor = isEnabled ? (isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText) : disabled
        layer.borderColor =
            (isEnabled ? AndroidReplicaTheme.accent : disabled).resolvedColor(with: traitCollection).cgColor
        backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }
}

@MainActor
private final class BookshelfManageSearchField: UITextField {
    private var textFont = UIFont.systemFont(ofSize: 14)
    private var fontPadding = UIEdgeInsets.zero

    func apply(font: UIFont) {
        textFont = font
        fontPadding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        self.font = font
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { paddedRect(bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { paddedRect(bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { paddedRect(bounds) }

    private func paddedRect(_ bounds: CGRect) -> CGRect {
        let inset = min(8, max(0, bounds.width / 2))
        let lineHeight = textFont.lineHeight
        let paddedHeight = ceil(lineHeight + fontPadding.top + fontPadding.bottom)
        let top = max(0, (bounds.height - paddedHeight) / 2) + fontPadding.top
        return CGRect(
            x: bounds.minX + inset, y: bounds.minY + min(top, bounds.height),
            width: max(0, bounds.width - inset * 2), height: min(ceil(lineHeight), max(0, bounds.height - top)))
    }

    override func drawPlaceholder(in rect: CGRect) {
        guard let hint = attributedPlaceholder else {
            super.drawPlaceholder(in: rect)
            return
        }
        guard rect.width > 0, rect.height > 0 else { return }
        hint.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
