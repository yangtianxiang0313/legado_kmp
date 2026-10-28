import shared
import UIKit

final class AndroidReplicaReplaceRuleCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaReplaceRuleCell"

    var onToggle: ((Bool) -> Void)?
    var onMore: (() -> Void)?
    var onEdit: (() -> Void)?
    var onSelect: (() -> Void)?

    var moreMenuAnchor: UIView? { moreButton }

    private let backgroundSelectionControl = UIControl()
    private let selectionButton = UIButton(type: .custom)
    private let selectionImageView = UIImageView()
    private let titleLabel = UILabel()
    private let enabledSwitch = UISwitch()
    private let editButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        onMore = nil
        onEdit = nil
        onSelect = nil
        cancelControlTracking()
        titleLabel.text = nil
        selectionButton.accessibilityLabel = nil
        selectionButton.accessibilityValue = nil
        selectionButton.accessibilityTraits = .button
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFont()
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
        isAccessibilityElement = false

        // Consume row-padding taps as selection too, never the caller's legacy row-edit action.
        backgroundSelectionControl.isAccessibilityElement = false
        backgroundSelectionControl.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)
        selectionButton.configuration = nil
        selectionButton.isAccessibilityElement = true
        selectionButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectionButton.addTarget(self, action: #selector(selectionTapped), for: .touchUpInside)

        selectionImageView.contentMode = .scaleAspectFit
        selectionImageView.preferredSymbolConfiguration = .init(pointSize: 22, weight: .regular)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        for item in [selectionImageView, titleLabel] {
            item.isUserInteractionEnabled = false
            item.isAccessibilityElement = false
            item.translatesAutoresizingMaskIntoConstraints = false
            selectionButton.addSubview(item)
        }

        enabledSwitch.onTintColor = AndroidReplicaTheme.accent
        enabledSwitch.setContentHuggingPriority(.required, for: .horizontal)
        enabledSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        enabledSwitch.addTarget(self, action: #selector(toggleChanged), for: .valueChanged)
        configureActionButton(
            editButton,
            image: UIImage(named: "BookDetailAndroidEdit")?.withRenderingMode(.alwaysTemplate)
                ?? UIImage(systemName: "square.and.pencil"),
            title: L10n.ReplaceRule.editAction, action: #selector(editTapped))
        configureActionButton(
            moreButton, image: ReaderMenuAndroidIcon.more.image(),
            title: L10n.Bookshelf.moreActions, action: #selector(moreTapped))

        for item in [backgroundSelectionControl, selectionButton, enabledSwitch, editButton, moreButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        // item_replace_rule.xml: 16dp horizontal / 8dp vertical padding, 36dp actions.
        // Text yields horizontally; the checkbox, switch and action targets never shrink.
        NSLayoutConstraint.activate([
            backgroundSelectionControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundSelectionControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundSelectionControl.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundSelectionControl.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            selectionButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            selectionButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            selectionButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            selectionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            selectionButton.trailingAnchor.constraint(equalTo: enabledSwitch.leadingAnchor, constant: -6),
            selectionImageView.leadingAnchor.constraint(equalTo: selectionButton.leadingAnchor),
            selectionImageView.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            selectionImageView.widthAnchor.constraint(equalToConstant: 24),
            selectionImageView.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.leadingAnchor.constraint(equalTo: selectionImageView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: selectionButton.trailingAnchor),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleLabel.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: selectionButton.topAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: selectionButton.bottomAnchor),
            enabledSwitch.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            enabledSwitch.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 8),
            enabledSwitch.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -8),
            enabledSwitch.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -6),
            editButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            editButton.widthAnchor.constraint(equalToConstant: 36),
            editButton.heightAnchor.constraint(equalToConstant: 36),
            moreButton.centerYAnchor.constraint(equalTo: selectionButton.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            moreButton.widthAnchor.constraint(equalToConstant: 36),
            moreButton.heightAnchor.constraint(equalToConstant: 36),
        ])
        contentView.accessibilityElements = [selectionButton, enabledSwitch, editButton, moreButton]
        applyFont()
    }

    private func configureActionButton(_ button: UIButton, image: UIImage?, title: String, action: Selector) {
        button.configuration = nil
        button.setImage(image, for: .normal)
        button.setPreferredSymbolConfiguration(.init(pointSize: 22, weight: .regular), forImageIn: .normal)
        button.imageView?.contentMode = .scaleAspectFit
        button.tintColor = AndroidReplicaTheme.primaryText
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addTarget(self, action: action, for: .touchUpInside)
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
    }

    private func applyFont() {
        titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: traitCollection)
        setNeedsLayout()
    }

    func configure(rule: ReplaceRule, selected: Bool, selectionMode _: Bool) {
        cancelControlTracking()
        // Match ReplaceRule.getDisplayNameGroup(); do not substitute regex/pattern text.
        let group = rule.group ?? ""
        let name =
            group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rule.name : "\(rule.name) (\(group))"
        let accessibilityName =
            name.isEmpty
            ? NSLocalizedString("replace_rule.unnamed", value: "未命名规则", comment: "Unnamed rule accessibility label")
            : name
        titleLabel.text = name
        selectionImageView.image = UIImage(systemName: selected ? "checkmark.square.fill" : "square")
        selectionImageView.tintColor = selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        selectionButton.accessibilityTraits = selected ? [.button, .selected] : [.button]
        selectionButton.accessibilityLabel = accessibilityName
        selectionButton.accessibilityValue =
            selected
            ? NSLocalizedString("replace_rule.checked", value: "已选择", comment: "Rule checkbox checked")
            : NSLocalizedString("replace_rule.unchecked", value: "未选择", comment: "Rule checkbox unchecked")
        selectionButton.accessibilityIdentifier = "replaceRule.selection.\(rule.id)"
        enabledSwitch.setOn(rule.isEnabled, animated: false)
        enabledSwitch.accessibilityLabel = "\(L10n.ReplaceRule.enableAction)：\(accessibilityName)"
        enabledSwitch.accessibilityIdentifier = "replaceRule.enabled.\(rule.id)"
        editButton.accessibilityLabel = "\(L10n.ReplaceRule.editAction)：\(accessibilityName)"
        editButton.accessibilityIdentifier = "replaceRule.edit.\(rule.id)"
        moreButton.accessibilityLabel = "\(L10n.Bookshelf.moreActions)：\(accessibilityName)"
        moreButton.accessibilityIdentifier = "replaceRule.more.\(rule.id)"
        // Android keeps all four controls available even while some rules are selected.
        applyFont()
    }

    private func cancelControlTracking() {
        for control in [backgroundSelectionControl, selectionButton, enabledSwitch, editButton, moreButton] {
            control.cancelTracking(with: nil)
            control.isHighlighted = false
        }
    }

    @objc private func selectionTapped() {
        onSelect?()
    }

    @objc private func toggleChanged() {
        onToggle?(enabledSwitch.isOn)
    }

    @objc private func moreTapped() {
        onMore?()
    }

    @objc private func editTapped() {
        onEdit?()
    }
}

