import UIKit

final class ReaderOverflowMenuRowView: UIControl {
    // Required owner/presentation-generation veto. Nil deliberately fails closed.
    // Replacing the closure invalidates in-flight input; a consumed row is never rearmed.
    var canInteract: (() -> Bool)? {
        didSet { cancelPendingInteraction() }
    }

    private enum Metrics {
        // AppCompat 1.7.1 abc_popup_menu_item_layout, abc_list_menu_item_icon,
        // and RtlOverlay.Widget.AppCompat.PopupMenuItem{,.InternalGroup}.
        static let minimumWidth: CGFloat = 196
        static let minimumHeight: CGFloat = 48
        static let textSize: CGFloat = 16
        static let textStartMargin: CGFloat = 16
        static let endPadding: CGFloat = 16
        static let iconSize: CGFloat = 24
        static let iconStartMargin: CGFloat = 8
        static let checkboxSize: CGFloat = 32
        static let verticalPadding: CGFloat = 8
        static let touchSlop: CGFloat = 8
    }

    private struct TouchInteraction {
        let touch: UITouch
        let revision: UInt64
        let origin: CGPoint
        let rowRect: CGRect
    }

    private let titleLabel = UILabel()
    private let iconView = UIImageView()
    private let checkboxView: ReaderOverflowMenuCheckView?
    private let itemEnabled: Bool
    private var appearance = ReaderOverflowMenuAppearance(isDark: false)
    private var revision: UInt64 = 0
    private var interaction: TouchInteraction?
    private var hasActivated = false
    private var dispatchRevision: UInt64?
    private var isSendingActions = false
    private var isCancellingInteraction = false
    private var hasReceivedAccessibilityFocus = false
    private var accessibilityFocusRevision: UInt64?

