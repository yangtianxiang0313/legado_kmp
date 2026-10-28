import UIKit

/// Legado 5f5d314 activity_replace_rule.xml / view_search.xml.
final class AndroidReplicaReplaceRuleToolbarView: NavigationToolbarView {
    let backButton = UIButton(type: .custom)
    let searchField = UITextField()
    let groupButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    private let searchBackground = UIView()
    private let clearButton = UIButton(type: .custom)
    private let hintIcon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private var clearWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else { return }
        applyPalette()
    }

    private func configureViews() {
        configure(backButton, image: ReaderMenuAndroidIcon.back.image(), label: L10n.Reader.backAction)
        configure(
            groupButton, image: UIImage(named: "BookDetailAndroidGroups")?.withRenderingMode(.alwaysTemplate),
            label: L10n.ReplaceRule.filterByGroup)
        configure(moreButton, image: ReaderMenuAndroidIcon.more.image(), label: L10n.Reader.menuMore)
        configure(clearButton, image: ReaderMenuAndroidIcon.clear.image(size: 20), label: L10n.Common.clear)
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        groupButton.accessibilityIdentifier = "replaceRule.group"
        moreButton.accessibilityIdentifier = "replaceRule.more"
        clearButton.accessibilityIdentifier = "replaceRule.clearSearch"
        clearButton.addTarget(self, action: #selector(clearQuery), for: .touchUpInside)

        searchBackground.isUserInteractionEnabled = false
        searchBackground.layer.cornerRadius = 15
        searchBackground.layer.borderWidth = 0.5
        searchField.placeholder = L10n.ReplaceRule.searchPlaceholder
        searchField.accessibilityLabel = L10n.ReplaceRule.searchPlaceholder
        searchField.accessibilityIdentifier = "replaceRule.search"
        searchField.font = .systemFont(ofSize: 14)
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.spellCheckingType = .no
        searchField.smartQuotesType = .no
        searchField.smartDashesType = .no
        searchField.clearButtonMode = .never
        searchField.borderStyle = .none
        searchField.addTarget(self, action: #selector(updateQueryChrome), for: .editingChanged)
        let hint = UIView(frame: CGRect(x: 0, y: 0, width: 22, height: 30))
        hint.isUserInteractionEnabled = false
        hintIcon.frame = CGRect(x: 2, y: 8, width: 14, height: 14)
        hintIcon.contentMode = .scaleAspectFit
        hint.addSubview(hintIcon)
        searchField.leftView = hint

        for item in [searchBackground, backButton, searchField, clearButton, groupButton, moreButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        clearWidth = clearButton.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 56),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
            groupButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            groupButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            groupButton.widthAnchor.constraint(equalToConstant: 44),
            groupButton.heightAnchor.constraint(equalToConstant: 44),
            searchBackground.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            searchBackground.trailingAnchor.constraint(equalTo: groupButton.leadingAnchor, constant: -8),
            searchBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchBackground.heightAnchor.constraint(equalToConstant: 30),
            searchField.leadingAnchor.constraint(equalTo: searchBackground.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 44),
            clearButton.trailingAnchor.constraint(equalTo: searchBackground.trailingAnchor),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.heightAnchor.constraint(equalToConstant: 44),
            clearWidth,
        ])
        applyPalette()
        updateQueryChrome()
    }

    private func configure(_ button: UIButton, image: UIImage?, label: String) {
        button.setImage(image, for: .normal)
        button.setPreferredSymbolConfiguration(.init(pointSize: 22), forImageIn: .normal)
        button.accessibilityLabel = label
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
    }

    private func applyPalette() {
        for button in [backButton, groupButton, moreButton, clearButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
            if button.configuration == nil {
                button.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
            }
        }
        let fill = UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? 1 : 0, alpha: 16.0 / 255) }
        searchBackground.backgroundColor = fill
        searchBackground.layer.borderColor = fill.resolvedColor(with: traitCollection).cgColor
        searchField.textColor = AndroidReplicaTheme.toolbarText
        searchField.tintColor = AndroidReplicaTheme.toolbarText
        let hint = AndroidReplicaTheme.toolbarText.withAlphaComponent(0.7)
        hintIcon.tintColor = hint
        searchField.attributedPlaceholder = NSAttributedString(
            string: L10n.ReplaceRule.searchPlaceholder, attributes: [.foregroundColor: hint])
    }

    @objc func updateQueryChrome() {
        let hasQuery = !(searchField.text ?? "").isEmpty
        searchField.leftViewMode = hasQuery ? .never : .always
        clearButton.isHidden = !hasQuery
        clearButton.isEnabled = hasQuery
        clearWidth.constant = hasQuery ? 44 : 0
        accessibilityElements =
            hasQuery
            ? [backButton, searchField, clearButton, groupButton, moreButton]
            : [backButton, searchField, groupButton, moreButton]
    }

    @objc private func clearQuery() {
        searchField.text = ""
        searchField.becomeFirstResponder()
        searchField.sendActions(for: .editingChanged)
    }
}

/// view_select_action_bar.xml; selection is available without changing toolbar modes.
final class AndroidReplicaReplaceRuleSelectionBar: UIView {
    let allButton = UIButton(type: .system)
    let invertButton = UIButton(type: .system)
    let deleteButton = UIButton(type: .system)
    let moreButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        allButton.setTitle("全选", for: .normal)
        invertButton.setTitle("反选", for: .normal)
        deleteButton.setTitle(L10n.ReplaceRule.deleteAction, for: .normal)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        moreButton.accessibilityLabel = L10n.Reader.menuMore
        for (index, button) in [allButton, invertButton, deleteButton, moreButton].enumerated() {
            button.accessibilityIdentifier =
                ["replaceRule.selectAll", "replaceRule.invert", "replaceRule.delete", "replaceRule.batchMore"][index]
            button.tintColor = AndroidReplicaTheme.accent
            button.titleLabel?.font = .systemFont(ofSize: 14)
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        allButton.contentHorizontalAlignment = .leading
        moreButton.tintColor = AndroidReplicaTheme.primaryText
        let divider = UIView()
        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 0.5),
            allButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            allButton.trailingAnchor.constraint(equalTo: invertButton.leadingAnchor, constant: -5),
            invertButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -5),
            invertButton.widthAnchor.constraint(equalToConstant: 64),
            deleteButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -5),
            deleteButton.widthAnchor.constraint(equalToConstant: 64),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            moreButton.widthAnchor.constraint(equalToConstant: 36),
        ])
        for button in [allButton, invertButton, deleteButton, moreButton] {
            button.topAnchor.constraint(equalTo: topAnchor, constant: 6).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        update(selectedCount: 0, totalCount: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func update(selectedCount: Int, totalCount: Int) {
        let all = totalCount > 0 && selectedCount == totalCount
        allButton.setImage(UIImage(systemName: all ? "checkmark.square.fill" : "square"), for: .normal)
        allButton.accessibilityValue = "\(selectedCount)/\(totalCount)"
        allButton.accessibilityTraits = all ? [.button, .selected] : .button
        allButton.isEnabled = totalCount > 0
        invertButton.isEnabled = totalCount > 0
        deleteButton.isEnabled = selectedCount > 0
        moreButton.isEnabled = selectedCount > 0
    }
}
