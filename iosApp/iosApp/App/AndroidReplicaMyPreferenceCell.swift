import UIKit

final class AndroidReplicaMyPreferenceCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaMyPreferenceCell"

    private let iconSlot = UIView()
    private let iconView = UIImageView()
    private let textStack = UIStackView()
    private let titleLabel = ReaderTocSingleLineLabel()
    private let summaryLabel = AndroidExploreTextLabel()
    private let valueContainer = UIView()
    // maxLines=1 is not singleLine=true: the value keeps its original newlines.
    private let valueLabel = AndroidExploreTextLabel()
    private var textToEdge: NSLayoutConstraint!
    private var valueConstraints: [NSLayoutConstraint] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        accessoryType = .none
        isAccessibilityElement = true
        accessibilityTraits = .button
        selectedBackgroundView = UIView()
        iconSlot.isUserInteractionEnabled = false
        iconSlot.isAccessibilityElement = false
        iconView.contentMode = .scaleAspectFit
        iconView.isAccessibilityElement = false

        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 8
        textStack.isAccessibilityElement = false
        for label in [titleLabel, summaryLabel, valueLabel] {
            label.isAccessibilityElement = false
            // Scale the size explicitly so UIKit does not substitute the bundled font.
            label.adjustsFontForContentSizeCategory = false
            label.adjustsFontSizeToFitWidth = false
            label.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
        }
        for label in [titleLabel, summaryLabel] {
            label.textAlignment = .natural
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(label)
        }
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.numberOfLines = 0
        summaryLabel.lineBreakMode = .byWordWrapping
        valueLabel.numberOfLines = 1
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.textAlignment = .center
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueContainer.isUserInteractionEnabled = false
        valueContainer.isAccessibilityElement = false
        // NameListPreference's item_fillet_text.xml, not an icon background or disclosure arrow.
        valueContainer.layer.cornerRadius = 16

        for item in [iconSlot, textStack, valueContainer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconSlot.addSubview(iconView)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueContainer.addSubview(valueLabel)
        textToEdge = textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        // Preference.bindView inflates the widget with a null root, so its root 3dp margin is not applied.
        valueConstraints = [
            textStack.trailingAnchor.constraint(equalTo: valueContainer.leadingAnchor, constant: -8),
            valueContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            valueContainer.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueContainer.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 18),
            valueContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
            valueContainer.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.44),
        ]
        // view_preference.xml: 16/10 outer padding, a 24dp icon slot and 16dp text gap; minHeight 60.
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            iconSlot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconSlot.widthAnchor.constraint(equalToConstant: 24),
            iconSlot.heightAnchor.constraint(equalToConstant: 24),
            iconSlot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconSlot.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: iconSlot.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: iconSlot.topAnchor, constant: 1),
            iconView.bottomAnchor.constraint(equalTo: iconSlot.bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: iconSlot.trailingAnchor, constant: 16),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueLabel.leadingAnchor.constraint(equalTo: valueContainer.leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: valueContainer.trailingAnchor, constant: -12),
            valueLabel.topAnchor.constraint(equalTo: valueContainer.topAnchor, constant: 4),
            valueLabel.bottomAnchor.constraint(equalTo: valueContainer.bottomAnchor, constant: -4),
            textToEdge,
        ])
        updateTypography()
        setValue(nil)
        applyPalette()
    }

    func configure(title: String, summary: String?, iconName: String, value: String?) {
        titleLabel.text = title
        summaryLabel.text = summary
        summaryLabel.isHidden = summary?.isEmpty != false
        iconView.image = UIImage(named: iconName)?.withRenderingMode(.alwaysTemplate)
        setValue(value)
        // Preserve raw strings in AX independently of the title's single-line transformation.
        accessibilityLabel = [title, summary].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
        applyPalette()
    }

    func setValue(_ value: String?) {
        valueLabel.text = value
        let hasValue = value?.isEmpty == false
        if valueContainer.isHidden == hasValue {
            NSLayoutConstraint.deactivate(valueConstraints + [textToEdge])
            valueContainer.isHidden = !hasValue
            NSLayoutConstraint.activate(hasValue ? valueConstraints : [textToEdge])
        }
        accessibilityValue = value
        setNeedsLayout()
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        prepareTextLayout(width: targetSize.width)
        return super.systemLayoutSizeFitting(
            targetSize, withHorizontalFittingPriority: horizontalFittingPriority,
            verticalFittingPriority: verticalFittingPriority)
    }

    override func layoutSubviews() {
        prepareTextLayout(width: contentView.bounds.width)
        super.layoutSubviews()
    }

    private func prepareTextLayout(width: CGFloat) {
        guard width.isFinite, width > 0 else { return }
        // Resolve the wrap width before automaticDimension measures a long summary.
        let valueWidth = min(valueLabel.intrinsicContentSize.width + 24, width * 0.44)
        let textWidth = max(1, width - 72 - (valueContainer.isHidden ? 0 : valueWidth + 8))
        if summaryLabel.preferredMaxLayoutWidth != textWidth {
            summaryLabel.preferredMaxLayoutWidth = textWidth
        }
    }

    func applyPalette() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        selectedBackgroundView?.backgroundColor = Self.pressedColor
        iconView.tintColor = AndroidReplicaTheme.accent
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        summaryLabel.textColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 179 / 255.0, alpha: 1)
                : UIColor(white: 44 / 255.0, alpha: 138 / 255.0)
        }
        valueLabel.textColor = AndroidReplicaTheme.primaryText
        valueContainer.backgroundColor = Self.pressedColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        summaryLabel.text = nil
        summaryLabel.isHidden = true
        summaryLabel.preferredMaxLayoutWidth = 0
        iconView.image = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        setValue(nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
        }
        applyPalette()
    }

    private func updateTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        let summaryFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        summaryLabel.font = summaryFont
        valueLabel.font = summaryFont
        setNeedsLayout()
    }

    private static let pressedColor = UIColor { traits in
        UIColor(white: (traits.userInterfaceStyle == .dark ? 77 : 172) / 255.0, alpha: 99 / 255.0)
    }
}
