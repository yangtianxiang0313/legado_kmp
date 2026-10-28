import UIKit

// Legado 5f5d314: dialog_search_scope.xml, book_search_scope.xml and ThemeRadioNoButton.
// AppCompat 1.7.1: Base.V7.Widget.AppCompat.Toolbar and abc_search_view.xml.
internal enum SearchScopeStyle {
    static var toolbar: UIColor { AndroidReplicaTheme.toolbarBackground }
    static var accent: UIColor { AndroidReplicaTheme.accent }

    static let toolbarHeight: CGFloat = 56
    static let searchWidth: CGFloat = 320
    static let searchHeight: CGFloat = 48
    static let modeMargin: CGFloat = 4
    static let modePadding: CGFloat = 5
    static let actionInset: CGFloat = 10
    static let actionPadding: CGFloat = 12
    static let actionGap: CGFloat = 16

    static func font(
        _ size: CGFloat, style: UIFont.TextStyle, traits: UITraitCollection,
        weight: Int = 400
    ) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(
            size: size, textStyle: style, weight: weight, compatibleWith: traits)
    }

    static func checkedTextColor(traits: UITraitCollection) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard
            accent.resolvedColor(with: traits).getRed(
                &red, green: &green, blue: &blue, alpha: &alpha)
        else { return .white }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        // ThemeRadioNoButton uses ColorUtils.calculateLuminance(accentColor) >= 0.5.
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.5 ? .black : .white
    }

    static func icon(named name: String) -> UIImage? {
        guard let source = UIImage(named: name) else { return nil }
        let size = CGSize(width: 24, height: 24)
        if source.size == size { return source.withRenderingMode(.alwaysTemplate) }
        return UIGraphicsImageRenderer(size: size).image { _ in
            source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysTemplate)
    }
}

/// Owns the SearchView interaction; filtering and source/group state remain with the controller.
final class SearchScopeToolbarView: UIView {
    let searchField: UITextField = SearchScopeSearchField()
    var onQueryChanged: ((String) -> Void)?
    private(set) var isFilterExpanded = false

    var query: String {
        get { searchField.text ?? "" }
        set { setQuery(newValue) }
    }

    private let titleLabel = AndroidExploreTextLabel()
    private let searchButton = UIButton(type: .custom)
    private let closeButton = UIButton(type: .custom)
    private let queryUnderline = UIView()
    private let closeToolTip = UIToolTipInteraction(
        defaultToolTip: NSLocalizedString(
            "search.scope_android_clear_query", value: "清除查询", comment: "AppCompat clear query description"))
    private var isSourceMode = false
    private var controlsEnabled = true
    private var lastQuery = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SearchScopeStyle.toolbar
        accessibilityIdentifier = "searchScope.toolbar"
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 2.5
        layer.shadowOffset = CGSize(width: 0, height: 2)
        heightAnchor.constraint(greaterThanOrEqualToConstant: SearchScopeStyle.toolbarHeight).isActive = true

        titleLabel.text = L10n.Search.scopeDialogTitle
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.clipsToBounds = true
        titleLabel.isAccessibilityElement = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "searchScope.title"

