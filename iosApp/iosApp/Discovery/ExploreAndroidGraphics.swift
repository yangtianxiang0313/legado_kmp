import UIKit

/// Legado 5f5d314: bg_find_book_group and the 1024-unit ic_arrow_right/down paths.
enum ExploreAndroidGraphics {
    enum Arrow { case right, down }

    static let sourceHeaderBackground = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: 16.0 / 255)
    }

    // shape_fillet_btn / shape_fillet_btn_press use #63 alpha in both palettes.
    static let kindBackground = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 77.0 / 255 : 172.0 / 255, alpha: 99.0 / 255)
    }

    static let kindPressedBackground = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 104.0 / 255 : 133.0 / 255, alpha: 99.0 / 255)
    }

    static func arrow(_ arrow: Arrow, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        if scale > 0 { format.scale = scale }
        return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format).image { context in
            context.cgContext.scaleBy(x: 20.0 / 1024, y: 20.0 / 1024)
            let points: [CGPoint]
            switch arrow {
            case .right:
                points = [
                    CGPoint(x: 434.94, y: 790.62), CGPoint(x: 389.69, y: 745.37),
                    CGPoint(x: 623.04, y: 512), CGPoint(x: 389.66, y: 278.62),
                    CGPoint(x: 434.91, y: 233.37), CGPoint(x: 713.57, y: 512),
                ]
            case .down:
                points = [
                    CGPoint(x: 512, y: 685.25), CGPoint(x: 233.38, y: 406.63),
                    CGPoint(x: 278.63, y: 361.38), CGPoint(x: 512, y: 594.75),
                    CGPoint(x: 745.38, y: 361.37), CGPoint(x: 790.63, y: 406.62),
                ]
            }
            let path = UIBezierPath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.close()
            UIColor.black.setFill()
            path.fill()
        }.withRenderingMode(.alwaysTemplate)
    }

    static func controlHighlight(toolbar: Bool, traits: UITraitCollection) -> UIColor {
        guard toolbar else { return AndroidReplicaTheme.activeIndicator.resolvedColor(with: traits) }
        // TitleBar's overlay follows its text contrast, not the page's light/dark style.
        var white: CGFloat = 1
        var alpha: CGFloat = 1
        AndroidReplicaTheme.toolbarText.resolvedColor(with: traits).getWhite(&white, alpha: &alpha)
        return white > 0.5
            ? UIColor(white: 1, alpha: 51.0 / 255)
            : UIColor(white: 0, alpha: 31.0 / 255)
    }

    static func isAvailableForInteraction(_ view: UIView) -> Bool {
        guard let window = view.window, window.windowScene?.activationState == .foregroundActive,
            !view.bounds.isEmpty
        else { return false }
        var visibleRect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard current.isUserInteractionEnabled, !current.isHidden, current.alpha > 0.01 else { return false }
            if current.clipsToBounds {
                visibleRect = visibleRect.intersection(current.convert(current.bounds, to: window))
            }
            guard !visibleRect.isEmpty, !visibleRect.isNull else { return false }
            ancestor = current.superview
        }
        return true
    }
}

/// AppCompat selectableItemBackground[Borderless]; feedback never enlarges the hit target.
final class ExploreAndroidSelectableButton: UIButton {
    enum Feedback: Equatable { case borderless, navigation, bounded }

    var feedback: Feedback = .borderless {
        didSet { setNeedsLayout() }
    }
    var usesToolbarPalette = true {
        didSet { updateFeedback(animated: false) }
    }
    var dimsWhenDisabled = true {
        didSet { updateEnabledAppearance() }
    }
    var showsFeedback = true {
        didSet { updateFeedback(animated: false) }
    }
    var feedbackInsets: UIEdgeInsets = .zero {
        didSet {
            if oldValue != feedbackInsets { setNeedsLayout() }
        }
    }

    private let feedbackLayer = CAShapeLayer()

    var canReceiveActivation: Bool {
        isEnabled && ExploreAndroidGraphics.isAvailableForInteraction(self)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        backgroundColor = .clear
        imageView?.contentMode = .center
        feedbackLayer.opacity = 0
        layer.insertSublayer(feedbackLayer, at: 0)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHighlighted: Bool {
        didSet { updateFeedback(animated: true) }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelPendingActivation() }
            updateEnabledAppearance()
        }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden { cancelPendingActivation() }
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            if !isUserInteractionEnabled { cancelPendingActivation() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = bounds.inset(by: feedbackInsets)
        let path: UIBezierPath
        switch feedback {
        case .bounded:
            path = UIBezierPath(rect: rect)
        case .borderless, .navigation:
            // abc_control_background_material uses a fixed 20dp navigation radius.
            let radius = feedback == .navigation ? 20 : min(rect.width, rect.height) / 2
            path = UIBezierPath(
                ovalIn: CGRect(
                    x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedbackLayer.frame = bounds
        feedbackLayer.path = path.cgPath
        CATransaction.commit()
        updateFeedback(animated: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelPendingActivation() }
        updateFeedback(animated: false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFeedback(animated: false)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard canReceiveActivation else { return false }
        return super.beginTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard canReceiveActivation else {
            cancelPendingActivation()
            return
        }
        super.endTracking(touch, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard canReceiveActivation else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func cancelPendingActivation() {
        cancelTracking(with: nil)
        isHighlighted = false
        updateFeedback(animated: false)
    }

    private func updateEnabledAppearance() {
        alpha = !isEnabled && dimsWhenDisabled ? 0.38 : 1
        updateFeedback(animated: false)
    }

    private func updateFeedback(animated: Bool) {
        let opacity: Float = showsFeedback && isHighlighted && canReceiveActivation ? 1 : 0
        let previousOpacity = feedbackLayer.presentation()?.opacity ?? feedbackLayer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedbackLayer.fillColor =
            ExploreAndroidGraphics.controlHighlight(
                toolbar: usesToolbarPalette, traits: traitCollection
            ).cgColor
        feedbackLayer.opacity = opacity
        feedbackLayer.removeAllAnimations()
        CATransaction.commit()
        guard animated, !UIAccessibility.isReduceMotionEnabled, previousOpacity != opacity else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = previousOpacity
        fade.toValue = opacity
        fade.duration = opacity == 1 ? 0.08 : 0.15
        feedbackLayer.add(fade, forKey: "selectableOpacity")
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        cancelPendingActivation()
    }
}
