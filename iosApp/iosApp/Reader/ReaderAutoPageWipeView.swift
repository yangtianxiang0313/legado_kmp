import UIKit

/// Reveals a dedicated next-page view without moving or resizing it as progress changes.
/// The target must be detached; never pass the live reader underneath this overlay.
@MainActor
final class ReaderAutoPageWipeView: UIView {
    let targetView: UIView
    private(set) var progress: CGFloat = 0

    var accentColor: UIColor {
        didSet { updateAccentColor() }
    }

    private let contentHost = UIView()
    private let revealMask = CALayer()
    private let accentLine = CALayer()

    init(target: UIView, accentColor: UIColor) {
        precondition(target.superview == nil, "The wipe target must be a detached next-page view.")
        targetView = target
        self.accentColor = accentColor
        super.init(frame: .zero)

        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        clipsToBounds = true

        contentHost.isOpaque = false
        contentHost.backgroundColor = .clear
        contentHost.isUserInteractionEnabled = false
        contentHost.clipsToBounds = true
        addSubview(contentHost)

        target.translatesAutoresizingMaskIntoConstraints = true
        target.autoresizingMask = []
        contentHost.addSubview(target)

        revealMask.backgroundColor = UIColor.black.cgColor
        revealMask.allowsEdgeAntialiasing = false
        contentHost.layer.mask = revealMask
        accentLine.allowsEdgeAntialiasing = false
        contentHost.layer.addSublayer(accentLine)
        updateAccentColor()
        updateReveal()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        return nil
    }

    /// Finite values are clamped to 0...1; nonfinite values reset the reveal to zero.
    func updateProgress(_ value: CGFloat) {
        progress = value.isFinite ? min(1, max(0, value)) : 0
        updateReveal()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
            rect.width.isFinite, rect.height.isFinite,
            rect.width >= 0, rect.height >= 0
        else {
            contentHost.isHidden = true
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        contentHost.isHidden = false
        contentHost.frame = rect
        // Only a real overlay resize changes the page's geometry, never a progress tick.
        let targetFrame = CGRect(origin: .zero, size: rect.size)
        if targetView.frame != targetFrame {
            targetView.frame = targetFrame
        }
        updateReveal()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateReveal()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAccentColor()
        updateReveal()
    }

    override func hitTest(_: CGPoint, with _: UIEvent?) -> UIView? {
        nil
    }

    private var displayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale.isFinite && scale >= 1 ? scale : 1
    }

    private func updateAccentColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        accentLine.backgroundColor = accentColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }

    private func updateReveal() {
        let size = contentHost.bounds.size
        let scale = displayScale
        let pixel = 1 / scale
        let hasArea =
            size.width.isFinite && size.height.isFinite
            && size.width > 0 && size.height > 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        revealMask.contentsScale = scale
        accentLine.contentsScale = scale
        guard hasArea else {
            revealMask.frame = .zero
            accentLine.isHidden = true
            return
        }

        let rawBottom = size.height * progress
        let pixelBottom = rawBottom * scale
        // Snap intermediate clip edges to pixels, but reveal the entire page at one.
        let bottom =
            progress == 1 || !pixelBottom.isFinite
            ? rawBottom : min(size.height, pixelBottom.rounded(.down) / scale)
        revealMask.frame = CGRect(x: 0, y: 0, width: size.width, height: bottom)
        accentLine.isHidden = bottom <= 0
        accentLine.frame = CGRect(x: 0, y: bottom - pixel, width: size.width, height: pixel)
    }
}
