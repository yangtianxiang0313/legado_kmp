import UIKit

struct ReaderPreferenceItem {
    enum Accessory {
        case action
        case value(String)
        case toggle(Bool)
    }

    let id: String
    let title: String
    var summary: String?
    let accessory: Accessory
    var toggleIdentifier: String?
    var isEnabled: Bool = true
    let isBottomBackground: Bool
    var onActivate: (() -> Void)?
    var onToggle: ((Bool) -> Void)?

    init(
        id: String,
        title: String,
        summary: String? = nil,
        accessory: Accessory = .action,
        toggleIdentifier: String? = nil,
        isEnabled: Bool = true,
        isBottomBackground: Bool = true,
        onActivate: (() -> Void)? = nil,
        onToggle: ((Bool) -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.accessory = accessory
        self.toggleIdentifier = toggleIdentifier
        self.isEnabled = isEnabled
        self.isBottomBackground = isBottomBackground
        self.onActivate = onActivate
        self.onToggle = onToggle
    }
}

final class ReaderPreferenceListView: UIView {
    let scrollView: UIScrollView = ReaderPreferenceScrollView()
    var canInteract: (() -> Bool)? {
        didSet { updateInteractionAvailability() }
    }

    private struct Anchor {
        struct Candidate {
            let id: String
            let pixelsFromVisibleTop: CGFloat
        }

        let candidates: [Candidate]
        let contentOffset: CGPoint
    }

    private var rowsByID: [String: ReaderPreferenceRow] = [:]
    private var orderedRows: [ReaderPreferenceRow] = []
    private var pendingAnchor: Anchor?
    private var accessibilityOrder: [ObjectIdentifier] = []
    private var interactionActive = true

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// The owner must deactivate before suspension, dismissal, or presenting an overlay.
    func setInteractionActive(_ active: Bool) {
        interactionActive = active
        updateInteractionAvailability()
    }

