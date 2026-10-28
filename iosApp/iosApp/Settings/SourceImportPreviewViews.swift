import UIKit
import shared

enum SourceImportPreviewStyle {
    static func font(
        _ size: CGFloat, style: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(for: .systemFont(ofSize: size, weight: weight), compatibleWith: traits)
    }

    static func actionButton(title: String, identifier: String, secondary: Bool = false) -> SourceImportPreviewActionButton {
        let button = SourceImportPreviewActionButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = secondary ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.accent
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        configuration.titleLineBreakMode = .byWordWrapping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { [weak button] attributes in
            var updated = attributes
            updated.font = font(14, compatibleWith: button?.traitCollection)
            return updated
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        return button
    }

    static func actionSize(_ button: UIButton, constrainedTo width: CGFloat) -> CGSize {
        let width = max(1, width)
        let insets = button.configuration?.contentInsets ?? .zero
        let activityWidth: CGFloat = button.configuration?.showsActivityIndicator == true ? 24 : 0
        let title = button.configuration?.title ?? button.title(for: .normal) ?? ""
        let textSize = (title as NSString).boundingRect(
            with: CGSize(width: max(1, width - insets.leading - insets.trailing - activityWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font(14, compatibleWith: button.traitCollection)], context: nil
        ).size
        return CGSize(
            width: min(width, max(44, ceil(textSize.width) + insets.leading + insets.trailing + activityWidth)),
            height: max(44, ceil(textSize.height) + insets.top + insets.bottom))
    }
}

// Import-only metrics: the original style above is also used by editor/check-source screens.
enum SourceImportPreviewAndroidStyle {
    static func font(
        _ size: CGFloat, style: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(
            size: size, textStyle: style,
            weight: weight.rawValue >= UIFont.Weight.bold.rawValue
                ? 700 : (weight.rawValue >= UIFont.Weight.medium.rawValue ? 500 : 400),
            compatibleWith: traits ?? .current)
    }

    static func singleLine(_ text: String) -> String {
        // Android SingleLineTransformationMethod changes presentation, not the source name/payload.
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    static func actionButton(
        title: String, identifier: String, secondary: Bool = false, singleLine: Bool = false,
        weight: UIFont.Weight = .regular
    ) -> SourceImportPreviewActionButton {
        let button = SourceImportPreviewActionButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseForegroundColor = secondary ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.accent
        configuration.titleLineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            [weak button] attributes in
            var updated = attributes
            updated.font = font(14, style: .subheadline, weight: weight, compatibleWith: button?.traitCollection)
            return updated
        }
        button.configuration = configuration
        applyActionFontPadding(to: button, weight: weight)
        button.clipsToBounds = true
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        button.titleLabel?.numberOfLines = singleLine ? 1 : 0
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        return button
    }

    static func applyActionFontPadding(
        to button: UIButton,
        contentInsets: NSDirectionalEdgeInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
        weight: UIFont.Weight = .regular
    ) {
        guard var configuration = button.configuration else { return }
        let font = font(14, style: .subheadline, weight: weight, compatibleWith: button.traitCollection)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: button.traitCollection.displayScale)
        // TextView's includeFontPadding is additional to the XML view padding.
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: contentInsets.top + padding.top, leading: contentInsets.leading,
            bottom: contentInsets.bottom + padding.bottom, trailing: contentInsets.trailing)
        button.configuration = configuration
    }

    static func actionSize(
        _ button: UIButton, constrainedTo width: CGFloat, weight: UIFont.Weight = .regular,
        minimumSize: CGSize = CGSize(width: 44, height: 44)
    ) -> CGSize {
        let width = max(1, width)
        let insets = button.configuration?.contentInsets ?? .zero
        let activityWidth: CGFloat = button.configuration?.showsActivityIndicator == true ? 24 : 0
        let title = button.configuration?.title ?? button.title(for: .normal) ?? ""
        let textWidth = max(1, width - insets.leading - insets.trailing - activityWidth)
        let font = font(14, style: .subheadline, weight: weight, compatibleWith: button.traitCollection)
        let textSize = (title as NSString).boundingRect(
            with: CGSize(
                width: button.titleLabel?.numberOfLines == 1 ? .greatestFiniteMagnitude : textWidth,
                height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).size
        return CGSize(
            width: min(
                width, max(minimumSize.width, ceil(textSize.width) + insets.leading + insets.trailing + activityWidth)),
            height: max(minimumSize.height, ceil(max(font.lineHeight, textSize.height)) + insets.top + insets.bottom))
    }
}

/// Touch-up must not survive a scroll, coverage change or background round-trip.
final class SourceImportPreviewActionButton: UIButton {
    var canInteract: (() -> Bool)?
    private var touchArmed = false
    private var trackingLocation: CGPoint?

