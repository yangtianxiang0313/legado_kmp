import UIKit

final class ReaderTipTitleModeControl: UIView {
    var onChange: ((Int32) -> Void)?

    private var buttons: [ReaderTipRadioButton] = []
    private var mode: Int32 = 0

    init() {
        super.init(frame: .zero)
        for (index, title) in ReaderTipText.titleModes.enumerated() {
            let button = ReaderTipRadioButton(title: title, mode: Int32(index))
            button.addAction(
                UIAction { [weak self] _ in
                    guard let self, self.mode != Int32(index) else { return }
                    self.update(mode: Int32(index))
                    self.onChange?(Int32(index))
                }, for: .touchUpInside)
            buttons.append(button)
            addSubview(button)
        }
        accessibilityElements = buttons
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func update(mode: Int32) {
        self.mode = (0...2).contains(mode) ? mode : 0
        for (index, button) in buttons.enumerated() {
            let selected = Int32(index) == self.mode
            if button.isSelected != selected { button.isSelected = selected }
        }
    }

    func apply(palette: ReaderMenuPalette) {
        for button in buttons { button.apply(palette: palette) }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: buttonLayout(width: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for (button, frame) in zip(buttons, buttonLayout(width: bounds.width).frames) {
            button.frame = frame
        }
    }

    private func buttonLayout(width: CGFloat) -> (height: CGFloat, frames: [CGRect]) {
        let width = max(1, width)
        var frames: [CGRect] = []
        var rowStart = 0
        var rowHeight: CGFloat = 0
        var x: CGFloat = 0
        var y: CGFloat = 0

        func finishRow() {
            for index in rowStart..<frames.count {
                frames[index].origin.y = y + (rowHeight - frames[index].height) / 2
            }
            y += rowHeight
            x = 0
            rowHeight = 0
            rowStart = frames.count
        }

        for button in buttons {
            let buttonWidth = min(width, button.naturalWidth)
            if x > 0, x + buttonWidth > width { finishRow() }
            let height = button.sizeThatFits(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude)).height
            frames.append(CGRect(x: x, y: y, width: buttonWidth, height: height))
            x += buttonWidth
            rowHeight = max(rowHeight, height)
        }
        finishRow()
        return (ceil(y), frames)
    }
}

private final class ReaderTipRadioButton: ReaderMenuPressButton {
    private let optionLabel = UILabel()
    private let radioImageView = UIImageView()
    private let pressedView = UIView()
    private var palette: ReaderMenuPalette?
    // AppCompat btn_radio_*_mtrl: 32dp canvas, 20dp outer ring and 10dp selected dot.
    private let symbolWidth: CGFloat = 32

    var naturalWidth: CGFloat {
        ceil(
            optionLabel.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width) + symbolWidth + 6
    }

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { updateSelection() } }
    }

    override var isHighlighted: Bool {
        didSet { updatePressedAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateSelection() }
    }

    init(title: String, mode: Int32) {
        super.init(frame: .zero)
        showsBorderlessFeedback = false
        optionLabel.text = title
        optionLabel.numberOfLines = 0
        optionLabel.lineBreakMode = .byWordWrapping
        optionLabel.adjustsFontForContentSizeCategory = false
        optionLabel.isAccessibilityElement = false
        radioImageView.contentMode = .center
        radioImageView.isAccessibilityElement = false
        pressedView.isUserInteractionEnabled = false
        pressedView.isAccessibilityElement = false
        addSubview(pressedView)
        addSubview(radioImageView)
        addSubview(optionLabel)
        isAccessibilityElement = true
        accessibilityIdentifier = "readerAppearance.tip.title.mode.\(mode)"
        accessibilityLabel = String(format: ReaderTipText.accessibilityPairFormat, ReaderTipText.bodyTitle, title)
        updateFonts()
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func apply(palette: ReaderMenuPalette) {
        self.palette = palette
        updateSelection()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleHeight = optionLabel.sizeThatFits(
            CGSize(width: max(1, size.width - symbolWidth - 6), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: ceil(max(symbolWidth, titleHeight)) + 6)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleWidth = max(1, bounds.width - symbolWidth - 6)
        let titleHeight = ceil(
            optionLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            ).height)
        radioImageView.frame = CGRect(
            x: 3, y: (bounds.height - symbolWidth) / 2, width: symbolWidth, height: symbolWidth)
        // Widget.Material.CompoundButton.RadioButton uses a 20dp-radius borderless ripple.
        pressedView.frame = CGRect(x: radioImageView.frame.midX - 20, y: bounds.midY - 20, width: 40, height: 40)
        pressedView.layer.cornerRadius = 20
        optionLabel.frame = CGRect(
            x: symbolWidth + 3, y: (bounds.height - titleHeight) / 2, width: titleWidth, height: titleHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        updateSelection()
        superview?.setNeedsLayout()
    }

    private func updateFonts() {
        optionLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        setNeedsLayout()
    }

    private static let uncheckedImage = radioImage(selected: false)
    private static let checkedImage = radioImage(selected: true)

    private static func radioImage(selected: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            UIColor.black.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 18, height: 18))
            ring.lineWidth = 2
            ring.stroke()
            if selected {
                UIColor.black.setFill()
                UIBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 10, height: 10)).fill()
            }
        }.withRenderingMode(.alwaysTemplate)
    }

    private func updateSelection() {
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let normal = ReaderPaletteColor.argb(isNight ? 0xB3FF_FFFF : 0x8A00_0000)
        let accent = palette?.accent ?? AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        optionLabel.textColor = ReaderPaletteColor.argb(
            isEnabled ? (isNight ? 0xFFFF_FFFF : 0xDE00_0000) : (isNight ? 0x4DFF_FFFF : 0x3900_0000))
        radioImageView.image = isSelected ? Self.checkedImage : Self.uncheckedImage
        radioImageView.tintColor = isEnabled && isSelected ? accent : normal
        radioImageView.alpha = isEnabled ? 1 : (isNight ? 0.30 : 0.26)
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = isSelected ? ReaderTipText.selected : ReaderTipText.notSelected
        updatePressedAppearance()
    }

    private func updatePressedAppearance() {
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let accent = palette?.accent ?? AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        // Plain RadioButton inherits control_highlight_material, not ThemeRadioButton's tint override.
        pressedView.backgroundColor =
            isSelected
            ? accent.withAlphaComponent(0.26)
            : ReaderPaletteColor.argb(isNight ? 0x33FF_FFFF : 0x1F00_0000)
        pressedView.isHidden = !isHighlighted || !isEnabled
    }
}

