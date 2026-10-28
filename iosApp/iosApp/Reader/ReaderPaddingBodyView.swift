import CoreText
import UIKit

final class ReaderPaddingBodyView: UIView {
    var minimumContentWidth: CGFloat {
        // Preserve the 60/24/track/24/60 columns, including the track's 16dp end padding.
        max(236, max(headerView.minimumContentWidth, footerView.minimumContentWidth) + 20)
    }

    var onFieldChange: ((ReaderPaddingField, Int32) -> Void)?
    var onHeaderLineChange: ((Bool) -> Void)?
    var onFooterLineChange: ((Bool) -> Void)?
    var canInteract: (() -> Bool)?

    private let headerView = ReaderPaddingSectionHeaderView(
        title: "页眉", titleInsets: .zero, bottomInset: 10, hasToggle: true)
    private let bodyTitleView = ReaderPaddingSectionHeaderView(
        title: "正文", titleInsets: UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0))
    private let footerView = ReaderPaddingSectionHeaderView(
        title: "页脚", titleInsets: UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0), hasToggle: true)
    private var sections: [(header: ReaderPaddingSectionHeaderView, rows: [AndroidReaderStyleSliderRow])] = []
    private var rowHeightConstraints: [NSLayoutConstraint] = []
    private var interactionEnabled = true

    private var allowsInteraction: Bool { interactionEnabled && (canInteract?() ?? true) }

    var initialAccessibilityElement: UIView { headerView.titleLabel }

    init(values: ReaderPaddingValues) {
        super.init(frame: .zero)
        headerView.setChecked(values.showHeaderLine)
        footerView.setChecked(values.showFooterLine)
        headerView.onToggle = { [weak self] in self?.onHeaderLineChange?($0) }
        footerView.onToggle = { [weak self] in self?.onFooterLineChange?($0) }
        headerView.toggleIdentifier = "readerAppearance.padding.header.line"
        footerView.toggleIdentifier = "readerAppearance.padding.footer.line"
        sections = [
            (
                headerView,
                makeRows([.headerTop, .headerBottom, .headerLeft, .headerRight], prefix: "header", values: values)
            ),
            (bodyTitleView, makeRows([.bodyTop, .bodyBottom, .bodyLeft, .bodyRight], prefix: "body", values: values)),
            (
                footerView,
                makeRows([.footerTop, .footerBottom, .footerLeft, .footerRight], prefix: "footer", values: values)
            ),
        ]
        for section in sections {
            section.header.canInteract = { [weak self] in self?.allowsInteraction ?? false }
            addSubview(section.header)
            section.rows.forEach(addSubview)
        }
        updateRowFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layoutContent(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layoutContent(width: bounds.width, applyFrames: true)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateRowFonts()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    func apply(palette: ReaderMenuPalette) {
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let textColor = ReaderPaletteColor.argb(isNight ? 0xFFFF_FFFF : 0xDE00_0000)
        for section in sections {
            section.header.apply(palette: palette)
            for row in section.rows {
                row.apply(palette: palette)
                // Padding DetailSeekBars do not set isBottomBackground or follow the book's paper.
                for view in row.arrangedSubviews {
                    if let label = view as? UILabel { label.textColor = textColor }
                    if let button = view as? UIButton { button.tintColor = textColor }
                }
            }
        }
    }

    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        if !enabled { cancelPendingTracking() }
        for section in sections {
            section.header.setInteractionEnabled(enabled)
            for row in section.rows { row.setInteractionEnabled(enabled) }
        }
    }

    func cancelPendingTracking() {
        for section in sections {
            for row in section.rows { row.cancelPendingTracking() }
        }
    }

    private func makeRows(
        _ fields: [ReaderPaddingField], prefix: String, values: ReaderPaddingValues
    ) -> [AndroidReaderStyleSliderRow] {
        zip(fields, ["top", "bottom", "left", "right"]).map { field, suffix in
            let row = AndroidReaderStyleSliderRow(
                title: field.title, identifier: "readerAppearance.padding.\(prefix).\(suffix)")
            row.canInteract = { [weak self] in self?.allowsInteraction ?? false }
            row.useAndroidCompactLayout(step: 1)
            row.valueFormatter = { String(Int($0.rounded())) }
            row.configure(min: 0, max: Float(field.maximum)) { [weak self] value in
                guard let self, self.allowsInteraction, value.isFinite else { return }
                let integer = Int32(min(max(0, value.rounded()), Float(field.maximum)))
                self.onFieldChange?(field, integer)
            }
            let value = values.values[field] ?? 0
            row.set(value: Float(value), text: String(value))
            for case let label as UILabel in row.arrangedSubviews {
                // view_detail_seek_bar.xml uses singleLine, not wrapped or auto-shrunk text.
                label.numberOfLines = 1
                label.lineBreakMode = .byTruncatingTail
                label.adjustsFontSizeToFitWidth = false
                label.adjustsFontForContentSizeCategory = false
            }
            let height = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 25)
            height.isActive = true
            rowHeightConstraints.append(height)
            return row
        }
    }

    private func updateRowFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        let height = max(25, readerPaddingTextHeight(font: font, traits: traitCollection))
        for constraint in rowHeightConstraints { constraint.constant = height }
        for section in sections {
            for row in section.rows {
                for case let label as UILabel in row.arrangedSubviews { label.font = font }
            }
        }
    }

    private func layoutContent(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let innerWidth = max(1, width - 20)
        var y: CGFloat = 10
        for section in sections {
            let headerHeight = section.header.sizeThatFits(
                CGSize(width: innerWidth, height: .greatestFiniteMagnitude)
            ).height
            if applyFrames {
                section.header.frame = CGRect(x: 10, y: y, width: innerWidth, height: headerHeight)
            }
            y += headerHeight
            for row in section.rows {
                let size = row.systemLayoutSizeFitting(
                    CGSize(width: innerWidth, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                let height = max(25, ceil(size.height))
                if applyFrames { row.frame = CGRect(x: 10, y: y, width: innerWidth, height: height) }
                y += height
            }
        }
        return ceil(y + 10)
    }
}

private final class ReaderPaddingSectionHeaderView: UIView {
    let titleLabel = UILabel()
    var onToggle: ((Bool) -> Void)?
    var canInteract: (() -> Bool)?
    var toggleIdentifier: String? {
        didSet { lineButton.accessibilityIdentifier = toggleIdentifier }
    }

    private let titleInsets: UIEdgeInsets
    private let bottomInset: CGFloat
    private let hasToggle: Bool
    private let lineButton = UIButton(type: .custom)
    private let lineLabel = UILabel()
    private let lineIndicator = ReaderAndroidCheckIndicatorView()
    private var palette: ReaderMenuPalette?

    var minimumContentWidth: CGFloat {
        let titleWidth = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width)
        guard hasToggle else { return titleWidth }
        let lineWidth = ceil(
            lineLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width)
        return titleWidth + lineWidth + 32
    }

    init(title: String, titleInsets: UIEdgeInsets, bottomInset: CGFloat = 0, hasToggle: Bool = false) {
        self.titleInsets = titleInsets
        self.bottomInset = bottomInset
        self.hasToggle = hasToggle
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        if hasToggle {
            lineLabel.text = "显示分隔线"
            lineLabel.numberOfLines = 0
            lineLabel.lineBreakMode = .byCharWrapping
            lineLabel.adjustsFontForContentSizeCategory = false
            lineLabel.isAccessibilityElement = true
            lineLabel.isUserInteractionEnabled = false
            addSubview(lineLabel)
            lineButton.addSubview(lineIndicator)
            lineButton.isAccessibilityElement = true
            lineButton.accessibilityLabel = "\(title)，显示分隔线"
            lineButton.addTarget(self, action: #selector(toggleLine), for: .touchUpInside)
            addSubview(lineButton)
        }
        updateFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = measure(width: size.width)
        return CGSize(width: size.width, height: metrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = measure(width: bounds.width)
        let rowHeight = bounds.height - bottomInset
        let titleBlockHeight = metrics.titleHeight + titleInsets.top + titleInsets.bottom
        let titlePadding = readerPaddingFontInsets(font: titleLabel.font, traits: traitCollection)
        titleLabel.frame = CGRect(
            x: titleInsets.left,
            y: (rowHeight - titleBlockHeight) / 2 + titleInsets.top + titlePadding.top,
            width: max(1, metrics.titleWidth - titleInsets.left - titleInsets.right),
            height: metrics.titleHeight - titlePadding.top - titlePadding.bottom)
        guard hasToggle else { return }
        let linePadding = readerPaddingFontInsets(font: lineLabel.font, traits: traitCollection)
        lineLabel.frame = CGRect(
            x: metrics.titleWidth, y: (rowHeight - metrics.toggleHeight) / 2 + linePadding.top,
            width: max(1, bounds.width - metrics.titleWidth - 32),
            height: metrics.toggleHeight - linePadding.top - linePadding.bottom)
        // SmoothCheckBox is a separate 20dp view with 6dp margins; its caption is not clickable.
        lineButton.frame = CGRect(
            x: bounds.width - 26, y: (rowHeight - 20) / 2, width: 20, height: 20)
        lineIndicator.frame = lineButton.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
    }

    func setChecked(_ checked: Bool) {
        lineButton.isSelected = checked
        updateToggleAccessibility()
        lineButton.accessibilityValue = checked ? L10n.Settings.enabled : L10n.Settings.disabled
        updateCheckIndicator()
    }

    func setInteractionEnabled(_ enabled: Bool) {
        lineButton.isEnabled = enabled
        if !enabled {
            lineButton.cancelTracking(with: nil)
            lineButton.isHighlighted = false
        }
        updateToggleAccessibility()
    }

    func apply(palette: ReaderMenuPalette) {
        self.palette = palette
        titleLabel.textColor = palette.accent
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        lineLabel.textColor = ReaderPaletteColor.argb(isNight ? 0xFFFF_FFFF : 0xDE00_0000)
        updateCheckIndicator()
    }

    private func updateFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .headline, compatibleWith: traitCollection)
        lineLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        setNeedsLayout()
    }

    private func updateCheckIndicator() {
        lineIndicator.apply(
            checked: lineButton.isSelected, accent: palette?.accent ?? AndroidReplicaTheme.accent,
            isNight: ReaderPaletteColor.isNightResource(traits: traitCollection))
    }

    private func updateToggleAccessibility() {
        lineButton.accessibilityTraits = lineButton.isSelected ? [.button, .selected] : .button
        if !lineButton.isEnabled { lineButton.accessibilityTraits.insert(.notEnabled) }
    }

    private func measure(width: CGFloat) -> (
        height: CGFloat, titleWidth: CGFloat, titleHeight: CGFloat, toggleHeight: CGFloat
    ) {
        let width = max(1, width)
        var titleWidth = width
        var toggleHeight: CGFloat = 0
        if hasToggle {
            let naturalToggleWidth =
                ceil(
                    lineLabel.sizeThatFits(
                        CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                    ).width) + 32
            let toggleWidth = min(naturalToggleWidth, max(32, width - 1))
            titleWidth = width - toggleWidth
            let padding = readerPaddingFontInsets(font: lineLabel.font, traits: traitCollection)
            toggleHeight =
                ceil(
                    lineLabel.sizeThatFits(
                        CGSize(width: max(1, toggleWidth - 32), height: .greatestFiniteMagnitude)
                    ).height)
                + padding.top + padding.bottom
        }
        let padding = readerPaddingFontInsets(font: titleLabel.font, traits: traitCollection)
        let titleHeight =
            ceil(
                titleLabel.sizeThatFits(
                    CGSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude)
                ).height) + padding.top + padding.bottom
        let height =
            max(titleHeight + titleInsets.top + titleInsets.bottom, max(hasToggle ? 32 : 0, toggleHeight)) + bottomInset
        return (ceil(height), titleWidth, titleHeight, toggleHeight)
    }

    @objc private func toggleLine() {
        guard hasToggle, lineButton.isEnabled, canInteract?() ?? true else { return }
        setChecked(!lineButton.isSelected)
        onToggle?(lineButton.isSelected)
    }
}

// TextView defaults to includeFontPadding; measure the resource font, not just the visible glyphs.
private func readerPaddingFontInsets(font: UIFont, traits: UITraitCollection) -> UIEdgeInsets {
    let bounds = CTFontGetBoundingBox(font as CTFont)
    let scale = max(1, traits.displayScale)
    return UIEdgeInsets(
        top: max(0, ceil(bounds.maxY * scale) / scale - font.ascender), left: 0,
        bottom: max(0, -floor(bounds.minY * scale) / scale + font.descender), right: 0)
}

private func readerPaddingTextHeight(font: UIFont, traits: UITraitCollection) -> CGFloat {
    let insets = readerPaddingFontInsets(font: font, traits: traits)
    return ceil(font.lineHeight) + insets.top + insets.bottom
}
