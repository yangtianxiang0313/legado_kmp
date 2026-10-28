import UIKit

/// cpv_color_item_circle.xml: 50pt color panel, 1pt border, centered 32pt check.
final class ReaderColorSwatchView: UIControl {
    var onSelect: (() -> Void)?
    var onShowHint: (() -> Void)?

    // Unchanged cpv_alpha.png bytes from colorpicker 1.1.0's drawable-xhdpi-v4
    // and drawable-xxhdpi-v4. Both repeat at 10pt without adding bundle resources.
    private static let alphaPattern2x: UIImage? = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAAAAACo4kLRAAAAJElEQVR4AWP8zwAD52AMRiTBs0NP8Cxc1BguPWQEz8EFjeCCAGiuJg7q0LsMAAAAAElFTkSuQmCC"
    ).flatMap { UIImage(data: $0, scale: 2) }
    private static let alphaPattern3x: UIImage? = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeCAAAAAAeW/F+AAAALElEQVR4AWP8z4ACziFzGBlIlD474NKj0mcZUBQYoygeCOlR6XOo0kYkSQMATHY5FXk7yIEAAAAASUVORK5CYII="
    ).flatMap { UIImage(data: $0, scale: 3) }

    private let checkImageView = UIImageView(
        image: UIImage(named: "ReaderTocAndroidCheck")?.withRenderingMode(.alwaysTemplate))
    private var color: UIColor = .clear
    private var argb: UInt32 = 0
    private var kind: ReaderColorPalette.SwatchKind = .preset
    private var consumedLongPress = false

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityTraits = .button
        checkImageView.contentMode = .scaleAspectFit
        checkImageView.isUserInteractionEnabled = false
        checkImageView.isAccessibilityElement = false
        addSubview(checkImageView)
        addTarget(self, action: #selector(selectColor), for: .touchUpInside)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(showHint(_:)))
        longPress.cancelsTouchesInView = true
        addGestureRecognizer(longPress)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "显示色值") { [weak self] _ in
                guard let self, self.isEnabled, let onShowHint = self.onShowHint else { return false }
                onShowHint()
                return true
            }
        ]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(color: UIColor, argb: UInt32, selected: Bool, kind: ReaderColorPalette.SwatchKind) {
        self.color = color
        self.argb = argb
        self.kind = kind
        isSelected = selected
        checkImageView.isHidden = !selected
        // Existing ic_check uses the identical path as cpv_preset_checked, at 32pt here.
        checkImageView.tintColor = ReaderColorPalette.usesDarkCheckmark(for: argb, kind: kind) ? .black : .white
        accessibilityValue = ReaderColorPalette.hexString(for: argb)
        accessibilityHint = selected ? "再次轻点以确认" : "轻点以选择"
        accessibilityTraits = selected ? [.button, .selected] : .button
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        checkImageView.frame = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let diameter = min(bounds.width, bounds.height)
        let outer = CGRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
            width: diameter, height: diameter)
        let border =
            ReaderColorPalette.borderColor(for: argb, kind: kind) == nil
            ? UIColor.secondaryLabel : color.withAlphaComponent(1)
        context.setFillColor(border.resolvedColor(with: traitCollection).cgColor)
        context.fillEllipse(in: outer)
        let inner = outer.insetBy(dx: 1, dy: 1)
        guard inner.width > 0, inner.height > 0 else { return }
        context.saveGState()
        context.addEllipse(in: inner)
        context.clip()
        if argb >> 24 != 255 {
            let pattern = traitCollection.displayScale >= 3 ? Self.alphaPattern3x : Self.alphaPattern2x
            if let pattern {
                pattern.drawAsPattern(in: bounds)
            } else {
                context.setFillColor(UIColor.white.cgColor)
                context.fill(inner)
            }
        }
        context.setFillColor(color.resolvedColor(with: traitCollection).cgColor)
        context.fill(inner)
        context.restoreGState()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        consumedLongPress = false
        return super.beginTracking(touch, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, let onSelect else { return false }
        onSelect()
        return true
    }

    @objc private func selectColor() {
        guard isEnabled, !consumedLongPress else { return }
        onSelect?()
    }

    @objc private func showHint(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, isEnabled, !consumedLongPress else { return }
        consumedLongPress = true
        onShowHint?()
    }
}