    private var available: Bool {
        guard isEnabled, canInteract?() != false, let window, window.isKeyWindow,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        var ancestor: UIView? = self
        var visible = convert(bounds, to: window).intersection(window.bounds)
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01, current.isUserInteractionEnabled else { return false }
            if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: window)) }
            ancestor = current.superview
        }
        let point = trackingLocation ?? CGPoint(x: visible.midX, y: visible.midY)
        guard !visible.isEmpty, !visible.isNull, visible.contains(point),
            let hit = window.hitTest(point, with: nil)
        else { return false }
        return hit === self || hit.isDescendant(of: self)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        trackingLocation = touch.location(in: window)
        guard available else {
            trackingLocation = nil
            return false
        }
        touchArmed = super.beginTracking(touch, with: event)
        return touchArmed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        trackingLocation = touches.first?.location(in: window)
        super.touchesEnded(touches, with: event)
        touchArmed = false
        trackingLocation = nil
    }

    override func cancelTracking(with event: UIEvent?) {
        touchArmed = false
        trackingLocation = nil
        super.cancelTracking(with: event)
        isHighlighted = false
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard available, event?.type != .touches || touchArmed else { return }
        super.sendAction(action, to: target, for: event)
    }

    override func sendActions(for controlEvents: UIControl.Event) {
        guard available else { return }
        super.sendActions(for: controlEvents)
    }

    override func accessibilityActivate() -> Bool {
        guard available else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}

/// Expires a dismissed editor's callback after its synchronous dismissal completion has had a chance to run.
final class SourceImportPreviewEditorLifetime: UIView {
    private let onDetach: () -> Void
    private var wasAttached = false

    init(onDetach: @escaping () -> Void) {
        self.onDetach = onDetach
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wasAttached = true
        } else if wasAttached {
            wasAttached = false
            DispatchQueue.main.async(execute: onDetach)
        }
    }
}

final class SourceImportPreviewToolbar: UIView {
    private let titleLabel = AndroidExploreTextLabel()
    private let actions: [UIView]

