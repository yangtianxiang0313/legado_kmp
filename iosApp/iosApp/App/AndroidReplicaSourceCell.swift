import UIKit
import shared

final class AndroidReplicaSourceCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaSourceCell"
    private static let enabledActionID = UIAction.Identifier("sourceManagement.cell.enabled")

    private let selectionButton = AndroidReplicaSourceActionButton(frame: .zero)
    private let selectionIcon = UIImageView()
    private let sourceNameLabel = UILabel()
    private let enabledSwitch = ReaderAndroidSwitchControl(frame: .zero)
    private let switchFeedback = AndroidReplicaSourceRipple()
    private let editButton = AndroidReplicaSourceActionButton(frame: .zero)
    private let moreButton = AndroidReplicaSourceActionButton(frame: .zero)
    private let exploreDot = UIView()
    private let domainHeaderLabel = UILabel()
    private var plainRowTopConstraint: NSLayoutConstraint?
    private var groupedRowTopConstraint: NSLayoutConstraint?
    private var rowHeightConstraint: NSLayoutConstraint?
    private var sourceURL: String?
    private var modelEnabled = false
    private var modelSelected = false
    private var mutationsEnabled = true
    private var presentationActive = true
    private var bindingRevision: UInt64 = 0
    private var cancellingInput = false
    private var switchPressed = false

    var moreMenuAnchor: UIView { moreButton }

    /// Capture the owner weakly; nil still requires a visible, active, unobscured cell.
    var canInteract: (() -> Bool)? {
        didSet { invalidateInput() }
    }

    var onSelectionChange: (() -> Void)? {
        didSet { invalidateInput() }
    }

    var onEnabledChange: ((Bool) -> Void)? {
        didSet { invalidateInput() }
    }

    var onEdit: (() -> Void)? {
        didSet { invalidateInput() }
    }

    var onMore: (() -> Void)? {
        didSet { invalidateInput() }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        selectionStyle = .none
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
        backgroundColor = .clear
        isAccessibilityElement = false
        selectionButton.configuration = nil
        selectionButton.feedbackAtLeadingEdge = true
        selectionButton.isAccessibilityElement = true
        selectionButton.addTarget(self, action: #selector(selectionChanged), for: .touchUpInside)
        selectionButton.canInteract = { [weak self] in
            guard let self else { return false }
            return self.onSelectionChange != nil && self.allowsInteraction(with: self.selectionButton)
        }
        selectionIcon.contentMode = .scaleAspectFit
        sourceNameLabel.numberOfLines = 1
        sourceNameLabel.lineBreakMode = .byTruncatingTail
        sourceNameLabel.clipsToBounds = true
        sourceNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sourceNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourceNameLabel.setContentCompressionResistancePriority(.init(999), for: .vertical)
        for item in [selectionIcon, sourceNameLabel] {
            item.isUserInteractionEnabled = false
            item.isAccessibilityElement = false
            item.translatesAutoresizingMaskIntoConstraints = false
            selectionButton.addSubview(item)
        }
        // AppCompat 1.7.1's original 32dp checkbox paths, not SF Symbols.
        selectionIcon.image = ReplaceRuleEditorIcons.unchecked
        configureButton(
            editButton,
            image: UIImage(named: "BookDetailAndroidEdit")?.withRenderingMode(.alwaysTemplate),
            action: #selector(handleEdit))
        configureButton(moreButton, image: ReaderMenuAndroidIcon.more.image(), action: #selector(handleMore))
        editButton.canInteract = { [weak self] in
            guard let self else { return false }
            return self.mutationsEnabled && self.onEdit != nil && self.allowsInteraction(with: self.editButton)
        }
        moreButton.canInteract = { [weak self] in
            guard let self else { return false }
            return self.mutationsEnabled && self.onMore != nil && self.allowsInteraction(with: self.moreButton)
        }
        enabledSwitch.canInteract = { [weak self] in
            guard let self else { return false }
            return self.mutationsEnabled && self.onEnabledChange != nil
                && self.allowsInteraction(with: self.enabledSwitch)
        }
        enabledSwitch.addTarget(self, action: #selector(switchTouchBegan), for: [.touchDown, .touchDragEnter])
        enabledSwitch.addTarget(
            self, action: #selector(switchTouchEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        exploreDot.layer.cornerRadius = 4
        exploreDot.isUserInteractionEnabled = false
        exploreDot.isAccessibilityElement = true
        exploreDot.isHidden = true
        domainHeaderLabel.numberOfLines = 1
        domainHeaderLabel.lineBreakMode = .byTruncatingTail
        domainHeaderLabel.clipsToBounds = true
        domainHeaderLabel.isHidden = true
        domainHeaderLabel.accessibilityTraits = .header
        domainHeaderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        domainHeaderLabel.setContentCompressionResistancePriority(.init(999), for: .vertical)

        for item in [selectionButton, enabledSwitch, editButton, moreButton, exploreDot, domainHeaderLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        contentView.layer.insertSublayer(switchFeedback.layer, below: enabledSwitch.layer)
        // Keep the 32dp checkbox and 47/36/36dp controls intact; only the name and
        // then the symmetric 16dp padding yield when the available width shrinks.
        let rowBounds = UILayoutGuide()
        contentView.addLayoutGuide(rowBounds)
        let preferredInset = rowBounds.leftAnchor.constraint(equalTo: contentView.leftAnchor, constant: 16)
        preferredInset.priority = .init(999)
        // item_book_source.xml: 16dp padding, host -12dp top / 16dp bottom margin.
        plainRowTopConstraint = selectionButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16)
        groupedRowTopConstraint = selectionButton.topAnchor.constraint(
            equalTo: domainHeaderLabel.bottomAnchor, constant: 16)
        rowHeightConstraint = selectionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)
        rowHeightConstraint?.priority = .init(999)
        rowHeightConstraint?.isActive = true
        plainRowTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            rowBounds.topAnchor.constraint(equalTo: contentView.topAnchor),
            rowBounds.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            rowBounds.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            rowBounds.leftAnchor.constraint(greaterThanOrEqualTo: contentView.leftAnchor),
            rowBounds.rightAnchor.constraint(lessThanOrEqualTo: contentView.rightAnchor),
            preferredInset,
            domainHeaderLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            domainHeaderLabel.leftAnchor.constraint(equalTo: rowBounds.leftAnchor),
            domainHeaderLabel.rightAnchor.constraint(equalTo: rowBounds.rightAnchor),
            selectionButton.leftAnchor.constraint(equalTo: rowBounds.leftAnchor),
            selectionButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            selectionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            selectionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 32),
            // No extra checkbox-to-switch margin in the Android XML.
            selectionButton.rightAnchor.constraint(equalTo: enabledSwitch.leftAnchor),
            selectionIcon.leadingAnchor.constraint(equalTo: selectionButton.leadingAnchor),
            selectionIcon.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            selectionIcon.widthAnchor.constraint(equalToConstant: 32),
            selectionIcon.heightAnchor.constraint(equalToConstant: 32),
            sourceNameLabel.leadingAnchor.constraint(equalTo: selectionIcon.trailingAnchor),
            sourceNameLabel.trailingAnchor.constraint(equalTo: selectionButton.trailingAnchor),
            sourceNameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            sourceNameLabel.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            sourceNameLabel.topAnchor.constraint(greaterThanOrEqualTo: selectionButton.topAnchor),
            sourceNameLabel.bottomAnchor.constraint(lessThanOrEqualTo: selectionButton.bottomAnchor),
            enabledSwitch.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            enabledSwitch.widthAnchor.constraint(equalToConstant: 47),
            enabledSwitch.heightAnchor.constraint(equalToConstant: 27),
            enabledSwitch.rightAnchor.constraint(equalTo: editButton.leftAnchor, constant: -6),
            editButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            editButton.rightAnchor.constraint(equalTo: moreButton.leftAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 36),
            editButton.heightAnchor.constraint(equalToConstant: 36),
            moreButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            moreButton.rightAnchor.constraint(equalTo: rowBounds.rightAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 36),
            moreButton.heightAnchor.constraint(equalToConstant: 36),
            exploreDot.topAnchor.constraint(equalTo: moreButton.topAnchor),
            exploreDot.rightAnchor.constraint(equalTo: moreButton.rightAnchor),
            exploreDot.widthAnchor.constraint(equalToConstant: 8),
            exploreDot.heightAnchor.constraint(equalToConstant: 8),
        ])
        updateTypography()
        accessibilityElements = [domainHeaderLabel, selectionButton, enabledSwitch, editButton, moreButton, exploreDot]
        applyPalette()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(deactivated(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(deactivated(_:)), name: UIScene.willDeactivateNotification, object: nil)
        updateControlAvailability()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureButton(_ button: UIButton, image: UIImage?, action: Selector) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.setImage(image, for: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        button.addTarget(self, action: action, for: .touchUpInside)
        let label = button === editButton ? L10n.SourceManagement.editAction : L10n.Bookshelf.moreActions
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        sourceURL = nil
        invalidateInput()
        onSelectionChange = nil
        onEnabledChange = nil
        onEdit = nil
        onMore = nil
        canInteract = nil
        presentationActive = true
        mutationsEnabled = true
        modelSelected = false
        modelEnabled = false
        sourceNameLabel.text = nil
        selectionButton.accessibilityLabel = nil
        selectionButton.accessibilityIdentifier = nil
        selectionButton.accessibilityTraits = .button
        selectionButton.accessibilityValue = nil
        enabledSwitch.setOn(false, animated: false)
        for control in [enabledSwitch, editButton, moreButton] {
            control.accessibilityLabel = nil
            control.accessibilityIdentifier = nil
        }
        exploreDot.isHidden = true
        exploreDot.accessibilityLabel = nil
        updateDomainHeader(nil, sourceURL: nil)
        updateSelectionAppearance()
        updateControlAvailability()
    }

    func configure(source: BookSource, isSelected: Bool, mutationsEnabled: Bool, domainHeader: String? = nil) {
        if let sourceURL, sourceURL != source.bookSourceUrl {
            // Direct rebinding need not pass through prepareForReuse. Drop old-URL closures.
            onSelectionChange = nil
            onEnabledChange = nil
            onEdit = nil
            onMore = nil
        }
        invalidateInput()
        sourceURL = source.bookSourceUrl
        modelEnabled = source.enabled
        modelSelected = isSelected
        self.mutationsEnabled = mutationsEnabled
        let group = source.bookSourceGroup ?? ""
        let name =
            group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? source.bookSourceName : "\(source.bookSourceName) (\(group))"
        sourceNameLabel.text = Self.singleLine(name)
        updateDomainHeader(domainHeader, sourceURL: source.bookSourceUrl)
        selectionButton.accessibilityLabel = name
        selectionButton.accessibilityIdentifier = "sourceManagement.selection.\(source.bookSourceUrl)"
        enabledSwitch.setOn(source.enabled, animated: false)
        enabledSwitch.accessibilityLabel = "\(L10n.SourceManagement.enableAction)：\(source.bookSourceName)"
        enabledSwitch.accessibilityIdentifier = "sourceManagement.enabled.\(source.bookSourceUrl)"
        editButton.accessibilityLabel = "\(L10n.SourceManagement.editAction)：\(source.bookSourceName)"
        moreButton.accessibilityLabel = "\(L10n.Bookshelf.moreActions)：\(source.bookSourceName)"
        editButton.accessibilityIdentifier = "sourceManagement.edit.\(source.bookSourceUrl)"
        moreButton.accessibilityIdentifier = "sourceManagement.more.\(source.bookSourceUrl)"
        exploreDot.isHidden = !source.hasExploreUrl
        // BookSourceAdapter.upShowExplore applies Color.GREEN/RED over the XML drawable.
        exploreDot.backgroundColor =
            source.enabledExplore
            ? UIColor(red: 0, green: 1, blue: 0, alpha: 1)
            : UIColor(red: 1, green: 0, blue: 0, alpha: 1)
        exploreDot.accessibilityLabel =
            source.enabledExplore
            ? L10n.SourceManagement.exploreEnabledBadge : L10n.SourceManagement.exploreDisabledBadge
        updateSelectionAppearance()
        updateControlAvailability()
        applyPalette()
    }

    /// Owner updates this for display/end-display, scrolling, covering UI and scene changes.
    /// Mutation-disabled rows still allow selection when presentation remains active.
    func setPresentationActive(_ active: Bool) {
        guard presentationActive != active else { return }
        presentationActive = active
        invalidateInput()
        updateControlAvailability()
    }

    func setMutationEnabled(_ enabled: Bool) {
        if mutationsEnabled != enabled {
            mutationsEnabled = enabled
            invalidateInput(includingSelection: false)
        }
        updateControlAvailability()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { invalidateInput() }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if superview !== newSuperview { invalidateInput() }
        super.willMove(toSuperview: newSuperview)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
        }
        applyPalette()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateSwitchFeedback()
    }

    private func updateTypography() {
        // ThemeCheckBox inherits 14sp Body1; only tv_host_text overrides it to 16sp.
        sourceNameLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        domainHeaderLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        sourceNameLabel.adjustsFontForContentSizeCategory = false
        domainHeaderLabel.adjustsFontForContentSizeCategory = false
        rowHeightConstraint?.constant = max(36, ceil(sourceNameLabel.font.lineHeight))
        setNeedsLayout()
    }

    private static func singleLine(_ text: String) -> String {
        // Android's singleLine transformation preserves text after embedded line breaks.
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    @objc private func applyPalette() {
        // convert replaces the XML root selector with withAlpha(background, .5).
        // ColorUtils.withAlpha truncates .5 * 255 to 127; no UIKit row highlight.
        contentView.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
            .withAlphaComponent(127 / 255.0)
        sourceNameLabel.textColor = AndroidReplicaTheme.primaryText.resolvedColor(with: traitCollection)
        domainHeaderLabel.textColor = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        enabledSwitch.onTintColor = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        for button in [editButton, moreButton] {
            button.tintColor = AndroidReplicaTheme.primaryText.resolvedColor(with: traitCollection)
            button.feedbackColor = uncheckedFeedbackColor
        }
        updateSelectionAppearance()
        updateSwitchFeedback()
    }

    private var uncheckedFeedbackColor: UIColor {
        // AppCompat ripple_material_light / ripple_material_dark, also used by TintHelper.
        UIColor(
            white: traitCollection.userInterfaceStyle == .dark ? 1 : 0,
            alpha: (traitCollection.userInterfaceStyle == .dark ? 51 : 31) / 255.0)
    }

    private var checkedFeedbackColor: UIColor {
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        return accent.withAlphaComponent((accent.cgColor.alpha * 255 * 0.4).rounded() / 255)
    }

    private func updateSelectionAppearance() {
        selectionIcon.image = modelSelected ? ReplaceRuleEditorIcons.checked : ReplaceRuleEditorIcons.unchecked
        selectionIcon.tintColor = (modelSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText)
            .resolvedColor(with: traitCollection)
        selectionButton.feedbackColor = modelSelected ? checkedFeedbackColor : uncheckedFeedbackColor
        // Keep state out of UIButton's native selected appearance.
        selectionButton.accessibilityTraits = modelSelected ? [.button, .selected] : [.button]
        selectionButton.accessibilityValue = modelSelected ? "已选中" : "未选中"
    }

    private func updateSwitchFeedback() {
        let onRight = enabledSwitch.isOn != (effectiveUserInterfaceLayoutDirection == .rightToLeft)
        // SwitchCompat.draw sets the background hotspot bounds to the 27dp thumb bounds.
        let center = CGPoint(
            x: enabledSwitch.frame.minX + (onRight ? 33.5 : 13.5), y: enabledSwitch.frame.midY)
        switchFeedback.layout(hotspot: CGRect(x: center.x - 13.5, y: center.y - 13.5, width: 27, height: 27))
        switchFeedback.color = enabledSwitch.isOn ? checkedFeedbackColor : uncheckedFeedbackColor
        switchFeedback.setPressed(switchPressed)
    }

    private func updateDomainHeader(_ title: String?, sourceURL: String?) {
        let showsHeader = !(title?.isEmpty ?? true)
        plainRowTopConstraint?.isActive = false
        groupedRowTopConstraint?.isActive = false
        domainHeaderLabel.text = showsHeader ? title.map(Self.singleLine) : nil
        domainHeaderLabel.isHidden = !showsHeader
        domainHeaderLabel.isAccessibilityElement = showsHeader
        domainHeaderLabel.accessibilityLabel = showsHeader ? title : nil
        domainHeaderLabel.accessibilityIdentifier =
            showsHeader ? sourceURL.map { "sourceManagement.domain.\($0)" } : nil
        if showsHeader { groupedRowTopConstraint?.isActive = true } else { plainRowTopConstraint?.isActive = true }
        setNeedsLayout()
    }

    private func updateControlAvailability() {
        let available = sourceURL != nil && presentationActive
        if selectionButton.isEnabled != available { selectionButton.isEnabled = available }
        for control in [enabledSwitch, editButton, moreButton] {
            control.isEnabled = available && mutationsEnabled
        }
    }

    private func invalidateInput(includingSelection: Bool = true) {
        guard !cancellingInput else { return }
        cancellingInput = true
        defer { cancellingInput = false }
        bindingRevision &+= 1
        if includingSelection { selectionButton.cancelPendingInteraction() }
        for button in [editButton, moreButton] { button.cancelPendingInteraction() }
        enabledSwitch.cancelTracking(with: nil)
        let interactive = enabledSwitch.isUserInteractionEnabled
        enabledSwitch.isUserInteractionEnabled = false
        enabledSwitch.isUserInteractionEnabled = interactive
        enabledSwitch.setOn(modelEnabled, animated: false)
        switchPressed = false
        switchFeedback.cancel()
        let revision = bindingRevision
        enabledSwitch.removeAction(identifiedBy: Self.enabledActionID, for: .valueChanged)
        enabledSwitch.addAction(
            UIAction(identifier: Self.enabledActionID) { [weak self] _ in
                self?.enabledChanged(revision: revision)
            }, for: .valueChanged)
    }

    private var interactionAllowed: Bool {
        guard sourceURL != nil, presentationActive, !cancellingInput,
            UIApplication.shared.applicationState == .active, let window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive
        else { return false }
        var visibleRect = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 || !view.isUserInteractionEnabled { return false }
            if let control = view as? UIControl, !control.isEnabled { return false }
            if let scroll = view as? UIScrollView {
                // isTracking is also true for a stationary long press; it is not scrolling.
                let panState = scroll.panGestureRecognizer.state
                if scroll.isDragging || scroll.isDecelerating || panState == .began || panState == .changed {
                    return false
                }
            }
            if let table = view as? UITableView {
                if table.hasActiveDrag || table.hasActiveDrop || !table.visibleCells.contains(where: { $0 === self }) {
                    return false
                }
            }
            if view.clipsToBounds { visibleRect = visibleRect.intersection(view.convert(view.bounds, to: window)) }
            ancestor = view.superview
        }
        guard !visibleRect.isNull, !visibleRect.isEmpty else { return false }
        var responder: UIResponder? = self
        while let current = responder {
            if let owner = current as? UIViewController {
                if owner.presentedViewController != nil || owner.isBeingDismissed || owner.isBeingPresented
                    || owner.isMovingFromParent || owner.isMovingToParent || owner.transitionCoordinator != nil
                {
                    return false
                }
                if let navigation = owner.navigationController,
                    let visible = navigation.visibleViewController,
                    owner !== navigation && owner !== visible && !owner.view.isDescendant(of: visible.view)
                {
                    return false
                }
            }
            responder = current.next
        }
        return canInteract?() ?? true
    }

    private func allowsInteraction(with control: UIControl) -> Bool {
        guard control.isEnabled, interactionAllowed, let window else { return false }
        let center = control.convert(CGPoint(x: control.bounds.midX, y: control.bounds.midY), to: window)
        guard let hit = window.hitTest(center, with: nil) else { return false }
        return hit === control || hit.isDescendant(of: control)
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        invalidateInput()
    }

    @objc private func switchTouchBegan() {
        guard mutationsEnabled, onEnabledChange != nil, allowsInteraction(with: enabledSwitch) else { return }
        switchPressed = true
        updateSwitchFeedback()
    }

    @objc private func switchTouchEnded() {
        switchPressed = false
        switchFeedback.setPressed(false)
    }

    @objc private func selectionChanged() {
        guard allowsInteraction(with: selectionButton), let callback = onSelectionChange else { return }
        modelSelected.toggle()
        updateSelectionAppearance()
        callback()
    }

    private func enabledChanged(revision: UInt64) {
        guard revision == bindingRevision else { return }
        guard mutationsEnabled, allowsInteraction(with: enabledSwitch),
            let callback = onEnabledChange, enabledSwitch.isOn != modelEnabled
        else {
            enabledSwitch.cancelPendingTracking()
            enabledSwitch.setOn(modelEnabled, animated: false)
            return
        }
        let value = enabledSwitch.isOn
        modelEnabled = value
        enabledSwitch.setOn(value, animated: true)
        switchTouchEnded()
        // Synchronous configure/reuse from the callback owns subsequent visual state.
        callback(value)
    }

    @objc private func handleEdit() {
        guard mutationsEnabled, allowsInteraction(with: editButton) else { return }
        onEdit?()
    }

    @objc private func handleMore() {
        guard mutationsEnabled, allowsInteraction(with: moreButton) else { return }
        onMore?()
    }
}

/// Cell-local input identity and borderless feedback; no native selected/highlighted artwork.
private final class AndroidReplicaSourceActionButton: UIButton {
    var canInteract: (() -> Bool)?
    var feedbackAtLeadingEdge = false
    var feedbackColor = UIColor.clear {
        didSet { feedback.color = feedbackColor }
    }

    private let feedback = AndroidReplicaSourceRipple()
    private var revision: UInt64 = 0
    private var touchRevision: UInt64?
    private var pressRevision: UInt64?
    private var endingTouch = false
    private var endingPress = false
    private var pressOrigin: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = false
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        layer.insertSublayer(feedback.layer, at: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet {
            let pressed = isHighlighted && isEnabled && canInteract?() != false
            feedback.setPressed(pressed, origin: pressOrigin)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x: CGFloat
        if feedbackAtLeadingEdge {
            x = effectiveUserInterfaceLayoutDirection == .rightToLeft ? bounds.width - 16 : 16
        } else {
            x = bounds.midX
        }
        // CompoundButton.onDraw uses the 32dp button drawable, not the whole text area.
        let size: CGFloat = feedbackAtLeadingEdge ? 32 : 36
        feedback.layout(hotspot: CGRect(x: x - size / 2, y: bounds.midY - size / 2, width: size, height: size))
    }

    func cancelPendingInteraction() {
        revision &+= 1
        touchRevision = nil
        pressRevision = nil
        pressOrigin = nil
        cancelTracking(with: nil)
        let interactive = isUserInteractionEnabled
        isUserInteractionEnabled = false
        isUserInteractionEnabled = interactive
        isHighlighted = false
        feedback.cancel()
        if isFirstResponder { _ = resignFirstResponder() }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, canInteract?() != false else { return false }
        touchRevision = revision
        pressOrigin = touch.location(in: self)
        let began = super.beginTracking(touch, with: event)
        if !began { touchRevision = nil }
        return began
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard touchRevision == revision, canInteract?() != false else {
            cancelPendingInteraction()
            return false
        }
        return super.continueTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        touchRevision = nil
        pressRevision = nil
        pressOrigin = nil
        super.cancelTracking(with: event)
        isHighlighted = false
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touchRevision == revision, canInteract?() != false else {
            super.touchesCancelled(touches, with: event)
            cancelPendingInteraction()
            return
        }
        endingTouch = true
        defer {
            endingTouch = false
            touchRevision = nil
            pressOrigin = nil
        }
        super.touchesEnded(touches, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, !isTracking, touchRevision == nil, pressRevision == nil,
            canInteract?() != false
        else { return false }
        pressOrigin = nil
        return super.accessibilityActivate()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard isEnabled, !isTracking, touchRevision == nil, canInteract?() != false else { return }
        pressRevision = revision
        pressOrigin = nil
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard pressRevision == revision, canInteract?() != false else {
            super.pressesCancelled(presses, with: event)
            pressRevision = nil
            return
        }
        endingPress = true
        defer {
            endingPress = false
            pressRevision = nil
        }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressRevision = nil
        super.pressesCancelled(presses, with: event)
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard isEnabled, canInteract?() != false,
            !endingTouch || touchRevision == revision,
            !endingPress || pressRevision == revision
        else { return }
        super.sendAction(action, to: target, for: event)
    }
}

/// AOSP RippleForeground/RippleComponent geometry and timing for borderless control feedback.
/// Colors come from Legado TintHelper; the bound row itself has no ripple after convert().
/// AOSP Copyright 2015, Apache-2.0: https://www.apache.org/licenses/LICENSE-2.0
private final class AndroidReplicaSourceRipple {
    let layer = CAShapeLayer()
    var color = UIColor.clear {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.fillColor = color.cgColor
            CATransaction.commit()
        }
    }

    private var hotspot = CGRect.zero
    private var radius: CGFloat = 0
    private var pressed = false
    private var enteredAt: CFTimeInterval = 0

    init() { layer.opacity = 0 }

    func layout(hotspot: CGRect) {
        self.hotspot = hotspot
        radius = hypot(hotspot.width / 2, hotspot.height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        layer.position = CGPoint(x: hotspot.midX, y: hotspot.midY)
        layer.path = UIBezierPath(ovalIn: layer.bounds).cgPath
        CATransaction.commit()
    }

    func setPressed(_ value: Bool, origin: CGPoint? = nil) {
        guard pressed != value else { return }
        pressed = value
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value ? 1 : 0
        CATransaction.commit()
        layer.removeAnimation(forKey: "opacity")
        guard !UIAccessibility.isReduceMotionEnabled, UIView.areAnimationsEnabled else {
            layer.removeAllAnimations()
            return
        }
        let now = CACurrentMediaTime()
        if value {
            enteredAt = now
            layer.removeAllAnimations()
            let startRadius = max(hotspot.width, hotspot.height) * 0.3
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = radius > 0 ? startRadius / radius : 1
            scale.toValue = 1
            scale.duration = 0.225
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            layer.add(scale, forKey: "radius")
            if let origin {
                let center = CGPoint(x: hotspot.midX, y: hotspot.midY)
                let dx = origin.x - center.x
                let dy = origin.y - center.y
                let distance = hypot(dx, dy)
                let allowedDistance = max(0, radius - startRadius)
                let ratio = distance > allowedDistance && distance > 0 ? allowedDistance / distance : 1
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(cgPoint: CGPoint(x: center.x + dx * ratio, y: center.y + dy * ratio))
                move.toValue = NSValue(cgPoint: center)
                move.duration = 0.225
                move.timingFunction = scale.timingFunction
                layer.add(move, forKey: "origin")
            }
        }
        if value {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.075
            fade.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(fade, forKey: "opacity")
        } else {
            // Preserve the enter fade, then hold until 225ms before the 150ms exit.
            let age = max(0, now - enteredAt)
            let remainingEnter = max(0, 0.075 - age)
            let hold = max(0, 0.225 - age)
            let duration = hold + 0.15
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            if remainingEnter > 0 {
                fade.values = [opacity, Float(1), Float(1), Float(0)]
                fade.keyTimes = [0, NSNumber(value: remainingEnter / duration), NSNumber(value: hold / duration), 1]
            } else if hold > 0 {
                fade.values = [opacity, opacity, Float(0)]
                fade.keyTimes = [0, NSNumber(value: hold / duration), 1]
            } else {
                fade.values = [opacity, Float(0)]
                fade.keyTimes = [0, 1]
            }
            fade.duration = duration
            fade.calculationMode = .linear
            layer.add(fade, forKey: "opacity")
        }
    }

    func cancel() {
        pressed = false
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        CATransaction.commit()
    }
}
