import UIKit
import shared

/// Flat item_toc_regex row. Editing and global automatic-recognition switches stay in management.
@MainActor
final class ReaderTxtTocRuleDialogCell: UITableViewCell {
    static let reuseIdentifier = "reader.txtToc.rule.cell"
    private(set) var ruleID: Int64?

    private let nameLabel = UILabel()
    private let regexLabel = UILabel()
    private let exampleLabel = UILabel()
    private let indicator = UIImageView()
    private var isRuleSelected = false
    private var interactionEnabled = true
    private var automaticRecognitionEnabled = true

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        selectedBackgroundView = UIView()
        isAccessibilityElement = true
        contentView.isAccessibilityElement = false
        for label in [nameLabel, regexLabel, exampleLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.textAlignment = .natural
            label.isAccessibilityElement = false
        }
        indicator.contentMode = .center
        indicator.isAccessibilityElement = false
        indicator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            indicator.widthAnchor.constraint(equalToConstant: 32),
            indicator.heightAnchor.constraint(equalToConstant: 32),
        ])
        let nameRow = UIStackView(arrangedSubviews: [indicator, nameLabel])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = 8
        let stack = UIStackView(arrangedSubviews: [nameRow, regexLabel, exampleLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ruleID = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    func configure(rule: TxtTocRule, selected: Bool, enabled: Bool) {
        ruleID = rule.id
        nameLabel.text = rule.name
        regexLabel.text = rule.rule
        exampleLabel.text = rule.example
        exampleLabel.isHidden = rule.example?.isEmpty != false
        automaticRecognitionEnabled = rule.enable
        accessibilityIdentifier = "reader.txtToc.rule.\(rule.id)"
        accessibilityLabel = [rule.name, rule.rule, rule.example ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        updateSelection(selected: selected, enabled: enabled)
        applyAppearance()
    }

    func updateSelection(selected: Bool, enabled: Bool) {
        isRuleSelected = selected
        interactionEnabled = enabled
        indicator.image = selected ? Self.checkedImage : Self.uncheckedImage
        indicator.tintColor = selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        indicator.alpha = enabled ? 1 : 0.38
        var traits: UIAccessibilityTraits = .button
        if selected { traits.insert(.selected) }
        if !enabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        // A globally disabled rule remains a fully selectable row.
        accessibilityValue =
            automaticRecognitionEnabled
            ? nil
            : NSLocalizedString(
                "reader.txt_toc_rule.auto_disabled", value: "自动识别未启用", comment: "Automatic recognition status only")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func applyAppearance() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectedBackgroundView?.backgroundColor = AndroidReplicaTheme.activeIndicator
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        regexLabel.textColor = AndroidReplicaTheme.secondaryText
        exampleLabel.textColor = AndroidReplicaTheme.secondaryText
        nameLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 16, textStyle: .body, compatibleWith: traitCollection)
        let detailFont = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        regexLabel.font = detailFont
        exampleLabel.font = detailFont
        updateSelection(selected: isRuleSelected, enabled: interactionEnabled)
    }

    // AppCompat btn_radio_{on,off}_mtrl: 32dp viewport, 9dp ring, 2dp stroke, 5dp dot.
    private static let checkedImage = radioImage(checked: true)
    private static let uncheckedImage = radioImage(checked: false)

    private static func radioImage(checked: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { _ in
            UIColor.black.setStroke()
            UIColor.black.setFill()
            let ring = UIBezierPath(ovalIn: CGRect(x: 7, y: 7, width: 18, height: 18))
            ring.lineWidth = 2
            ring.stroke()
            if checked { UIBezierPath(ovalIn: CGRect(x: 11, y: 11, width: 10, height: 10)).fill() }
        }.withRenderingMode(.alwaysTemplate)
    }
}
