import UIKit

/// view_select_action_bar.xml: a counted checkbox, two stroke actions and 36dp overflow.
final class SourceManagementSelectionBar: UIView {
    private let selectAllButton = SourceManagementSelectionActionButton(type: .custom)
    private let selectionIcon = UIImageView()
    private let selectionTitleLabel = UILabel()
    private let invertButton = SourceManagementSelectionActionButton(type: .custom)
    private let deleteButton = SourceManagementSelectionActionButton(type: .custom)
    private let moreButton = SourceManagementSelectionActionButton(type: .custom)
    private var selectedCount = 0
    private var totalCount = 0
    private var isUpdating = false
    private var presentationActive = true
    private var measuredHeight: CGFloat = 54
    var onSelectAll: (() -> Void)?
    var onInvert: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMore: (() -> Void)?
    var canInteract: (() -> Bool)?
    var menuAnchor: UIView { moreButton }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure(selectAllButton, title: nil, identifier: "selectAll", action: #selector(handleSelectAll))
        configure(invertButton, title: "反选", identifier: "invertSelection", action: #selector(invert))
        configure(deleteButton, title: L10n.Common.delete, identifier: "deleteSelection", action: #selector(deleteSelection))
        configure(moreButton, title: nil, identifier: "batchActions", action: #selector(more))
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        moreButton.imageView?.contentMode = .center
        moreButton.accessibilityLabel = L10n.Bookshelf.moreActions
        selectionIcon.contentMode = .scaleAspectFit
        selectionIcon.isUserInteractionEnabled = false
        selectionIcon.isAccessibilityElement = false
        selectionTitleLabel.numberOfLines = 0
        selectionTitleLabel.textAlignment = .natural
        selectionTitleLabel.isUserInteractionEnabled = false
        selectionTitleLabel.isAccessibilityElement = false
        selectAllButton.addSubview(selectionIcon)
        selectAllButton.addSubview(selectionTitleLabel)
        for button in [invertButton, deleteButton] {
            button.layer.cornerRadius = 3
            button.layer.borderWidth = 1
        }
        accessibilityElements = [selectAllButton, invertButton, deleteButton, moreButton]
        updateTypography()
        update(selectedCount: 0, totalCount: 0, isUpdating: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshColors), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics(width: bounds.width > 0 ? bounds.width : 402).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: metrics(width: size.width).height)
    }

    func update(selectedCount: Int, totalCount: Int, isUpdating: Bool) {
        self.selectedCount = max(0, selectedCount)
        self.totalCount = max(0, totalCount)
        self.isUpdating = isUpdating
        let all = self.totalCount > 0 && self.selectedCount >= self.totalCount
        let title = all ? L10n.Bookshelf.deselectAll : L10n.Bookshelf.selectAll
        // SelectActionBar.upCountView places the count in the checkbox text, not a second caption.
        selectionTitleLabel.text = "\(title)（\(self.selectedCount)/\(self.totalCount)）"
        selectionIcon.image = all ? ReplaceRuleEditorIcons.checked : ReplaceRuleEditorIcons.unchecked
        selectAllButton.accessibilityLabel = title
        selectAllButton.accessibilityValue = "\(self.selectedCount)/\(self.totalCount)"
        selectAllButton.accessibilityTraits = all ? [.button, .selected] : .button
        updateAvailability()
        refreshColors()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        updateAvailability()
        if !active {
            for button in [selectAllButton, invertButton, deleteButton, moreButton] {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = metrics(width: bounds.width)
        if measuredHeight != m.height {
            measuredHeight = m.height
            invalidateIntrinsicContentSize()
        }
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rtl ? bounds.width - x - width : x, y: y, width: max(0, width), height: height)
        }
        let checkboxHeight = m.stacked ? m.checkboxHeight : m.rowHeight
        selectAllButton.frame = frame(16, 6, m.checkboxWidth, checkboxHeight)
        let actionY = m.stacked ? 6 + m.checkboxHeight : 6
        let actionStart = m.stacked ? max(16, bounds.width - 8 - m.actionsWidth) : 16 + m.checkboxWidth
        var x = actionStart + 5
        invertButton.frame = frame(x, actionY + (m.rowHeight - m.actionHeight) / 2, m.actionWidth, m.actionHeight)
        x += m.actionWidth + 10
        deleteButton.frame = frame(x, actionY + (m.rowHeight - m.actionHeight) / 2, m.actionWidth, m.actionHeight)
        x += m.actionWidth + 5
        moreButton.frame = frame(x, actionY + (m.rowHeight - 36) / 2, 36, 36)
        let iconX: CGFloat = rtl ? selectAllButton.bounds.width - 37 : 5
        selectionIcon.frame = CGRect(x: iconX, y: (checkboxHeight - 32) / 2, width: 32, height: 32)
        selectionTitleLabel.frame = CGRect(
            x: rtl ? 5 : 37, y: 5, width: max(0, selectAllButton.bounds.width - 42), height: max(0, checkboxHeight - 10))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        refreshColors()
    }

    private struct Metrics {
        let actionWidth: CGFloat
        let actionHeight: CGFloat
        let actionsWidth: CGFloat
        let checkboxWidth: CGFloat
        let checkboxHeight: CGFloat
        let rowHeight: CGFloat
        let stacked: Bool
        var height: CGFloat { 12 + rowHeight + (stacked ? checkboxHeight : 0) }
    }

    private func metrics(width: CGFloat) -> Metrics {
        let font = selectionTitleLabel.font ?? .systemFont(ofSize: 14)
        let preferredActionWidth = max(
            72,
            ceil(
                max(
                    invertButton.titleLabel?.intrinsicContentSize.width ?? 0,
                    deleteButton.titleLabel?.intrinsicContentSize.width ?? 0)) + 10)
        let minimumCheckboxWidth = 42 + 2 * font.pointSize
        let stacked = width - 24 - (2 * preferredActionWidth + 56) < minimumCheckboxWidth
        let actionWidth = stacked ? min(preferredActionWidth, max(1, (width - 80) / 2)) : preferredActionWidth
        let actionsWidth = 2 * actionWidth + 56
        let checkboxWidth = max(0, width - 24 - (stacked ? 0 : actionsWidth))
        let textHeight = selectionTitleLabel.sizeThatFits(
            CGSize(width: max(1, checkboxWidth - 42), height: CGFloat.greatestFiniteMagnitude)
        ).height
        // The 32dp compound drawable plus XML 5dp padding, not a UIKit 48pt minimum.
        let checkboxHeight = max(32, ceil(textHeight)) + 10
        let actionTextHeight =
            [invertButton, deleteButton].map {
                $0.titleLabel?.sizeThatFits(CGSize(width: max(1, actionWidth - 10), height: .greatestFiniteMagnitude)).height ?? 0
            }.max() ?? 0
        let actionHeight = ceil(max(font.lineHeight, actionTextHeight)) + 10
        // Both stroke actions also have a 5dp vertical margin in the horizontal row.
        let rowHeight = max(36, actionHeight + 10, stacked ? 0 : checkboxHeight)
        return Metrics(
            actionWidth: actionWidth, actionHeight: actionHeight, actionsWidth: actionsWidth,
            checkboxWidth: checkboxWidth, checkboxHeight: checkboxHeight, rowHeight: rowHeight, stacked: stacked)
    }

    private func configure(
        _ button: SourceManagementSelectionActionButton, title: String?, identifier: String, action: Selector
    ) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.setTitle(title, for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.titleLabel?.textAlignment = .center
        if title != nil { button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5) }
        button.accessibilityLabel = title
        button.accessibilityIdentifier = "sourceManagement." + identifier
        button.permitsInteraction = { [weak self] in
            guard let self else { return false }
            return self.presentationActive && self.canInteract?() != false
        }
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func updateTypography() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        selectionTitleLabel.font = font
        selectionTitleLabel.adjustsFontForContentSizeCategory = false
        // AccentStrokeTextView is a regular TextView, not a medium-weight Android Button.
        for button in [invertButton, deleteButton] {
            button.titleLabel?.font = font
            button.titleLabel?.adjustsFontForContentSizeCategory = false
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateAvailability() {
        selectAllButton.isEnabled = presentationActive && totalCount > 0
        invertButton.isEnabled = presentationActive && selectedCount > 0
        deleteButton.isEnabled = presentationActive && selectedCount > 0 && !isUpdating
        moreButton.isEnabled = presentationActive && selectedCount > 0 && !isUpdating
        refreshColors()
    }

    @objc private func refreshColors() {
        let surface = AndroidReplicaTheme.bottomBackground.resolvedColor(with: traitCollection)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        surface.getRed(&r, green: &g, blue: &b, alpha: nil)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let light = linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722 >= 0.5
        let primary = UIColor(white: light ? 0 : 1, alpha: light ? 222 / 255.0 : 1)
        let disabled = UIColor(white: light ? 0 : 1, alpha: light ? 97 / 255.0 : 77 / 255.0)
        let disabledIcon = UIColor(white: light ? 0 : 1, alpha: light ? 36 / 255.0 : 54 / 255.0)
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        backgroundColor = surface
        selectionTitleLabel.textColor = primary
        selectionIcon.tintColor =
            selectedCount > 0 && selectedCount >= totalCount
            ? accent : UIColor(white: light ? 0 : 1, alpha: light ? 138 / 255.0 : 179 / 255.0)
        // SelectActionBar uses secondary_text_disabled_material for overflow only.
        moreButton.tintColor = moreButton.isEnabled ? primary : disabledIcon
        for button in [invertButton, deleteButton] {
            button.setTitleColor(accent, for: .normal)
            button.setTitleColor(disabled, for: .disabled)
            button.layer.borderColor = (button.isEnabled ? accent : disabled).cgColor
        }
    }

    @objc private func handleSelectAll() { onSelectAll?() }
    @objc private func invert() { onInvert?() }
    @objc private func deleteSelection() { onDelete?() }
    @objc private func more() { onMore?() }
}

private final class SourceManagementSelectionActionButton: UIButton {
    var permitsInteraction: (() -> Bool)?
    override var isHighlighted: Bool {
        didSet {
            backgroundColor =
                isHighlighted
                ? UIColor { traits in
                    UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: 48 / 255.0)
                } : .clear
        }
    }

    private var available: Bool {
        guard isEnabled, permitsInteraction?() != false,
            window?.windowScene?.activationState == .foregroundActive
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 || !view.isUserInteractionEnabled { return false }
            ancestor = view.superview
        }
        return true
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard available else { return }
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
