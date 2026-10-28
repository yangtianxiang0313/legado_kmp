import UIKit

final class ReaderPreferenceChoiceDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }
}

final class ReaderPreferenceChoiceDialogRow: UIControl {
    // select_dialog_singlechoice_material: start 20, drawable padding 20, end 24.
    private let startInset: CGFloat = 20
    private let endInset: CGFloat = 24
    private let indicatorSlot: CGFloat = 32
    private let indicatorGap: CGFloat = 20
    private let label = UILabel()
    private let indicator = UIImageView()

    init(title: String) {
        super.init(frame: .zero)
        label.text = title
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .natural
        label.textColor = AndroidReplicaTheme.primaryText
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        indicator.contentMode = .scaleAspectFit
        indicator.isAccessibilityElement = false
        indicator.isUserInteractionEnabled = false
        addSubview(label)
        addSubview(indicator)
        isAccessibilityElement = true
        accessibilityLabel = title
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            if !isEnabled { isHighlighted = false }
            updateSelection()
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textWidth = max(1, size.width - startInset - indicatorSlot - indicatorGap - endInset)
        let textHeight = ceil(
            label.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            ).height)
        // select_dialog_singlechoice_material has no vertical padding; the drawable is 32dp.
        return CGSize(width: size.width, height: max(48, max(32, textHeight)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let textStart = startInset + indicatorSlot + indicatorGap
        let textWidth = max(1, bounds.width - textStart - endInset)
        let indicatorX = isRTL ? bounds.width - startInset - indicatorSlot : startInset
        indicator.frame = CGRect(x: indicatorX, y: bounds.midY - 16, width: 32, height: 32)
        label.frame = CGRect(
            x: isRTL ? endInset : textStart, y: 0,
            width: textWidth, height: bounds.height)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    private func updateSelection() {
        indicator.image = isSelected ? Self.checkedImage : Self.uncheckedImage
        indicator.tintColor = isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
    }

    // AppCompat 1.7.1 btn_radio_{on,off}_mtrl.xml: 32dp viewport, 9dp ring / 2dp stroke, 5dp dot.
    private static let checkedImage = radioImage(checked: true)
    private static let uncheckedImage = radioImage(checked: false)

    private static func radioImage(checked: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            UIColor.black.setStroke()
            UIColor.black.setFill()
            let ring = UIBezierPath()
            ring.move(to: CGPoint(x: 16, y: 7))
            ring.addCurve(to: CGPoint(x: 25, y: 16), controlPoint1: CGPoint(x: 20.9705627482, y: 7), controlPoint2: CGPoint(x: 25, y: 11.0294372518))
            ring.addCurve(to: CGPoint(x: 16, y: 25), controlPoint1: CGPoint(x: 25, y: 20.9705627482), controlPoint2: CGPoint(x: 20.9705627482, y: 25))
            ring.addCurve(to: CGPoint(x: 7, y: 16), controlPoint1: CGPoint(x: 11.0294372518, y: 25), controlPoint2: CGPoint(x: 7, y: 20.9705627482))
            ring.addCurve(to: CGPoint(x: 16, y: 7), controlPoint1: CGPoint(x: 7, y: 11.0294372518), controlPoint2: CGPoint(x: 11.0294372518, y: 7))
            ring.close()
            ring.lineWidth = 2
            ring.stroke()
            if checked {
                let dot = UIBezierPath()
                dot.move(to: CGPoint(x: 16, y: 11))
                dot.addCurve(to: CGPoint(x: 11, y: 16), controlPoint1: CGPoint(x: 13.2380065918, y: 11), controlPoint2: CGPoint(x: 11, y: 13.2380065918))
                dot.addCurve(to: CGPoint(x: 16, y: 21), controlPoint1: CGPoint(x: 11, y: 18.7619934082), controlPoint2: CGPoint(x: 13.2380065918, y: 21))
                dot.addCurve(to: CGPoint(x: 21, y: 16), controlPoint1: CGPoint(x: 18.7619934082, y: 21), controlPoint2: CGPoint(x: 21, y: 18.7619934082))
                dot.addCurve(to: CGPoint(x: 16, y: 11), controlPoint1: CGPoint(x: 21, y: 13.2380065918), controlPoint2: CGPoint(x: 18.7619934082, y: 11))
                dot.close()
                dot.fill()
            }
        }.withRenderingMode(.alwaysTemplate)
    }
}

final class ReaderPreferenceChoiceDialogCancelControl: UIControl {
    private let label = UILabel()

    var preferredWidth: CGFloat {
        max(
            64,
            ceil(
                label.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                ).width) + 16)
    }

    init() {
        super.init(frame: .zero)
        label.text = L10n.Common.cancel
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        label.textColor = AndroidReplicaTheme.accent
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = L10n.Common.cancel
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            if !isEnabled { isHighlighted = false }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textHeight = ceil(
            label.sizeThatFits(
                CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude)
            ).height)
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

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }
}
