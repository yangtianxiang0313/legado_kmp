import UIKit

// Legado 5f5d314: item_radio_button/item_check_box and ThemeRadioButton/ThemeCheckBox.
// Mark assets retain AppCompat 1.7.1's btn_{radio,checkbox}_*_mtrl vector paths.
final class SearchScopeOptionCell: UITableViewCell {
    static let reuseIdentifier = "SearchScopeOptionCell"

    private let indicatorView = UIImageView()
    private let nameLabel = AndroidExploreTextLabel()
    private let touchFeedbackView = UIView()
    private var isGroup = false
    private var isChecked = false
    private var touchFeedbackStartedAt: CFTimeInterval?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button

        indicatorView.contentMode = .scaleAspectFit
        indicatorView.isAccessibilityElement = false
        indicatorView.isUserInteractionEnabled = false

        // Widget.CompoundButton -> TextAppearance.Material -> body_1: 14sp, regular.
        applyFont()
        nameLabel.adjustsFontForContentSizeCategory = false
        nameLabel.adjustsFontSizeToFitWidth = false
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byWordWrapping
        nameLabel.textAlignment = .natural
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.isAccessibilityElement = false
        nameLabel.isUserInteractionEnabled = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        // control_background_40dp_material: 20dp ripple radius at the button hotspot.
        touchFeedbackView.layer.cornerRadius = 20
        touchFeedbackView.alpha = 0
        touchFeedbackView.isAccessibilityElement = false
        touchFeedbackView.isUserInteractionEnabled = false

        for item in [touchFeedbackView, indicatorView, nameLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        // item_{radio_button,check_box}: 8dp vertical / 16dp horizontal padding.
        // CompoundButton adds the entire 32dp drawable width, with no extra text gap.
        let minimumHeight = contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        minimumHeight.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            minimumHeight,
            indicatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            indicatorView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            indicatorView.widthAnchor.constraint(equalToConstant: 32),
            indicatorView.heightAnchor.constraint(equalToConstant: 32),
            nameLabel.leadingAnchor.constraint(equalTo: indicatorView.trailingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
            nameLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            touchFeedbackView.centerXAnchor.constraint(equalTo: indicatorView.centerXAnchor),
            touchFeedbackView.centerYAnchor.constraint(equalTo: indicatorView.centerYAnchor),
            touchFeedbackView.widthAnchor.constraint(equalToConstant: 40),
            touchFeedbackView.heightAnchor.constraint(equalToConstant: 40),
        ])
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(name: String, isGroup: Bool, isSelected: Bool, identifier: String) {
        self.isGroup = isGroup
        isChecked = isSelected
        nameLabel.text = name
        let assetName: String
        if isGroup {
            assetName = isSelected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff"
        } else {
            assetName = isSelected ? "SearchScopeAndroidRadioOn" : "SearchScopeAndroidRadioOff"
        }
        indicatorView.image = UIImage(named: assetName)?.withRenderingMode(.alwaysTemplate)
        accessibilityLabel = name
        accessibilityIdentifier = identifier
        updateAccessibility()
        updateColors()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        let changed = isHighlighted != highlighted
        super.setHighlighted(highlighted, animated: animated)
        if changed {
            setTouchFeedbackVisible(highlighted)
        }
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        // UITableView's transient selection must not replace the selection draft.
        updateAccessibility()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        super.setHighlighted(false, animated: false)
        super.setSelected(false, animated: false)
        isGroup = false
        isChecked = false
        nameLabel.text = nil
        indicatorView.image = nil
        accessibilityLabel = nil
        accessibilityIdentifier = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = .button
        resetTouchFeedback()
        updateColors()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            resetTouchFeedback()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            applyFont()
        }
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            updateColors()
        }
    }

    private func applyFont() {
        nameLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        nameLabel.invalidateIntrinsicContentSize()
        contentView.setNeedsLayout()
    }

    private func updateColors() {
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        // ThemeRadioButton/ThemeCheckBox -> TintHelper.setTint; unchecked ATE colors
        // are #8A000000 / #B3FFFFFF, identical to the shared secondaryText palette.
        indicatorView.tintColor = isChecked ? accent : AndroidReplicaTheme.secondaryText
        touchFeedbackView.backgroundColor =
            isChecked ? accent.withAlphaComponent(0.4) : AndroidReplicaTheme.activeIndicator
    }

    private func updateAccessibility() {
        accessibilityTraits = isChecked ? [.button, .selected] : .button
        accessibilityValue =
            isChecked
            ? NSLocalizedString("search.more.selected", value: "已选中", comment: "Selected search scope option")
            : NSLocalizedString("search.more.notSelected", value: "未选中", comment: "Unselected search scope option")
        accessibilityHint =
            isGroup
            ? NSLocalizedString(
                "search.scope.toggle_group", value: "双击切换此分组的选中状态", comment: "Search scope group accessibility hint"
            )
            : NSLocalizedString(
                "search.scope.select_source", value: "双击选择此书源", comment: "Search scope source accessibility hint"
            )
    }

    private func setTouchFeedbackVisible(_ visible: Bool) {
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            resetTouchFeedback()
            touchFeedbackView.alpha = visible ? 1 : 0
            return
        }
        // Android RippleForeground: radius 225ms, opacity 75ms in / 150ms out,
        // with a 225ms minimum visible interval for short taps.
        let now = CACurrentMediaTime()
        let delay: TimeInterval
        if visible {
            touchFeedbackView.layer.removeAllAnimations()
            touchFeedbackView.alpha = 0
            touchFeedbackStartedAt = now
            delay = 0
            let expansion = CABasicAnimation(keyPath: "transform.scale")
            expansion.fromValue = 0
            expansion.toValue = 1
            expansion.duration = 0.225
            expansion.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            touchFeedbackView.layer.add(expansion, forKey: "searchScope.touchExpansion")
        } else {
            guard let startedAt = touchFeedbackStartedAt else { return }
            delay = max(0, 0.225 - (now - startedAt))
            touchFeedbackStartedAt = nil
        }
        UIView.animate(
            withDuration: visible ? 0.075 : 0.15,
            delay: delay,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveLinear],
            animations: {
                self.touchFeedbackView.alpha = visible ? 1 : 0
            }
        )
    }

    private func resetTouchFeedback() {
        touchFeedbackView.layer.removeAllAnimations()
        touchFeedbackView.alpha = 0
        touchFeedbackStartedAt = nil
    }
}