    init(item: ReaderOverflowMenuView.Item) {
        itemEnabled = item.isEnabled
        checkboxView = item.isChecked.map { ReaderOverflowMenuCheckView(isChecked: $0) }
        super.init(frame: .zero)
        isEnabled = item.isEnabled
        isOpaque = false
        isMultipleTouchEnabled = false
        clipsToBounds = true

        isAccessibilityElement = true
        accessibilityIdentifier = item.identifier
        accessibilityLabel = item.title
        if let checked = item.isChecked {
            accessibilityValue =
                checked
                ? L10n.ReaderAppearance.optionSelected : L10n.ReaderAppearance.optionNotSelected
        }

        titleLabel.text = item.title
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.isAccessibilityElement = false
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        iconView.image = item.image?.withRenderingMode(.alwaysTemplate)
        iconView.isHidden = item.image == nil
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false
        iconView.isUserInteractionEnabled = false
        addSubview(iconView)
        if let checkboxView { addSubview(checkboxView) }

        updateTypography()
        updateAppearance()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(applicationBecameInactive), name: UIApplication.willResignActiveNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(applicationBecameInactive), name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(sceneBecameInactive(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func apply(_ appearance: ReaderOverflowMenuAppearance) {
        self.appearance = appearance
        updateAppearance()
    }

    func preferredWidth(maximum: CGFloat) -> CGFloat {
        guard !maximum.isNaN, maximum > 0 else { return 0 }
        let textWidth = titleLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ).width
        let naturalWidth = ceil(textWidth) + horizontalChromeWidth
        return min(maximum, max(Metrics.minimumWidth, naturalWidth))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite ? max(0, size.width) : preferredWidth(maximum: .greatestFiniteMagnitude)
        let textWidth = horizontalLayout(width: width).textWidth
        let textHeight = titleLabel.sizeThatFits(
            CGSize(width: max(1, textWidth), height: CGFloat.greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: width,
            height: max(Metrics.minimumHeight, ceil(textHeight) + Metrics.verticalPadding * 2))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = horizontalLayout(width: bounds.width)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // RtlOverlay's textAlignment=viewStart follows the view, not the title's script.
        titleLabel.textAlignment = isRTL ? .right : .left
        func rect(start: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: bounds.minX + (isRTL ? bounds.width - start - width : start),
                y: bounds.midY - height / 2, width: width, height: height)
        }

        titleLabel.frame = rect(
            start: layout.textStart, width: layout.textWidth,
            height: max(0, bounds.height - Metrics.verticalPadding * 2))
        iconView.frame = rect(start: layout.iconStart, width: layout.iconWidth, height: layout.iconWidth)
        checkboxView?.frame = rect(
            start: bounds.width - layout.endPadding - layout.checkboxWidth,
            width: layout.checkboxWidth, height: layout.checkboxWidth)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            cancelPendingInteraction()
            updateTypography()
            // The popup owns the frames and scroll viewport, including when its width changes.
            var ancestor = superview
            while let view = ancestor, !(view is UIWindow) {
                view.setNeedsLayout()
                ancestor = view.superview
            }
        }
        setNeedsLayout()
    }

    private var horizontalChromeWidth: CGFloat {
        Metrics.textStartMargin + Metrics.endPadding
            + (iconView.isHidden ? 0 : Metrics.iconSize)
            + (checkboxView == nil ? 0 : Metrics.checkboxSize)
    }

    private func horizontalLayout(width: CGFloat) -> (
        textStart: CGFloat, textWidth: CGFloat, endPadding: CGFloat,
        iconStart: CGFloat, iconWidth: CGFloat, checkboxWidth: CGFloat
    ) {
        // Preserve Android metrics at 240pt and above; only impossible sub-chrome widths compress slots.
        let scale = min(1, max(0, width - 1) / horizontalChromeWidth)
        let iconWidth = (iconView.isHidden ? 0 : Metrics.iconSize) * scale
        let checkboxWidth = (checkboxView == nil ? 0 : Metrics.checkboxSize) * scale
        let start = Metrics.textStartMargin * scale + iconWidth
        let end = Metrics.endPadding * scale
        return (
            start, max(0, width - start - end - checkboxWidth), end,
            Metrics.iconStartMargin * scale, iconWidth, checkboxWidth
        )
    }

    private func updateTypography() {
        // AppCompat titles are single-line; only accessibility sizes opt into wrapping.
        let allowsWrapping = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        titleLabel.numberOfLines = allowsWrapping ? 0 : 1
        titleLabel.lineBreakMode = allowsWrapping ? .byWordWrapping : .byTruncatingTail
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: Metrics.textSize, textStyle: .body, compatibleWith: traitCollection)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateAppearance() {
        let enabled = itemEnabled && isEnabled
        titleLabel.textColor = enabled ? appearance.text : appearance.disabledText
        // applyOpenTint sets a scalar primaryText tint, with no disabled selector.
        iconView.tintColor = appearance.icon
        if let checkboxView {
            checkboxView.tintColor =
                enabled
                ? (checkboxView.isChecked ? appearance.checked : appearance.control)
                : appearance.disabledControl
        }
        var traits: UIAccessibilityTraits = .button
        if checkboxView?.isChecked == true { traits.insert(.selected) }
        if !enabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        updateHighlight()
    }

    override var isHighlighted: Bool {
        didSet { updateHighlight() }
    }

    private func updateHighlight() {
        backgroundColor = isHighlighted && itemEnabled && isEnabled ? appearance.highlight : .clear
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { cancelPendingInteraction() }
            updateAppearance()
        }
    }

    override var isHidden: Bool {
        didSet { if isHidden { cancelPendingInteraction() } }
    }

