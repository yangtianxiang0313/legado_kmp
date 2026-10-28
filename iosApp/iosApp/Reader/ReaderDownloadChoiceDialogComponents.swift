import UIKit

private enum ReaderDownloadChoiceTextMetrics {
    static func roundUp(_ value: CGFloat, traits: UITraitCollection) -> CGFloat {
        let scale = max(1, traits.displayScale)
        return ceil(value * scale) / scale
    }

    static func padding(font: UIFont, traits: UITraitCollection) -> UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
    }
}

final class ReaderDownloadChoiceLabel: UILabel {
    private var fontPadding: UIEdgeInsets {
        ReaderDownloadChoiceTextMetrics.padding(font: font, traits: traitCollection)
    }

    override var intrinsicContentSize: CGSize { paddedSize(super.intrinsicContentSize) }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        return paddedSize(
            super.sizeThatFits(
                CGSize(width: size.width, height: max(0, size.height - padding.top - padding.bottom))))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: fontPadding))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    private func paddedSize(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        // Round the complete line box up, not just the glyph height, to keep the final line intact.
        return CGSize(
            width: ReaderDownloadChoiceTextMetrics.roundUp(size.width, traits: traitCollection),
            height: ReaderDownloadChoiceTextMetrics.roundUp(
                max(font.lineHeight, size.height) + padding.top + padding.bottom, traits: traitCollection))
    }
}

final class ReaderDownloadChoiceField: UITextField {
    var showsError = false { didSet { updateBorder() } }

    init(field: ReaderDownloadChoiceRangePolicy.Field) {
        super.init(frame: .zero)
        placeholder = field.title
        accessibilityLabel = field.title
        keyboardType = .numberPad
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        smartInsertDeleteType = .no
        textContentType = .none
        textAlignment = .natural
        borderStyle = .none
        backgroundColor = .clear
        layer.borderWidth = 1
        contentVerticalAlignment = .center
        adjustsFontForContentSizeCategory = false
        textColor = AndroidReplicaTheme.primaryText
        tintColor = UIColor(red: 59 / 255, green: 150 / 255, blue: 252 / 255, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    var preferredWidth: CGFloat {
        let font = font ?? .systemFont(ofSize: 14)
        let digitWidth = (0...9).map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let hintWidth = ((placeholder ?? "") as NSString).size(withAttributes: [.font: font]).width
        return max(
            60, ReaderDownloadChoiceTextMetrics.roundUp(max(digitWidth * 5, hintWidth) + 10, traits: traitCollection))
    }

    private var fontPadding: UIEdgeInsets {
        ReaderDownloadChoiceTextMetrics.padding(font: font ?? .systemFont(ofSize: 14), traits: traitCollection)
    }

    var preferredHeight: CGFloat {
        let padding = fontPadding
        return ReaderDownloadChoiceTextMetrics.roundUp(
            (font?.lineHeight ?? 17) + padding.top + padding.bottom + 8, traits: traitCollection)
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect {
        let padding = fontPadding
        return bounds.inset(
            by: UIEdgeInsets(top: 4 + padding.top, left: 5, bottom: 4 + padding.bottom, right: 5))
    }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { textRect(forBounds: bounds) }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -max(0, (44 - bounds.height) / 2)).contains(point)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorder()
    }

    func apply(traits: UITraitCollection) {
        font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
        attributedPlaceholder = NSAttributedString(
            string: placeholder ?? "", attributes: [.foregroundColor: AndroidReplicaTheme.secondaryText])
        updateBorder()
    }

    private func updateBorder() {
        let color: UIColor
        if showsError {
            color = .systemRed
        } else {
            // bg_edit.xml is a static 1dp stroke, not an accent-colored focus selector.
            color = UIColor { traits in
                UIColor(white: traits.userInterfaceStyle == .dark ? 77 / 255 : 172 / 255, alpha: 99 / 255)
            }
        }
        layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }
}

final class ReaderDownloadChoiceRangeView: UIView {
    let startField = ReaderDownloadChoiceField(field: .start)
    let endField = ReaderDownloadChoiceField(field: .end)
    private let chapterLabel = ReaderDownloadChoiceLabel()
    private let toLabel = ReaderDownloadChoiceLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        chapterLabel.text = NSLocalizedString(
            "reader.download.choice.chapter", value: "章", comment: "Legado chapter")
        toLabel.text = NSLocalizedString("reader.download.choice.to", value: "至", comment: "Legado to")
        for label in [chapterLabel, toLabel] {
            label.textColor = AndroidReplicaTheme.primaryText
            label.numberOfLines = 0
            label.textAlignment = .center
            label.adjustsFontForContentSizeCategory = false
        }
        for item in [chapterLabel, startField, toLabel, endField] { addSubview(item) }
        accessibilityElements = [chapterLabel, startField, toLabel, endField]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func apply(traits: UITraitCollection) {
        for label in [chapterLabel, toLabel] {
            label.font = ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traits)
        }
        for field in [startField, endField] { field.apply(traits: traits) }
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: placement(for: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = placement(for: bounds.width).frames
        for (item, frame) in zip([chapterLabel, startField, toLabel, endField], frames) {
            item.frame = frame
        }
    }

