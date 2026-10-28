import UIKit

/// dialog_tip_config.xml at Legado 5f5d314; the presenter owns scrolling and safe-area placement.
final class ReaderTipBodyView: UIView {
    // The host keeps this width in narrow windows and exposes horizontal scrolling.
    static let minimumContentWidth: CGFloat = 280

    var onChange: ((ReaderTipChange) -> Void)?
    var onSelect: ((ReaderTipSelection) -> Void)?
    var initialAccessibilityElement: UIView { titleLabel }
    var accessibilityFocusElement: UIView {
        if let lastSelectionRow { return lastSelectionRow }
        return initialAccessibilityElement
    }

    private var values: ReaderTipValues
    private let titleLabel = UILabel()
    private let titleModeControl = ReaderTipTitleModeControl()
    private let titleSizeRow = AndroidReaderStyleSliderRow(title: "字号", identifier: "readerAppearance.tip.title.size")
    private let titleTopRow = AndroidReaderStyleSliderRow(title: "上边距", identifier: "readerAppearance.tip.title.top")
    private let titleBottomRow = AndroidReaderStyleSliderRow(
        title: "下边距", identifier: "readerAppearance.tip.title.bottom")
    private var sections: [(title: UILabel, rows: [ReaderTipValueControl])] = []
    private var selectionRows: [ReaderTipSelection: ReaderTipValueControl] = [:]
    private weak var lastSelectionRow: ReaderTipValueControl?
    private var trackingSliders: Set<ObjectIdentifier> = []

    private var sliderRows: [AndroidReaderStyleSliderRow] { [titleSizeRow, titleTopRow, titleBottomRow] }