    init(title: String, actions: [UIView] = []) {
        self.actions = actions
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceImport.preview.title"
        addSubview(titleLabel)
        for action in actions { addSubview(action) }
        applyPalette()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyPalette()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        backgroundColor = palette.titleBackground
        titleLabel.textColor = palette.toolbarText
        for case let button as UIButton in actions {
            button.tintColor = palette.toolbarText
            button.configuration?.baseForegroundColor = palette.toolbarText
            button.setTitleColor(palette.toolbarText, for: .normal)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { layout(width: size.width, apply: false) }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layout(width: bounds.width, apply: true)
    }

    private func layout(width: CGFloat, apply: Bool) -> CGSize {
        titleLabel.font = SourceImportPreviewAndroidStyle.font(
            20, style: .headline, weight: .medium, compatibleWith: traitCollection)
        let inset = min(16, max(0, (width - 1) / 2))
        let available = max(0, width - inset)
        let iconCount = actions.filter { ($0 as? UIButton)?.configuration?.title == nil }.count
        // Material overflow: 24dp drawable, 6dp start / 10dp end padding (36dp minimum).
        let iconWidth = min(40, available / CGFloat(max(1, iconCount)))
        var remaining = max(0, available - CGFloat(iconCount) * iconWidth)
        let sizes = actions.map { action -> CGSize in
            if let button = action as? UIButton, button.configuration?.title != nil {
                // abc_action_menu_item_layout's 4dp vertical padding; Material start/end override to 12dp.
                SourceImportPreviewAndroidStyle.applyActionFontPadding(
                    to: button, contentInsets: NSDirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12),
                    weight: .medium)
                let size = SourceImportPreviewAndroidStyle.actionSize(
                    button, constrainedTo: max(1, remaining), weight: .medium,
                    minimumSize: CGSize(width: 48, height: 48))
                let result = CGSize(width: min(remaining, size.width), height: size.height)
                remaining -= result.width
                return result
            }
            if apply, let button = action as? UIButton {
                if button.configuration != nil {
                    button.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 10)
                } else {
                    let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                    button.contentEdgeInsets = UIEdgeInsets(top: 0, left: rtl ? 10 : 6, bottom: 0, right: rtl ? 6 : 10)
                }
            }
            return CGSize(width: iconWidth, height: 48)
        }
        // Toolbar title and always-visible group action remain one line, even for a long group name.
        let actionsWidth = sizes.reduce(0) { $0 + $1.width }
        let actionRowHeight = max(56, sizes.map(\.height).max() ?? 0)
        let titleStart = min(width, inset + 4)
        let titleWidth = max(0, width - titleStart - actionsWidth - 4)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0)).height)
        // Retain the dialog's 56 minimum; iOS accessibility text may need a taller natural action row.
        let height = max(actionRowHeight, titleHeight + AndroidToolbarLayout.titleVerticalMargins)
        if apply {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: rtl ? width - x - w : x, y: y, width: w, height: h)
            }
            titleLabel.frame = frame(titleStart, max(4, (height - titleHeight) / 2), titleWidth, titleHeight)
            var x = width - actionsWidth
            for (action, size) in zip(actions, sizes) {
                action.frame = frame(x, (actionRowHeight - size.height) / 2, size.width, size.height)
                x += size.width
            }
        }
        return CGSize(width: width, height: height)
    }
}

final class SourceImportPreviewCell: UITableViewCell {
    static let reuseIdentifier = "SourceImportPreviewCell"
    var onToggle: (() -> Void)?
    var onOpen: (() -> Void)?
    var canInteract: (() -> Bool)?
    private(set) var bindingID = UUID()
    private let checkbox = SourceImportPreviewActionButton(type: .custom)
    private let checkboxIcon = UIImageView()
    private let nameLabel = AndroidExploreTextLabel()
    private let statusLabel = AndroidExploreTextLabel()
    private let openButton = SourceImportPreviewAndroidStyle.actionButton(
        title: SourceImportPreviewText.open, identifier: "sourceImport.preview.open", secondary: true, singleLine: true
    )

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectedBackgroundView = UIView()
        isAccessibilityElement = false
        checkboxIcon.contentMode = .scaleAspectFit
        checkboxIcon.isAccessibilityElement = false
        checkboxIcon.isUserInteractionEnabled = false
        checkbox.addSubview(checkboxIcon)
        checkbox.addSubview(nameLabel)
        checkbox.clipsToBounds = true
        checkbox.isAccessibilityElement = true
        checkbox.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        openButton.addTarget(self, action: #selector(open), for: .touchUpInside)
        for button in [checkbox, openButton] {
            button.canInteract = { [weak self] in self?.canInteract?() == true }
            contentView.addSubview(button)
        }
        for label in [nameLabel, statusLabel] {
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            label.isUserInteractionEnabled = false
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.clipsToBounds = true
        }
        contentView.addSubview(statusLabel)
        accessibilityElements = [checkbox, openButton]
        applyPalette()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPendingTracking()
        bindingID = UUID()
        onToggle = nil
        onOpen = nil
        canInteract = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        applyPalette()
        setNeedsLayout()
    }

    func configure(candidate: SourceImportCandidate, selected: Bool, index: Int, enabled: Bool) {
        cancelPendingTracking()
        bindingID = UUID()
        let sourceName = candidate.source.bookSourceName
        let status = SourceImportPreviewText.status(for: candidate)
        nameLabel.text = SourceImportPreviewAndroidStyle.singleLine(sourceName)
        statusLabel.text = status
        updateTypography()
        checkbox.accessibilityIdentifier = "sourceImport.preview.row.\(index).checkbox"
        checkbox.accessibilityLabel = "\(sourceName)，\(status)"
        openButton.accessibilityIdentifier = "sourceImport.preview.row.\(index).open"
        openButton.accessibilityLabel = "\(SourceImportPreviewText.open)，\(sourceName)"
        accessibilityIdentifier = "sourceImport.preview.row.\(index)"
        updateSelection(selected)
        setInteractive(enabled)
        setNeedsLayout()
    }