final class ReaderTipValueControl: ReaderMenuPressButton {
    private let optionLabel = UILabel()
    private let valueLabel = UILabel()

    override var isEnabled: Bool {
        didSet { accessibilityTraits = isEnabled ? .button : [.button, .notEnabled] }
    }

    init(selection: ReaderTipSelection, sectionTitle: String) {
        super.init(frame: .zero)
        showsBorderlessFeedback = false
        optionLabel.text = selection.title
        // XML places the wrap_content value at the trailing edge without changing text gravity.
        valueLabel.textAlignment = .left
        for label in [optionLabel, valueLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            addSubview(label)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "readerAppearance.tip.\(selection.rawValue)"
        accessibilityLabel = String(format: ReaderTipText.accessibilityPairFormat, sectionTitle, selection.title)
        updateFonts()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func update(value: String) {
        guard valueLabel.text != value else { return }
        valueLabel.text = value
        accessibilityValue = value
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    func apply(palette _: ReaderMenuPalette) {
        // These TextViews explicitly use values[-night]/colors.xml, independent of menu contrast.
        let textColor = ReaderPaletteColor.argb(
            ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0xFFFF_FFFF : 0xDE00_0000)
        optionLabel.textColor = textColor
        valueLabel.textColor = textColor
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = measure(width: size.width)
        return CGSize(width: size.width, height: metrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = measure(width: bounds.width)
        optionLabel.frame = metrics.titleFrame
        valueLabel.frame = metrics.valueFrame
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        superview?.setNeedsLayout()
    }

    private func updateFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        optionLabel.font = font
        valueLabel.font = font
        setNeedsLayout()
    }

    private func measure(width: CGFloat) -> (
        height: CGFloat, titleFrame: CGRect, valueFrame: CGRect
    ) {
        // Preserve weighted title + wrap_content value and each TextView's 6dp padding.
        let textWidth = max(2, width - 24)
        let unconstrained = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let naturalTitleWidth = ceil(optionLabel.sizeThatFits(unconstrained).width)
        let naturalValueWidth = ceil(valueLabel.sizeThatFits(unconstrained).width)
        let stacked = naturalTitleWidth + naturalValueWidth > textWidth
        let titleWidth = stacked ? max(1, width - 12) : textWidth - naturalValueWidth
        let valueWidth = stacked ? min(naturalValueWidth, max(1, width - 12)) : naturalValueWidth
        let titleHeight = ceil(
            optionLabel.sizeThatFits(
                CGSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude)
            ).height)
        let valueHeight = ceil(
            valueLabel.sizeThatFits(
                CGSize(width: max(1, valueWidth), height: .greatestFiniteMagnitude)
            ).height)
        if stacked {
            return (
                titleHeight + valueHeight + 24,
                CGRect(x: 6, y: 6, width: titleWidth, height: titleHeight),
                CGRect(x: width - valueWidth - 6, y: titleHeight + 18, width: valueWidth, height: valueHeight)
            )
        }
        let height = max(titleHeight, valueHeight) + 12
        return (
            height,
            CGRect(x: 6, y: (height - titleHeight) / 2, width: titleWidth, height: titleHeight),
            CGRect(x: titleWidth + 18, y: (height - valueHeight) / 2, width: valueWidth, height: valueHeight)
        )
    }
}
