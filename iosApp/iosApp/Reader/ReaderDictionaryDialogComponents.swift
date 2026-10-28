import UIKit

/// DictDialog.kt MODE_FIXED / GRAVITY_FILL through four rules; otherwise MODE_SCROLLABLE.
@MainActor
final class ReaderDictionaryDialogTabStrip: UIView {
    static let height: CGFloat = 48
    static let bottomPadding: CGFloat = 16

    var onSelect: ((Int) -> Void)?
    var canInteract: (() -> Bool)? {
        didSet { if !inputAllowed { cancelPendingTracking() } }
    }
    private let scrollView = ReaderEffectiveReplaceScrollView()
    private let indicator = UIView()
    private var buttons: [ReaderDictionaryDialogTabButton] = []
    private var selectedIndex = 0
    private var needsReveal = false
    private var lastSize = CGSize.zero
    private var titlesGeneration = UUID()
    private var controlsEnabled = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        addSubview(scrollView)
        indicator.isUserInteractionEnabled = false
        indicator.isAccessibilityElement = false
        scrollView.addSubview(indicator)
        accessibilityIdentifier = "reader.dictionary.tabs"
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func setTitles(_ titles: [String], selecting index: Int = 0) {
        cancelPendingTracking()
        titlesGeneration = UUID()
        let generation = titlesGeneration
        let hadSelection = buttons.indices.contains(selectedIndex)
        let selectionChanged = selectedIndex != index
        for button in buttons { button.removeFromSuperview() }
        buttons = titles.enumerated().map { index, title in
            let button = ReaderDictionaryDialogTabButton(title: title)
            button.tag = index
            button.accessibilityIdentifier = "reader.dictionary.tab.\(index)"
            button.isEnabled = controlsEnabled
            button.canInteract = { [weak self] in
                self?.titlesGeneration == generation && self?.inputAllowed == true
            }
            button.onActivate = { [weak self, weak button] in
                guard let self, let button, self.titlesGeneration == generation, self.inputAllowed,
                    self.buttons.indices.contains(index), self.buttons[index] === button, index != self.selectedIndex
                else { return }
                self.onSelect?(index)
            }
            scrollView.addSubview(button)
            return button
        }
        scrollView.bringSubviewToFront(indicator)
        selectedIndex = buttons.indices.contains(index) ? index : 0
        needsReveal = !hadSelection || selectionChanged
        applyAppearance()
        for (offset, button) in buttons.enumerated() { button.isSelected = offset == selectedIndex }
    }

    func select(_ index: Int) {
        guard buttons.indices.contains(index) else { return }
        if selectedIndex != index { needsReveal = true }
        selectedIndex = index
        for (offset, button) in buttons.enumerated() { button.isSelected = offset == index }
        setNeedsLayout()
    }

    func setControlsEnabled(_ enabled: Bool) {
        controlsEnabled = enabled
        if !enabled { cancelPendingTracking() }
        for button in buttons { button.isEnabled = enabled }
        scrollView.isUserInteractionEnabled = enabled
    }