    func updateSelection(_ selected: Bool) {
        checkbox.isSelected = selected
        checkboxIcon.image =
            UIImage(named: selected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
            .withRenderingMode(.alwaysTemplate)
        checkbox.accessibilityValue = selected ? SourceImportPreviewText.selected : SourceImportPreviewText.unselected
        checkbox.accessibilityTraits = selected ? [.button, .selected] : .button
        applyPalette()
    }

    @objc func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        selectedBackgroundView?.backgroundColor = ReaderPaletteColor.argb(
            ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0x33FF_FFFF : 0x1F00_0000)
        nameLabel.textColor = palette.primaryText
        statusLabel.textColor = palette.secondaryText
        checkboxIcon.tintColor = checkbox.isSelected ? palette.accent : palette.secondaryText
        openButton.configuration?.baseForegroundColor = palette.secondaryText
    }

    private func updateTypography() {
        nameLabel.font = SourceImportPreviewAndroidStyle.font(14, style: .subheadline, compatibleWith: traitCollection)
        statusLabel.font = SourceImportPreviewAndroidStyle.font(
            14, style: .subheadline, compatibleWith: traitCollection)
        SourceImportPreviewAndroidStyle.applyActionFontPadding(
            to: openButton, contentInsets: NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
        openButton.setNeedsUpdateConfiguration()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width, apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layout(width: contentView.bounds.width, apply: true)
    }

    private func layout(width: CGFloat, apply: Bool) -> CGFloat {
        // item_source_import.xml: 8dp root, packed checkbox/name + padded state, 12dp end margin on open.
        let stateSize = statusLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
        let stateNaturalWidth = ceil(stateSize.width) + 16
        let openSize = SourceImportPreviewAndroidStyle.actionSize(
            openButton, constrainedTo: .greatestFiniteMagnitude, minimumSize: .zero)
        let insetScale = min(1, max(0, (width - 32 - stateNaturalWidth - openSize.width) / 28))
        let leading = 8 * insetScale
        let trailing = 20 * insetScale
        let available = max(0, width - leading - trailing)
        let checkWidth = min(32, available)
        // Only impossible widths compress the controls; names always yield first and never add rows.
        let controlScale = min(1, max(0, available - checkWidth) / max(1, stateNaturalWidth + openSize.width))
        let stateWidth = stateNaturalWidth * controlScale
        let openWidth = openSize.width * controlScale
        let nameSize = nameLabel.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 0))
        let nameWidth = min(ceil(nameSize.width), max(0, available - checkWidth - stateWidth - openWidth))
        let nameHeight = ceil(nameSize.height)
        let stateHeight = ceil(stateSize.height)
        let mainHeight = max(32, nameHeight, stateHeight + 16, openSize.height)
        let height = mainHeight + 16
        if apply {
            let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
            func frame(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: rtl ? width - x - w : x, y: y, width: w, height: h)
            }
            let checkboxWidth = checkWidth + nameWidth
            checkbox.frame = frame(leading, 8, checkboxWidth, mainHeight)
            checkboxIcon.frame = CGRect(
                x: rtl ? checkboxWidth - checkWidth : 0, y: (mainHeight - 32) / 2, width: checkWidth, height: 32)
            nameLabel.frame = CGRect(
                x: rtl ? 0 : checkWidth, y: (mainHeight - nameHeight) / 2, width: nameWidth, height: nameHeight)
            let stateInset = min(8, stateWidth / 2)
            statusLabel.frame = frame(
                leading + checkboxWidth + stateInset, 8 + (mainHeight - stateHeight) / 2,
                max(0, stateWidth - stateInset * 2), stateHeight)
            openButton.frame = frame(
                width - trailing - openWidth, 8 + (mainHeight - openSize.height) / 2,
                openWidth, openSize.height)
        }
        return height
    }

    func setInteractive(_ enabled: Bool) {
        checkbox.isEnabled = enabled
        openButton.isEnabled = enabled
        checkboxIcon.alpha = enabled ? 1 : 0.38
        nameLabel.alpha = enabled ? 1 : 0.38
        if !enabled { cancelPendingTracking() }
    }

    func cancelPendingTracking() {
        checkbox.cancelTracking(with: nil)
        openButton.cancelTracking(with: nil)
        isHighlighted = false
    }

    @objc private func toggle() { if canInteract?() != false { onToggle?() } }
    @objc private func open() { if canInteract?() != false { onOpen?() } }
}

