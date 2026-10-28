import shared
import UIKit

final class DictRuleViewController: UIViewController, NavigationCustomToolbarProviding, UITableViewDataSource,
    UITableViewDelegate, UITextFieldDelegate
{
    private let screen = SettingsScreenAdapter()
    private let topBar = NavigationToolbarView()
    private let backButton = UIButton(type: .system)
    private let searchField = UITextField()
    private let addButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var allRules: [DictRule] = []
    private var filteredRules: [DictRule] = []
    private var searchKeyword = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Settings.dictRuleTitle
        view.backgroundColor = AndroidReplicaTheme.background
        navigationController?.setNavigationBarHidden(true, animated: false)
        configureViews()
        bootstrap()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    deinit {
        screen.unbind()
    }

    private func configureViews() {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.accessibilityLabel = L10n.Reader.backAction
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        configureSearchField()
        configureIconButton(addButton, image: "plus", label: L10n.Settings.dictRuleAddAction, action: #selector(handleAddRule))
        configureIconButton(moreButton, image: "ellipsis", label: L10n.Bookshelf.moreActions, action: #selector(handleMoreActions))

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AndroidReplicaDictRuleCell.self, forCellReuseIdentifier: AndroidReplicaDictRuleCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "settings.dictRule.table"

        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = L10n.Settings.loading

        for item in [topBar, tableView, emptyLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [backButton, searchField, addButton, moreButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 48),
            backButton.heightAnchor.constraint(equalToConstant: 48),

            moreButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            moreButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 42),
            moreButton.heightAnchor.constraint(equalToConstant: 42),

            addButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            addButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 42),
            addButton.heightAnchor.constraint(equalToConstant: 42),

            searchField.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            searchField.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 32),

            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableView.trailingAnchor, constant: -24),
        ])
    }

    private func configureSearchField() {
        searchField.placeholder = L10n.Settings.dictRuleTitle
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.delegate = self
        searchField.backgroundColor = AndroidReplicaTheme.menuBackground
        searchField.layer.cornerRadius = 16
        searchField.font = .systemFont(ofSize: 15)
        searchField.textColor = AndroidReplicaTheme.primaryText
        searchField.tintColor = AndroidReplicaTheme.accent
        searchField.attributedPlaceholder = NSAttributedString(
            string: L10n.Settings.dictRuleTitle,
            attributes: [.foregroundColor: AndroidReplicaTheme.secondaryText]
        )
        let icon = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        icon.tintColor = AndroidReplicaTheme.secondaryText
        icon.contentMode = .center
        icon.frame = CGRect(x: 0, y: 0, width: 34, height: 28)
        searchField.leftView = icon
        searchField.leftViewMode = .always
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        searchField.accessibilityIdentifier = "settings.dictRule.search"
    }

    private func configureIconButton(_ button: UIButton, image: String, label: String, action: Selector) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func bootstrap() {
        emptyLabel.text = L10n.Settings.loading
        emptyLabel.isHidden = false
        screen.onDictRulesChange = { [weak self] rules in
            self?.allRules = rules
            self?.applyFilter()
        }
        switch screen.bootstrap() {
        case .success:
            Task { await reloadRules() }
        case let .failure(error):
            emptyLabel.text = error.message
        }
    }

    private func reloadRules() async {
        do {
            let rules = try await screen.loadDictRules()
            await MainActor.run {
                allRules = rules
                applyFilter()
            }
        } catch {
            await MainActor.run {
                emptyLabel.text = error.userFacingMessage
                emptyLabel.isHidden = false
            }
        }
    }

    private func applyFilter() {
        let sortedRules = allRules.sorted { lhs, rhs in
            if lhs.sortNumber == rhs.sortNumber {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.sortNumber < rhs.sortNumber
        }
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty {
            filteredRules = sortedRules
        } else {
            filteredRules = sortedRules.filter { rule in
                rule.name.localizedCaseInsensitiveContains(keyword) ||
                    rule.urlRule.localizedCaseInsensitiveContains(keyword) ||
                    rule.showRule.localizedCaseInsensitiveContains(keyword)
            }
        }
        if allRules.isEmpty {
            emptyLabel.text = "\(L10n.Settings.dictRuleListEmptyTitle)\n\(L10n.Settings.dictRuleListEmptyDetail)"
        } else {
            emptyLabel.text = L10n.Search.noResults
        }
        emptyLabel.isHidden = filteredRules.isEmpty == false
        tableView.reloadData()
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func searchTextChanged() {
        searchKeyword = searchField.text ?? ""
        applyFilter()
    }

    @objc private func handleAddRule() {
        presentEditor(rule: nil)
    }

    @objc private func handleMoreActions() {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.Settings.dictRuleTitle,
            options: [
                .init(title: L10n.Settings.dictRuleImportTitle, systemImage: "square.and.arrow.down", isSelected: false) { [weak self] in
                    self?.showImportSheet()
                },
                .init(title: L10n.Settings.dictRuleExportTitle, systemImage: "doc.on.doc", isSelected: false) { [weak self] in
                    self?.exportAllRules()
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 3)),
            animated: true
        )
    }

    private func presentEditor(rule: DictRule?) {
        let controller = AndroidReplicaDictRuleEditorViewController(rule: rule)
        controller.onSave = { [weak self] payload in
            self?.saveRule(payload, original: rule)
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 430), animated: true)
    }

    private func saveRule(_ payload: AndroidReplicaDictRuleEditorViewController.Payload, original: DictRule?) {
        guard payload.name.isEmpty == false else {
            showTransientMessage(L10n.Settings.dictRuleValidationMessage)
            return
        }
        let candidate = DictRule(
            name: payload.name,
            urlRule: payload.urlRule,
            showRule: payload.showRule,
            enabled: original?.enabled ?? true,
            sortNumber: original?.sortNumber ?? Int32(allRules.count)
        )
        Task { [weak self] in
            do {
                _ = try await self?.screen.saveDictRule(candidate)
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func showImportSheet() {
        let controller = AndroidReplicaDictRuleImportViewController()
        controller.onImport = { [weak self] payload in
            self?.importRules(payload: payload)
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 390), animated: true)
    }

    private func importRules(payload: String) {
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPayload.isEmpty == false else { return }
        Task { [weak self] in
            do {
                let count = try await self?.screen.importDictRules(payload: trimmedPayload) ?? 0
                await MainActor.run {
                    self?.showTransientMessage(String(format: L10n.Settings.dictRuleImportSuccess, count))
                }
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func exportAllRules() {
        Task { [weak self] in
            do {
                let json = try await self?.screen.exportDictRules(names: []) ?? ""
                await MainActor.run {
                    UIPasteboard.general.string = json
                    self?.showTransientMessage(L10n.Settings.dictRuleExportSuccess)
                }
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func showMenu(for rule: DictRule) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: rule.name,
            options: [
                .init(title: L10n.Settings.dictRuleEditTitle, systemImage: "pencil", isSelected: false) { [weak self] in
                    self?.presentEditor(rule: rule)
                },
                .init(
                    title: rule.enabled ? L10n.Settings.dictRuleDisabled : L10n.Settings.dictRuleEnabled,
                    systemImage: rule.enabled ? "pause.circle" : "play.circle",
                    isSelected: false
                ) { [weak self] in
                    self?.setEnabled(rule: rule, enabled: !rule.enabled)
                },
                .init(title: L10n.Settings.dictRuleExportTitle, systemImage: "doc.on.doc", isSelected: false) { [weak self] in
                    self?.exportRules(names: [rule.name])
                },
                .init(title: L10n.SourceManagement.deleteAction, systemImage: "trash", isSelected: false, isDestructive: true) { [weak self] in
                    self?.presentDeleteConfirmation(for: rule)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 5)),
            animated: true
        )
    }

    private func exportRules(names: [String]) {
        Task { [weak self] in
            do {
                let json = try await self?.screen.exportDictRules(names: names) ?? ""
                await MainActor.run {
                    UIPasteboard.general.string = json
                    self?.showTransientMessage(L10n.Settings.dictRuleExportSuccess)
                }
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func presentDeleteConfirmation(for rule: DictRule) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.Settings.dictRuleDeleteTitle,
            options: [
                .init(title: L10n.SourceManagement.deleteAction, systemImage: "trash", isSelected: false, isDestructive: true) { [weak self] in
                    Task {
                        do {
                            try await self?.screen.deleteDictRule(name: rule.name)
                        } catch {
                            await MainActor.run {
                                self?.showTransientMessage(error.userFacingMessage)
                            }
                        }
                    }
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 2)),
            animated: true
        )
    }

    private func setEnabled(rule: DictRule, enabled: Bool) {
        Task { [weak self] in
            do {
                _ = try await self?.screen.setDictRuleEnabled(name: rule.name, enabled: enabled)
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        filteredRules.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AndroidReplicaDictRuleCell.reuseIdentifier, for: indexPath) as! AndroidReplicaDictRuleCell
        let rule = filteredRules[indexPath.row]
        cell.configure(rule: rule)
        cell.onEnabledChange = { [weak self] enabled in self?.setEnabled(rule: rule, enabled: enabled) }
        cell.onMore = { [weak self] in self?.showMenu(for: rule) }
        cell.accessibilityIdentifier = "settings.dictRule.cell"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        presentEditor(rule: filteredRules[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

private final class AndroidReplicaDictRuleCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaDictRuleCell"
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let enabledSwitch = UISwitch()
    private let moreButton = UIButton(type: .system)

    var onEnabledChange: ((Bool) -> Void)?
    var onMore: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none

        nameLabel.font = .systemFont(ofSize: 16, weight: .medium)
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.numberOfLines = 1

        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.numberOfLines = 3

        enabledSwitch.addTarget(self, action: #selector(enabledChanged), for: .valueChanged)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.primaryText
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)

        for item in [nameLabel, detailLabel, enabledSwitch, moreButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            nameLabel.trailingAnchor.constraint(equalTo: enabledSwitch.leadingAnchor, constant: -10),

            enabledSwitch.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            enabledSwitch.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -8),

            moreButton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            moreButton.widthAnchor.constraint(equalToConstant: 36),
            moreButton.heightAnchor.constraint(equalToConstant: 36),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onEnabledChange = nil
        onMore = nil
    }

    func configure(rule: DictRule) {
        nameLabel.text = rule.name
        let details = [
            rule.enabled ? L10n.Settings.dictRuleEnabled : L10n.Settings.dictRuleDisabled,
            rule.urlRule.isEmpty ? nil : rule.urlRule,
            rule.showRule.isEmpty ? nil : rule.showRule,
        ].compactMap { $0 }
        detailLabel.text = details.joined(separator: "\n")
        enabledSwitch.setOn(rule.enabled, animated: false)
    }

    @objc private func enabledChanged() {
        onEnabledChange?(enabledSwitch.isOn)
    }

    @objc private func handleMore() {
        onMore?()
    }
}

final class AndroidReplicaDictRuleEditorViewController: UIViewController, UITextFieldDelegate {
    struct Payload {
        let name: String
        let urlRule: String
        let showRule: String
    }

    var onSave: ((Payload) -> Void)?

    private let rule: DictRule?
    private let stackView = UIStackView()
    private let nameField = UITextField()
    private let urlField = UITextField()
    private let showField = UITextField()

    init(rule: DictRule?) {
        self.rule = rule
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: 430)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = rule == nil ? L10n.Settings.dictRuleCreateTitle : L10n.Settings.dictRuleEditTitle
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        configureField(nameField, placeholder: L10n.Settings.dictRuleNamePlaceholder, text: rule?.name)
        nameField.isEnabled = rule == nil
        configureField(urlField, placeholder: L10n.Settings.dictRuleUrlPlaceholder, text: rule?.urlRule)
        configureField(showField, placeholder: L10n.Settings.dictRuleShowPlaceholder, text: rule?.showRule)

        let saveButton = makeButton(title: L10n.Common.save, image: "checkmark.circle.fill", foreground: .white, background: AndroidReplicaTheme.accent) { [weak self] in
            self?.submit()
        }
        let cancelButton = makeButton(title: L10n.Common.cancel, image: "chevron.down.circle", foreground: AndroidReplicaTheme.primaryText, background: AndroidReplicaTheme.menuBackground) { [weak self] in
            self?.dismiss(animated: true)
        }

        [nameField, urlField, showField, saveButton, cancelButton].forEach(stackView.addArrangedSubview)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func configureField(_ field: UITextField, placeholder: String, text: String?) {
        field.placeholder = placeholder
        field.text = text
        field.delegate = self
        field.font = .systemFont(ofSize: 15)
        field.textColor = AndroidReplicaTheme.primaryText
        field.tintColor = AndroidReplicaTheme.accent
        field.backgroundColor = AndroidReplicaTheme.menuBackground
        field.layer.cornerRadius = 8
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.clearButtonMode = .whileEditing
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 48).isActive = true
    }

    private func makeButton(title: String, image: String, foreground: UIColor, background: UIColor, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 10
        configuration.baseForegroundColor = foreground
        configuration.baseBackgroundColor = background
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func submit() {
        let payload = Payload(
            name: nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            urlRule: urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            showRule: showField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        dismiss(animated: true) { [onSave] in
            onSave?(payload)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField {
            urlField.becomeFirstResponder()
        } else if textField === urlField {
            showField.becomeFirstResponder()
        } else {
            textField.resignFirstResponder()
            submit()
        }
        return true
    }
}

final class AndroidReplicaDictRuleImportViewController: UIViewController {
    var onImport: ((String) -> Void)?
    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Settings.dictRuleImportTitle
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        textView.backgroundColor = AndroidReplicaTheme.menuBackground
        textView.layer.cornerRadius = 8
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none

        let importButton = makeButton(title: L10n.Common.confirm, image: "square.and.arrow.down", foreground: .white, background: AndroidReplicaTheme.accent) { [weak self] in
            self?.submit()
        }
        let cancelButton = makeButton(title: L10n.Common.cancel, image: "chevron.down.circle", foreground: AndroidReplicaTheme.primaryText, background: AndroidReplicaTheme.menuBackground) { [weak self] in
            self?.dismiss(animated: true)
        }

        let stackView = UIStackView(arrangedSubviews: [textView, importButton, cancelButton])
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 190),
        ])
    }

    private func makeButton(title: String, image: String, foreground: UIColor, background: UIColor, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 10
        configuration.baseForegroundColor = foreground
        configuration.baseBackgroundColor = background
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func submit() {
        let payload = textView.text ?? ""
        dismiss(animated: true) { [onImport] in
            onImport?(payload)
        }
    }
}