    func cancelPendingTracking() {
        for button in buttons { button.cancelPendingTracking() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { cancelPendingTracking() }
        super.willMove(toWindow: newWindow)
    }

    func applyAppearance() {
        backgroundColor = AndroidReplicaTheme.background
        indicator.backgroundColor = AndroidReplicaTheme.accent
        for button in buttons { button.applyAppearance(traits: traitCollection) }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let fixed = buttons.count <= 4
        var widths = buttons.map { fixed ? bounds.width / CGFloat(max(1, buttons.count)) : $0.preferredWidth }
        // Material 1.13 SlidingTabIndicator.onMeasure: equal-width centered tabs if
        // the widest tab fits count times inside the two 16dp gutters.
        if !fixed, let widest = widths.max(), widest * CGFloat(buttons.count) <= bounds.width - 32 {
            widths = Array(repeating: widest, count: buttons.count)
        }
        let totalWidth = widths.reduce(CGFloat.zero, +)
        let centeringInset = max(0, (bounds.width - totalWidth) / 2)
        var x =
            effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? max(bounds.width, totalWidth) - centeringInset : centeringInset
        for (button, width) in zip(buttons, widths) {
            if effectiveUserInterfaceLayoutDirection == .rightToLeft { x -= width }
            button.frame = CGRect(x: x, y: 0, width: width, height: Self.height)
            if effectiveUserInterfaceLayoutDirection != .rightToLeft { x += width }
        }
        scrollView.contentSize = CGSize(width: max(bounds.width, totalWidth), height: Self.height)
        scrollView.isScrollEnabled = !fixed
        indicator.isHidden = !buttons.indices.contains(selectedIndex)
        if buttons.indices.contains(selectedIndex) {
            let button = buttons[selectedIndex]
            // Widget.Design.TabLayout sets tabIndicatorFullWidth=true; drawable height is 2dp.
            indicator.frame = CGRect(x: button.frame.minX, y: Self.height - 2, width: button.bounds.width, height: 2)
            if needsReveal || lastSize != bounds.size {
                let maximum = max(0, scrollView.contentSize.width - bounds.width)
                let x = min(maximum, max(0, button.frame.midX - bounds.width / 2))
                scrollView.setContentOffset(CGPoint(x: x, y: 0), animated: false)
            }
        }
        let clampedX = min(max(0, scrollView.contentOffset.x), max(0, scrollView.contentSize.width - bounds.width))
        if clampedX != scrollView.contentOffset.x {
            scrollView.setContentOffset(CGPoint(x: clampedX, y: 0), animated: false)
        }
        lastSize = bounds.size
        needsReveal = false
        accessibilityElements = buttons
    }

    private var inputAllowed: Bool {
        guard controlsEnabled, !isHidden, isUserInteractionEnabled, window != nil,
            !scrollView.isDragging, !scrollView.isDecelerating, canInteract?() != false
        else { return false }
        let pan = scrollView.panGestureRecognizer.state
        return pan != .began && pan != .changed
    }

    @objc private func panChanged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended
            || recognizer.state == .cancelled
        {
            cancelPendingTracking()
        }
    }
}

@MainActor
private final class ReaderDictionaryDialogTabButton: UIControl {
    var canInteract: (() -> Bool)?
    var onActivate: (() -> Void)?
    private let caption = UILabel()
    private let text: String
    private var titleFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private var twoLineFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    private var permitsActivation = false
    private var touchOrigin = CGPoint.zero
    private var trackingID = UUID()
    private var isCancellingTracking = false

    var preferredWidth: CGFloat {
        min(264, max(72, ceil((text as NSString).size(withAttributes: [.font: titleFont]).width) + 24))
    }

    init(title: String) {
        text = title.uppercased(with: Locale.current)
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = title
        showsLargeContentViewer = true
        largeContentTitle = title
        addInteraction(UILargeContentViewerInteraction())
        caption.text = text
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.lineBreakMode = .byTruncatingTail
        caption.isAccessibilityElement = false
        caption.isUserInteractionEnabled = false
        addSubview(caption)
        addTarget(self, action: #selector(activate), for: .touchUpInside)
        addTarget(self, action: #selector(discardTouch), for: [.touchCancel, .touchUpOutside])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isSelected: Bool { didSet { updateSelection() } }
    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelPendingTracking() }
            updateSelection()
        }
    }
    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    func applyAppearance(traits: UITraitCollection) {
        // Keep one/two lines inside Material's fixed 48pt tab; full AX text remains in Large Content Viewer.
        titleFont = tabFont(size: 14, maximumSize: 40, traits: traits)
        twoLineFont = tabFont(size: 12, maximumSize: 20, traits: traits)
        updateSelection()
        setNeedsLayout()
    }

    private func tabFont(size: CGFloat, maximumSize: CGFloat, traits: UITraitCollection) -> UIFont {
        let scaledSize = min(
            maximumSize, UIFontMetrics(forTextStyle: .subheadline).scaledValue(for: size, compatibleWith: traits))
        return ReaderAndroidDefaultFont.font(size: scaledSize, weight: 500)
            ?? .systemFont(ofSize: scaledSize, weight: .medium)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let available = bounds.insetBy(dx: min(12, bounds.width / 2), dy: 0)
        guard available.width > 0, available.height > 0 else {
            caption.frame = .zero
            return
        }
        // TabView uses design_tab_text_size_2line (12sp), not arbitrary text shrinking.
        let singleLineWidth = (text as NSString).size(withAttributes: [.font: titleFont]).width
        caption.font = singleLineWidth > available.width ? twoLineFont : titleFont
        caption.frame = available
    }