final class SourceImportPreviewFooterView: UIView {
    let selectionButton = SourceImportPreviewAndroidStyle.actionButton(
        title: "", identifier: "sourceImport.preview.selectAll"
    )
    let cancelButton = SourceImportPreviewAndroidStyle.actionButton(
        title: L10n.Common.cancel, identifier: "sourceImport.preview.cancel", secondary: true
    )
    let confirmButton: SourceImportPreviewActionButton
    private var measuredHeight: CGFloat = 44

    private struct Layout {
        let selection: CGRect
        let cancel: CGRect
        let confirm: CGRect
        let height: CGFloat
    }

    init(
        confirmTitle: String = L10n.Common.ok, showsSelection: Bool = false, identifier: String = "sourceImport.preview"
    ) {
        confirmButton = SourceImportPreviewAndroidStyle.actionButton(
            title: confirmTitle, identifier: "\(identifier).confirm")
        super.init(frame: .zero)
        selectionButton.isHidden = !showsSelection
        selectionButton.contentHorizontalAlignment = .leading
        selectionButton.titleLabel?.numberOfLines = 0
        selectionButton.titleLabel?.lineBreakMode = .byWordWrapping
        cancelButton.accessibilityIdentifier = "\(identifier).cancel"
        for button in [selectionButton, cancelButton, confirmButton] { addSubview(button) }
        applyPalette()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: layout(width: size.width).height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        for button in [selectionButton, cancelButton, confirmButton] {
            SourceImportPreviewAndroidStyle.applyActionFontPadding(to: button)
            button.setNeedsUpdateConfiguration()
        }
        applyPalette()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        backgroundColor = palette.background
        selectionButton.configuration?.baseForegroundColor = palette.accent
        cancelButton.configuration?.baseForegroundColor = palette.secondaryText
        confirmButton.configuration?.baseForegroundColor = palette.accent
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let result = layout(width: bounds.width)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (button, rect) in [(selectionButton, result.selection), (cancelButton, result.cancel), (confirmButton, result.confirm)] {
            button.frame = isRTL ? CGRect(x: bounds.width - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }
        if measuredHeight != result.height {
            measuredHeight = result.height
            invalidateIntrinsicContentSize()
        }
    }

    private func layout(width: CGFloat) -> Layout {
        // dialog_recycler_view.xml: 12dp outer horizontal padding, wrapping left count and right actions.
        let inset = min(12, max(0, (width - 1) / 2))
        let available = max(1, width - inset * 2)
        let naturalCancel = SourceImportPreviewAndroidStyle.actionSize(cancelButton, constrainedTo: available)
        let naturalConfirm = SourceImportPreviewAndroidStyle.actionSize(confirmButton, constrainedTo: available)
        let actionsWrap = naturalCancel.width + naturalConfirm.width > available
        let actionWidth = actionsWrap ? available / 2 : available
        let cancelSize = SourceImportPreviewAndroidStyle.actionSize(cancelButton, constrainedTo: actionWidth)
        let confirmSize = SourceImportPreviewAndroidStyle.actionSize(confirmButton, constrainedTo: actionWidth)
        let actionsWidth = cancelSize.width + confirmSize.width
        let actionHeight = max(cancelSize.height, confirmSize.height)
        let naturalSelection = SourceImportPreviewAndroidStyle.actionSize(selectionButton, constrainedTo: available)
        let wraps = !selectionButton.isHidden && naturalSelection.width + actionsWidth > available
        let selectionWidth = selectionButton.isHidden ? 0 : naturalSelection.width
        let selectionHeight =
            selectionButton.isHidden
            ? 0
            : SourceImportPreviewAndroidStyle.actionSize(
                selectionButton, constrainedTo: selectionWidth
            ).height
        let actionY = wraps ? selectionHeight : 0
        let height = actionY + max(actionHeight, wraps ? 0 : selectionHeight)
        return Layout(
            selection: CGRect(x: inset, y: 0, width: selectionWidth, height: wraps ? selectionHeight : height),
            cancel: CGRect(x: width - inset - actionsWidth, y: actionY, width: cancelSize.width, height: actionHeight),
            confirm: CGRect(x: width - inset - confirmSize.width, y: actionY, width: confirmSize.width, height: actionHeight),
            height: height)
    }

    func setSaving(_ saving: Bool, value: String = SourceImportPreviewText.saving) {
        confirmButton.configuration?.showsActivityIndicator = saving
        confirmButton.accessibilityValue = saving ? value : nil
        setNeedsLayout()
    }
}

/// The ordinal distinguishes duplicate URLs; the revision invalidates callbacks from an older draft/cell.
struct SourceImportPreviewIdentity: Hashable {
    let ordinal: Int
    let url: String
    let revision: UUID

