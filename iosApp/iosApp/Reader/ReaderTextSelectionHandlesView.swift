import UIKit

// Legado  Copyright (C) 2019-2023  gedoor
// Original project license: GNU GPL version 3; see Resources/LegadoMenuIcons-LICENSE.txt.
// https://github.com/gedoor/legado, revision 5f5d31404af9957684703747ecee2b91e7161f1d
// Sources: app/src/main/res/drawable/ic_cursor_left.xml, ic_cursor_right.xml,
// and app/src/main/res/layout/activity_book_read.xml. The XMLs have no copyright header.
// UIKit adaptation: original 24 x 24 paths retained, with transparent 44pt hit targets.

enum ReaderTextSelectionEndpoint {
    case start
    case end

    fileprivate var opposite: Self { self == .start ? .end : .start }
}

/// Covers the reader's bounds; caret rectangles and drag points use overlay coordinates.
final class ReaderTextSelectionHandlesView: UIView, UIGestureRecognizerDelegate {
    /// .began is touch-down, not pan recognition; only .changed can move a boundary.
    var onDrag: ((ReaderTextSelectionEndpoint, CGPoint, UIGestureRecognizer.State) -> Void)?
    var onStep: ((ReaderTextSelectionEndpoint, Int) -> Void)?

    static let cursorWidth: CGFloat = 24

    private struct Interaction {
        let control: HandleControl
        let initialTip: CGPoint
        let bounds: CGRect
        var lastTip: CGPoint
        var hasBegun = false
    }

