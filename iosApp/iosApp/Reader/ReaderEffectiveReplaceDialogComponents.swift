import UIKit

private enum ReaderEffectiveReplaceTextMetrics {
    static func roundUp(_ value: CGFloat, traits: UITraitCollection) -> CGFloat {
        let scale = max(1, traits.displayScale)
        return ceil(value * scale) / scale
    }

    static func padding(font: UIFont, traits: UITraitCollection) -> UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
    }
}

final class ReaderEffectiveReplaceLabel: UILabel {
    override var text: String? {
        get { super.text }
        set {
            // SingleLineTransformationMethod changes display text, not the rule or its AX label.
            super.text = newValue?.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        }
    }

    private var fontPadding: UIEdgeInsets {
        ReaderEffectiveReplaceTextMetrics.padding(font: font, traits: traitCollection)
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
        return CGSize(
            width: ReaderEffectiveReplaceTextMetrics.roundUp(max(0, size.width), traits: traitCollection),
            // Empty names still occupy a line; ceil the complete padded box at display scale.
            height: ReaderEffectiveReplaceTextMetrics.roundUp(
                max(font.lineHeight, size.height) + padding.top + padding.bottom, traits: traitCollection))
    }
}

final class ReaderEffectiveReplaceScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

final class ReaderEffectiveReplaceRuleRow: UIControl {
    let snapshotID: UUID
    private let label = ReaderEffectiveReplaceLabel()

    init(title: String, snapshotID: UUID) {
        self.snapshotID = snapshotID
        super.init(frame: .zero)
        label.text = title
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.textAlignment = .natural
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = false
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

    func apply(font: UIFont, textColor: UIColor) {
        label.font = font
        label.textColor = textColor
        setNeedsLayout()
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear
        }
    }

    override var isEnabled: Bool {
        didSet {
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textHeight = label.sizeThatFits(
            CGSize(width: max(0, size.width - 12), height: .greatestFiniteMagnitude)
        ).height
        // item_1line_text.xml has 6dp padding on each edge and no minimum row height.
        return CGSize(
            width: size.width,
            height: ReaderEffectiveReplaceTextMetrics.roundUp(textHeight + 12, traits: traitCollection))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(
            x: 6, y: 6, width: max(0, bounds.width - 12), height: max(0, bounds.height - 12))
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}