    init(ordinal: Int, candidate: SourceImportCandidate) {
        self.ordinal = ordinal
        url = candidate.source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        revision = UUID()
    }
}

@MainActor
final class SourceImportPreviewList: NSObject, UITableViewDataSource, UITableViewDelegate {
    private struct Anchor {
        var identity: SourceImportPreviewIdentity
        let offset: CGFloat
    }

    private let state: SourceImportPreviewState
    private let table: UITableView
    private let sizingCell: SourceImportPreviewCell
    private(set) var identities: [SourceImportPreviewIdentity]
    private var heights: [SourceImportPreviewIdentity: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0
    private var needsHeightUpdate = false
    private var pendingAnchor: Anchor?
    private var highlightedIdentity: SourceImportPreviewIdentity?
    private var actionRevision = UUID()
    private var enabled = true
    var canInteract: (() -> Bool)?
    var onToggle: ((SourceImportPreviewIdentity) -> Void)?
    var onOpen: ((SourceImportPreviewIdentity) -> Void)?
    var onBeginDragging: (() -> Void)?

    init(state: SourceImportPreviewState, table: UITableView, sizingCell: SourceImportPreviewCell) {
        self.state = state
        self.table = table
        self.sizingCell = sizingCell
        identities = state.candidates.enumerated().map { SourceImportPreviewIdentity(ordinal: $0.offset, candidate: $0.element) }
        super.init()
        table.dataSource = self
        table.delegate = self
        table.estimatedRowHeight = 52
        table.register(SourceImportPreviewCell.self, forCellReuseIdentifier: SourceImportPreviewCell.reuseIdentifier)
    }

    func index(for identity: SourceImportPreviewIdentity) -> Int? {
        let index = identity.ordinal
        guard identities.indices.contains(index), state.candidates.indices.contains(index),
            identities[index] == identity,
            state.candidates[index].source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines) == identity.url
        else { return nil }
        return index
    }

    func matches(_ snapshot: [SourceImportPreviewIdentity]) -> Bool {
        identities == snapshot && snapshot.allSatisfy { index(for: $0) != nil }
    }

    func receivePreparedPreview(_ preview: SourceImportPreview) {
        cancelPendingTracking()
        state.receivePreparedPreview(preview)
        identities = state.candidates.enumerated().map { SourceImportPreviewIdentity(ordinal: $0.offset, candidate: $0.element) }
        heights.removeAll()
        pendingAnchor = nil
        needsHeightUpdate = true
        table.reloadData()
    }

    func rememberAnchor() {
        if pendingAnchor == nil { pendingAnchor = captureAnchor() }
    }

    func invalidateMeasurements() {
        rememberAnchor()
        heights.removeAll()
        needsHeightUpdate = true
    }

    func layoutPreservingAnchor(_ layout: () -> Void) {
        let anchor = pendingAnchor ?? captureAnchor()
        pendingAnchor = nil
        let previousWidth = table.bounds.width
        layout()
        if previousWidth != table.bounds.width { needsHeightUpdate = true }
        if needsHeightUpdate {
            needsHeightUpdate = false
            UIView.performWithoutAnimation {
                table.beginUpdates()
                table.endUpdates()
            }
        }
        table.layoutIfNeeded()
        restore(anchor)
    }

