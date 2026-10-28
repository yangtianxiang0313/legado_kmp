import UIKit

/// AppCompat 1.7.1 SwitchCompat, with Legado 5f5d314's applyTint colors.
final class ReaderAndroidSwitchControl: UIControl, UIGestureRecognizerDelegate {
    private(set) var isOn = false

    var onTintColor: UIColor? {
        didSet { render(animated: false) }
    }

    /// Install with a weak owner capture. Nil permits interaction while attached/enabled.
    var canInteract: (() -> Bool)? {
        didSet {
            if !interactionAllowed { cancelPendingTracking() }
        }
    }

    private var authoritativeOn = false
    private var thumbPosition: CGFloat = 0
    private var trackingTouch: UITouch?
    private var touchOrigin = CGPoint.zero
    private var lastDragX: CGFloat = 0
    private var startsOnThumb = false
    private var isDraggingThumb = false
    private var permitsTouchCommit = false
    private var panVelocity: CGFloat = 0
    private var press: UIPress?
    private var handlingPress = false
    private var endingTouch = false
    private var sendingChange = false
    private let trackView = UIImageView()
    private let thumbView = UIImageView()
    // Borrow UIKit's public switch AX descriptors/localization, never its artwork/layout.
    private let accessibilitySwitch = UISwitch()
    private let focusOutline = CAShapeLayer()
    private lazy var horizontalPan: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panChanged(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.allowedPressTypes = []
        recognizer.delegate = self
        return recognizer
    }()

