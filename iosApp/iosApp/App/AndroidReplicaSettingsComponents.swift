import UIKit

final class AndroidReplicaSettingsSectionHeader: UIView {
    private let label = AndroidExploreTextLabel()
    private let divider = UIView()
    private let dividerHeight: CGFloat

    init(title: String, allowsDividerAbove: Bool = true) {
        dividerHeight = allowsDividerAbove ? 8 : 0
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        divider.backgroundColor = AndroidReplicaSettingsPreferenceAppearance.categoryDivider
        divider.isAccessibilityElement = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        label.text = title
        label.textColor = AndroidReplicaTheme.accent
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontForContentSizeCategory = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.isAccessibilityElement = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .header
        updateTypography()
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: dividerHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textSize = label.sizeThatFits(
            CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: dividerHeight + 24 + ceil(textSize.height))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
        }
        applyPalette()
    }

    func applyPalette() {
        backgroundColor = AndroidReplicaTheme.background
        divider.backgroundColor = AndroidReplicaSettingsPreferenceAppearance.categoryDivider
        label.textColor = AndroidReplicaTheme.accent
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        prepareTextLayout(width: targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority)
    }

    override func layoutSubviews() {
        prepareTextLayout(width: bounds.width)
        super.layoutSubviews()
    }

    private func prepareTextLayout(width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        let textWidth = max(1, width - 16)
        if label.preferredMaxLayoutWidth != textWidth { label.preferredMaxLayoutWidth = textWidth }
    }

    private func updateTypography() {
        // The custom category XML inherits Widget.Material.TextView's 14sp small appearance.
        label.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        invalidateIntrinsicContentSize()
    }
}

final class AndroidReplicaSettingsRowCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaSettingsRowCell"
    private static let toggleActionIdentifier = UIAction.Identifier("settings.preference.toggle")

    /// Change when the owner binds a different row/session; nil keeps existing callers valid.
    var bindingGeneration: UInt64? {
        didSet {
            if oldValue != bindingGeneration { invalidateBinding() }
        }
    }

    /// Capture the owner weakly. Nil allows input while the cell is attached and visible.
    var canInteract: (() -> Bool)? {
        didSet { invalidateBinding() }
    }

    var onToggle: ((Bool) -> Void)? {
        didSet { invalidateBinding() }
    }

    var onActivate: (() -> Void)? {
        didSet { invalidateBinding() }
    }

    private let titleLabel = ReaderTocSingleLineLabel()
    private let detailLabel = AndroidExploreTextLabel()
    private var rawTitle: String?
    private let textStack = UIStackView()
    private let toggle = ReaderAndroidSwitchControl(frame: .zero)
    private let colorPreview = AndroidReplicaSettingsColorPreview()
    private var textToEdge: NSLayoutConstraint!
    private var toggleConstraints: [NSLayoutConstraint] = []
    private var previewConstraints: [NSLayoutConstraint] = []
    private var isToggleRow = false
    private var isConfigured = false
    private var modelValue = false
    private var bindingRevision: UInt64 = 0
    private var rowTapRevision: UInt64?
    private var cancellingTracking = false
    private var switchPressed = false
    private var reuseRevision: UInt64 = 0
    private var focusedContext: AccessibilityContext?
    private var hasAccessibilityFocus = false
    private lazy var rowTap: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(rowTapped))
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = true
        recognizer.allowedPressTypes = []
        return recognizer
    }()

    private struct AccessibilityContext: Equatable {
        let title: String?
        let isToggle: Bool
        let generation: UInt64?
        let reuseRevision: UInt64
    }

    var isTrackingInteraction: Bool { toggle.isTracking || isHighlighted }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none
        accessoryType = .none
        isAccessibilityElement = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        detailLabel.textColor = AndroidReplicaSettingsPreferenceAppearance.summary
        for label in [titleLabel, detailLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.textAlignment = .natural
            label.adjustsFontForContentSizeCategory = false
            label.adjustsFontSizeToFitWidth = false
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(label)
        }
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 8
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        textStack.isAccessibilityElement = false
        toggle.onTintColor = AndroidReplicaTheme.accent
        toggle.isAccessibilityElement = false
        toggle.isHidden = true
        toggle.addTarget(self, action: #selector(switchTouchBegan), for: .touchDown)
        toggle.addTarget(
            self, action: #selector(switchTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel])

        for item in [textStack, toggle, colorPreview] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        textToEdge = textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        // view_preference.xml: 10dp outer padding; the widget has its own 8dp margins.
        toggleConstraints = [
            textStack.trailingAnchor.constraint(equalTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 47),
            toggle.heightAnchor.constraint(equalToConstant: 27),
            toggle.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 18),
            toggle.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
        ]
        // ColorPreference.onBindView overrides the circle widget to 30dp; outer padding remains 16/10dp.
        previewConstraints = [
            textStack.trailingAnchor.constraint(equalTo: colorPreview.leadingAnchor, constant: -8),
            colorPreview.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            colorPreview.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            colorPreview.widthAnchor.constraint(equalToConstant: 30),
            colorPreview.heightAnchor.constraint(equalToConstant: 30),
            colorPreview.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 18),
            colorPreview.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
        ]
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            textToEdge,
        ])
        contentView.addGestureRecognizer(rowTap)
        updateTypography()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(deactivated(_:)),
            name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(deactivated(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func prepareForReuse() {
        super.prepareForReuse()
        isConfigured = false
        reuseRevision &+= 1
        cancelPendingTracking()
        onToggle = nil
        onActivate = nil
        canInteract = nil
        bindingGeneration = nil
        rawTitle = nil
        titleLabel.text = nil
        detailLabel.text = nil
        updateAccessory(isToggle: isToggleRow, previewColor: nil)
        updateAccessibility()
        setSelected(false, animated: false)
    }

    func configure(
        title: String, detail: String?, iconName _: String, isToggle: Bool, isOn: Bool,
        previewColor: UIColor? = nil
    ) {
        invalidateBinding()
        isConfigured = true
        if rawTitle != title {
            rawTitle = title
            titleLabel.text = title
        }
        if detailLabel.text != detail { detailLabel.text = detail }
        titleLabel.isHidden = title.isEmpty
        detailLabel.isHidden = detail?.isEmpty != false
        updateAccessory(isToggle: isToggle, previewColor: previewColor)
        modelValue = isOn
        toggle.setOn(isOn, animated: false)
        updateAccessibility()
        setNeedsLayout()
    }

    private func updateAccessory(isToggle: Bool, previewColor: UIColor?) {
        NSLayoutConstraint.deactivate(toggleConstraints + previewConstraints + [textToEdge])
        isToggleRow = isToggle
        toggle.isHidden = !isToggle
        colorPreview.color = isToggle ? nil : previewColor
        colorPreview.isHidden = colorPreview.color == nil
        NSLayoutConstraint.activate(
            isToggle ? toggleConstraints : (colorPreview.isHidden ? [textToEdge] : previewConstraints))
    }

    /// The owner may call this before reload/removal, scrolling or presenting another screen.
    func cancelPendingTracking() {
        guard !cancellingTracking else { return }
        cancellingTracking = true
        defer { cancellingTracking = false }
        rowTapRevision = nil
        rowTap.isEnabled = false
        rowTap.isEnabled = true
        toggle.cancelTracking(with: nil)
        let interactive = toggle.isUserInteractionEnabled
        toggle.isUserInteractionEnabled = false
        toggle.isUserInteractionEnabled = interactive
        toggle.setOn(modelValue, animated: false)
        switchPressed = false
        setHighlighted(false, animated: false)
    }

    private func invalidateBinding() {
        bindingRevision &+= 1
        cancelPendingTracking()
        let revision = bindingRevision
        toggle.canInteract = { [weak self] in
            guard let self else { return false }
            return self.isToggleRow && self.onToggle != nil && self.interactionAllowed
                && self.bindingRevision == revision
        }
        toggle.removeAction(identifiedBy: Self.toggleActionIdentifier, for: .valueChanged)
        toggle.addAction(
            UIAction(identifier: Self.toggleActionIdentifier) { [weak self] _ in
                self?.toggleChanged(revision: revision)
            }, for: .valueChanged)
    }

    private var interactionAllowed: Bool {
        guard isConfigured, !cancellingTracking, let window,
            window.windowScene?.activationState != .background,
            window.windowScene?.activationState != .foregroundInactive
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 || !view.isUserInteractionEnabled { return false }
            if let control = view as? UIControl, !control.isEnabled { return false }
            if let table = view as? UITableView, table.isDragging || table.isDecelerating { return false }
            ancestor = view.superview
        }
        return canInteract?() ?? true
    }

    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === rowTap else {
            // UITableViewCell does not implement this optional delegate selector.
            return true
        }
        guard isToggleRow, onToggle != nil, interactionAllowed else { return false }
        if let view = touch.view, view === toggle || view.isDescendant(of: toggle) { return false }
        rowTapRevision = bindingRevision
        return true
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === rowTap else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        return rowTapRevision == bindingRevision && interactionAllowed
    }

    @objc private func rowTapped() {
        let revision = rowTapRevision
        rowTapRevision = nil
        guard isToggleRow, onToggle != nil, interactionAllowed, revision == bindingRevision else { return }
        _ = activateToggle()
    }

    @discardableResult
    func activateToggle() -> Bool {
        guard isToggleRow, onToggle != nil, interactionAllowed else { return false }
        return toggle.accessibilityActivate()
    }

    private func toggleChanged(revision: UInt64) {
        guard isToggleRow, interactionAllowed, revision == bindingRevision, let onToggle else {
            toggle.setOn(modelValue, animated: false)
            updateAccessibility()
            return
        }
        let target = toggle.isOn
        guard target != modelValue else { return }
        modelValue = target
        updateAccessibility()
        // Direct thumb drags can retain the current value: never invert the model here.
        onToggle(target)
    }

    private var accessibilityContext: AccessibilityContext {
        AccessibilityContext(
            title: rawTitle, isToggle: isToggleRow,
            generation: bindingGeneration, reuseRevision: reuseRevision)
    }

    private func updateAccessibility() {
        accessibilityLabel = [rawTitle, detailLabel.text]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityTraits = isToggleRow ? toggle.accessibilityTraits : .button
        accessibilityValue = isToggleRow ? toggle.accessibilityValue : colorPreview.hexValue
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        hasAccessibilityFocus = true
        focusedContext = accessibilityContext
    }

    override func accessibilityElementDidLoseFocus() {
        super.accessibilityElementDidLoseFocus()
        hasAccessibilityFocus = false
        focusedContext = nil
    }

    override func accessibilityActivate() -> Bool {
        guard interactionAllowed,
            !hasAccessibilityFocus || focusedContext == accessibilityContext
        else { return false }
        if isToggleRow {
            return activateToggle()
        }
        if let onActivate {
            onActivate()
            return true
        }
        return super.accessibilityActivate()
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelPendingTracking() } }
    }

    override var isHidden: Bool {
        didSet { if isHidden { cancelPendingTracking() } }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { cancelPendingTracking() }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if superview !== newSuperview { cancelPendingTracking() }
        super.willMove(toSuperview: newSuperview)
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        updateHighlight()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updateHighlight()
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateHighlight()
    }

    private func updateHighlight() {
        contentView.backgroundColor =
            interactionAllowed && (isHighlighted || isSelected || isFocused || switchPressed)
            ? AndroidReplicaSettingsPreferenceAppearance.pressed : .clear
    }

    @objc private func switchTouchBegan() {
        switchPressed = interactionAllowed
        updateHighlight()
    }

    @objc private func switchTouchEnded() {
        switchPressed = false
        updateHighlight()
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        cancelPendingTracking()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
        }
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection {
            cancelPendingTracking()
        }
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateAccessibility()
        }
    }

    private func updateTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        detailLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        setNeedsLayout()
    }
}

