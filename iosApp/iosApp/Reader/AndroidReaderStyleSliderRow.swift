import UIKit

final class AndroidReaderStyleSliderRow: UIStackView {
    private final class DetailSlider: UISlider {
        var usesCompactTrack = false
        var adjustValue: ((Float) -> Void)?
        var beginCompactTracking: (() -> Bool)?
        var continueCompactTracking: (() -> Bool)?
        var finishCompactTracking: ((Float) -> Void)?
        var rejectCompactTracking: (() -> Void)?
        private var isCancellingCompactTracking = false
        private var compactTouchOffset: CGFloat = 0
        private var compactTouchOrigin = CGPoint.zero
        private var isDraggingCompactTrack = false

        override var alignmentRectInsets: UIEdgeInsets {
            usesCompactTrack ? .zero : super.alignmentRectInsets
        }

        override func trackRect(forBounds bounds: CGRect) -> CGRect {
            guard usesCompactTrack else { return super.trackRect(forBounds: bounds) }
            // AppCompat 1.7.1 Base.Widget.AppCompat.SeekBar has 16dp horizontal padding.
            let inset = min(16, max((bounds.width - 12) / 2, 0))
            return CGRect(x: bounds.minX + inset, y: bounds.midY - 1, width: max(bounds.width - 2 * inset, 0), height: 2)
        }

        override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
            guard usesCompactTrack else { return super.thumbRect(forBounds: bounds, trackRect: rect, value: value) }
            let range = CGFloat(maximumValue - minimumValue)
            let fraction = range > 0 ? min(max(CGFloat(value - minimumValue) / range, 0), 1) : 0
            let position = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - fraction : fraction
            // AppCompat's constant-size selector keeps the thumb center on the full padded track.
            let diameter: CGFloat = 18
            return CGRect(
                x: rect.minX + rect.width * position - diameter / 2,
                y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        }

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard usesCompactTrack else { return super.beginTracking(touch, with: event) }
            guard beginCompactTracking?() == true else { return false }
            let point = touch.location(in: self)
            let thumb = thumbRect(forBounds: bounds, trackRect: trackRect(forBounds: bounds), value: value)
            let offset = thumb.midX - point.x
            compactTouchOffset = abs(offset) <= thumb.width / 2 ? offset : 0
            compactTouchOrigin = point
            isDraggingCompactTrack = !hasScrollableAncestor
            isHighlighted = isDraggingCompactTrack
            if isDraggingCompactTrack { updateCompactValue(at: point) }
            guard continueCompactTracking?() == true else {
                isHighlighted = false
                rejectCompactTracking?()
                return false
            }
            return true
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            guard usesCompactTrack else { return super.continueTracking(touch, with: event) }
            guard continueCompactTracking?() == true else { return false }
            let point = touch.location(in: self)
            if !isDraggingCompactTrack {
                let dx = abs(point.x - compactTouchOrigin.x)
                let dy = abs(point.y - compactTouchOrigin.y)
                guard dx > 10, dx > dy else { return true }
                isDraggingCompactTrack = true
                isHighlighted = true
            }
            updateCompactValue(at: point)
            return continueCompactTracking?() == true
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            guard usesCompactTrack else {
                super.endTracking(touch, with: event)
                return
            }
            guard continueCompactTracking?() == true else { return }
            if let touch { updateCompactValue(at: touch.location(in: self)) }
            isHighlighted = false
            compactTouchOffset = 0
            isDraggingCompactTrack = false
            finishCompactTracking?(value)
        }

        override func cancelTracking(with event: UIEvent?) {
            guard usesCompactTrack else {
                super.cancelTracking(with: event)
                return
            }
            guard !isCancellingCompactTracking else { return }
            isCancellingCompactTracking = true
            defer { isCancellingCompactTracking = false }
            // AbsSeekBar ACTION_CANCEL commits the current draft, not UIKit's possible rollback.
            let draft = value
            let wasDragging = isDraggingCompactTrack
            super.cancelTracking(with: event)
            isHighlighted = false
            compactTouchOffset = 0
            isDraggingCompactTrack = false
            if wasDragging {
                finishCompactTracking?(draft)
            } else {
                // A vertical scroll never started seeking and must not submit a value.
                rejectCompactTracking?()
            }
        }