    func rowHeight(at index: Int, width: CGFloat) -> CGFloat {
        guard identities.indices.contains(index) else { return 52 }
        if measuredWidth != width {
            measuredWidth = width
            heights.removeAll()
        }
        let identity = identities[index]
        if let height = heights[identity] { return height }
        sizingCell.configure(candidate: state.candidates[index], selected: state.selections[index], index: index, enabled: false)
        let height = max(52, ceil(sizingCell.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height))
        heights[identity] = height
        return height
    }

    func updateSelections(at indices: [Int]) {
        let changed = Set(indices)
        for case let cell as SourceImportPreviewCell in table.visibleCells {
            guard let row = table.indexPath(for: cell)?.row, changed.contains(row), state.selections.indices.contains(row) else { continue }
            cell.updateSelection(state.selections[row])
        }
    }

    @discardableResult
    func replaceCandidate(_ identity: SourceImportPreviewIdentity, with candidate: SourceImportCandidate) -> Bool {
        guard let index = index(for: identity) else { return false }
        rememberAnchor()
        state.replaceCandidate(at: index, with: candidate)
        let replacement = SourceImportPreviewIdentity(ordinal: index, candidate: candidate)
        identities[index] = replacement
        heights[identity] = nil
        if pendingAnchor?.identity == identity { pendingAnchor?.identity = replacement }
        highlightedIdentity = nil
        if let cell = table.cellForRow(at: IndexPath(row: index, section: 0)) as? SourceImportPreviewCell {
            bind(cell, at: index)
        }
        needsHeightUpdate = true
        return true
    }

    func setInteractive(_ enabled: Bool) {
        self.enabled = enabled
        for case let cell as SourceImportPreviewCell in table.visibleCells { cell.setInteractive(enabled) }
        if !enabled { cancelPendingTracking() }
    }

    func cancelPendingTracking() {
        actionRevision = UUID()
        highlightedIdentity = nil
        for case let cell as SourceImportPreviewCell in table.visibleCells {
            cell.cancelPendingTracking()
            if let index = table.indexPath(for: cell)?.row, identities.indices.contains(index) {
                bindActions(cell, at: index)
            }
        }
        if let selected = table.indexPathForSelectedRow { table.deselectRow(at: selected, animated: false) }
    }

    func applyPalette() {
        for case let cell as SourceImportPreviewCell in table.visibleCells { cell.applyPalette() }
        sizingCell.applyPalette()
    }

    private func bind(_ cell: SourceImportPreviewCell, at index: Int) {
        cell.configure(candidate: state.candidates[index], selected: state.selections[index], index: index, enabled: enabled)
        bindActions(cell, at: index)
    }

    private func bindActions(_ cell: SourceImportPreviewCell, at index: Int) {
        let identity = identities[index]
        let bindingID = cell.bindingID
        let revision = actionRevision
        cell.canInteract = { [weak self, weak cell] in
            guard let self, let cell, self.enabled, self.canInteract?() == true,
                self.actionRevision == revision,
                let currentIndex = self.index(for: identity), self.table.indexPath(for: cell)?.row == currentIndex,
                cell.bindingID == bindingID,
                !self.table.isDragging, !self.table.isDecelerating,
                cell.frame.intersects(self.table.bounds), cell.window === self.table.window
            else { return false }
            return true
        }
        cell.onToggle = { [weak self, weak cell] in
            guard let self, self.actionRevision == revision,
                cell?.bindingID == bindingID, cell?.canInteract?() == true
            else { return }
            self.onToggle?(identity)
        }
        cell.onOpen = { [weak self, weak cell] in
            guard let self, self.actionRevision == revision,
                cell?.bindingID == bindingID, cell?.canInteract?() == true
            else { return }
            self.onOpen?(identity)
        }
    }

    private func captureAnchor() -> Anchor? {
        guard table.bounds.height > 0,
            let path = table.indexPathsForVisibleRows?.sorted().first(where: {
                table.rectForRow(at: $0).maxY > table.contentOffset.y
            }), identities.indices.contains(path.row)
        else { return nil }
        return Anchor(identity: identities[path.row], offset: table.rectForRow(at: path).minY - table.contentOffset.y)
    }