    private let firstControl = HandleControl(endpoint: .start)
    private let secondControl = HandleControl(endpoint: .end)
    private let pan = UIPanGestureRecognizer()
    private weak var trackingTouch: UITouch?
    private var interaction: Interaction?
    private var startTip: CGPoint?
    private var endTip: CGPoint?
    private var isResettingPan = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        isAccessibilityElement = false
        for control in [firstControl, secondControl] {
            control.isHidden = true
            control.onStep = { [weak self, weak control] direction in
                guard let self, let control, self.canInteract,
                    !control.isHidden, self.interaction == nil
                else { return }
                self.onStep?(control.endpoint, direction)
            }
            control.onTrackingEnd = { [weak self, weak control] touch, state in
                guard let self, let control else { return }
                self.finishPendingInteraction(control: control, touch: touch, state: state)
            }
            addSubview(control)
        }
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.addTarget(self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        positionControls()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            guard isUserInteractionEnabled != oldValue else { return }
            refreshAvailability()
        }
    }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            refreshAvailability()
        }
    }

    override var alpha: CGFloat {
        didSet {
            guard alpha != oldValue else { return }
            refreshAvailability()
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if superview !== newSuperview { cancelInteraction() }
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if let superview { frame = superview.bounds }
        refreshAvailability()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { cancelInteraction() }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshAvailability()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let interaction, interaction.bounds != bounds {
            cancelInteraction()
        } else {
            positionControls()
        }
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        nearestControl(to: point) != nil
    }

    override func hitTest(_ point: CGPoint, with _: UIEvent?) -> UIView? {
        // Never return the overlay itself, so body text and sibling menus remain reachable.
        nearestControl(to: point)
    }

    func update(
        start: CGRect?, end: CGRect?,
        activeEndpoint: ReaderTextSelectionEndpoint? = nil, color: UIColor
    ) {
        startTip = Self.tip(for: start)
        endTip = Self.tip(for: end)
        tintColor = color
        if let interaction, interaction.hasBegun, let activeEndpoint {
            // Role changes never replace the physical control or rebase the drag origin.
            interaction.control.endpoint = activeEndpoint
            otherControl(than: interaction.control).endpoint = activeEndpoint.opposite
        }
        if let interaction,
            tip(for: interaction.control.endpoint) == nil || !canInteract || interaction.bounds != bounds
        {
            cancelInteraction()
        } else {
            positionControls()
        }
    }

    func cancelInteraction() {
        let previous = interaction
        let endpoint = previous?.control.endpoint
        interaction = nil
        trackingTouch = nil
        // Reset possible gestures as well, preventing an old touch from beginning later.
        if !isResettingPan {
            isResettingPan = true
            pan.isEnabled = false
            pan.isEnabled = canInteract
            isResettingPan = false
        }
        positionControls()
        if let previous, let endpoint {
            onDrag?(endpoint, previous.lastTip, .cancelled)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan, canInteract, interaction == nil,
            let control = touch.view as? HandleControl,
            control === firstControl || control === secondControl,
            !control.isHidden, control.isEnabled, let tip = tip(for: control.endpoint)
        else { return false }
        if let trackingTouch, trackingTouch.phase != .ended, trackingTouch.phase != .cancelled {
            return false
        }
        trackingTouch = touch
        // Capture at touch-down, before the pan recognizer crosses its movement threshold.
        interaction = Interaction(control: control, initialTip: tip, bounds: bounds, lastTip: tip)
        onDrag?(control.endpoint, tip, .began)
        return interaction?.control === control && trackingTouch === touch
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan && canInteract && interaction != nil
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isResettingPan else { return }
        switch gesture.state {
        case .began:
            interaction?.hasBegun = true
            sendDrag(state: .changed)
        case .changed, .ended:
            sendDrag(state: gesture.state)
        case .cancelled, .failed:
            cancelInteraction()
        default:
            break
        }
    }

    private func finishPendingInteraction(
        control: HandleControl, touch: UITouch?, state: UIGestureRecognizer.State
    ) {
        guard !isResettingPan, let current = interaction, current.control === control,
            !current.hasBegun
        else { return }
        // Pan recognition cancels UIControl tracking before its target action may run.
        guard pan.state != .began, pan.state != .changed, pan.state != .ended else { return }
        if state == .ended, let touch, trackingTouch === touch {
            interaction = nil
            trackingTouch = nil
            positionControls()
            onDrag?(control.endpoint, current.lastTip, .ended)
        } else {
            cancelInteraction()
        }
    }

    private func sendDrag(state: UIGestureRecognizer.State) {
        guard var current = interaction else { return }
        guard canInteract, !current.control.isHidden, current.control.isEnabled,
            current.bounds == bounds, current.hasBegun
        else {
            cancelInteraction()
            return
        }
        let translation = pan.translation(in: self)
        let point = CGPoint(
            x: current.initialTip.x + translation.x,
            y: current.initialTip.y + translation.y)
        guard point.x.isFinite, point.y.isFinite else {
            cancelInteraction()
            return
        }
        let endpoint = current.control.endpoint
        current.hasBegun = true
        current.lastTip = point
        if state == .ended {
            // Clear before calling out: a reentrant update/cancel cannot finish this drag twice.
            interaction = nil
            trackingTouch = nil
            positionControls()
        } else {
            interaction = current
        }
        onDrag?(endpoint, point, state)
    }

    private var canInteract: Bool {
        guard window != nil else { return false }
        var view: UIView? = self
        while let current = view {
            guard current.isUserInteractionEnabled, !current.isHidden, current.alpha > 0.01 else { return false }
            view = current.superview
        }
        return true
    }

    private func refreshAvailability() {
        if !canInteract {
            cancelInteraction()
        } else {
            pan.isEnabled = true
            positionControls()
        }
    }

    private func positionControls() {
        if interaction == nil {
            firstControl.endpoint = .start
            secondControl.endpoint = .end
        }
        let enabled = canInteract
        for control in [firstControl, secondControl] {
            let tip = tip(for: control.endpoint)
            control.isHidden = tip == nil
            control.isEnabled = enabled
            control.isAccessibilityElement = tip != nil && enabled
            guard let tip else { continue }
            let visualX = tip.x - (control.endpoint == .start ? HandleControl.visualSize : 0)
            control.frame = CGRect(
                x: visualX - HandleControl.hitPadding, y: tip.y - HandleControl.hitPadding,
                width: HandleControl.hitSize, height: HandleControl.hitSize)
        }
        let startControl = firstControl.endpoint == .start ? firstControl : secondControl
        accessibilityElements = [startControl, otherControl(than: startControl)]
    }

    private func nearestControl(to point: CGPoint) -> HandleControl? {
        guard canInteract, bounds.contains(point) else { return nil }
        var nearest: HandleControl?
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for control in [firstControl, secondControl] where !control.isHidden && control.isEnabled {
            guard control.frame.contains(point) else { continue }
            let dx = point.x - control.frame.midX
            let dy = point.y - control.frame.midY
            let distance = dx * dx + dy * dy
            // Fixed physical order breaks ties; an existing touch keeps its physical control.
            if distance < nearestDistance {
                nearest = control
                nearestDistance = distance
            }
        }
        return nearest
    }

    private func otherControl(than control: HandleControl) -> HandleControl {
        control === firstControl ? secondControl : firstControl
    }

    private func tip(for endpoint: ReaderTextSelectionEndpoint) -> CGPoint? {
        endpoint == .start ? startTip : endTip
    }

    private static func tip(for caret: CGRect?) -> CGPoint? {
        guard let caret, !caret.isNull, !caret.isInfinite,
            caret.origin.x.isFinite, caret.origin.y.isFinite,
            caret.width.isFinite, caret.height.isFinite,
            caret.minX.isFinite, caret.maxY.isFinite
        else { return nil }
        return CGPoint(x: caret.minX, y: caret.maxY)
    }

    private final class HandleControl: UIControl {
        static let visualSize = ReaderTextSelectionHandlesView.cursorWidth
        static let hitSize: CGFloat = 44
        static let hitPadding: CGFloat = (hitSize - visualSize) / 2

        var onStep: ((Int) -> Void)?
        var onTrackingEnd: ((UITouch?, UIGestureRecognizer.State) -> Void)?
        var endpoint: ReaderTextSelectionEndpoint {
            didSet {
                guard endpoint != oldValue else { return }
                updateAccessibilityRole()
                setNeedsDisplay()
            }
        }

        init(endpoint: ReaderTextSelectionEndpoint) {
            self.endpoint = endpoint
            super.init(frame: CGRect(x: 0, y: 0, width: Self.hitSize, height: Self.hitSize))
            backgroundColor = .clear
            isOpaque = false
            contentMode = .redraw
            tintAdjustmentMode = .normal
            accessibilityTraits = .adjustable
            updateAccessibilityRole()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            preconditionFailure("init(coder:) is unavailable")
        }

        override func tintColorDidChange() {
            super.tintColorDidChange()
            setNeedsDisplay()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
                setNeedsDisplay()
            }
        }

        override func draw(_: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            context.saveGState()
            context.translateBy(x: Self.hitPadding, y: Self.hitPadding)
            tintColor.setFill()
            (endpoint == .start ? Self.leftPath : Self.rightPath).fill()
            context.restoreGState()
        }

        override func beginTracking(_: UITouch, with _: UIEvent?) -> Bool {
            isEnabled && !isHidden
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            onTrackingEnd?(touch, .ended)
            super.endTracking(touch, with: event)
        }

        override func cancelTracking(with event: UIEvent?) {
            onTrackingEnd?(nil, .cancelled)
            super.cancelTracking(with: event)
        }

        override func accessibilityIncrement() {
            guard isEnabled, !isHidden else { return }
            onStep?(1)
        }

        override func accessibilityDecrement() {
            guard isEnabled, !isHidden else { return }
            onStep?(-1)
        }

        private func updateAccessibilityRole() {
            accessibilityLabel = endpoint == .start ? "选择起点" : "选择终点"
            accessibilityIdentifier =
                endpoint == .start
                ? "reader.textSelection.startHandle" : "reader.textSelection.endHandle"
        }

        // ic_cursor_left.xml: M12,4h8v8c0,4.418-3.582,8-8,8s-8-3.582-8-8S7.582,4,12,4z
        private static let leftPath: UIBezierPath = {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 12, y: 4))
            path.addLine(to: CGPoint(x: 20, y: 4))
            path.addLine(to: CGPoint(x: 20, y: 12))
            path.addCurve(
                to: CGPoint(x: 12, y: 20),
                controlPoint1: CGPoint(x: 20, y: 16.418), controlPoint2: CGPoint(x: 16.418, y: 20))
            path.addCurve(
                to: CGPoint(x: 4, y: 12),
                controlPoint1: CGPoint(x: 7.582, y: 20), controlPoint2: CGPoint(x: 4, y: 16.418))
            path.addCurve(
                to: CGPoint(x: 12, y: 4),
                controlPoint1: CGPoint(x: 4, y: 7.582), controlPoint2: CGPoint(x: 7.582, y: 4))
            path.close()
            return path
        }()

        // ic_cursor_right.xml: M12,4.208H4v8c0,4.418,3.582,8,8,8s8-3.582,8-8S16.418,4.208,12,4.208z
        private static let rightPath: UIBezierPath = {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 12, y: 4.208))
            path.addLine(to: CGPoint(x: 4, y: 4.208))
            path.addLine(to: CGPoint(x: 4, y: 12.208))
            path.addCurve(
                to: CGPoint(x: 12, y: 20.208),
                controlPoint1: CGPoint(x: 4, y: 16.626), controlPoint2: CGPoint(x: 7.582, y: 20.208))
            path.addCurve(
                to: CGPoint(x: 20, y: 12.208),
                controlPoint1: CGPoint(x: 16.418, y: 20.208), controlPoint2: CGPoint(x: 20, y: 16.626))
            path.addCurve(
                to: CGPoint(x: 12, y: 4.208),
                controlPoint1: CGPoint(x: 20, y: 7.79), controlPoint2: CGPoint(x: 16.418, y: 4.208))
            path.close()
            return path
        }()
    }
}