    init(values: ReaderTipValues) {
        self.values = values
        super.init(frame: .zero)
        backgroundColor = .clear
        configureHeading(titleLabel, title: "正文标题")
        addSubview(titleLabel)
        addSubview(titleModeControl)
        configureSliders()
        sliderRows.forEach(addSubview)
        addSection(title: "页眉", selections: [.headerMode, .headerLeft, .headerMiddle, .headerRight])
        addSection(title: "页脚", selections: [.footerMode, .footerLeft, .footerMiddle, .footerRight])
        addSection(title: "页眉&页脚", selections: [.tipColor, .dividerColor])
        titleModeControl.onChange = { [weak self] mode in self?.commit(.titleMode(mode)) }
        var orderedElements: [UIView] = [titleLabel, titleModeControl]
        orderedElements.append(contentsOf: sliderRows)
        for section in sections {
            orderedElements.append(section.title)
            orderedElements.append(contentsOf: section.rows)
        }
        accessibilityElements = orderedElements
        updateFonts()
        refreshValues()
        apply(palette: ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func update(values: ReaderTipValues) {
        guard self.values != values else { return }
        self.values = values
        refreshValues()
    }

    func apply(palette: ReaderMenuPalette) {
        titleLabel.textColor = palette.accent
        titleModeControl.apply(palette: palette)
        let textColor = ReaderPaletteColor.argb(
            ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0xFFFF_FFFF : 0xDE00_0000)
        for row in sliderRows {
            row.apply(palette: palette)
            // DetailSeekBar defaults to @color/primaryText, not bottomBackground contrast.
            for view in row.arrangedSubviews {
                if let label = view as? UILabel { label.textColor = textColor }
                if let button = view as? UIButton { button.tintColor = textColor }
            }
        }
        for section in sections {
            section.title.textColor = palette.accent
            for row in section.rows { row.apply(palette: palette) }
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = contentWidth(for: size.width)
        return CGSize(width: width, height: layoutContent(width: width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layoutContent(width: contentWidth(for: bounds.width), applyFrames: true)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        invalidateContentLayout()
    }

    private func configureHeading(_ label: UILabel, title: String) {
        label.text = title
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = true
        label.accessibilityTraits = .header
    }

    private func addSection(title: String, selections: [ReaderTipSelection]) {
        let label = UILabel()
        configureHeading(label, title: title)
        addSubview(label)
        let rows = selections.map { selection in
            let row = ReaderTipValueControl(selection: selection, sectionTitle: title)
            row.addAction(
                UIAction { [weak self, weak row] _ in
                    guard let self, let row else { return }
                    self.lastSelectionRow = row
                    self.onSelect?(selection)
                }, for: .touchUpInside)
            selectionRows[selection] = row
            addSubview(row)
            return row
        }
        sections.append((label, rows))
    }

    private func configureSliders() {
        for row in sliderRows {
            row.useAndroidCompactLayout(step: 1)
            row.valueFormatter = { value in
                guard value.isFinite else { return "0" }
                return String(Int(min(max(value.rounded(), 0), 100)))
            }
            for case let slider as UISlider in row.arrangedSubviews {
                slider.addTarget(self, action: #selector(sliderTrackingBegan), for: .touchDown)
                slider.addTarget(
                    self, action: #selector(sliderTrackingEnded),
                    for: [.touchUpInside, .touchUpOutside, .touchCancel])
            }
            // DetailSeekBar keeps single-line text inside its fixed 60dp label columns.
            for case let label as UILabel in row.arrangedSubviews {
                label.numberOfLines = 1
                label.lineBreakMode = .byTruncatingTail
                label.adjustsFontSizeToFitWidth = false
                label.adjustsFontForContentSizeCategory = false
                label.preferredMaxLayoutWidth = 60
            }
        }
        titleSizeRow.configure(min: 0, max: 10) { [weak self] value in
            guard value.isFinite else { return }
            self?.commit(.titleSize(value))
        }
        titleTopRow.configure(min: 0, max: 100) { [weak self] value in
            guard value.isFinite else { return }
            self?.commit(.titleTopSpacing(Int32(min(max(value.rounded(), 0), 100))))
        }
        titleBottomRow.configure(min: 0, max: 100) { [weak self] value in
            guard value.isFinite else { return }
            self?.commit(.titleBottomSpacing(Int32(min(max(value.rounded(), 0), 100))))
        }
    }

    private func refreshValues() {
        titleModeControl.update(mode: values.titleMode)
        refreshSliderValues()
        for (selection, row) in selectionRows {
            row.update(value: displayedValue(for: selection))
        }
        invalidateContentLayout()
    }

    private func displayedValue(for selection: ReaderTipSelection) -> String {
        let text = values.text(for: selection)
        guard selection == .tipColor || selection == .dividerColor, text.hasPrefix("#") else { return text }
        let digits = text.dropFirst()
        guard digits.count == 6 || digits.count == 8, let color = UInt32(digits, radix: 16) else { return text }
        // TipConfigDialog displays Int.hexString (Integer.toHexString), without changing the stored color.
        let argb = digits.count == 6 ? color | 0xFF00_0000 : color
        return "#\(String(argb, radix: 16))"
    }

    private func commit(_ change: ReaderTipChange) {
        guard let change = change.normalized, values.apply(change) else { return }
        refreshValues()
        onChange?(change)
    }

    private func refreshSliderValues() {
        let rowValues: [(AndroidReaderStyleSliderRow, Float)] = [
            (titleSizeRow, values.titleSize), (titleTopRow, Float(values.titleTopSpacing)),
            (titleBottomRow, Float(values.titleBottomSpacing)),
        ]
        for (row, value) in rowValues {
            guard let slider = row.arrangedSubviews.first(where: { $0 is UISlider }) as? UISlider,
                !slider.isTracking, !trackingSliders.contains(ObjectIdentifier(slider))
            else { continue }
            let input = value.isFinite ? value : slider.minimumValue
            let normalized = min(max(input, slider.minimumValue), slider.maximumValue).rounded()
            guard slider.value != normalized else { continue }
            row.set(value: normalized, text: "")
        }
    }

    @objc private func sliderTrackingBegan(_ slider: UISlider) {
        trackingSliders.insert(ObjectIdentifier(slider))
    }

    @objc private func sliderTrackingEnded(_ slider: UISlider) {
        trackingSliders.remove(ObjectIdentifier(slider))
        // Let the row's own end-tracking target commit before filling any deferred values.
        DispatchQueue.main.async { [weak self] in self?.refreshSliderValues() }
    }

    private func updateFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .headline, compatibleWith: traitCollection)
        titleLabel.font = font
        for section in sections { section.title.font = font }
        setNeedsLayout()
    }

    private func invalidateContentLayout() {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func contentWidth(for width: CGFloat) -> CGFloat {
        width.isFinite ? max(Self.minimumContentWidth, width) : Self.minimumContentWidth
    }

    private func layoutContent(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset: CGFloat = 16
        let innerWidth = width - inset * 2
        var y = inset

        func place(_ view: UIView) {
            let height = ceil(view.sizeThatFits(CGSize(width: innerWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames { view.frame = CGRect(x: inset, y: y, width: innerWidth, height: height) }
            y += height
        }

        place(titleLabel)
        place(titleModeControl)
        for row in sliderRows {
            let rowWidth = innerWidth - 6
            let measured = row.systemLayoutSizeFitting(
                CGSize(width: rowWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            let height = max(25, ceil(measured.height))
            if applyFrames {
                row.frame = CGRect(x: inset + 3, y: y + 3, width: rowWidth, height: height)
            }
            y += height + 6
        }
        for section in sections {
            place(section.title)
            section.rows.forEach(place)
        }
        return ceil(y + inset)
    }
}