    private func restore(_ anchor: Anchor?) {
        guard let anchor, let index = index(for: anchor.identity), !table.isDragging, !table.isDecelerating else { return }
        let y = table.rectForRow(at: IndexPath(row: index, section: 0)).minY - anchor.offset
        let minimum = -table.adjustedContentInset.top
        let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let offset = CGPoint(x: table.contentOffset.x, y: min(maximum, max(minimum, y)))
        if table.contentOffset != offset { table.setContentOffset(offset, animated: false) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { state.candidates.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        rowHeight(at: indexPath.row, width: max(1, tableView.bounds.width))
    }

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        guard identities.indices.contains(indexPath.row), measuredWidth == tableView.bounds.width else { return 52 }
        return heights[identities[indexPath.row]] ?? 52
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SourceImportPreviewCell.reuseIdentifier, for: indexPath) as? SourceImportPreviewCell
        else { return UITableViewCell() }
        bind(cell, at: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard enabled, canInteract?() == true, identities.indices.contains(indexPath.row) else { return false }
        highlightedIdentity = identities[indexPath.row]
        return true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let identity = highlightedIdentity
        highlightedIdentity = nil
        guard enabled, canInteract?() == true, let identity, index(for: identity) == indexPath.row else { return }
        onToggle?(identity)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        pendingAnchor = nil
        cancelPendingTracking()
        onBeginDragging?()
    }
}

final class SourceImportPreviewPresentationController: UIPresentationController {
    private let outsideControl = SourceImportPreviewActionButton(type: .custom)

    func cancelPendingTracking() { outsideControl.cancelTracking(with: nil) }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let containerView, let preview = presentedViewController as? SourceImportPreviewViewController else { return .zero }
        let safeFrame = containerView.safeAreaLayoutGuide.layoutFrame
        let available = safeFrame.insetBy(
            dx: min(16, max(0, (safeFrame.width - 1) / 2)),
            dy: min(16, max(0, (safeFrame.height - 1) / 2)))
        // ImportBookSourceDialog.onStart: MATCH_PARENT width, WRAP_CONTENT height.
        let size = preview.dialogSize(fitting: available.size)
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func presentationTransitionWillBegin() {
        guard let containerView else { return }
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityIdentifier = "sourceImport.preview.backdrop"
        outsideControl.canInteract = { [weak self] in
            guard let self else { return false }
            return self.delegate?.presentationControllerShouldDismiss?(self) != false
        }
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        outsideControl.frame = containerView.bounds
        outsideControl.alpha = 0
        containerView.insertSubview(outsideControl, at: 0)
        if let transition = presentedViewController.transitionCoordinator {
            transition.animate(alongsideTransition: { _ in self.outsideControl.alpha = 1 })
        } else {
            outsideControl.alpha = 1
        }
    }

    override func dismissalTransitionWillBegin() {
        if let transition = presentedViewController.transitionCoordinator {
            transition.animate(alongsideTransition: { _ in self.outsideControl.alpha = 0 })
        } else {
            outsideControl.alpha = 0
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed { outsideControl.removeFromSuperview() }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed { outsideControl.removeFromSuperview() }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        outsideControl.frame = containerView?.bounds ?? .zero
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    override func adaptivePresentationStyle(for traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    @objc private func cancel() {
        guard let preview = presentedViewController as? SourceImportPreviewViewController,
            delegate?.presentationControllerShouldDismiss?(self) != false
        else { return }
        preview.dismiss(animated: true)
    }
}

final class SourceImportPreviewTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) { self.isPresenting = isPresenting }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0 : 0.18
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let controller = transitionContext.viewController(forKey: key),
            let view = transitionContext.view(forKey: isPresenting ? .to : .from)
        else {
            transitionContext.completeTransition(false)
            return
        }
        if isPresenting {
            transitionContext.containerView.addSubview(view)
            view.frame = transitionContext.finalFrame(for: controller)
            view.alpha = 0
        }
        UIView.animate(
            withDuration: transitionDuration(using: transitionContext),
            animations: {
                view.alpha = self.isPresenting ? 1 : 0
            },
            completion: { _ in
                let completed = !transitionContext.transitionWasCancelled
                if completed, !self.isPresenting { view.removeFromSuperview() }
                view.alpha = 1
                transitionContext.completeTransition(completed)
            })
    }
}

final class SourceImportPreviewScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