final class AndroidReplicaTextInputSheetViewController: UIViewController, UITextFieldDelegate {
    private let titleText: String
    private let placeholder: String
    private let initialValue: String?
    private let keyboardType: UIKeyboardType
    private let completion: (String) -> Void
    private let titleLabel = UILabel()
    private let textField = UITextField()
    private let cancelButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    init(titleText: String, placeholder: String, initialValue: String?, keyboardType: UIKeyboardType, completion: @escaping (String) -> Void) {
        self.titleText = titleText
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.keyboardType = keyboardType
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textField.becomeFirstResponder()
    }

    private func configureViews() {
        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText

        textField.placeholder = placeholder
        textField.text = initialValue
        textField.keyboardType = keyboardType
        textField.returnKeyType = .done
        textField.delegate = self
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.clearButtonMode = .whileEditing
        textField.backgroundColor = AndroidReplicaTheme.menuBackground
        textField.layer.cornerRadius = 12
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        textField.leftViewMode = .always

        configureActionButton(cancelButton, title: L10n.Common.cancel, color: AndroidReplicaTheme.secondaryText, action: #selector(cancelTapped))
        configureActionButton(confirmButton, title: L10n.Common.confirm, color: AndroidReplicaTheme.accent, action: #selector(confirmTapped))

        let actionStack = UIStackView(arrangedSubviews: [cancelButton, confirmButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 12
        actionStack.distribution = .fillEqually

        for item in [titleLabel, textField, actionStack] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            textField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            textField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textField.heightAnchor.constraint(equalToConstant: 46),

            actionStack.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 18),
            actionStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            actionStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            actionStack.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private func configureActionButton(_ button: UIButton, title: String, color: UIColor, action: Selector) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = AndroidReplicaTheme.menuBackground
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        confirmTapped()
        return true
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func confirmTapped() {
        let text = textField.text ?? ""
        dismiss(animated: true) { [completion] in
            completion(text)
        }
    }
}

final class AndroidReplicaReplaceRuleImportPreviewSheetViewController: UIViewController {
    private let rules: [ReplaceRule]
    private let completion: (String?) -> Void
    private let titleLabel = UILabel()
    private let summaryLabel = UILabel()
    private let textView = UITextView()
    private let groupField = UITextField()
    private let cancelButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    init(rules: [ReplaceRule], completion: @escaping (String?) -> Void) {
        self.rules = rules
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        titleLabel.text = L10n.ReplaceRule.importPreviewTitle
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText

        summaryLabel.text = L10n.ReplaceRule.importPreviewMessage(rules.count)
        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = AndroidReplicaTheme.secondaryText

        textView.text = previewText
        textView.isEditable = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.backgroundColor = AndroidReplicaTheme.menuBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        groupField.placeholder = L10n.ReplaceRule.importGroupPlaceholder
        groupField.backgroundColor = AndroidReplicaTheme.menuBackground
        groupField.layer.cornerRadius = 12
        groupField.clearButtonMode = .whileEditing
        groupField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        groupField.leftViewMode = .always

        configureActionButton(cancelButton, title: L10n.Common.cancel, color: AndroidReplicaTheme.secondaryText, action: #selector(cancelTapped))
        configureActionButton(confirmButton, title: L10n.ReplaceRule.importPreviewConfirm, color: AndroidReplicaTheme.accent, action: #selector(confirmTapped))

        let actionStack = UIStackView(arrangedSubviews: [cancelButton, confirmButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 12
        actionStack.distribution = .fillEqually

        for item in [titleLabel, summaryLabel, textView, groupField, actionStack] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            textView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 14),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            textView.heightAnchor.constraint(equalToConstant: 280),

            groupField.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 14),
            groupField.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            groupField.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            groupField.heightAnchor.constraint(equalToConstant: 44),

            actionStack.topAnchor.constraint(equalTo: groupField.bottomAnchor, constant: 16),
            actionStack.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            actionStack.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            actionStack.heightAnchor.constraint(equalToConstant: 46),
        ])
    }

    private var previewText: String {
        var names = rules.prefix(80).map { rule -> String in
            let name = rule.name.isEmpty ? rule.pattern : rule.name
            if let group = rule.group, group.isEmpty == false {
                return "\(name)  [\(group)]"
            }
            return name
        }.joined(separator: "\n")
        if rules.count > 80 {
            names += "\n..."
        }
        return names
    }

    private func configureActionButton(_ button: UIButton, title: String, color: UIColor, action: Selector) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.baseForegroundColor = color
        configuration.baseBackgroundColor = AndroidReplicaTheme.menuBackground
        configuration.cornerStyle = .medium
        button.configuration = configuration
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func confirmTapped() {
        let group = groupField.text
        dismiss(animated: true) { [completion] in
            completion(group)
        }
    }
}

extension ReplaceRule {
    func copyWithGroup(_ group: String?) -> ReplaceRule {
        ReplaceRule(
            id: id,
            name: name,
            group: group,
            pattern: pattern,
            replacement: replacement,
            scope: scope,
            scopeTitle: scopeTitle,
            scopeContent: scopeContent,
            excludeScope: excludeScope,
            isEnabled: isEnabled,
            isRegex: isRegex,
            timeoutMillisecond: timeoutMillisecond,
            order: order
        )
    }

    var exportDictionary: [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "name": name,
            "pattern": pattern,
            "replacement": replacement,
            "isRegex": isRegex,
            "scopeTitle": scopeTitle,
            "scopeContent": scopeContent,
            "isEnabled": isEnabled,
            "order": order,
            "timeout": timeoutMillisecond,
        ]
        if let group, group.isEmpty == false {
            dict["group"] = group
        }
        if let scope, scope.isEmpty == false {
            dict["scope"] = scope
        }
        if let excludeScope, excludeScope.isEmpty == false {
            dict["excludeScope"] = excludeScope
        }
        return dict
    }
}