        searchField.borderStyle = .none
        searchField.returnKeyType = .search
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.clearButtonMode = .never
        searchField.adjustsFontForContentSizeCategory = false
        searchField.adjustsFontSizeToFitWidth = false
        searchField.contentVerticalAlignment = .center
        searchField.textColor = AndroidReplicaTheme.toolbarText
        searchField.tintColor = AndroidReplicaTheme.toolbarText
        let searchDescription = NSLocalizedString(
            "search.scope_android_search", value: "搜索", comment: "AppCompat search description")
        searchField.accessibilityLabel = searchDescription
        searchField.accessibilityIdentifier = "SearchScopeFilter"
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchField.addTarget(self, action: #selector(submitQuery), for: .editingDidEndOnExit)
        searchField.addTarget(self, action: #selector(focusChanged), for: [.editingDidBegin, .editingDidEnd])

        configureIcon(
            searchButton, asset: "SearchScopeAndroidSearch", title: searchDescription,
            identifier: "searchScope.filterToggle")
        searchButton.addInteraction(UIToolTipInteraction(defaultToolTip: searchDescription))
        searchButton.addTarget(self, action: #selector(expandSearch), for: .touchUpInside)
        configureIcon(
            closeButton, asset: "SearchScopeAndroidClear", title: closeToolTip.defaultToolTip ?? L10n.Common.clear,
            identifier: "searchScope.filterClose")
        closeButton.addInteraction(closeToolTip)
        closeButton.addTarget(self, action: #selector(closeSearch), for: .touchUpInside)

        queryUnderline.isUserInteractionEnabled = false
        queryUnderline.isAccessibilityElement = false
        for item in [titleLabel, searchField, searchButton, closeButton, queryUnderline] { addSubview(item) }
        applyFonts()
        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let textHeight = max(titleLabel.intrinsicContentSize.height + 8, searchField.intrinsicContentSize.height + 12)
        return CGSize(width: UIView.noIntrinsicMetric, height: max(SearchScopeStyle.toolbarHeight, ceil(textHeight)))
    }

    func setSourceMode(_ isSourceMode: Bool) {
        self.isSourceMode = isSourceMode
        if !isSourceMode { searchField.resignFirstResponder() }
        // Android changes menu visibility only: screenText and the iconified state survive.
        updateVisibility()
    }

    func setControlsEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        searchButton.isEnabled = enabled
        closeButton.isEnabled = enabled
        searchField.isEnabled = enabled
        if !enabled {
            searchField.resignFirstResponder()
            for button in [searchButton, closeButton] {
                button.isHighlighted = false
                button.backgroundColor = .clear
            }
        }
        updateVisibility()
    }

    func setQuery(_ query: String, notify: Bool = false) {
        let changed = query != lastQuery
        searchField.text = query
        lastQuery = query
        updateCloseAction()
        if notify, changed { onQueryChanged?(query) }
    }

    func setFilterExpanded(_ expanded: Bool, focusSearch: Bool = true) {
        isFilterExpanded = expanded
        if !expanded { searchField.resignFirstResponder() }
        updateVisibility()
        if expanded, isSourceMode, controlsEnabled, focusSearch {
            layoutIfNeeded()
            searchField.becomeFirstResponder()
        }
    }

    func toggleFilter() {
        guard isSourceMode, controlsEnabled else { return }
        setFilterExpanded(!isFilterExpanded)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width)
        let height = max(0, bounds.height)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func rect(_ leading: CGFloat, _ itemWidth: CGFloat, _ itemHeight: CGFloat) -> CGRect {
            CGRect(
                x: isRTL ? width - leading - itemWidth : leading,
                y: (height - itemHeight) / 2, width: max(0, itemWidth), height: max(0, itemHeight))
        }

        let expanded = isSourceMode && isFilterExpanded
        // SearchView.onMeasure(AT_MOST) takes min(320dp, available). Toolbar measures
        // its menu before its title. This action has no collapseActionView flag and no
        // collapse button; a narrow toolbar can leave the title zero width.
        let actionWidth =
            isSourceMode
            ? min(expanded ? SearchScopeStyle.searchWidth : 48, max(0, width - 16)) : 0
        let actionLeading = width - actionWidth
        // Toolbar collapses its 4dp title start margin into the 16dp content inset.
        let titleLeading = min(16, width)
        let titleWidth = max(0, actionLeading - 8 - titleLeading)
        let titleFont: UIFont = titleLabel.font
        let ellipsisWidth = ("\u{2026}" as NSString).size(withAttributes: [.font: titleFont]).width
        titleLabel.isHidden = titleWidth < min(titleLabel.intrinsicContentSize.width, ellipsisWidth)
        titleLabel.textAlignment = isRTL ? .right : .left
        titleLabel.frame = rect(titleLeading, titleWidth, min(height, ceil(titleLabel.intrinsicContentSize.height)))
        let plateHeight = min(height, max(SearchScopeStyle.searchHeight, searchField.intrinsicContentSize.height + 12))
        searchButton.frame = rect(actionLeading, actionWidth, plateHeight)

        // abc_search_view: edit-frame 8dp margins, text 8dp padding, close 24+8+8dp.
        let closeWidth = min(40, max(0, actionWidth - 16))
        let closeLeading = max(actionLeading, width - 8 - closeWidth)
        let fieldLeading = min(closeLeading, actionLeading + 8)
        let fieldWidth = max(0, closeLeading - fieldLeading)
        closeButton.frame = rect(closeLeading, closeWidth, plateHeight)
        searchField.textAlignment = isRTL ? .right : .left
        searchField.frame = rect(fieldLeading, fieldWidth, min(plateHeight, searchField.intrinsicContentSize.height))
        let lineHeight: CGFloat = controlsEnabled && searchField.isFirstResponder ? 2 : 1
        queryUnderline.frame = CGRect(
            x: isRTL ? 8 : actionLeading + 8, y: (height + plateHeight) / 2 - 4,
            width: max(0, actionWidth - 16), height: lineHeight)
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isSourceMode, isFilterExpanded else { return super.accessibilityPerformEscape() }
        setFilterExpanded(false, focusSearch: false)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
    }

    private func applyFonts() {
        titleLabel.font = SearchScopeStyle.font(20, style: .headline, traits: traitCollection, weight: 500)
        // SearchAutoComplete inherits AppCompat textAppearanceMediumInverse (18sp).
        searchField.font = SearchScopeStyle.font(18, style: .body, traits: traitCollection)
        updateHint()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func configureIcon(_ button: UIButton, asset: String, title: String, identifier: String) {
        button.setImage(SearchScopeStyle.icon(named: asset), for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.tintColor = AndroidReplicaTheme.toolbarText.withAlphaComponent(0.7)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.isAccessibilityElement = true
        button.adjustsImageWhenDisabled = false
        button.adjustsImageWhenHighlighted = false
        button.clipsToBounds = true
        button.addTarget(self, action: #selector(highlightIcon(_:)), for: [.touchDown, .touchDragEnter])
        button.addTarget(
            self, action: #selector(unhighlightIcon(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    private func updateVisibility() {
        let expanded = isSourceMode && isFilterExpanded
        searchButton.isHidden = !isSourceMode || expanded
        searchField.isHidden = !expanded
        closeButton.isHidden = !expanded
        queryUnderline.isHidden = !expanded
        searchField.accessibilityElementsHidden = !expanded
        searchButton.alpha = controlsEnabled ? 1 : 0.38
        searchField.alpha = controlsEnabled ? 1 : 0.38
        closeButton.alpha = controlsEnabled ? 1 : 0.38
        queryUnderline.alpha = controlsEnabled ? 1 : 0.38
        updateCloseAction()
        setNeedsLayout()
    }

    private func updateCloseAction() {
        // abc_search_view keeps its raw "clear query" description even when empty.
        closeButton.tintColor = AndroidReplicaTheme.toolbarText.withAlphaComponent(query.isEmpty ? 0.3 : 0.7)
        queryUnderline.backgroundColor = AndroidReplicaTheme.toolbarText.withAlphaComponent(
            controlsEnabled && searchField.isFirstResponder ? 0.7 : 0.3)
        for button in [searchButton, closeButton] {
            button.accessibilityTraits = controlsEnabled ? .button : [.button, .notEnabled]
        }
        searchButton.accessibilityValue = query.isEmpty ? nil : query
    }

    private func updateHint() {
        guard let font = searchField.font, let image = SearchScopeStyle.icon(named: "SearchScopeAndroidSearch") else { return }
        // Default AppCompat SearchView decorates an empty hint with its search drawable.
        let size = floor(font.pointSize * 1.25)
        let attachment = NSTextAttachment()
        attachment.image = image.withTintColor(AndroidReplicaTheme.toolbarText.withAlphaComponent(0.3), renderingMode: .alwaysOriginal)
        attachment.bounds = CGRect(x: 0, y: (font.ascender + font.descender - size) / 2, width: size, height: size)
        let hint = NSMutableAttributedString(string: " ", attributes: [.font: font])
        hint.append(NSAttributedString(attachment: attachment))
        hint.append(NSAttributedString(string: " ", attributes: [.font: font]))
        searchField.attributedPlaceholder = hint
    }

    @objc private func focusChanged() {
        updateCloseAction()
        setNeedsLayout()
    }

    @objc private func expandSearch() {
        guard controlsEnabled else { return }
        setFilterExpanded(true)
    }

    @objc private func closeSearch() {
        guard controlsEnabled else { return }
        if query.isEmpty {
            setFilterExpanded(false, focusSearch: false)
        } else {
            setQuery("", notify: true)
            searchField.becomeFirstResponder()
        }
    }

    @objc private func queryChanged() {
        let value = query
        guard value != lastQuery else { return }
        lastQuery = value
        updateCloseAction()
        onQueryChanged?(value)
    }

    @objc private func submitQuery() {
        queryChanged()
        searchField.resignFirstResponder()
    }

    @objc private func highlightIcon(_ sender: UIButton) {
        sender.backgroundColor = AndroidReplicaTheme.toolbarText.withAlphaComponent(0.12)
    }

    @objc private func unhighlightIcon(_ sender: UIButton) {
        sender.backgroundColor = .clear
    }
}

/// The controller supplies the RadioGroup's 11dp inset; this view owns only its 4dp child margins.
final class SearchScopeModeControl: UIControl {
    var selectedSegmentIndex: Int = 0 {
        didSet {
            selectedSegmentIndex = min(max(selectedSegmentIndex, 0), 1)
            updateSelection()
        }
    }

    override var isEnabled: Bool {
        didSet { updateSelection() }
    }

    private let buttons = [
        SearchScopeTextButton(
            title: L10n.Search.scopeGroupPrefix, padding: SearchScopeStyle.modePadding, singleLine: true),
        SearchScopeTextButton(
            title: L10n.Search.sourceFallback, padding: SearchScopeStyle.modePadding, singleLine: true),
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "searchScope.mode"
        isAccessibilityElement = false
        let identifiers = ["searchScope.mode.group", "searchScope.mode.source"]
        for (index, button) in buttons.enumerated() {
            button.tag = index
            button.layer.cornerRadius = 2
            button.layer.borderWidth = 2
            button.clipsToBounds = true
            button.accessibilityIdentifier = identifiers[index]
            button.addInteraction(UIToolTipInteraction(defaultToolTip: button.accessibilityLabel ?? ""))
            button.addTarget(self, action: #selector(selectMode(_:)), for: .touchUpInside)
            addSubview(button)
        }
        applyFonts()
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: (buttons.map { $0.intrinsicContentSize.height }.max() ?? 0) + 2 * SearchScopeStyle.modeMargin)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = SearchScopeStyle.modeMargin
        let gap = SearchScopeStyle.modeMargin * 2
        let width = max(0, (bounds.width - 2 * inset - gap) / 2)
        let height = max(0, bounds.height - 2 * SearchScopeStyle.modeMargin)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (index, button) in buttons.enumerated() {
            let leading = min(bounds.width, inset) + CGFloat(index) * (width + gap)
            button.frame = CGRect(
                x: isRTL ? bounds.width - leading - width : leading,
                y: SearchScopeStyle.modeMargin, width: width, height: height)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
        updateSelection()
    }

    private func applyFonts() {
        // AppCompat RadioButton inherits textAppearance (14sp), not a 40dp button minimum.
        for button in buttons {
            button.apply(font: SearchScopeStyle.font(14, style: .subheadline, traits: traitCollection))
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedSegmentIndex
            let color = selected ? SearchScopeStyle.accent : AndroidReplicaTheme.primaryText
            button.isSelected = selected
            button.isEnabled = isEnabled
            button.alpha = isEnabled ? 1 : 0.38
            button.backgroundColor = selected ? SearchScopeStyle.accent : .clear
            button.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
            let textColor =
                selected
                ? SearchScopeStyle.checkedTextColor(traits: traitCollection) : AndroidReplicaTheme.primaryText
            button.setTextColor(textColor)
            var traits: UIAccessibilityTraits = selected ? [.button, .selected] : .button
            if !isEnabled { traits.insert(.notEnabled) }
            button.accessibilityTraits = traits
        }
    }

    @objc private func selectMode(_ sender: UIButton) {
        guard isEnabled, selectedSegmentIndex != sender.tag else { return }
        selectedSegmentIndex = sender.tag
        sendActions(for: .valueChanged)
    }
}

/// TextView-sized commands, with a weighted spacer after "all sources".
final class SearchScopeActionsView: UIView {
    var onAllSources: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let buttons = [
        SearchScopeTextButton(
            title: NSLocalizedString("search.scope_all_sources", value: "全部书源", comment: "Search scope: all sources"),
            padding: SearchScopeStyle.actionPadding),
        SearchScopeTextButton(title: L10n.Common.cancel, padding: SearchScopeStyle.actionPadding),
        SearchScopeTextButton(title: L10n.Common.confirm, padding: SearchScopeStyle.actionPadding),
    ]
    private var measuredWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        accessibilityIdentifier = "searchScope.actions"
        let identifiers = ["searchScope.allSources", "searchScope.cancel", "searchScope.confirm"]
        for (index, button) in buttons.enumerated() {
            button.tag = index
            button.setTextColor(index == 1 ? AndroidReplicaTheme.secondaryText : SearchScopeStyle.accent)
            button.clipsToBounds = true
            button.accessibilityIdentifier = identifiers[index]
            button.addTarget(self, action: #selector(performCommand(_:)), for: .touchUpInside)
            addSubview(button)
        }
        applyFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: commandLayout(width: measuredWidth).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: commandLayout(width: size.width).height)
    }

    func prepareLayout(width: CGFloat) {
        let width = max(0, width)
        guard measuredWidth != width else { return }
        measuredWidth = width
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setControlsEnabled(_ enabled: Bool) {
        for button in buttons {
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.38
            button.backgroundColor = .clear
            button.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width)
        prepareLayout(width: width)
        let layout = commandLayout(width: width)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var leading = SearchScopeStyle.actionInset
        for (index, button) in buttons.enumerated() {
            let buttonWidth = layout.widths[index]
            let buttonHeight = min(bounds.height, layout.heights[index])
            button.frame = CGRect(
                // XML uses physical marginRight, including on the final command.
                x: isRTL ? width - leading - SearchScopeStyle.actionGap - buttonWidth : leading,
                y: max(0, (bounds.height - buttonHeight) / 2),
                width: buttonWidth, height: buttonHeight)
            leading += buttonWidth + SearchScopeStyle.actionGap
            if index == 0 { leading += layout.spacer }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
    }

    private func applyFonts() {
        for button in buttons {
            button.apply(font: SearchScopeStyle.font(14, style: .subheadline, traits: traitCollection))
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func commandLayout(width: CGFloat) -> (
        widths: [CGFloat], heights: [CGFloat], height: CGFloat, spacer: CGFloat
    ) {
        let padding = 2 * SearchScopeStyle.actionPadding
        let naturalWidths = buttons.map { $0.intrinsicContentSize.width }
        // XML has a physical 16dp right margin on EACH TextView, including the last one.
        let margins = 2 * SearchScopeStyle.actionInset + 3 * SearchScopeStyle.actionGap
        let naturalTotal = naturalWidths.reduce(0, +)
        let available = width > 0 ? max(0, width - margins) : naturalTotal
        let widths: [CGFloat]
        if naturalTotal <= available {
            widths = naturalWidths
        } else {
            // Keep natural widths normally; let labels wrap with Dynamic Type or a
            // narrow presentation instead of overlapping fixed 104/64dp slots.
            let textWidths = naturalWidths.map { max(1, $0 - padding) }
            let textTotal = textWidths.reduce(0, +)
            let contentWidth = max(0, available - CGFloat(buttons.count) * padding)
            widths = textWidths.map { min(available / 3, padding) + contentWidth * $0 / textTotal }
        }
        let heights = zip(buttons, widths).map { button, buttonWidth in
            button.sizeThatFits(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude)).height
        }
        return (widths, heights, heights.max() ?? padding, max(0, available - widths.reduce(0, +)))
    }

    @objc private func performCommand(_ sender: UIButton) {
        guard sender.isEnabled else { return }
        switch sender.tag {
        case 0: onAllSources?()
        case 1: onCancel?()
        default: onConfirm?()
        }
    }

}

/// TextView/CompoundButton text without UIButton's lazily created titleLabel.
private final class SearchScopeTextButton: UIButton {
    private let textLabel = AndroidExploreTextLabel()
    private let padding: CGFloat

    init(title: String, padding: CGFloat, singleLine: Bool = false) {
        self.padding = padding
        super.init(frame: .zero)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
        textLabel.text = title
        textLabel.numberOfLines = singleLine ? 1 : 0
        textLabel.lineBreakMode = singleLine ? .byClipping : .byWordWrapping
        textLabel.textAlignment = singleLine ? .center : .natural
        textLabel.adjustsFontForContentSizeCategory = false
        textLabel.adjustsFontSizeToFitWidth = false
        textLabel.isAccessibilityElement = false
        textLabel.isUserInteractionEnabled = false
        addSubview(textLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func apply(font: UIFont) {
        textLabel.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setTextColor(_ color: UIColor) { textLabel.textColor = color }

    override var intrinsicContentSize: CGSize {
        let text = textLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: ceil(text.width) + 2 * padding, height: ceil(text.height) + 2 * padding)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = min(max(0, size.width), intrinsicContentSize.width)
        let text = textLabel.sizeThatFits(CGSize(width: max(1, width - 2 * padding), height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(text.height) + 2 * padding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontal = min(padding, max(0, bounds.width / 2))
        let vertical = min(padding, max(0, bounds.height / 2))
        textLabel.frame = bounds.insetBy(dx: horizontal, dy: vertical)
    }
}

private final class SearchScopeSearchField: UITextField {
    override var intrinsicContentSize: CGSize {
        let padding = fontPadding
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: max(36, ceil(lineHeight(includingHint: true) + padding.top + padding.bottom)))
    }

    override var font: UIFont? {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { lineRect(in: bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { lineRect(in: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { lineRect(in: bounds, includingHint: true) }

    private var fontPadding: UIEdgeInsets {
        guard let font else { return .zero }
        return AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
    }

    private func lineHeight(includingHint: Bool) -> CGFloat {
        let textHeight = font?.lineHeight ?? 0
        guard includingHint, let hint = attributedPlaceholder else { return textHeight }
        // AppCompat's 1.25-em hint drawable may be taller than the font's line box.
        let hintHeight = hint.boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
        ).height
        return max(textHeight, hintHeight)
    }

    private func lineRect(in bounds: CGRect, includingHint: Bool = false) -> CGRect {
        let padding = fontPadding
        let lineHeight = lineHeight(includingHint: includingHint)
        let paddedLineHeight = lineHeight + padding.top + padding.bottom
        let inset = min(8, max(0, bounds.width / 2))
        let top = max(0, (bounds.height - paddedLineHeight) / 2) + padding.top
        return CGRect(
            x: bounds.minX + inset, y: bounds.minY + min(top, bounds.height),
            width: max(0, bounds.width - 2 * inset),
            height: min(ceil(lineHeight), max(0, bounds.height - top - padding.bottom)))
    }
}