    private func updateSelection() {
        caption.textColor = isSelected ? AndroidReplicaTheme.primaryText : AndroidReplicaTheme.secondaryText
        accessibilityTraits = .button
        if isSelected { accessibilityTraits.insert(.selected) }
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, canInteract?() != false, let onActivate else { return false }
        cancelPendingTracking()
        onActivate()
        return true
    }

    func cancelPendingTracking() {
        guard !isCancellingTracking else { return }
        isCancellingTracking = true
        defer { isCancellingTracking = false }
        permitsActivation = false
        trackingID = UUID()
        super.cancelTracking(with: nil)
        isHighlighted = false
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, canInteract?() != false else { return false }
        trackingID = UUID()
        touchOrigin = touch.location(in: self)
        permitsActivation = true
        let accepted = super.beginTracking(touch, with: event)
        if !accepted { cancelPendingTracking() }
        return accepted
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        guard permitsActivation, canInteract?() != false,
            hypot(point.x - touchOrigin.x, point.y - touchOrigin.y) <= 8
        else {
            cancelPendingTracking()
            return false
        }
        return super.continueTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        permitsActivation =
            permitsActivation && canInteract?() != false
            && touch.map { bounds.contains($0.location(in: self)) } == true
        super.endTracking(touch, with: event)
        let id = trackingID
        DispatchQueue.main.async { [weak self] in
            if self?.trackingID == id { self?.permitsActivation = false }
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelPendingTracking()
    }

    @objc private func activate() {
        guard permitsActivation, isEnabled, canInteract?() != false else {
            cancelPendingTracking()
            return
        }
        cancelPendingTracking()
        onActivate?()
    }

    @objc private func discardTouch() { cancelPendingTracking() }
}

/// RotateLoading.kt at 5f5d314: 60pt slot, paired 6pt round arcs, 10...160 degree sweep.
@MainActor
final class ReaderDictionaryDialogLoadingView: UIView {
    private let rotatingLayer = CALayer()
    private let arcs = [CAShapeLayer(), CAShapeLayer()]
    private let shadows = [CAShapeLayer(), CAShapeLayer()]
    private var isLoading = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = L10n.Settings.loading
        accessibilityTraits = .updatesFrequently
        accessibilityIdentifier = "reader.dictionary.loading"
        layer.addSublayer(rotatingLayer)
        for arc in shadows + arcs {
            arc.fillColor = UIColor.clear.cgColor
            arc.lineWidth = 6
            arc.lineCap = .round
            rotatingLayer.addSublayer(arc)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAnimations),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        setLoading(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        isHidden = !loading
        updateAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotatingLayer.frame = bounds
        for (index, arc) in arcs.enumerated() {
            let start = CGFloat(10 + index * 180) * .pi / 180
            let path = UIBezierPath(
                arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                radius: max(0, min(bounds.width, bounds.height) / 2 - 12),
                startAngle: start, endAngle: start + 160 * .pi / 180, clockwise: true
            ).cgPath
            arc.frame = bounds
            arc.path = path
            arc.strokeColor = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection).cgColor
            shadows[index].frame = bounds.offsetBy(dx: 2, dy: 2)
            shadows[index].path = path
            shadows[index].strokeColor = UIColor.black.withAlphaComponent(0.1).cgColor
        }
        CATransaction.commit()
    }

    @objc private func updateAnimations() {
        guard isLoading, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            rotatingLayer.removeAllAnimations()
            for arc in arcs + shadows { arc.removeAllAnimations() }
            return
        }
        guard rotatingLayer.animation(forKey: "rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 0.6
        rotation.repeatCount = .infinity
        rotatingLayer.add(rotation, forKey: "rotation")
        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweep.values = [10.0 / 160, 1, 10.0 / 160]
        sweep.keyTimes = [0, NSNumber(value: 2.0 / 3), 1]
        sweep.duration = 1.875
        sweep.repeatCount = .infinity
        for arc in arcs + shadows { arc.add(sweep, forKey: "sweep") }
    }
}