    private func placement(for width: CGFloat) -> (height: CGFloat, frames: [CGRect]) {
        // dialog_download_choice.xml: 16dp content padding and 5dp label/input gaps.
        let availableWidth = max(1, width - 32)
        let labelSizes = [chapterLabel, toLabel].map {
            $0.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
        }
        let widths = [
            labelSizes[0].width, startField.preferredWidth,
            labelSizes[1].width, endField.preferredWidth,
        ]
        let heights = [
            labelSizes[0].height, startField.preferredHeight,
            labelSizes[1].height, endField.preferredHeight,
        ]
        let rowWidth = widths.reduce(0, +) + 15
        if rowWidth <= availableWidth {
            // Keep Android's wrap_content density; the fields expand only their hit regions to 44pt.
            let rowHeight = heights.max() ?? 0
            var x = (width - rowWidth) / 2
            var frames: [CGRect] = []
            for (itemWidth, itemHeight) in zip(widths, heights) {
                frames.append(
                    CGRect(
                        x: x, y: 16 + (rowHeight - itemHeight) / 2,
                        width: itemWidth, height: itemHeight))
                x += itemWidth + 5
            }
            return (rowHeight + 32, frames)
        }
        // Large text / narrow windows retain every label and a usable input, without squeezing type.
        var y: CGFloat = 16
        var frames: [CGRect] = []
        for index in widths.indices {
            let itemWidth = index.isMultiple(of: 2) ? availableWidth : min(availableWidth, widths[index])
            let slotHeight = index.isMultiple(of: 2) ? heights[index] : max(44, heights[index])
            frames.append(
                CGRect(
                    x: (width - itemWidth) / 2, y: y + (slotHeight - heights[index]) / 2,
                    width: itemWidth, height: heights[index]))
            y += slotHeight + (index == 3 ? 0 : 5)
        }
        return (y + 16, frames)
    }
}

final class ReaderDownloadChoiceActionControl: UIControl {
    private let label = ReaderDownloadChoiceLabel()
    private static let pressedText = UIColor { traits in
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return accent }
        // AlertDialog.applyTint -> ColorUtils.darkenColor shifts HSV value by 0.9.
        return UIColor(red: red * 0.9, green: green * 0.9, blue: blue * 0.9, alpha: alpha)
    }

    init(title: String) {
        super.init(frame: .zero)
        label.text = title.uppercased(with: Locale.current)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        label.textColor = AndroidReplicaTheme.accent
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    var preferredWidth: CGFloat {
        max(
            64,
            label.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ).width + 16)
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            if !isEnabled { isHighlighted = false }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear
            label.textColor = isHighlighted ? Self.pressedText : AndroidReplicaTheme.accent
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textHeight = label.sizeThatFits(
            CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: max(48, textHeight + 16))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(traits: UITraitCollection) {
        label.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traits)
        setNeedsLayout()
    }
}

final class ReaderDownloadChoiceScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is ReaderDownloadChoiceActionControl { return true }
        return super.touchesShouldCancel(in: view)
    }
}