        private var hasScrollableAncestor: Bool {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                    let insets = scroll.adjustedContentInset
                    if scroll.contentSize.width + insets.left + insets.right > scroll.bounds.width
                        || scroll.contentSize.height + insets.top + insets.bottom > scroll.bounds.height
                    {
                        return true
                    }
                }
                ancestor = view.superview
            }
            return false
        }

        private func updateCompactValue(at point: CGPoint) {
            let track = trackRect(forBounds: bounds)
            guard track.width > 0 else { return }
            let position: CGFloat
            // AbsSeekBar.trackTouchEvent snaps past the padded edges before applying the thumb offset.
            if point.x < track.minX {
                position = 0
            } else if point.x > track.maxX {
                position = 1
            } else {
                position = min(max((point.x + compactTouchOffset - track.minX) / track.width, 0), 1)
            }
            let fraction = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - position : position
            value = minimumValue + Float(fraction) * (maximumValue - minimumValue)
            sendActions(for: .valueChanged)
        }

        override func accessibilityIncrement() {
            guard usesCompactTrack else {
                super.accessibilityIncrement()
                return
            }
            adjustValue?(1)
        }

        override func accessibilityDecrement() {
            guard usesCompactTrack else {
                super.accessibilityDecrement()
                return
            }
            adjustValue?(-1)
        }
    }

    private var titleLabel = UILabel()
    private var valueLabel = UILabel()
    private let slider = DetailSlider()
    private let labels = UIStackView()
    private let minusButton = AndroidReaderStyleStepButton()
    private let plusButton = AndroidReaderStyleStepButton()
    private var compactStep: Float?
    private var rawCompactValueText: String?
    private var onChange: ((Float) -> Void)?
    private var lastCommittedValue: Float?
    private var authoritativeValue: (value: Float, text: String)?
    private var isCompactTracking = false
    private var isInteractionEnabled = true
    private var isCancellingPendingTracking = false
    private var palette: ReaderMenuPalette?

    /// The owner must capture itself weakly and reject inactive or covered contexts.
    var canInteract: (() -> Bool)?

    var valueFormatter: ((Float) -> String)? {
        didSet {
            if compactStep != nil || valueFormatter != nil { refreshValueText() }
        }
    }

    var valueText: String {
        get { rawCompactValueText ?? valueLabel.text ?? "" }
        set {
            if compactStep != nil {
                rawCompactValueText = newValue
                valueLabel.text = Self.compactDisplayText(newValue)
                valueLabel.accessibilityLabel = newValue
            } else {
                valueLabel.text = newValue
            }
            slider.accessibilityValue = newValue
            minusButton.accessibilityValue = newValue
            plusButton.accessibilityValue = newValue
        }
    }

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 6
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.textColor = .secondaryLabel
        valueLabel.textAlignment = .right
        titleLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        valueLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82
        valueLabel.minimumScaleFactor = 0.82
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        [titleLabel, UIView(), valueLabel].forEach(labels.addArrangedSubview)
        labels.axis = .horizontal
        labels.alignment = .center
        addArrangedSubview(labels)
        slider.accessibilityIdentifier = identifier
        slider.accessibilityLabel = title
        addArrangedSubview(slider)
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    @available(*, unavailable)
    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(min: Float, max: Float, onChange: @escaping (Float) -> Void) {
        let rangeChanged = slider.minimumValue != min || slider.maximumValue != max
        self.onChange = onChange
        slider.minimumValue = min
        slider.maximumValue = max
        if compactStep != nil {
            if rangeChanged { cancelPendingTracking() }
            guard !isCompactTracking && !slider.isTracking else { return }
            slider.value = normalizedValue(slider.value)
            lastCommittedValue = slider.value
            refreshValueText()
        }
    }

    func set(value: Float, text: String) {
        authoritativeValue = (value, text)
        // An unrelated info-row refresh must not replace a finger-owned draft value.
        if compactStep != nil, isCompactTracking || slider.isTracking {
            _ = checkCompactInteraction()
            return
        }
        slider.value = compactStep == nil ? value : normalizedValue(value)
        lastCommittedValue = slider.value
        valueText = valueFormatter?(slider.value) ?? text
    }

    func setInteractionEnabled(_ enabled: Bool) {
        isInteractionEnabled = enabled
        guard compactStep != nil else { return }
        if !enabled { cancelPendingTracking() }
        let enabledChanged = slider.isEnabled != enabled
        slider.isEnabled = enabled
        if enabledChanged {
            // iOS 26 can retain the disabled custom thumb until the next value change.
            let thumb = slider.thumbImage(for: .normal)
            slider.setThumbImage(nil, for: .normal)
            slider.setThumbImage(thumb, for: .normal)
        }
        minusButton.isEnabled = enabled
        plusButton.isEnabled = enabled
    }

    /// Owner invalidation discards a draft; a normal system touch cancellation still commits.
    func cancelPendingTracking() {
        guard compactStep != nil, !isCancellingPendingTracking else { return }
        isCancellingPendingTracking = true
        defer { isCancellingPendingTracking = false }
        // Invalidate before UIKit can synchronously dispatch cancellation callbacks.
        isCompactTracking = false
        slider.cancelTracking(with: nil)
        minusButton.cancelTracking(with: nil)
        plusButton.cancelTracking(with: nil)
        restoreAuthoritativeValue()
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            if !isUserInteractionEnabled { cancelPendingTracking() }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelPendingTracking() }
        super.willMove(toWindow: newWindow)
    }

    func useAndroidCompactLayout(step: Float) {
        let wasCompact = compactStep != nil
        let previousStep = compactStep
        compactStep = step.isFinite && step > 0 ? step : 1
        if wasCompact, previousStep != compactStep { cancelPendingTracking() }
        slider.value = normalizedValue(slider.value)
        lastCommittedValue = slider.value
        guard !wasCompact else {
            refreshValueText()
            return
        }

        let rawTitle = titleLabel.text ?? ""
        let rawValue = valueText
        for label in [titleLabel, valueLabel] {
            labels.removeArrangedSubview(label)
            label.removeFromSuperview()
        }
        // Keep legacy consumers on UILabel; only DetailSeekBar gets Android's font padding.
        titleLabel = Self.makeCompactLabel(text: rawTitle, alignment: .natural)
        valueLabel = Self.makeCompactLabel(text: rawValue, alignment: .right)
        rawCompactValueText = rawValue
        removeArrangedSubview(labels)
        labels.removeFromSuperview()
        removeArrangedSubview(slider)
        slider.removeFromSuperview()
        axis = .horizontal
        alignment = .center
        spacing = 0
        [titleLabel, minusButton, slider, plusButton, valueLabel].forEach(addArrangedSubview)
        slider.usesCompactTrack = true
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.adjustValue = { [weak self] direction in self?.adjustValue(by: direction) }
        slider.beginCompactTracking = { [weak self] in self?.beginTracking() ?? false }
        slider.continueCompactTracking = { [weak self] in
            guard let self, self.isCompactTracking else { return false }
            return self.checkCompactInteraction()
        }
        slider.finishCompactTracking = { [weak self] value in self?.endTracking(value: value) }
        slider.rejectCompactTracking = { [weak self] in self?.cancelPendingTracking() }

        // ic_add.xml already has an unchanged 24pt template asset; ic_reduce has no catalog equivalent.
        let icons: [(UIButton, String, UIImage?)] = [
            (minusButton, "minus", Self.compactReduceImage),
            (plusButton, "plus", UIImage(named: "BookshelfAndroidAdd")?.withRenderingMode(.alwaysTemplate)),
        ]
        for (button, symbol, image) in icons {
            button.setImage(image, for: .normal)
            button.imageView?.contentMode = .scaleAspectFit
            button.accessibilityIdentifier = "\(slider.accessibilityIdentifier ?? "").\(symbol)"
            // legado 5f5d314 view_detail_seek_bar.xml: reduce/plus content descriptions.
            let actionName = symbol == "minus" ? "\u{51CF}" : "\u{52A0}"
            button.accessibilityLabel = "\(actionName)\(rawTitle)"
        }
        minusButton.addAction(UIAction { [weak self] _ in self?.adjustValue(by: -1) }, for: .touchUpInside)
        plusButton.addAction(UIAction { [weak self] _ in self?.adjustValue(by: 1) }, for: .touchUpInside)
        accessibilityElements = [minusButton, slider, plusButton]
        setInteractionEnabled(isInteractionEnabled)

        // view_detail_seek_bar.xml: 60 / 24 / flexible / 24 / 60; only the track is 25dp high.
        let rowHeight = heightAnchor.constraint(equalToConstant: 25)
        rowHeight.priority = .defaultHigh
        let trackWidth = slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 24)
        trackWidth.priority = UILayoutPriority(999)
        var constraints = [
            rowHeight, trackWidth,
            heightAnchor.constraint(greaterThanOrEqualToConstant: 25),
            heightAnchor.constraint(greaterThanOrEqualTo: titleLabel.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualTo: valueLabel.heightAnchor),
            titleLabel.widthAnchor.constraint(equalToConstant: 60),
            valueLabel.widthAnchor.constraint(equalToConstant: 60),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 12),
            slider.heightAnchor.constraint(equalToConstant: 25),
        ]
        for button in [minusButton, plusButton] {
            constraints.append(button.widthAnchor.constraint(equalToConstant: 24))
            constraints.append(button.heightAnchor.constraint(equalToConstant: 24))
        }
        NSLayoutConstraint.activate(constraints)
        updateCompactFont()
        apply(palette: palette ?? ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection))
        refreshValueText()
    }

    private static func makeCompactLabel(text: String, alignment: NSTextAlignment) -> AndroidExploreTextLabel {
        let label = AndroidExploreTextLabel()
        label.text = compactDisplayText(text)
        label.accessibilityLabel = text
        label.textAlignment = alignment
        label.numberOfLines = 1
        // Non-editable singleLine TextViews default to END ellipsis, not wrapping or autosizing.
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontSizeToFitWidth = false
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        label.clipsToBounds = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }

    private static func compactDisplayText(_ text: String) -> String {
        // SingleLineTransformationMethod changes display only; AX and valueText retain the raw text.
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    // Legado 5f5d314 ic_reduce.xml (GPL-3.0): 24dp viewport, M19,13H5v-2h14v2z.
    private static let compactReduceImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
        UIColor.black.setFill()
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 19, y: 13))
        path.addLine(to: CGPoint(x: 5, y: 13))
        path.addLine(to: CGPoint(x: 5, y: 11))
        path.addLine(to: CGPoint(x: 19, y: 11))
        path.addLine(to: CGPoint(x: 19, y: 13))
        path.close()
        path.fill()
    }.withRenderingMode(.alwaysTemplate)

    func apply(palette: ReaderMenuPalette) {
        self.palette = palette
        titleLabel.textColor = palette.bodyText
        valueLabel.textColor = palette.bodyText
        minusButton.tintColor = palette.bodyText
        plusButton.tintColor = palette.bodyText
        slider.minimumTrackTintColor = palette.accent
        guard compactStep != nil else { return }

        func track(_ color: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
            }.resizableImage(withCapInsets: .zero)
        }
        func thumb(_ color: UIColor, diameter: CGFloat = 12, outlined: Bool = false) -> UIImage {
            // Keep one image canvas for every state so pressing cannot shift the track endpoints.
            UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
                let rect = CGRect(x: (18 - diameter) / 2, y: (18 - diameter) / 2, width: diameter, height: diameter)
                if outlined {
                    color.setStroke()
                    let ring = UIBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                    ring.lineWidth = 2
                    ring.stroke()
                } else {
                    color.setFill()
                    UIBezierPath(ovalIn: rect).fill()
                }
            }
        }
        slider.setMinimumTrackImage(track(palette.accent), for: .normal)
        slider.setMaximumTrackImage(track(palette.bodyText.withAlphaComponent(0.3)), for: .normal)
        slider.setThumbImage(thumb(palette.accent), for: .normal)
        slider.setThumbImage(thumb(palette.accent, diameter: 18), for: .highlighted)
        slider.setMinimumTrackImage(track(palette.sliderDisabled), for: .disabled)
        slider.setMaximumTrackImage(track(palette.sliderDisabled), for: .disabled)
        slider.setThumbImage(thumb(palette.sliderDisabled, outlined: true), for: .disabled)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if compactStep != nil { updateCompactFont() }
    }

    private func updateCompactFont() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        titleLabel.font = font
        valueLabel.font = font
    }

    private func normalizedValue(_ value: Float) -> Float {
        guard let step = compactStep else { return value }
        let minimum = Double(slider.minimumValue)
        let maximum = Double(slider.maximumValue)
        let input = value.isFinite ? Double(value) : minimum
        let ticks = ((input - minimum) / Double(step)).rounded()
        // legado 5f5d314 ReadStyleDialog uses 1/100 letter-spacing ticks, including exact zero.
        let locale = Locale(identifier: "en_US_POSIX")
        let origin = Decimal(string: String(slider.minimumValue), locale: locale) ?? Decimal(minimum)
        let increment = Decimal(string: String(step), locale: locale) ?? Decimal(Double(step))
        let snapped = NSDecimalNumber(decimal: origin + Decimal(ticks) * increment).doubleValue
        return Float(Swift.min(Swift.max(snapped, minimum), maximum))
    }

    private func refreshValueText() {
        valueText = valueFormatter?(slider.value) ?? String(format: "%g", Double(slider.value))
    }

    private func adjustValue(by direction: Float) {
        guard let step = compactStep, checkCompactInteraction() else { return }
        slider.value = normalizedValue(slider.value + direction * step)
        refreshValueText()
        commitCompactValue(force: true)
    }

    private func commitCompactValue(force: Bool = false) {
        guard checkCompactInteraction() else { return }
        guard force || lastCommittedValue != slider.value else { return }
        lastCommittedValue = slider.value
        // An accepted UI submission stays authoritative until the owner supplies a newer snapshot.
        authoritativeValue = (slider.value, valueText)
        onChange?(slider.value)
    }

    private func beginTracking() -> Bool {
        guard compactStep != nil, checkCompactInteraction() else { return false }
        isCompactTracking = true
        return true
    }

    private func checkCompactInteraction() -> Bool {
        guard !isCancellingPendingTracking else { return false }
        if isInteractionEnabled, isUserInteractionEnabled, !isHidden,
            window != nil,
            slider.isEnabled, slider.isUserInteractionEnabled,
            minusButton.isEnabled, plusButton.isEnabled, canInteract?() ?? true
        {
            return true
        }
        cancelPendingTracking()
        return false
    }

    private func restoreAuthoritativeValue() {
        let value = authoritativeValue?.value ?? lastCommittedValue ?? slider.value
        slider.value = normalizedValue(value)
        lastCommittedValue = slider.value
        valueText = valueFormatter?(slider.value) ?? authoritativeValue?.text ?? String(format: "%g", Double(slider.value))
    }

    @objc private func valueChanged() {
        guard compactStep != nil else {
            if valueFormatter != nil { refreshValueText() }
            onChange?(slider.value)
            return
        }
        guard checkCompactInteraction() else { return }
        // AX and step buttons commit directly; a retired native touch must never become a write.
        guard isCompactTracking else { return }
        // legado 5f5d314 DetailSeekBar: progress formats live; only onStopTrackingTouch commits.
        slider.value = normalizedValue(slider.value)
        refreshValueText()
    }

    private func endTracking(value: Float) {
        guard compactStep != nil, isCompactTracking, checkCompactInteraction() else { return }
        isCompactTracking = false
        slider.value = normalizedValue(value)
        refreshValueText()
        commitCompactValue(force: true)
    }
}
