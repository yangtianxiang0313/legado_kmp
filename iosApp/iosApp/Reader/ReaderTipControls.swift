import UIKit

final class ReaderTipTitleModeControl: UIView {
    var onChange: ((Int32) -> Void)?

    private var buttons: [ReaderTipRadioButton] = []
    private var mode: Int32 = 0

    init() {
        super.init(frame: .zero)
        for (index, title) in ["靠左", "居中", "隐藏"].enumerated() {
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
        let widths = buttonWidths(for: size.width)
        let height =
            zip(buttons, widths).map { button, width in
                button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            }.max() ?? 0
        return CGSize(width: size.width, height: ceil(height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x: CGFloat = 0
        for (button, width) in zip(buttons, buttonWidths(for: bounds.width)) {
            button.frame = CGRect(x: x, y: 0, width: width, height: bounds.height)
            x += width
        }
    }

    private func buttonWidths(for width: CGFloat) -> [CGFloat] {
        let natural = buttons.map(\.naturalWidth)
        guard natural.reduce(0, +) > width else { return natural }
        return Array(repeating: max(1, width / CGFloat(max(1, buttons.count))), count: buttons.count)
    }
}

private final class ReaderTipRadioButton: UIControl {
    private let titleLabel = UILabel()
    private let radioImageView = UIImageView()
    private let pressedView = UIView()
    private var palette: ReaderMenuPalette?
    // AppCompat btn_radio_*_mtrl: 32dp canvas, 20dp outer ring and 10dp selected dot.
    private let symbolWidth: CGFloat = 32

    var naturalWidth: CGFloat {
        ceil(
            titleLabel.sizeThatFits(
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
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.isAccessibilityElement = false
        radioImageView.contentMode = .center
        radioImageView.isAccessibilityElement = false
        pressedView.isUserInteractionEnabled = false
        pressedView.isAccessibilityElement = false
        addSubview(pressedView)
        addSubview(radioImageView)
        addSubview(titleLabel)
        isAccessibilityElement = true
        accessibilityIdentifier = "readerAppearance.tip.title.mode.\(mode)"
        accessibilityLabel = "正文标题，\(title)"
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

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: max(1, size.width - symbolWidth - 6), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: ceil(max(symbolWidth, titleHeight)) + 6)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleWidth = max(1, bounds.width - symbolWidth - 6)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            ).height)
        radioImageView.frame = CGRect(
            x: 3, y: (bounds.height - symbolWidth) / 2, width: symbolWidth, height: symbolWidth)
        // Widget.Material.CompoundButton.RadioButton uses a 20dp-radius borderless ripple.
        pressedView.frame = CGRect(x: radioImageView.frame.midX - 20, y: bounds.midY - 20, width: 40, height: 40)
        pressedView.layer.cornerRadius = 20
        titleLabel.frame = CGRect(
            x: symbolWidth + 3, y: (bounds.height - titleHeight) / 2, width: titleWidth, height: titleHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        updateSelection()
        superview?.setNeedsLayout()
    }

    private func updateFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
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
        titleLabel.textColor = ReaderPaletteColor.argb(
            isEnabled ? (isNight ? 0xFFFF_FFFF : 0xDE00_0000) : (isNight ? 0x4DFF_FFFF : 0x3900_0000))
        radioImageView.image = isSelected ? Self.checkedImage : Self.uncheckedImage
        radioImageView.tintColor = isEnabled && isSelected ? accent : normal
        radioImageView.alpha = isEnabled ? 1 : (isNight ? 0.30 : 0.26)
        accessibilityTraits = isSelected ? [.button, .selected] : .button
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = isSelected ? "已选择" : "未选择"
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

final class ReaderTipValueControl: UIControl {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()

    override var isEnabled: Bool {
        didSet { accessibilityTraits = isEnabled ? .button : [.button, .notEnabled] }
    }

    init(selection: ReaderTipSelection, sectionTitle: String) {
        super.init(frame: .zero)
        titleLabel.text = selection.title
        // XML places the wrap_content value at the trailing edge without changing text gravity.
        valueLabel.textAlignment = .left
        for label in [titleLabel, valueLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            addSubview(label)
        }
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "readerAppearance.tip.\(selection.rawValue)"
        accessibilityLabel = "\(sectionTitle)，\(selection.title)"
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
        setNeedsLayout()
    }

    func apply(palette _: ReaderMenuPalette) {
        // These TextViews explicitly use values[-night]/colors.xml, independent of menu contrast.
        let textColor = ReaderPaletteColor.argb(
            ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0xFFFF_FFFF : 0xDE00_0000)
        titleLabel.textColor = textColor
        valueLabel.textColor = textColor
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = measure(width: size.width)
        return CGSize(width: size.width, height: metrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = measure(width: bounds.width)
        titleLabel.frame = CGRect(
            x: 6, y: (bounds.height - metrics.titleHeight) / 2,
            width: metrics.titleWidth, height: metrics.titleHeight)
        valueLabel.frame = CGRect(
            x: metrics.titleWidth + 18, y: (bounds.height - metrics.valueHeight) / 2,
            width: metrics.valueWidth, height: metrics.valueHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        superview?.setNeedsLayout()
    }

    private func updateFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        titleLabel.font = font
        valueLabel.font = font
        setNeedsLayout()
    }

    private func measure(width: CGFloat) -> (
        height: CGFloat, titleWidth: CGFloat, valueWidth: CGFloat, titleHeight: CGFloat, valueHeight: CGFloat
    ) {
        // Each XML TextView has its own 6dp padding; leave both text columns room to wrap.
        let textWidth = max(2, width - 24)
        let unconstrained = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let naturalTitleWidth = ceil(titleLabel.sizeThatFits(unconstrained).width)
        let naturalValueWidth = ceil(valueLabel.sizeThatFits(unconstrained).width)
        let reservedTitleWidth = min(naturalTitleWidth, textWidth * 0.4)
        let valueWidth = min(naturalValueWidth, textWidth - reservedTitleWidth)
        let titleWidth = textWidth - valueWidth
        let titleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude)
            ).height)
        let valueHeight = ceil(
            valueLabel.sizeThatFits(
                CGSize(width: max(1, valueWidth), height: .greatestFiniteMagnitude)
            ).height)
        return (max(titleHeight, valueHeight) + 12, titleWidth, valueWidth, titleHeight, valueHeight)
    }
}
