import UIKit

/// Read-only, nonanimated SmoothCheckBox.setChecked() rendering at legado 5f5d314.
final class ReaderAndroidCheckIndicatorView: UIView {
    private var checked = false
    private var accent = AndroidReplicaTheme.accent
    private var isNightOverride: Bool?

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        updateDisplayScale()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func apply(checked: Bool, accent: UIColor, isNight: Bool? = nil) {
        self.checked = checked
        self.accent = accent
        isNightOverride = isNight
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayScale()
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateDisplayScale()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), bounds.width > 0, bounds.height > 0 else { return }

        // Android measures/quantizes in integer px. Map those to iOS backing pixels,
        // including the literal 3px minimum (not 3pt), then map the drawing back to pt.
        let scale = contentScaleFactor
        let width = Int((bounds.width * scale).rounded(.toNearestOrAwayFromZero))
        let height = Int((bounds.height * scale).rounded(.toNearestOrAwayFromZero))
        guard width > 0, height > 0 else { return }
        let strokeWidth = max(3, min(width / 10, width / 5))
        let center = CGPoint(x: CGFloat(width / 2), y: CGFloat(height / 2))
        func tickPoint(_ x: Float, _ y: Float) -> CGPoint {
            CGPoint(
                x: CGFloat((Float(width) / 30 * x).rounded(.toNearestOrAwayFromZero)),
                y: CGFloat((Float(height) / 30 * y).rounded(.toNearestOrAwayFromZero)))
        }
        let tickPoints = [tickPoint(7, 14), tickPoint(13, 20), tickPoint(22, 10)]
        let isNight = isNightOverride ?? (traitCollection.userInterfaceStyle == .dark)
        // background_menu / transparent30 are resource colors, never page-following colors.
        let menuColor = UIColor(white: isNight ? 66.0 / 255.0 : 238.0 / 255.0, alpha: 1)
        let floorColor = UIColor(white: isNight ? 1 : 0, alpha: 48.0 / 255.0)

        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        context.setShouldAntialias(true)

        func fillCircle(radius: CGFloat, color: UIColor) {
            guard radius > 0 else { return }
            context.setFillColor(color.cgColor)
            context.fillEllipse(
                in: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
        }
        // reset(): floorScale=1; center scale=0 when checked, otherwise 1.
        fillCircle(radius: center.x, color: checked ? menuColor : floorColor)
        fillCircle(radius: checked ? 0 : center.x - CGFloat(strokeWidth), color: menuColor)
        guard checked else { return }

        context.setStrokeColor(accent.resolvedColor(with: traitCollection).cgColor)
        context.setLineWidth(CGFloat(strokeWidth))
        context.setLineCap(.round)
        // Android draws two separate ROUND-cap paths, not a joined checkmark glyph.
        for (start, end) in [(tickPoints[0], tickPoints[1]), (tickPoints[1], tickPoints[2])] {
            context.beginPath()
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        }
    }

    private func updateDisplayScale() {
        let scale = traitCollection.displayScale
        contentScaleFactor = scale > 0 ? scale : (window?.screen.scale ?? UIScreen.main.scale)
    }
}
