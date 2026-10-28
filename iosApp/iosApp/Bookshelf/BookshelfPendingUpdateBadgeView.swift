import UIKit

/// BadgeView.kt / view_navigation_badge.xml; the parent owns icon placement and accessibility.
final class BookshelfPendingUpdateBadgeView: UIView {
    private let label = UILabel()
    private let textInsets = UIEdgeInsets(top: 1, left: 5, bottom: 1, right: 5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        layer.cornerRadius = 8
        clipsToBounds = true

        label.textAlignment = .center
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.2
        label.baselineAdjustment = .alignCenters
        label.adjustsFontForContentSizeCategory = true
        label.isAccessibilityElement = false
        addSubview(label)
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
        applyAppearance()
        setCount(0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func setCount(_ count: Int) {
        label.text = count > 0 ? String(count) : nil
        isHidden = count <= 0
        applyAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let textSize = label.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(
            width: max(16, ceil(textSize.width) + textInsets.left + textInsets.right),
            height: max(
                18,
                ceil(max(textSize.height, label.font.lineHeight))
                    + textInsets.top + textInsets.bottom))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        intrinsicContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.inset(by: textInsets)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func applyAppearance() {
        label.font = UIFontMetrics(forTextStyle: .caption2).scaledFont(
            for: .systemFont(ofSize: 11), compatibleWith: traitCollection)
        backgroundColor = AndroidReplicaTheme.accent
        label.textColor = Self.textColor(for: AndroidReplicaTheme.accent.resolvedColor(with: traitCollection))
    }

    private static func textColor(for color: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return .white }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        // Android ColorUtils.isColorLight uses relative sRGB luminance, not HSV brightness.
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.5 ? .black : .white
    }
}