enum AndroidReplicaSettingsTypography {
    static func apply(title: UILabel, status: UILabel, retry: UIButton, traits: UITraitCollection) -> CGFloat {
        title.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traits)
        status.font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        retry.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, weight: 500, compatibleWith: traits)
        for label in [title, status] { label.adjustsFontForContentSizeCategory = false }
        return max(56, ceil(title.sizeThatFits(CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude)).height) + 8)
    }
}

/// ColorPanelView's circle without selection, hint gestures or its own accessibility element.
private final class AndroidReplicaSettingsColorPreview: UIView {
    var color: UIColor? {
        didSet { setNeedsDisplay() }
    }

    // Original cpv_alpha.png tiles, also used by ReaderColorSwatchView, repeating every 10pt.
    private static let alphaPattern2x: UIImage? = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAAAAACo4kLRAAAAJElEQVR4AWP8zwAD52AMRiTBs0NP8Cxc1BguPWQEz8EFjeCCAGiuJg7q0LsMAAAAAElFTkSuQmCC"
    ).flatMap { UIImage(data: $0, scale: 2) }
    private static let alphaPattern3x: UIImage? = Data(
        base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAB4AAAAeCAAAAAAeW/F+AAAALElEQVR4AWP8z4ACziFzGBlIlD474NKj0mcZUBQYoygeCOlR6XOo0kYkSQMATHY5FXk7yIEAAAAASUVORK5CYII="
    ).flatMap { UIImage(data: $0, scale: 3) }

    var hexValue: String? {
        guard let color else { return nil }
        let resolved = color.resolvedColor(with: traitCollection)
        let alpha = UInt32((min(1, max(0, resolved.cgColor.alpha)) * 255).rounded())
        let rgb = ReaderColorHex.hexString(color: resolved, traits: traitCollection)
        return "#" + (alpha == 255 ? "" : String(format: "%02X", alpha)) + rgb
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let color, let context = UIGraphicsGetCurrentContext() else { return }
        let diameter = min(bounds.width, bounds.height)
        let outer = CGRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
            width: diameter, height: diameter)
        let border =
            traitCollection.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 179 / 255.0) : UIColor(white: 0, alpha: 138 / 255.0)
        context.setFillColor(border.cgColor)
        context.fillEllipse(in: outer)
        let inner = outer.insetBy(dx: 1, dy: 1)
        guard inner.width > 0, inner.height > 0 else { return }
        context.saveGState()
        context.addEllipse(in: inner)
        context.clip()
        let resolved = color.resolvedColor(with: traitCollection)
        if resolved.cgColor.alpha < 1 {
            let pattern = traitCollection.displayScale >= 3 ? Self.alphaPattern3x : Self.alphaPattern2x
            pattern?.drawAsPattern(in: bounds)
        }
        context.setFillColor(resolved.cgColor)
        context.fill(inner)
        context.restoreGState()
    }
}

private enum AndroidReplicaSettingsPreferenceAppearance {
    static let summary = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 179 / 255.0, alpha: 1)
            : UIColor(white: 44 / 255.0, alpha: 138 / 255.0)
    }

    // bg_prefs_color.xml uses btn_bg_press, not the platform ripple or a rounded card.
    static let pressed = UIColor { traits in
        UIColor(white: (traits.userInterfaceStyle == .dark ? 77 : 172) / 255.0, alpha: 99 / 255.0)
    }

    static let categoryDivider = UIColor { traits in
        let background = AndroidReplicaTheme.background.resolvedColor(with: traits)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        background.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        let multiplier: CGFloat = traits.userInterfaceStyle == .dark ? 1.05 : 0.95
        return UIColor(
            hue: hue, saturation: saturation,
            brightness: min(1, brightness * multiplier), alpha: 0.5)
    }
}