    // Android ViewConfiguration defaults: 8dp slop, 50dp/s fling; SwitchCompat: 250ms.
    private static let touchSlop: CGFloat = 8
    private static let minFlingVelocity: CGFloat = 50
    private static let measuredSize = CGSize(width: 47, height: 27)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: CGSize { Self.measuredSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize { Self.measuredSize }

    /// Every model refresh should call this, including equal values, to acknowledge authority.
    /// Equal authority preserves a live draft; changed authority invalidates the entire gesture.
    /// This method never emits valueChanged.
    func setOn(_ on: Bool, animated: Bool) {
        let changedAuthority = authoritativeOn != on
        authoritativeOn = on
        if trackingTouch != nil || press != nil {
            if !changedAuthority && isOn == on && interactionAllowed { return }
            clearInput()
        }
        isOn = on
        thumbPosition = on ? 1 : 0
        render(animated: animated)
    }

    /// Reuse/removal/owner invalidation: discard drafts without writing to the model.
    func cancelPendingTracking() {
        clearInput()
        isOn = authoritativeOn
        thumbPosition = authoritativeOn ? 1 : 0
        render(animated: false)
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelPendingTracking() } else { render(animated: false) }
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelPendingTracking() } }
    }

    override var isHidden: Bool {
        didSet { if isHidden { cancelPendingTracking() } }
    }

    override var canBecomeFirstResponder: Bool { interactionAllowed }
    override var canBecomeFocused: Bool { interactionAllowed }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { cancelPendingTracking() }
        return resigned
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { cancelPendingTracking() }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if superview !== newSuperview { cancelPendingTracking() }
        super.willMove(toSuperview: newSuperview)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if (trackingTouch != nil || press != nil) && !interactionAllowed {
            cancelPendingTracking()
        }
        applyFrames()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        render(animated: false)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if trackingTouch != nil,
            effectiveUserInterfaceLayoutDirection != touchDirection
        {
            cancelPendingTracking()
        }
        render(animated: false)
    }

    private var touchDirection = UIUserInterfaceLayoutDirection.leftToRight

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingTouch == nil, press == nil, !sendingChange, interactionAllowed else {
            return false
        }
        layoutIfNeeded()
        stopThumbAnimation()
        trackingTouch = touch
        touchOrigin = touch.location(in: self)
        lastDragX = touchOrigin.x
        startsOnThumb = thumbHitRect.contains(touchOrigin)
        isDraggingThumb = false
        permitsTouchCommit = true
        panVelocity = 0
        touchDirection = effectiveUserInterfaceLayoutDirection
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingTouch === touch, permitsTouchCommit, interactionAllowed,
            touchDirection == effectiveUserInterfaceLayoutDirection
        else {
            cancelPendingTracking()
            return false
        }
        let point = touch.location(in: self)
        let dx = point.x - touchOrigin.x
        let dy = point.y - touchOrigin.y
        if !isDraggingThumb {
            // Yield vertical intent to the list; a cancelled scroll must never become a click.
            if abs(dy) > Self.touchSlop && abs(dy) >= abs(dx) {
                cancelPendingTracking()
                return false
            }
            if startsOnThumb && abs(dx) > Self.touchSlop {
                isDraggingThumb = true
                lastDragX = point.x  // SwitchCompat discards the threshold-crossing movement.
            } else if !startsOnThumb && abs(dx) > Self.touchSlop {
                cancelPendingTracking()
                return false
            }
        } else {
            let direction: CGFloat = touchDirection == .rightToLeft ? -1 : 1
            let next = min(1, max(0, thumbPosition + direction * (point.x - lastDragX) / 20))
            if next != thumbPosition {
                lastDragX = point.x
                thumbPosition = next
                render(animated: false)
            }
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        defer { super.endTracking(touch, with: event) }
        guard let touch, trackingTouch === touch, permitsTouchCommit, interactionAllowed,
            touchDirection == effectiveUserInterfaceLayoutDirection
        else {
            cancelPendingTracking()
            return
        }
        let target: Bool
        if isDraggingThumb {
            // UIKit supplies velocity fitting; SwitchCompat's threshold and RTL decision are exact.
            let velocity = panVelocity
            if abs(velocity) > Self.minFlingVelocity {
                target = touchDirection == .rightToLeft ? velocity < 0 : velocity > 0
            } else {
                target = thumbPosition > 0.5
            }
        } else {
            guard bounds.contains(touch.location(in: self)) else {
                cancelPendingTracking()
                return
            }
            target = !isOn
        }
        clearInput()
        _ = commitUserValue(target)
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelPendingTracking()
        super.cancelTracking(with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endingTouch = true
        defer { endingTouch = false }
        super.touchesEnded(touches, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard trackingTouch == nil, press == nil, !isTracking else { return false }
        return commitUserValue(!isOn)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handlingPress = true
        defer { handlingPress = false }
        for candidate in presses where isActivationPress(candidate) {
            if press == nil && trackingTouch == nil && !isTracking && interactionAllowed {
                press = candidate
                isHighlighted = true
            }
        }
        let others = Set(presses.filter { !isActivationPress($0) })
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = Set(presses.filter { !isActivationPress($0) })
        if !others.isEmpty { super.pressesChanged(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        handlingPress = true
        defer { handlingPress = false }
        if let press, presses.contains(where: { $0 === press }) {
            self.press = nil
            isHighlighted = false
            _ = commitUserValue(!isOn)
        }
        let others = Set(presses.filter { !isActivationPress($0) })
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let press, presses.contains(where: { $0 === press }) { cancelPendingTracking() }
        let others = Set(presses.filter { !isActivationPress($0) })
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
    }

    override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.previouslyFocusedView === self && context.nextFocusedView !== self {
            cancelPendingTracking()
        }
        focusOutline.isHidden = !isFocused
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === horizontalPan, permitsTouchCommit,
            startsOnThumb, interactionAllowed
        else { return false }
        let translation = horizontalPan.translation(in: self)
        return abs(translation.x) > abs(translation.y)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === horizontalPan,
            let scrollView = otherGestureRecognizer.view as? UIScrollView
        else { return false }
        return otherGestureRecognizer === scrollView.panGestureRecognizer && isDescendant(of: scrollView)
    }

    private var interactionAllowed: Bool {
        guard isEnabled, let window,
            window.windowScene?.activationState != .background,
            window.windowScene?.activationState != .foregroundInactive
        else { return false }
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 || !current.isUserInteractionEnabled {
                return false
            }
            if let control = current as? UIControl, !control.isEnabled { return false }
            view = current.superview
        }
        return canInteract?() ?? true
    }

    private var artworkOrigin: CGPoint {
        CGPoint(
            x: bounds.midX - Self.measuredSize.width / 2,
            y: bounds.midY - Self.measuredSize.height / 2)
    }

    private var thumbHitRect: CGRect {
        // SwitchCompat.hitThumb uses switchLeft + offset, not the shadow's left edge.
        let position =
            effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? 1 - thumbPosition : thumbPosition
        return CGRect(
            x: artworkOrigin.x + 3.5 + position * 20 - Self.touchSlop,
            y: artworkOrigin.y - Self.touchSlop,
            width: 27 + Self.touchSlop, height: 27 + Self.touchSlop * 2)
    }

    private func configure() {
        isOpaque = false
        isMultipleTouchEnabled = false
        isAccessibilityElement = true
        trackView.image = Artwork.track
        for view in [trackView, thumbView] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            addSubview(view)
        }
        focusOutline.fillColor = UIColor.clear.cgColor
        focusOutline.lineWidth = 2
        focusOutline.isHidden = true
        layer.addSublayer(focusOutline)
        addGestureRecognizer(horizontalPan)
        addTarget(self, action: #selector(primaryAction), for: .primaryActionTriggered)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(deactivated(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(deactivated(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        render(animated: false)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func clearInput() {
        trackingTouch = nil
        startsOnThumb = false
        isDraggingThumb = false
        permitsTouchCommit = false
        press = nil
        isHighlighted = false
    }

    @discardableResult
    private func commitUserValue(_ value: Bool) -> Bool {
        guard !sendingChange, interactionAllowed else {
            cancelPendingTracking()
            return false
        }
        let changed = isOn != value
        isOn = value
        thumbPosition = value ? 1 : 0
        render(animated: true)
        if changed {
            sendingChange = true
            defer { sendingChange = false }
            // Reentrant setOn/disable/removal from the owner wins; no post-callback overwrite.
            sendActions(for: .valueChanged)
        }
        return true
    }

    @objc private func primaryAction() {
        guard !endingTouch, !handlingPress, trackingTouch == nil, press == nil, !isTracking else {
            return
        }
        _ = commitUserValue(!isOn)
    }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        // Only endTracking commits, so pan end cannot produce a second write.
        switch recognizer.state {
        case .began, .changed, .ended:
            panVelocity = recognizer.velocity(in: self).x
        case .cancelled:
            cancelPendingTracking()
        default:
            break
        }
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        cancelPendingTracking()
    }

    @objc private func reduceMotionChanged() {
        if UIAccessibility.isReduceMotionEnabled { render(animated: false) }
    }

    private func isActivationPress(_ press: UIPress) -> Bool {
        if press.type == .select { return true }
        guard let key = press.key, key.keyCode == .keyboardSpacebar else { return false }
        return key.modifierFlags.intersection([.command, .control, .alternate, .shift]).isEmpty
    }

    private func stopThumbAnimation() {
        if let presentation = thumbView.layer.presentation() {
            thumbView.frame = presentation.frame
            let physicalPosition = (presentation.frame.minX - artworkOrigin.x) / 20
            thumbPosition = min(
                1,
                max(
                    0,
                    effectiveUserInterfaceLayoutDirection == .rightToLeft
                        ? 1 - physicalPosition : physicalPosition))
        }
        thumbView.layer.removeAllAnimations()
    }

    private func applyFrames() {
        let origin = artworkOrigin
        // SwitchCompat.onLayout/draw with 14/13/14/14px optical insets at 4x.
        trackView.frame = CGRect(x: origin.x + 7, y: origin.y + 3.25, width: 33, height: 20.25)
        let position =
            effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? 1 - thumbPosition : thumbPosition
        thumbView.frame = CGRect(x: origin.x + position * 20, y: origin.y, width: 27, height: 27)
        focusOutline.frame = bounds
        focusOutline.path =
            UIBezierPath(
                roundedRect: bounds.insetBy(dx: -2, dy: -2), cornerRadius: 3
            ).cgPath
        focusOutline.strokeColor =
            (onTintColor ?? tintColor ?? .systemBlue)
            .resolvedColor(with: traitCollection).cgColor
    }

    private func render(animated: Bool) {
        accessibilitySwitch.setOn(isOn, animated: false)
        accessibilitySwitch.isEnabled = isEnabled
        super.accessibilityTraits = accessibilitySwitch.accessibilityTraits
        super.accessibilityValue = accessibilitySwitch.accessibilityValue
        thumbView.image = isOn ? Artwork.thumbOn : Artwork.thumbOff
        let colors = tintColors()
        // Android ColorStateList switches tint immediately; only position animates.
        trackView.tintColor = colors.track
        thumbView.tintColor = colors.thumb
        let animate =
            animated && window != nil && UIView.areAnimationsEnabled
            && !UIAccessibility.isReduceMotionEnabled
        if animate {
            UIView.animate(
                withDuration: 0.25, delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
            ) {
                self.applyFrames()
            }
        } else {
            thumbView.layer.removeAllAnimations()
            UIView.performWithoutAnimation { self.applyFrames() }
        }
    }

    private func tintColors() -> (thumb: UIColor, track: UIColor) {
        // Legado TintHelper.modifySwitchDrawable + values/colors.xml ate_switch_*.
        let dark = traitCollection.userInterfaceStyle == .dark
        if !isEnabled {
            return (
                UIColor(white: (dark ? 66 : 189) / 255.0, alpha: 1),
                UIColor(white: dark ? 1 : 0, alpha: (dark ? 26 : 31) / 255.0)
            )
        }
        if !isOn {
            return (
                UIColor(white: (dark ? 189 : 250) / 255.0, alpha: 1),
                UIColor(white: dark ? 1 : 0, alpha: (dark ? 77 : 67) / 255.0)
            )
        }
        var accent = (onTintColor ?? tintColor ?? .systemBlue).resolvedColor(with: traitCollection)
        if dark {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            if accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
                accent = UIColor(
                    hue: hue, saturation: saturation,
                    brightness: min(1, brightness * 1.1), alpha: alpha)
            }
        }
        let trackAlpha = (accent.cgColor.alpha * 255 * 0.5).rounded() / 255
        return (accent, accent.withAlphaComponent(trackAlpha))
    }
}