    /// IDs must be unique. Call on the main thread; supplied values are authoritative.
    func update(items: [ReaderPreferenceItem]) {
        precondition(Set(items.map(\.id)).count == items.count, "Preference IDs must be unique")

        if isScrolling {
            pendingAnchor = nil
        } else if pendingAnchor == nil {
            pendingAnchor = captureAnchor()
        }

        let retainedIDs = Set(items.map(\.id))
        for row in orderedRows where !retainedIDs.contains(row.id) {
            row.prepareForRemoval()
            row.removeFromSuperview()
            rowsByID.removeValue(forKey: row.id)
        }

        orderedRows = items.map { item in
            let row: ReaderPreferenceRow
            if let existing = rowsByID[item.id] {
                row = existing
            } else {
                row = ReaderPreferenceRow(id: item.id)
                rowsByID[item.id] = row
                row.canInteract = { [weak self, weak row] in
                    guard let self, let row, self.rowsByID[row.id] === row else { return false }
                    return self.allowsInteraction && !self.isPanning
                }
                scrollView.addSubview(row)
            }
            row.setInteractionActive(interactionActive)
            row.update(item: item)
            return row
        }

        // Retained accessibility objects stay intact, including the compact switch.
        let elements = orderedRows.map(\.accessibilityTarget)
        let order = elements.map { ObjectIdentifier($0) }
        if accessibilityOrder != order {
            scrollView.accessibilityElements = elements
            accessibilityOrder = order
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let anchor: Anchor?
        if isScrolling {
            anchor = nil
        } else if let pendingAnchor {
            // A caller or accessibility scroll may have moved since update(items:).
            anchor = pendingAnchor.contentOffset == scrollView.contentOffset ? pendingAnchor : nil
        } else {
            anchor = captureAnchor()
        }
        pendingAnchor = nil

        // Android's list has no extra padding, apart from navigation-bar insets.
        // UIKit supplies vertical safe-area adjustment; avoid side cutouts as well.
        scrollView.frame = CGRect(
            x: safeAreaInsets.left, y: 0,
            width: max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right),
            height: bounds.height)

        let width = scrollView.bounds.width
        guard width > 0 else { return }
        var y: CGFloat = 0
        for row in orderedRows {
            let height = row.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            row.frame = CGRect(x: 0, y: y, width: width, height: height)
            y += height
        }

        let contentSize = CGSize(width: width, height: y)
        if scrollView.contentSize != contentSize {
            scrollView.contentSize = contentSize
        }
        if let anchor, !isScrolling {
            restore(anchor: anchor)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            for row in orderedRows { row.setInteractionActive(false) }
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateInteractionAvailability()
    }

    override var isUserInteractionEnabled: Bool {
        didSet { updateInteractionAvailability() }
    }

    override var isHidden: Bool {
        didSet { updateInteractionAvailability() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        for row in orderedRows { row.updateTypography() }
        setNeedsLayout()
    }

    private func configure() {
        backgroundColor = AndroidReplicaTheme.bottomBackground
        tintColor = ReaderPreferenceAppearance.accent
        scrollView.backgroundColor = .clear
        scrollView.isAccessibilityElement = false
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.delaysContentTouches = true
        scrollView.canCancelContentTouches = true
        scrollView.contentInsetAdjustmentBehavior = .automatic
        addSubview(scrollView)
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(accessibilityFocusDidChange(_:)),
            name: UIAccessibility.elementFocusedNotification, object: nil)
    }

    private var allowsInteraction: Bool {
        guard interactionActive, canInteract?() != false, let window else { return false }
        if let scene = window.windowScene, scene.activationState != .foregroundActive { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0.01 else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func updateInteractionAvailability() {
        for row in orderedRows { row.setInteractionActive(interactionActive) }
    }

    @objc private func accessibilityFocusDidChange(_ notification: Notification) {
        let element = notification.userInfo?[UIAccessibility.focusedElementUserInfoKey] as? NSObject
        for row in orderedRows { row.accessibilityFocusDidChange(to: element) }
    }

    private var isPanning: Bool {
        let state = scrollView.panGestureRecognizer.state
        return scrollView.isDragging || scrollView.isDecelerating || state == .began || state == .changed
    }

    private var isScrolling: Bool {
        let state = scrollView.panGestureRecognizer.state
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
            || state == .began || state == .changed
    }

    private var pixelScale: CGFloat {
        max(1, window?.screen.scale ?? traitCollection.displayScale)
    }

    private func captureAnchor() -> Anchor? {
        let laidOutRows = orderedRows.filter { $0.bounds.height > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
        guard scrollView.bounds.height > 0, !laidOutRows.isEmpty else { return nil }

        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        let first = laidOutRows.firstIndex { $0.frame.maxY > top } ?? (laidOutRows.count - 1)
        // Prefer the first visible ID, then later visible IDs if that row disappears.
        let candidates = Array(laidOutRows[first...]) + Array(laidOutRows[..<first].reversed())
        return Anchor(
            candidates: candidates.map {
                Anchor.Candidate(id: $0.id, pixelsFromVisibleTop: ($0.frame.minY - top) * pixelScale)
            },
            contentOffset: scrollView.contentOffset)
    }

    private func restore(anchor: Anchor) {
        guard let candidate = anchor.candidates.first(where: { rowsByID[$0.id] != nil }),
            let row = rowsByID[candidate.id]
        else { return }

        let inset = scrollView.adjustedContentInset
        let minimum = -inset.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        let desired = row.frame.minY - candidate.pixelsFromVisibleTop / pixelScale - inset.top
        let y = min(maximum, max(minimum, desired))
        guard abs(y - scrollView.contentOffset.y) >= 0.5 / pixelScale else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
    }
}

private final class ReaderPreferenceScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor, current !== self {
            if current is ReaderAndroidSwitchControl {
                let translation = panGestureRecognizer.translation(in: self)
                let movement = translation == .zero ? panGestureRecognizer.velocity(in: self) : translation
                // Vertical drags scroll even when starting on the switch; horizontal drags belong to it.
                return abs(movement.y) >= abs(movement.x)
            }
            ancestor = current.superview
        }
        // A row is a UIControl; let a vertical drag cancel its pending activation.
        return true
    }
}

private final class ReaderPreferenceRow: UIControl {
    private static let switchActionIdentifier = UIAction.Identifier("reader.preference.toggle")

    let id: String
    var canInteract: (() -> Bool)?

    private struct SemanticContext: Equatable {
        enum Kind: Equatable { case action, value, toggle }
        let title: String
        let kind: Kind
        let toggleIdentifier: String?
        let hasHandler: Bool

        init(item: ReaderPreferenceItem) {
            title = item.title
            switch item.accessory {
            case .action: kind = .action
            case .value: kind = .value
            case .toggle: kind = .toggle
            }
            toggleIdentifier = kind == .toggle ? item.toggleIdentifier : nil
            hasHandler = kind == .toggle ? item.onToggle != nil : item.onActivate != nil
        }
    }

    private struct TouchInteraction {
        let revision: UInt64
        let touch: UITouch
        let origin: CGPoint
    }

    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let valueChip = UIView()
    private let valueLabel = UILabel()
    private var switchControl: ReaderAndroidSwitchControl?
    private var isToggle = false
    private var toggleValue = false
    private var itemEnabled = true
    private var ownerActive = true
    private var bindingRevision: UInt64 = 0
    private var semanticContext: SemanticContext?
    private var focusedSemanticContext: SemanticContext?
    private var hasAccessibilityFocus = false
    private var touchInteraction: TouchInteraction?
    private var isCancellingInteraction = false
    private var onActivate: (() -> Void)?
    private var onToggle: ((Bool) -> Void)?

    var accessibilityTarget: UIView {
        if isToggle, let switchControl { return switchControl }
        return self
    }

    override var canBecomeFocused: Bool { allowsInteraction && !isToggle }

    override var isHighlighted: Bool {
        didSet { updateHighlight() }
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                cancelPendingInteraction()
            }
            switchControl?.isEnabled = isEnabled && isToggle
            titleLabel.alpha = isEnabled ? 1 : 0.38
            summaryLabel.alpha = isEnabled ? 1 : 0.38
            valueChip.alpha = isEnabled ? 1 : 0.38
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            updateHighlight()
        }
    }

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        accessibilityIdentifier = id
        for label in [titleLabel, summaryLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.textAlignment = .natural
            label.adjustsFontSizeToFitWidth = false
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            addSubview(label)
        }
        titleLabel.textColor = ReaderPreferenceAppearance.title
        summaryLabel.textColor = ReaderPreferenceAppearance.summary
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byClipping
        valueLabel.numberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.textAlignment = .center
        valueLabel.textColor = ReaderPreferenceAppearance.title
        valueLabel.adjustsFontSizeToFitWidth = false
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.isAccessibilityElement = false
        valueChip.isAccessibilityElement = false
        valueChip.isUserInteractionEnabled = false
        valueChip.isHidden = true
        valueChip.clipsToBounds = true
        valueChip.layer.cornerRadius = ReaderPreferenceAppearance.valueCornerRadius
        valueChip.addSubview(valueLabel)
        addSubview(valueChip)
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func update(item: ReaderPreferenceItem) {
        // Closures are not comparable: never let a pre-refresh touch use a newly bound handler.
        bindingRevision &+= 1
        cancelPendingInteraction()
        semanticContext = SemanticContext(item: item)
        onActivate = item.onActivate
        onToggle = item.onToggle
        itemEnabled = item.isEnabled
        titleLabel.textColor =
            item.isBottomBackground ? ReaderPreferenceAppearance.title : AndroidReplicaTheme.primaryText
        summaryLabel.textColor =
            item.isBottomBackground ? ReaderPreferenceAppearance.summary : AndroidReplicaTheme.summaryText
        valueLabel.textColor = titleLabel.textColor
        if titleLabel.text != item.title { titleLabel.text = item.title }
        if summaryLabel.text != item.summary { summaryLabel.text = item.summary }
        titleLabel.isHidden = item.title.isEmpty
        summaryLabel.isHidden = item.summary?.isEmpty != false

        if case .value(let value) = item.accessory {
            valueChip.isHidden = false
            if valueLabel.text != value { valueLabel.text = value }
        } else {
            valueChip.isHidden = true
        }

        switch item.accessory {
        case .action, .value:
            isToggle = false
            switchControl?.isHidden = true
        case .toggle(let value):
            isToggle = true
            let control = existingSwitch()
            let revision = bindingRevision
            control.canInteract = { [weak self, weak control] in
                guard let self, let control, self.switchControl === control, self.isToggle else { return false }
                return self.allowsInteraction && revision == self.bindingRevision
            }
            control.removeAction(identifiedBy: Self.switchActionIdentifier, for: .valueChanged)
            control.addAction(
                UIAction(identifier: Self.switchActionIdentifier) { [weak self, weak control] _ in
                    guard let self, let control else { return }
                    self.switchValueChanged(control, revision: revision)
                }, for: .valueChanged)
            control.isHidden = false
            toggleValue = value
            control.setOn(value, animated: false)
            control.accessibilityIdentifier = item.toggleIdentifier
        }

        updateAvailability()
        isAccessibilityElement = !isToggle
        let label = [item.title, item.summary].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
        accessibilityLabel = label
        accessibilityValue = valueChip.isHidden ? nil : valueLabel.text
        switchControl?.accessibilityLabel = label
        accessibilityElements = isToggle ? switchControl.map { [$0] } : nil
        setNeedsLayout()
    }