    override var alpha: CGFloat {
        didSet { if alpha <= 0.01 { cancelPendingInteraction() } }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelPendingInteraction() } }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { cancelPendingInteraction() }
        super.willMove(toSuperview: newSuperview)
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { cancelPendingInteraction() }
        super.willMove(toWindow: newWindow)
    }

    func cancelPendingTracking() {
        cancelPendingInteraction()
    }

    func cancelPendingInteraction() {
        guard !isCancellingInteraction else { return }
        isCancellingInteraction = true
        revision &+= 1
        interaction = nil
        dispatchRevision = nil
        accessibilityFocusRevision = nil
        isHighlighted = false
        super.cancelTracking(with: nil)
        isCancellingInteraction = false
    }

    @objc private func applicationBecameInactive() {
        cancelPendingInteraction()
    }

    @objc private func sceneBecameInactive(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        cancelPendingInteraction()
    }

    private var interactionAllowed: Bool {
        guard !hasActivated, !isCancellingInteraction, itemEnabled, isEnabled,
            UIApplication.shared.applicationState == .active,
            let window, window.windowScene?.activationState == .foregroundActive,
            canInteract?() == true
        else { return false }

        var visibleRect = convert(bounds, to: window).intersection(window.bounds)
        var opacity: CGFloat = 1
        var ancestor: UIView? = self
        while let view = ancestor {
            opacity *= view.alpha
            guard !view.isHidden, opacity > 0.01, view.isUserInteractionEnabled,
                !view.accessibilityElementsHidden
            else { return false }
            if let scrollView = view as? UIScrollView {
                let panState = scrollView.panGestureRecognizer.state
                guard !scrollView.isDragging, !scrollView.isDecelerating,
                    panState != .began, panState != .changed
                else { return false }
            }
            if view.clipsToBounds { visibleRect = visibleRect.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        guard !visibleRect.isNull, !visibleRect.isEmpty,
            visibleRect.width.isFinite, visibleRect.height.isFinite
        else { return false }
        // Covers clipped-off rows and rows obscured by a newer child/modal in the same window.
        guard let hit = window.hitTest(CGPoint(x: visibleRect.midX, y: visibleRect.midY), with: nil) else {
            return false
        }
        return hit === self || hit.isDescendant(of: self)
    }

    // Own touch delivery rather than combining a manual commit with UIControl's automatic up event.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard interaction == nil, touches.count == 1, let touch = touches.first else {
            cancelPendingInteraction()
            return
        }
        _ = beginTracking(touch, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = interaction?.touch, touches.contains(touch) else { return }
        _ = continueTracking(touch, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = interaction?.touch, touches.contains(touch) else { return }
        endTracking(touch, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelTracking(with: event)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let currentRevision = revision
        guard interaction == nil, interactionAllowed, revision == currentRevision,
            let window, bounds.contains(touch.location(in: self))
        else { return false }
        interaction = TouchInteraction(
            touch: touch, revision: currentRevision,
            origin: touch.location(in: window), rowRect: convert(bounds, to: window))
        isHighlighted = true
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let interaction, accepts(touch, interaction: interaction) else {
            cancelPendingInteraction()
            return false
        }
        isHighlighted = true
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let interaction, let touch, accepts(touch, interaction: interaction) else {
            cancelPendingInteraction()
            return
        }
        self.interaction = nil
        isHighlighted = false
        _ = activate(revision: interaction.revision)
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelPendingInteraction()
    }

    private func accepts(_ touch: UITouch, interaction: TouchInteraction) -> Bool {
        guard interaction.touch === touch, interaction.revision == revision,
            interactionAllowed, interaction.revision == revision, let window,
            bounds.contains(touch.location(in: self))
        else { return false }
        let point = touch.location(in: window)
        let rowRect = convert(bounds, to: window)
        return hypot(point.x - interaction.origin.x, point.y - interaction.origin.y) <= Metrics.touchSlop
            && rowRect == interaction.rowRect
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        hasReceivedAccessibilityFocus = true
        let currentRevision = revision
        accessibilityFocusRevision = interactionAllowed && revision == currentRevision ? currentRevision : nil
    }

    override func accessibilityElementDidLoseFocus() {
        accessibilityFocusRevision = nil
        super.accessibilityElementDidLoseFocus()
    }

    override func accessibilityActivate() -> Bool {
        guard isAccessibilityElement, interaction == nil,
            !hasReceivedAccessibilityFocus || accessibilityFocusRevision == revision
        else { return false }
        return activate(revision: revision)
    }

    private func activate(revision expectedRevision: UInt64) -> Bool {
        guard expectedRevision == revision, interactionAllowed, expectedRevision == revision else { return false }
        hasActivated = true
        isHighlighted = false
        dispatchRevision = expectedRevision
        defer { dispatchRevision = nil }
        sendActions(for: .touchUpInside)
        return true
    }

    override func sendActions(for controlEvents: UIControl.Event) {
        guard controlEvents == .touchUpInside, dispatchRevision == revision, !isSendingActions else { return }
        isSendingActions = true
        defer { isSendingActions = false }
        super.sendActions(for: .touchUpInside)
    }
}
