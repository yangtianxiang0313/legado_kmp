import UIKit

/// RotateLoading.kt at 5f5d314; the owner supplies the layout slot and AX value.
final class BookshelfBookStatusLoadingView: UIView {
    var loadingWidth: CGFloat = 2 {
        didSet { setNeedsDisplay() }
    }

    private var isRefreshing = false
    private var isPresentationActive = true
    private var sceneIsActive = false
    private var displayLink: CADisplayLink?
    private lazy var displayTarget = DisplayTarget(owner: self)
    private var visibilityObservations: [NSKeyValueObservation] = []
    private var elapsed: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        contentMode = .redraw

        let center = NotificationCenter.default
        for name in [
            UIScene.didActivateNotification, UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            center.addObserver(self, selector: #selector(sceneStateChanged(_:)), name: name, object: nil)
        }
        center.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func setRefreshing(_ refreshing: Bool) {
        let changed = isRefreshing != refreshing
        isRefreshing = refreshing
        isHidden = !refreshing
        if changed {
            elapsed = 0
            lastTimestamp = nil
            observeVisibility()
        }
        updateAnimationVisibility()
        setNeedsDisplay()
    }

    /// Visibility alone cannot detect a page covered by another controller.
    func setPresentationActive(_ active: Bool) {
        isPresentationActive = active
        updateAnimationVisibility()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window {
            stopDisplayLink()
            visibilityObservations.removeAll()
            sceneIsActive = false
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneIsActive = window?.windowScene?.activationState == .foregroundActive
        observeVisibility()
        updateAnimationVisibility()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        observeVisibility()
        updateAnimationVisibility()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateAnimationVisibility()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    func updateAnimationVisibility() {
        guard shouldAnimate else {
            stopDisplayLink()
            return
        }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: displayTarget, selector: #selector(DisplayTarget.tick(_:)))
        link.preferredFramesPerSecond = 60
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private var shouldAnimate: Bool {
        isRefreshing && isPresentationActive && sceneIsActive
            && window?.windowScene?.activationState == .foregroundActive
            && !UIAccessibility.isReduceMotionEnabled && isActuallyVisible
    }

    private var isActuallyVisible: Bool {
        guard let window, !bounds.isEmpty else { return false }
        var visibleRect = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, !visibleRect.isEmpty, !visibleRect.isNull else { return false }
            if view.clipsToBounds {
                visibleRect = visibleRect.intersection(view.convert(view.bounds, to: window))
            }
            ancestor = view.superview
        }
        return !visibleRect.isEmpty && !visibleRect.isNull
    }

    private func observeVisibility() {
        visibilityObservations.removeAll()
        guard isRefreshing, window != nil else { return }
        // Observe clipped collection/pager scrolling as well as hidden ancestor pages.
        // No offscreen timer is retained just to detect a later return to the viewport.
        var ancestor: UIView? = self
        while let view = ancestor {
            visibilityObservations.append(
                view.observe(\.isHidden, options: [.new]) { [weak self] _, _ in
                    self?.updateAnimationVisibility()
                })
            visibilityObservations.append(
                view.observe(\.alpha, options: [.new]) { [weak self] _, _ in
                    self?.updateAnimationVisibility()
                })
            visibilityObservations.append(
                view.observe(\.center, options: [.new]) { [weak self] _, _ in
                    self?.updateAnimationVisibility()
                })
            visibilityObservations.append(
                view.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                    self?.updateAnimationVisibility()
                })
            visibilityObservations.append(
                view.observe(\.transform, options: [.new]) { [weak self] _, _ in
                    self?.updateAnimationVisibility()
                })
            if let scrollView = view as? UIScrollView {
                visibilityObservations.append(
                    scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                        self?.updateAnimationVisibility()
                    })
            }
            ancestor = view.superview
        }
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    private func tick(_ link: CADisplayLink) {
        guard shouldAnimate else {
            stopDisplayLink()
            return
        }
        if let lastTimestamp {
            elapsed += max(0, link.timestamp - lastTimestamp)
        }
        lastTimestamp = link.timestamp
        setNeedsDisplay()
    }

    @objc private func sceneStateChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        // willDeactivate can arrive before activationState changes.
        sceneIsActive = notification.name == UIScene.didActivateNotification
        updateAnimationVisibility()
    }

    @objc private func reduceMotionChanged() {
        updateAnimationVisibility()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard isRefreshing else { return }
        let strokeWidth: CGFloat = loadingWidth.isFinite && loadingWidth > 0 ? loadingWidth : 2
        let loadingRect = bounds.insetBy(dx: 2 * strokeWidth, dy: 2 * strokeWidth)
        guard loadingRect.width > 0, loadingRect.height > 0 else { return }

        // Android rotates 10 degrees/frame, grows by integer (10 / 4) = 2,
        // then shrinks by 4. Normalize to 60Hz without speeding up on 120Hz screens.
        let growthDuration: CFTimeInterval = 150.0 / 120.0
        let shrinkDuration: CFTimeInterval = 150.0 / 240.0
        let phase = elapsed.truncatingRemainder(dividingBy: growthDuration + shrinkDuration)
        let sweep =
            UIAccessibility.isReduceMotionEnabled
            ? CGFloat(90)
            : CGFloat(phase < growthDuration ? 10 + phase * 120 : 160 - (phase - growthDuration) * 240)
        let start =
            UIAccessibility.isReduceMotionEnabled
            ? CGFloat(10)
            : CGFloat((10 + elapsed * 600).truncatingRemainder(dividingBy: 360))
        let radius = min(loadingRect.width, loadingRect.height) / 2
        let center = CGPoint(x: loadingRect.midX, y: loadingRect.midY)

        // XML supplies attrs: getInt(shadow_position, 2) overrides the dp-converted
        // constructor value. Keep that raw 2px offset, not a blurred CALayer shadow.
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        let shadowCenter = CGPoint(x: center.x + 2 / scale, y: center.y + 2 / scale)
        drawArcs(
            center: shadowCenter, radius: radius, start: start, sweep: sweep,
            color: UIColor(white: 0, alpha: 26.0 / 255.0), width: strokeWidth)
        drawArcs(
            center: center, radius: radius, start: start, sweep: sweep,
            color: AndroidReplicaTheme.accent.resolvedColor(with: traitCollection), width: strokeWidth)
    }

    private func drawArcs(center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, color: UIColor, width: CGFloat) {
        color.setStroke()
        for angle in [start, start + 180] {
            let path = UIBezierPath(
                arcCenter: center, radius: radius, startAngle: angle * .pi / 180,
                endAngle: (angle + sweep) * .pi / 180, clockwise: true)
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        }
    }

    private final class DisplayTarget: NSObject {
        weak var owner: BookshelfBookStatusLoadingView?

        init(owner: BookshelfBookStatusLoadingView) {
            self.owner = owner
        }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
    }
}