    func prepareForRemoval() {
        bindingRevision &+= 1
        ownerActive = false
        onActivate = nil
        onToggle = nil
        updateAvailability()
    }

    func setInteractionActive(_ active: Bool) {
        ownerActive = active
        // A presented child can temporarily veto input while the owner remains active.
        if !active || canInteract?() != true { cancelPendingInteraction() }
        updateAvailability()
    }

    func accessibilityFocusDidChange(to element: NSObject?) {
        hasAccessibilityFocus = element === accessibilityTarget
        focusedSemanticContext = hasAccessibilityFocus ? semanticContext : nil
    }

    private var allowsInteraction: Bool {
        isEnabled && itemEnabled && ownerActive && !isCancellingInteraction
            && isUserInteractionEnabled && !isHidden && window != nil
            && canInteract?() == true
            && (!hasAccessibilityFocus || focusedSemanticContext == semanticContext)
    }

    private func updateAvailability() {
        isEnabled = itemEnabled && ownerActive
    }

    private func restoreToggleValue() {
        switchControl?.setOn(toggleValue, animated: false)
    }

    private func cancelPendingInteraction() {
        guard !isCancellingInteraction else { return }
        isCancellingInteraction = true
        defer { isCancellingInteraction = false }
        cancelTracking(with: nil)
        let interactive = isUserInteractionEnabled
        isUserInteractionEnabled = false
        isUserInteractionEnabled = interactive
        if let switchControl {
            switchControl.cancelTracking(with: nil)
            // Also invalidate UIKit's live touch delivery, not just the control's draft.
            let interactive = switchControl.isUserInteractionEnabled
            switchControl.isUserInteractionEnabled = false
            switchControl.isUserInteractionEnabled = interactive
        }
        restoreToggleValue()
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let revision = bindingRevision
        guard allowsInteraction, revision == bindingRevision else { return false }
        touchInteraction = TouchInteraction(revision: revision, touch: touch, origin: touch.location(in: self))
        isHighlighted = true
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let interaction = touchInteraction, interaction.touch === touch,
            allowsInteraction, interaction.revision == bindingRevision
        else {
            cancelTracking(with: event)
            return false
        }
        let point = touch.location(in: self)
        guard abs(point.x - interaction.origin.x) < 10, abs(point.y - interaction.origin.y) < 10 else {
            cancelTracking(with: event)
            return false
        }
        isHighlighted = bounds.contains(point)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let interaction = touchInteraction
        touchInteraction = nil
        isHighlighted = false
        super.endTracking(touch, with: event)
        guard let touch, let interaction, interaction.touch === touch,
            bounds.contains(touch.location(in: self)),
            abs(touch.location(in: self).x - interaction.origin.x) < 10,
            abs(touch.location(in: self).y - interaction.origin.y) < 10
        else { return }
        _ = activate(revision: interaction.revision)
    }