private enum Artwork {
    // Verbatim Apache-2.0 AOSP drawables from appcompat-1.7.1.aar, drawable-xxxhdpi-v4:
    // abc_switch_track_mtrl_alpha.9.png; abc_btn_switch_to_on_mtrl_00001/00012.9.png.
    // Only the 1px metadata border is removed at runtime; alpha/shadows are not redrawn.
    // Thumb body: 108x108px, padding L/R=14px. npLb optical L/T/R/B=14/13/14/14px.
    // SwitchCompat.onMeasure: 2*((108-14-14)/4)+(14+14)/4 = 47dp, height=108/4=27dp.
    // getThumbScrollRange: 47-20-0-0-3.5-3.5=20dp. Other density buckets round differently.
    static let thumbOff = decode(thumbOffPNG)
    static let thumbOn = decode(thumbOnPNG)

    static let track: UIImage? = {
        guard let source = decode(trackPNG), let cgImage = source.cgImage else { return nil }
        // Original top/left 9-patch stretch runs (border excluded), not a synthesized pill:
        // X [41,53) of 94px; Y [0,4) and [60,64) of 64px. Middle 56px stays fixed.
        let xs: [CGFloat] = [0, 10.25, 13.25, 23.5]
        let ys: [CGFloat] = [0, 1, 15, 16]
        let xd: [CGFloat] = [0, 10.25, 22.75, 33]
        let yd: [CGFloat] = [0, 3.125, 17.125, 20.25]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 4
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 33, height: 20.25), format: format)
            .image { _ in
                for y in 0..<3 {
                    for x in 0..<3 {
                        let crop = CGRect(
                            x: xs[x] * 4, y: ys[y] * 4,
                            width: (xs[x + 1] - xs[x]) * 4,
                            height: (ys[y + 1] - ys[y]) * 4)
                        guard let tile = cgImage.cropping(to: crop) else { continue }
                        UIImage(cgImage: tile, scale: 4, orientation: .up).draw(
                            in: CGRect(
                                x: xd[x], y: yd[y], width: xd[x + 1] - xd[x],
                                height: yd[y + 1] - yd[y]))
                    }
                }
            }.withRenderingMode(.alwaysTemplate)
    }()

    private static func decode(_ base64: String) -> UIImage? {
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            let image = UIImage(data: data)?.cgImage,
            let body = image.cropping(
                to: CGRect(
                    x: 1, y: 1,
                    width: image.width - 2, height: image.height - 2))
        else { return nil }
        return UIImage(cgImage: body, scale: 4, orientation: .up).withRenderingMode(.alwaysTemplate)
    }

    private static let trackPNG = """
        iVBORw0KGgoAAAANSUhEUgAAAGAAAABCCAQAAAAC9RuOAAAB0UlEQVR42u3aP04CQRSAcRMS1qyRBhsSSkI8ARZ6BbNaeRC8ACLx
        AEpDYSK1XMKCEr2AgcVYIGBc1kabz3KjsSDwZh6TzG8PQL5il/nztozg/8fUj7kMH+ADNucFIEeNOnf0GZPwV8KYPnfUqZHbsAAC
        zujxwbI+6HFGsBEBFGkwYxUzGhRVAwi5JGUdKZeESgEcM0JCzLH1ALa5RtIN2xYDKDFA2oCSpQCqDDFhSNVCABUmmDKhYjiAMiNM
        iikbDCBggGkDAnMBbWxoGwogwpbIQAC7vGLLKwX5gBY2tYQDKJJiU0pRNuAC2xqCAeSZYtuUvFxAhIZILuAeDfdCAQSkaEgJZAKO
        0HIoE1BHS10moIOWjkzAA1oeZAJitMQyAQlaFjIBilwP+JIJWKBl7vpLPPKfUe0/Mr+U0F7M+eW07obGbymzTT0zJzf1GZrY1nT9
        YGvP7aPFK/mz0YKjh7sZTrDl1NQFxy023Jq7oQl5xLQnQrOXfGNMeqHs8jXrGxW3L7r3/aiB5rCHxrhN7OS4TYaQ1toDTy12tEfO
        msxZxZym6shZhjwRPRKWldAjIr+ZY5dd+oz55Ldv3nmmT5dzDsj5wVcf4AMkR49x+Nn6AWWf2Ul4wGuaAAAAAElFTkSuQmCC
        """

    private static let thumbOffPNG = """
        iVBORw0KGgoAAAANSUhEUgAAAG4AAABuCAMAAADxhdbJAAACOlBMVEUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAcHBwA
        AAAzMzMAAAAAAAArKysAAAAAAABtbW0AAAAAAAAAAAAAAAAAAABRUVEAAAAAAACSkpIAAAAAAACmpqYAAACqqqoAAAAKCgqPj48A
        AAAKCgqTk5MAAAAAAACSkpIAAAAAAACAgIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC8vLzDw8MAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAhISEAAACamprPz88AAAAAAAAKCgrHx8cAAAAAAAAAAADU1NQAAABHR0cAAAAAAAAAAAAJCQnX19cEBAQ9PT1FRUUZ
        GRkxMTExMTF1dXU1NTU3Nzc7OzteXl5cXFxbW1t5eXlycnLo6Oh+fn59fX2EhITe3t7V1dXq6urc3Ny/v7/u7u7o6Oi1tbXt7e3r
        6+vAwMCrq6vx8fGxsbHv7+/CwsLg4ODq6uq8vLzCwsLw8PDAwMDV1dXt7e3R0dHHx8fIyMjT09P09PTQ0ND09PTr6+vv7+/k5OTz
        8/Pi4uLa2tr39/fc3Nzz8/Pj4+Ph4eHp6en39/fk5OTx8fH39/f29vbv7+/p6ens7Oz4+Pjq6urt7e3u7u75+fn19fX09PTx8fH5
        +fn4+Pj5+fn4+Pj19fX29vbz8/P19fX4+Pj09PT5+fn29vb4+Pj19fX29vb19fX6+vr5+fn4+Pj6+vr39/f5+fn6+vr4+Pj6+vr5
        +fkAAAD6+vr/AACpBxqcAAAAu3RSTlMAAQIDBAUGBwgJCQoKCwwMDQ4ODxAREhMTFBUVFhcXGBgZGRkaGhobHBwdHh4fICEiIyQl
        JiYmJygpKissLS4vLzAwMDEyMjIzNDU1NjY3ODk5OTo7Oz0+Pz9ERUVMTlFSV1hZWl1dYWFna2xvcXJzdnl9gIGFhYWJi4uNjY2V
        l5qeoaKmp6qsrrK0t7i6vL3Cw8XIyMnKz9LS09rb3+Lj5ubn5+jq6uvr6+zs7u7v7/D09fb29/f3+Pn6sbLXSQAABnVJREFUeF7s
        lU1rE0Ecxp//M5v0JdIXUjRp0noIJRVMvKR4aXooAcXCYkEqFQs9hJzag+C59FjoZ/Dm0YMnL6EfwKNF8CwIVU9tESsFXV2XptLd
        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
        e+r03wAAAABJRU5ErkJggg==
        """

    private static let thumbOnPNG = """
        iVBORw0KGgoAAAANSUhEUgAAAG4AAABuCAMAAADxhdbJAAACVVBMVEUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAQEBAAAAAAAAAAAAANDQ0AAAAAAABJSUkAAABGRkZRUVEAAABkZGQAAABKSkoAAAAAAABFRUVYWFgA
        AAAAAACAgIAAAAAAAAAAAAAAAAAAAACTk5MAAACPj48AAAAAAABjY2MAAAAAAAAAAAAAAACsrKwAAACoqKgAAACqqqoAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAFBQWzs7MAAAAAAAAiIiIAAABDQ0MAAAAAAAAAAAAAAAAAAAAAAAAnJycAAAAeHh4AAAAAAAAAAAAY
        GBgEBAQXFxcbGxsaGhohISEwMDBBQUFBQUHW1tbX19dWVlbLy8tVVVVRUVFUVFTFxcXa2tplZWXOzs7h4eHc3Nyqqqri4uLd3d2f
        n5+srKyRkZHm5uaSkpLn5+ebm5vj4+PY2Njq6uqtra3m5ualpaWtra3JycmpqanCwsK2tra5ubnExMS/v7/u7u7w8PDl5eXw8PDq
        6urv7+/d3d3b29vx8fHu7u7S0tLu7u7T09PW1tbU1NTg4ODg4ODy8vLb29v09PTz8/Pv7+/p6enh4eHk5OTi4uL19fXp6en29vbo
        6Ojz8/Py8vL29vb29vbs7Oz39/f4+Pjx8fH39/f09PTt7e309PTx8fH4+Pjv7+/w8PDy8vLx8fH4+Pj29vb6+vr4+Pjy8vL19fX0
        9PT5+fn5+fn5+fn29vb4+Pj5+fn29vb39/f6+voAAAD6+vr/AADrf+aeAAAAxHRSTlMAAQIDBAUGBwgJCgsMDQ4PEBAREhMTFBUV
        FhYWFxcYGBkaGhobHBwdHh8gISEiIiMkJCUmJygoKSkqKissLS4vMDEyMjIzNDQ1NTY3ODk6Ozs8PD0+Pz9AQkNERkpKS0tMTU9R
        UlJTU1hYXV5gYWJlaW9vcHN1dXZ4eXp9fX+AiYyPj5OUl5qam5ufpaeoqamsra6ztLa3uLm6vcTFx8fR0dLU1dfY2tvb3Nze39/g
        4OLi5ebm6Ojp6+zt7/Dx8vLy9PT+QEN7vwAAB4VJREFUeAHc1gOPbUkUxfG1Vt22bURj27b57PfCZ4/i0VeZePANGlFH4wnHtt2o
        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
        tDn/AQN/NHVbJmN7AAAAAElFTkSuQmCC
        """
}
