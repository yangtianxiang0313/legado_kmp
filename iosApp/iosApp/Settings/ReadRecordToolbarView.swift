import UIKit

// Legado 5f5d31404: view_search.xml / book_read_record.xml.
final class ReadRecordToolbarView: NavigationToolbarView {
    let backButton: UIButton = ReadRecordToolbarButton(type: .custom)
    let searchField: UITextField = ReadRecordSearchTextField(frame: .zero)
    let sortButton: UIButton = ReadRecordToolbarButton(type: .custom)
    let moreButton: UIButton = ReadRecordToolbarButton(type: .custom)

    var onBack: (() -> Void)?
    var onQueryChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onSort: (() -> Void)?
    var onMore: (() -> Void)?

    private enum Metrics {
        static let minimumHeight: CGFloat = 56
        static let slot: CGFloat = 48
        static let searchHeight: CGFloat = 30
        static let verticalPadding: CGFloat = 10
        static let editMargin: CGFloat = 8
        static let textInset: CGFloat = 8
        static let clearWidth: CGFloat = 40
        static let submitWidth: CGFloat = 56
    }

    private let searchBackground = UIView()
    private let focusTarget = UIControl()
    private let clearButton = ReadRecordToolbarButton(type: .custom)
    private let submitButton = ReadRecordToolbarButton(type: .custom)
    private let queryHint = NSLocalizedString("readRecord.queryHint", value: "搜索", comment: "Android search")
    private var interactionEnabled = true
    private var lastQuery = ""
    private var measuredWidth: CGFloat = 0
    private var placeholderColor = UIColor.white.withAlphaComponent(0.5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        clipsToBounds = true
        searchBackground.isUserInteractionEnabled = false
        searchBackground.isAccessibilityElement = false
        searchBackground.layer.borderWidth = 0.5
        addSubview(searchBackground)
        focusTarget.isAccessibilityElement = false
        focusTarget.addTarget(self, action: #selector(focusSearch), for: .touchUpInside)
        addSubview(focusTarget)

        configure(
            backButton, image: ReaderMenuAndroidIcon.back.image(), label: L10n.Reader.backAction,
            identifier: "readRecord.back", action: #selector(backTapped))
        configure(
            sortButton, image: Self.sortImage, label: L10n.Bookshelf.sortMenuTitle,
            identifier: "readRecord.sort", action: #selector(sortTapped))
        configure(
            moreButton, image: ReaderMenuAndroidIcon.more.image(), label: L10n.Reader.menuMore,
            identifier: "readRecord.more", action: #selector(moreTapped))
        configure(
            clearButton, image: ReaderMenuAndroidIcon.clear.image(),
            label: NSLocalizedString(
                "readRecord.clearQuery", value: "清除查询", comment: "SearchView clear query"),
            identifier: "readRecord.search.clear", action: #selector(clearQuery))
        configure(
            submitButton, image: Self.image(named: "SearchToolbarAndroidGo"), label: queryHint,
            identifier: "readRecord.search.submit", action: #selector(submitQuery))

        searchField.accessibilityIdentifier = "readRecord.search"
        searchField.accessibilityLabel = queryHint
        searchField.placeholder = queryHint
        searchField.borderStyle = .none
        searchField.clearButtonMode = .never
        searchField.backgroundColor = .clear
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.spellCheckingType = .no
        searchField.smartQuotesType = .no
        searchField.smartDashesType = .no
        searchField.adjustsFontForContentSizeCategory = false
        searchField.adjustsFontSizeToFitWidth = false
        searchField.contentVerticalAlignment = .center
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        searchField.addTarget(self, action: #selector(submitQuery), for: .editingDidEndOnExit)
        searchField.addTarget(self, action: #selector(updateQueryControls), for: [.editingDidBegin, .editingDidEnd])
        addSubview(searchField)
        heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumHeight).isActive = true
        applyTypography()
        applyPalette()
        updateQueryControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var searchHeight: CGFloat {
        guard let font = searchField.font else { return Metrics.searchHeight }
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        return max(Metrics.searchHeight, ceil(font.lineHeight + padding.top + padding.bottom))
    }

    private func arrangement(width: CGFloat) -> (height: CGFloat, actionRows: Int, stacked: Bool) {
        let available = max(0, width - safeAreaInsets.left - safeAreaInsets.right)
        let minimumSearch =
            3 * (searchField.font?.pointSize ?? 14)
            + 2 * (Metrics.editMargin + Metrics.textInset) + Metrics.clearWidth + Metrics.submitWidth
        let stacked = available > 0 && available < 3 * Metrics.slot + minimumSearch
        let actionRows = available >= 3 * Metrics.slot || !stacked ? 1 : (available >= 2 * Metrics.slot ? 2 : 3)
        let height =
            stacked
            ? CGFloat(actionRows) * Metrics.slot + searchHeight + 2 * Metrics.verticalPadding
            : max(Metrics.minimumHeight, searchHeight + 2 * Metrics.verticalPadding)
        return (height, actionRows, stacked)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: arrangement(width: bounds.width).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrangement(width: size.width).height)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        sizeThatFits(targetSize)
    }

    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        for button in [backButton, sortButton, moreButton, clearButton, submitButton] {
            button.isEnabled = enabled
            if !enabled {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
        }
        searchField.isEnabled = enabled
        focusTarget.isEnabled = enabled
        if !enabled { focusTarget.cancelTracking(with: nil) }
        updateQueryControls()
    }

    func setQuery(_ query: String, notify: Bool = false) {
        let changed = query != lastQuery
        searchField.text = query
        lastQuery = query
        updateQueryControls()
        if notify, changed, interactionEnabled { onQueryChange?(query) }
    }

    @objc func updateQueryControls() {
        clearButton.isHidden = (searchField.text ?? "").isEmpty
        submitButton.isHidden = !searchField.isFirstResponder
        clearButton.isEnabled = interactionEnabled && !clearButton.isHidden
        submitButton.isEnabled = interactionEnabled && !submitButton.isHidden
        var elements: [UIView] = [backButton, searchField]
        if !clearButton.isHidden { elements.append(clearButton) }
        if !submitButton.isHidden { elements.append(submitButton) }
        elements.append(contentsOf: [sortButton, moreButton])
        accessibilityElements = elements
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        let content = bounds.inset(
            by: UIEdgeInsets(
                top: 0, left: safeAreaInsets.left, bottom: 0, right: safeAreaInsets.right))
        let width = max(0, content.width)
        let layout = arrangement(width: bounds.width)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func rect(_ leading: CGFloat, _ y: CGFloat, _ itemWidth: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rtl ? content.maxX - leading - itemWidth : content.minX + leading,
                y: content.minY + y, width: max(0, itemWidth), height: max(0, height))
        }
        let navigationY = layout.stacked ? 0 : max(0, (bounds.height - Metrics.slot) / 2)
        backButton.frame = rect(0, navigationY, Metrics.slot, Metrics.slot)
        let sortY = layout.actionRows > 1 ? Metrics.slot : navigationY
        let moreY = layout.actionRows == 3 ? 2 * Metrics.slot : sortY
        sortButton.frame = rect(max(0, width - 2 * Metrics.slot), sortY, Metrics.slot, Metrics.slot)
        moreButton.frame = rect(max(0, width - Metrics.slot), moreY, Metrics.slot, Metrics.slot)

        let searchLeading = layout.stacked ? min(10, width / 2) : Metrics.slot
        let searchWidth = max(0, width - (layout.stacked ? 2 * searchLeading : 3 * Metrics.slot))
        let searchY =
            layout.stacked
            ? CGFloat(layout.actionRows) * Metrics.slot + Metrics.verticalPadding
            : max(0, (bounds.height - searchHeight) / 2)
        searchBackground.frame = rect(searchLeading, searchY, searchWidth, searchHeight)
        searchBackground.layer.cornerRadius = min(35, searchHeight / 2)
        let touchHeight = max(44, searchHeight)
        let touchY = searchY + (searchHeight - touchHeight) / 2
        focusTarget.frame = rect(searchLeading, touchY, searchWidth, touchHeight)

        let clearWidth = clearButton.isHidden ? 0 : Metrics.clearWidth
        let submitWidth = submitButton.isHidden ? 0 : Metrics.submitWidth
        // Reduce SearchView's internal margins first, not its font or outer action slots.
        let reserved = clearWidth + submitWidth
        let paddingScale = min(1, max(0, (searchWidth - reserved - (searchField.font?.pointSize ?? 14)) / 32))
        let margin = min(Metrics.editMargin * paddingScale, searchWidth / 2)
        let editorWidth = max(0, searchWidth - 2 * margin)
        let goWidth = min(submitWidth, editorWidth)
        let closeWidth = min(clearWidth, max(0, editorWidth - goWidth))
        let textWidth = max(0, editorWidth - goWidth - closeWidth)
        let inset = min(Metrics.textInset * paddingScale, textWidth / 2)
        let editorLeading = searchLeading + margin
        searchField.textAlignment = rtl ? .right : .left
        searchField.frame = rect(editorLeading + inset, searchY, max(0, textWidth - 2 * inset), searchHeight)
        clearButton.frame = rect(editorLeading + textWidth, touchY, closeWidth, touchHeight)
        submitButton.frame = rect(editorLeading + textWidth + closeWidth, touchY, goWidth, touchHeight)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTypography()
        applyPalette()
    }

    private func configure(_ button: UIButton, image: UIImage?, label: String, identifier: String, action: Selector) {
        button.configuration = nil
        button.adjustsImageWhenHighlighted = false
        button.adjustsImageWhenDisabled = false
        button.setImage(image, for: .normal)
        button.imageView?.contentMode = .center
        button.clipsToBounds = true
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func applyTypography() {
        searchField.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        updatePlaceholder()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func applyPalette() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        let primary = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        let light = Self.isLight(primary)
        let textColor = UIColor(white: light ? 0 : 1, alpha: light ? 222.0 / 255 : 1)
        let iconColor = UIColor(white: light ? 0 : 1, alpha: light ? 138.0 / 255 : 179.0 / 255)
        for button in [backButton, sortButton, moreButton] { button.tintColor = iconColor }
        clearButton.tintColor = textColor
        submitButton.tintColor = textColor
        searchField.textColor = textColor
        searchField.tintColor = UIColor(white: light ? 33.0 / 255 : 250.0 / 255, alpha: 1)
        placeholderColor = UIColor(white: light ? 0 : 1, alpha: light ? 0.38 : 0.5)
        let night =
            traitCollection.userInterfaceStyle == .dark
            && UserDefaults.standard.string(forKey: "theme_mode") != "E_INK"
        let fill = UIColor(white: night ? 1 : 0, alpha: 16.0 / 255)
        searchBackground.backgroundColor = fill
        searchBackground.layer.borderColor = fill.cgColor
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        guard let font = searchField.font else { return }
        let paragraph = NSMutableParagraphStyle()
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        paragraph.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        paragraph.alignment = rtl ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: placeholderColor, .paragraphStyle: paragraph,
        ]
        let hint = NSMutableAttributedString(string: "", attributes: attributes)
        let size = floor(font.pointSize)
        if let image = Self.image(named: "SearchToolbarAndroidHint", size: size) {
            let attachment = NSTextAttachment()
            attachment.image = image.withTintColor(
                UIColor(white: 192.0 / 255, alpha: 1), renderingMode: .alwaysOriginal)
            attachment.bounds = CGRect(
                x: 0, y: (font.ascender + font.descender - size) / 2, width: size, height: size)
            hint.append(NSAttributedString(string: " ", attributes: attributes))
            hint.append(NSAttributedString(attachment: attachment))
            hint.append(NSAttributedString(string: " ", attributes: attributes))
        }
        hint.append(NSAttributedString(string: queryHint, attributes: attributes))
        hint.addAttributes(attributes, range: NSRange(location: 0, length: hint.length))
        searchField.attributedPlaceholder = hint
    }

    private static func isLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) >= 0.5
    }

    private static func image(named name: String, size: CGFloat = 24) -> UIImage? {
        guard let source = UIImage(named: name) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }.withRenderingMode(.alwaysTemplate)
    }

    // Original ic_baseline_sort_24.xml consists of three filled rectangles, without autoMirrored.
    private static let sortImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { renderer in
        renderer.cgContext.setFillColor(UIColor.white.cgColor)
        renderer.cgContext.fill([
            CGRect(x: 3, y: 16, width: 6, height: 2),
            CGRect(x: 3, y: 6, width: 18, height: 2),
            CGRect(x: 3, y: 11, width: 12, height: 2),
        ])
    }.withRenderingMode(.alwaysTemplate)

    @objc private func queryChanged() {
        updateQueryControls()
        guard interactionEnabled else { return }
        let query = searchField.text ?? ""
        guard query != lastQuery else { return }
        lastQuery = query
        onQueryChange?(query)
    }

    @objc private func submitQuery() {
        guard interactionEnabled else { return }
        queryChanged()
        guard interactionEnabled else { return }
        searchField.resignFirstResponder()
        updateQueryControls()
        onSubmit?()
    }

    @objc private func clearQuery() {
        guard interactionEnabled, clearButton.isEnabled else { return }
        searchField.text = ""
        searchField.becomeFirstResponder()
        searchField.sendActions(for: .editingChanged)
    }

    @objc private func focusSearch() {
        guard interactionEnabled else { return }
        searchField.becomeFirstResponder()
    }

    @objc private func backTapped() {
        guard interactionEnabled, backButton.isEnabled else { return }
        onBack?()
    }

    @objc private func sortTapped() {
        guard interactionEnabled, sortButton.isEnabled else { return }
        onSort?()
    }

    @objc private func moreTapped() {
        guard interactionEnabled, moreButton.isEnabled else { return }
        onMore?()
    }
}

private final class ReadRecordToolbarButton: UIButton {
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? tintColor.withAlphaComponent(0.12) : .clear }
    }

    override var isEnabled: Bool {
        didSet { alpha = isEnabled ? 1 : 0.38 }
    }
}

private final class ReadRecordSearchTextField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { lineRect(in: bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { lineRect(in: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { lineRect(in: bounds) }

    private func lineRect(in bounds: CGRect) -> CGRect {
        guard let font else { return bounds }
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        let lineHeight = ceil(font.lineHeight)
        let top = max(0, (bounds.height - lineHeight - padding.top - padding.bottom) / 2) + padding.top
        return CGRect(
            x: bounds.minX, y: bounds.minY + min(top, bounds.height), width: max(0, bounds.width),
            height: min(lineHeight, max(0, bounds.height - top - padding.bottom)))
    }

    override func drawPlaceholder(in rect: CGRect) {
        guard let hint = attributedPlaceholder, rect.width > 0 else { return }
        let height = ceil(hint.size().height)
        hint.draw(
            with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
}