    override func cancelTracking(with event: UIEvent?) {
        touchInteraction = nil
        isHighlighted = false
        super.cancelTracking(with: event)
        restoreToggleValue()
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            if !isUserInteractionEnabled { cancelPendingInteraction() }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { cancelPendingInteraction() }
        super.willMove(toWindow: newWindow)
    }

    func updateTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        summaryLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        valueLabel.font = summaryLabel.font
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        switchControl?.onTintColor = tintColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        superview?.superview?.setNeedsLayout()
    }

    override func accessibilityActivate() -> Bool {
        guard isAccessibilityElement else { return false }
        return activate(revision: bindingRevision)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateHighlight()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let metrics = measure(width: size.width)
        return CGSize(width: size.width, height: metrics.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let metrics = measure(width: bounds.width)
        let bodyHeight = bounds.height
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let textX =
            isRTL
            ? bounds.width - ReaderPreferenceAppearance.horizontalPadding - metrics.textWidth
            : ReaderPreferenceAppearance.horizontalPadding
        let textY = (bodyHeight - metrics.textHeight) / 2
        titleLabel.frame = CGRect(
            x: textX, y: textY, width: metrics.textWidth, height: metrics.titleHeight)
        summaryLabel.frame = CGRect(
            x: textX,
            y: textY + metrics.titleHeight + metrics.summaryGap,
            width: metrics.textWidth, height: metrics.summaryHeight)
        if isToggle, let switchControl {
            switchControl.frame = CGRect(
                x: isRTL
                    ? ReaderPreferenceAppearance.horizontalPadding
                    : bounds.width - ReaderPreferenceAppearance.horizontalPadding - metrics.switchSize.width,
                y: (bodyHeight - metrics.switchSize.height) / 2,
                width: metrics.switchSize.width, height: metrics.switchSize.height)
        }
        if !valueChip.isHidden {
            let appearance = ReaderPreferenceAppearance.self
            valueChip.frame = CGRect(
                x: isRTL
                    ? appearance.horizontalPadding
                    : bounds.width - appearance.horizontalPadding - metrics.valueSize.width,
                y: (bodyHeight - metrics.valueSize.height) / 2,
                width: metrics.valueSize.width, height: metrics.valueSize.height)
            valueLabel.frame = CGRect(
                x: appearance.valueHorizontalPadding, y: appearance.valueVerticalPadding,
                width: max(1, metrics.valueSize.width - appearance.valueHorizontalPadding * 2),
                height: max(0, metrics.valueSize.height - appearance.valueVerticalPadding * 2))
        }
    }

    private func existingSwitch() -> ReaderAndroidSwitchControl {
        if let switchControl { return switchControl }
        let control = ReaderAndroidSwitchControl(frame: .zero)
        control.onTintColor = tintColor
        control.isAccessibilityElement = true
        // Nested UIControls do not bubble touchUpInside to the row.
        addSubview(control)
        switchControl = control
        return control
    }

    private func activate(revision: UInt64) -> Bool {
        guard allowsInteraction, revision == bindingRevision else {
            restoreToggleValue()
            return false
        }
        if isToggle, let switchControl {
            guard let onToggle else { return false }
            let value = !toggleValue
            toggleValue = value
            switchControl.setOn(value, animated: !UIAccessibility.isReduceMotionEnabled)
            onToggle(value)
            return true
        }
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    private func switchValueChanged(_ sender: ReaderAndroidSwitchControl, revision: UInt64) {
        guard sender === switchControl, isToggle, sender.isEnabled, allowsInteraction,
            revision == bindingRevision, let onToggle
        else {
            sender.setOn(toggleValue, animated: false)
            return
        }
        let value = sender.isOn
        guard value != toggleValue else { return }
        toggleValue = value
        onToggle(value)
    }

    private func updateHighlight() {
        let isPressed = isEnabled && (isHighlighted || isFocused)
        backgroundColor =
            isPressed
            ? ReaderPreferenceAppearance.pressed : .clear
        valueChip.backgroundColor =
            isPressed
            ? ReaderPreferenceAppearance.valuePressed : ReaderPreferenceAppearance.pressed
    }

    private func measure(width: CGFloat) -> (
        height: CGFloat, textWidth: CGFloat, textHeight: CGFloat,
        titleHeight: CGFloat, summaryHeight: CGFloat, summaryGap: CGFloat,
        switchSize: CGSize, valueSize: CGSize
    ) {
        let appearance = ReaderPreferenceAppearance.self
        let switchSize = isToggle ? (switchControl?.sizeThatFits(.zero) ?? .zero) : .zero
        var widgetWidth = isToggle ? switchSize.width + appearance.widgetHorizontalMargin : 0
        // view_preference.xml keeps 8dp margins above/below the widget container.
        var widgetHeight = isToggle ? switchSize.height + appearance.widgetVerticalMargin * 2 : 0
        var valueSize = CGSize.zero
        if !valueChip.isHidden {
            let availableWidth = max(1, width - appearance.horizontalPadding * 2)
            let unconstrained = CGSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            let naturalValueWidth =
                ceil(valueLabel.sizeThatFits(unconstrained).width)
                + appearance.valueHorizontalPadding * 2
            // The wrap-content widget is measured before the title's 0dp/weight=1 column.
            let maximumValueWidth = max(1, availableWidth - appearance.widgetHorizontalMargin)
            let valueWidth = min(naturalValueWidth, maximumValueWidth)
            let valueTextSize = valueLabel.sizeThatFits(
                CGSize(
                    width: max(1, valueWidth - appearance.valueHorizontalPadding * 2),
                    height: .greatestFiniteMagnitude))
            valueSize = CGSize(
                width: valueWidth,
                height: ceil(max(valueLabel.font.lineHeight, valueTextSize.height))
                    + appearance.valueVerticalPadding * 2)
            widgetWidth = valueSize.width + appearance.widgetHorizontalMargin
            widgetHeight = valueSize.height + appearance.widgetVerticalMargin * 2
        }
        let textWidth = max(1, width - appearance.horizontalPadding * 2 - widgetWidth)
        let fitting = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let titleHeight = titleLabel.isHidden ? 0 : ceil(titleLabel.sizeThatFits(fitting).height)
        let summaryHeight = summaryLabel.isHidden ? 0 : ceil(summaryLabel.sizeThatFits(fitting).height)
        let summaryGap: CGFloat = summaryLabel.isHidden ? 0 : appearance.summaryGap
        let textHeight = titleHeight + summaryGap + summaryHeight
        let bodyHeight = max(
            appearance.minimumHeight,
            max(textHeight, widgetHeight) + appearance.verticalPadding * 2)
        return (
            ceil(bodyHeight),
            textWidth, textHeight, titleHeight, summaryHeight, summaryGap, switchSize, valueSize
        )
    }
}

private enum ReaderPreferenceAppearance {
    // legado 5f5d31404: view_preference.xml, not preference_material.xml.
    // bindView() makes preference_icon GONE when absent, including the last two XML rows.
    // Preference.Material disallows dividers above these rows; there are no category separators.
    static let minimumHeight: CGFloat = 60
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 10
    static let summaryGap: CGFloat = 8
    static let widgetHorizontalMargin: CGFloat = 8
    static let widgetVerticalMargin: CGFloat = 8
    // item_fillet_text.xml and shape_fillet_btn.xml. inflate(..., null) drops the root's 3dp margin.
    static let valueHorizontalPadding: CGFloat = 12
    static let valueVerticalPadding: CGFloat = 4
    static let valueCornerRadius: CGFloat = 16

    static let title = UIColor { traits in
        ReaderPaletteColor.primaryText(on: AndroidReplicaTheme.bottomBackground.resolvedColor(with: traits))
    }
    static let summary = UIColor { traits in
        // MaterialValueHelper.getSecondaryTextColor uses dark PRIMARY text on dark backgrounds.
        let background = AndroidReplicaTheme.bottomBackground.resolvedColor(with: traits)
        return ReaderPaletteColor.argb(ReaderPaletteColor.isLight(background) ? 0x8A00_0000 : 0xFFFF_FFFF)
    }
    static let pressed = color(light: 0x63AC_ACAC, dark: 0x634D_4D4D)
    static let valuePressed = color(light: 0x6385_8585, dark: 0x6368_6868)
    static let accent = AndroidReplicaTheme.accent

    private static func color(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let argb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((argb >> 16) & 0xFF) / 255,
                green: CGFloat((argb >> 8) & 0xFF) / 255,
                blue: CGFloat(argb & 0xFF) / 255,
                alpha: CGFloat((argb >> 24) & 0xFF) / 255)
        }
    }
}
