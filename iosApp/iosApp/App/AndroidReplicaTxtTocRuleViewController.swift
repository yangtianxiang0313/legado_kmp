import shared
import UIKit

class AndroidReplicaTxtTocRuleViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let screen = SettingsScreenAdapter()
    private lazy var topBar = AndroidReplicaDetailBar(title: L10n.Settings.txtTocRuleTitle, target: self, backAction: #selector(handleBack))
    private let addButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyView = AndroidReplicaTxtTocRuleEmptyView()
    private var rules: [TxtTocRule] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        navigationController?.setNavigationBarHidden(true, animated: false)
        configureViews()
        bootstrap()
    }

    deinit {
        screen.unbind()
    }

    private func configureViews() {
        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.accessibilityLabel = L10n.Settings.txtTocRuleAddAction
        addButton.addTarget(self, action: #selector(handleAddRule), for: .touchUpInside)
        topBar.addAction(addButton)

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AndroidReplicaTxtTocRuleCell.self, forCellReuseIdentifier: AndroidReplicaTxtTocRuleCell.reuseIdentifier)
        tableView.accessibilityIdentifier = UIIdentifiers.Settings.txtTocRuleTable

        emptyView.isHidden = true
        emptyView.onAdd = { [weak self] in
            self?.presentEditor(rule: nil)
        }

        for item in [topBar, tableView, emptyView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyView.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: tableView.leadingAnchor, constant: 28),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: tableView.trailingAnchor, constant: -28),
        ])
    }

    private func bootstrap() {
        emptyView.showLoading()
        screen.onTxtTocRulesChange = { [weak self] rules in
            self?.applyRules(rules)
        }
        switch screen.bootstrap() {
        case .success:
            Task { [weak self] in
                guard let self else { return }
                do {
                    let rules = try await self.screen.loadTxtTocRules()
                    await MainActor.run {
                        self.applyRules(rules)
                    }
                } catch {
                    await MainActor.run {
                        self.emptyView.showError(error.userFacingMessage) { [weak self] in
                            self?.bootstrap()
                        }
                    }
                }
            }
        case let .failure(error):
            emptyView.showError(error.message) { [weak self] in
                self?.bootstrap()
            }
        }
    }

    private func applyRules(_ rules: [TxtTocRule]) {
        self.rules = rules.sorted { lhs, rhs in
            if lhs.serialNumber == rhs.serialNumber {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.serialNumber < rhs.serialNumber
        }
        tableView.reloadData()
        emptyView.showEmpty(isEmpty: self.rules.isEmpty) { [weak self] in
            self?.presentEditor(rule: nil)
        }
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func handleAddRule() {
        presentEditor(rule: nil)
    }

    private func presentEditor(rule: TxtTocRule?) {
        let controller = AndroidReplicaTxtTocRuleEditorViewController(rule: rule)
        controller.onSave = { [weak self] draft in
            self?.save(rule: draft)
        }
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: 430),
            animated: true
        )
    }

    private func save(rule: TxtTocRule) {
        Task { [weak self] in
            do {
                _ = try await self?.screen.saveTxtTocRule(rule)
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func setEnabled(rule: TxtTocRule, enabled: Bool) {
        Task { [weak self] in
            do {
                _ = try await self?.screen.setTxtTocRuleEnabled(id: rule.id, enabled: enabled)
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func presentActions(for rule: TxtTocRule) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: rule.name,
            options: [
                .init(title: L10n.Settings.txtTocRuleEditTitle, systemImage: "pencil", isSelected: false) { [weak self] in
                    self?.presentEditor(rule: rule)
                },
                .init(
                    title: rule.enable ? L10n.Settings.txtTocRuleDisabled : L10n.Settings.txtTocRuleEnabled,
                    systemImage: rule.enable ? "pause.circle" : "play.circle",
                    isSelected: false
                ) { [weak self] in
                    self?.setEnabled(rule: rule, enabled: !rule.enable)
                },
                .init(title: L10n.Bookshelf.deleteAction, systemImage: "trash", isSelected: false, isDestructive: true) { [weak self] in
                    self?.presentDeleteConfirmation(for: rule)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 4)),
            animated: true
        )
    }

    private func presentDeleteConfirmation(for rule: TxtTocRule) {
        let controller = AndroidReplicaTxtTocRuleDeleteConfirmViewController(ruleName: rule.name)
        controller.onDelete = { [weak self] in
            self?.delete(rule: rule)
        }
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: 260),
            animated: true
        )
    }

    private func delete(rule: TxtTocRule) {
        Task { [weak self] in
            do {
                try await self?.screen.deleteTxtTocRule(id: rule.id)
            } catch {
                await MainActor.run {
                    self?.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        rules.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AndroidReplicaTxtTocRuleCell.reuseIdentifier, for: indexPath) as! AndroidReplicaTxtTocRuleCell
        let rule = rules[indexPath.row]
        cell.configure(rule: rule)
        cell.onEnabledChange = { [weak self] enabled in
            self?.setEnabled(rule: rule, enabled: enabled)
        }
        cell.onMore = { [weak self] in
            self?.presentActions(for: rule)
        }
        cell.accessibilityIdentifier = UIIdentifiers.Settings.txtTocRuleCell
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        presentActions(for: rules[indexPath.row])
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

private final class AndroidReplicaTxtTocRuleCell: UITableViewCell {
    static let reuseIdentifier = "androidReplica.txtTocRule.cell"
    var onEnabledChange: ((Bool) -> Void)?
    var onMore: (() -> Void)?

    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let patternLabel = UILabel()
    private let exampleLabel = UILabel()
    private let enabledSwitch = UISwitch()
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
        onEnabledChange = nil
        onMore = nil
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none

        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.numberOfLines = 1

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = AndroidReplicaTheme.accent

        patternLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        patternLabel.textColor = AndroidReplicaTheme.secondaryText
        patternLabel.numberOfLines = 2

        exampleLabel.font = .systemFont(ofSize: 13)
        exampleLabel.textColor = AndroidReplicaTheme.secondaryText
        exampleLabel.numberOfLines = 1

        enabledSwitch.onTintColor = AndroidReplicaTheme.accent
        enabledSwitch.addTarget(self, action: #selector(enabledChanged), for: .valueChanged)

        moreButton.setImage(UIImage(systemName: "ellipsis.vertical"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.secondaryText
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, statusLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        let textStack = UIStackView(arrangedSubviews: [titleRow, patternLabel, exampleLabel])
        textStack.axis = .vertical
        textStack.spacing = 5

        let actionStack = UIStackView(arrangedSubviews: [enabledSwitch, moreButton])
        actionStack.axis = .horizontal
        actionStack.alignment = .center
        actionStack.spacing = 8

        let row = UIStackView(arrangedSubviews: [textStack, actionStack])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 14

        for item in [row] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        moreButton.widthAnchor.constraint(equalToConstant: 38).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 38).isActive = true
        actionStack.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 13),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -13),
        ])
    }

    func configure(rule: TxtTocRule) {
        nameLabel.text = rule.name
        statusLabel.text = rule.enable ? L10n.Settings.txtTocRuleEnabled : L10n.Settings.txtTocRuleDisabled
        statusLabel.textColor = rule.enable ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        patternLabel.text = rule.rule
        if let example = rule.example, example.isEmpty == false {
            exampleLabel.isHidden = false
            exampleLabel.text = "\(L10n.Settings.txtTocRuleExampleTitle): \(example)"
        } else {
            exampleLabel.isHidden = true
            exampleLabel.text = nil
        }
        enabledSwitch.setOn(rule.enable, animated: false)
    }

    @objc private func enabledChanged() {
        onEnabledChange?(enabledSwitch.isOn)
    }

    @objc private func moreTapped() {
        onMore?()
    }
}

private final class AndroidReplicaTxtTocRuleEmptyView: UIView {
    var onAdd: (() -> Void)?

    private let iconView = UIImageView(image: UIImage(systemName: "list.bullet.rectangle.portrait"))
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        iconView.tintColor = AndroidReplicaTheme.secondaryText
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.title = L10n.Settings.txtTocRuleAddAction
        configuration.image = UIImage(systemName: "plus")
        configuration.imagePadding = 8
        configuration.baseBackgroundColor = AndroidReplicaTheme.menuBackground
        configuration.baseForegroundColor = AndroidReplicaTheme.primaryText
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 18, bottom: 11, trailing: 18)
        actionButton.configuration = configuration
        actionButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func showLoading() {
        isHidden = false
        titleLabel.text = L10n.Settings.loading
        messageLabel.text = nil
        actionButton.isHidden = true
    }

    func showEmpty(isEmpty: Bool, add: @escaping () -> Void) {
        isHidden = isEmpty == false
        onAdd = add
        titleLabel.text = L10n.Settings.txtTocRuleListEmptyTitle
        messageLabel.text = L10n.Settings.txtTocRuleListEmptyDetail
        actionButton.isHidden = false
        var configuration = actionButton.configuration
        configuration?.title = L10n.Settings.txtTocRuleAddAction
        configuration?.image = UIImage(systemName: "plus")
        actionButton.configuration = configuration
    }

    func showError(_ message: String, retry: @escaping () -> Void) {
        isHidden = false
        titleLabel.text = L10n.Settings.failed
        messageLabel.text = message
        actionButton.isHidden = false
        onAdd = retry
        var configuration = actionButton.configuration
        configuration?.title = L10n.Common.retry
        configuration?.image = UIImage(systemName: "arrow.clockwise")
        actionButton.configuration = configuration
    }

    @objc private func addTapped() {
        onAdd?()
    }
}

private final class AndroidReplicaTxtTocRuleEditorViewController: UIViewController, UITextFieldDelegate {
    var onSave: ((TxtTocRule) -> Void)?

    private let rule: TxtTocRule?
    private let nameField = AndroidReplicaTxtTocRuleField(title: L10n.Settings.txtTocRuleNameTitle)
    private let patternField = AndroidReplicaTxtTocRuleField(title: L10n.Settings.txtTocRulePatternTitle)
    private let exampleField = AndroidReplicaTxtTocRuleField(title: L10n.Settings.txtTocRuleExampleTitle)
    private let errorLabel = UILabel()

    init(rule: TxtTocRule?) {
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
        title = rule == nil ? L10n.Settings.txtTocRuleCreateTitle : L10n.Settings.txtTocRuleEditTitle
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        fillRule()
    }

    private func configureViews() {
        patternField.textField.autocorrectionType = .no
        patternField.textField.autocapitalizationType = .none
        nameField.textField.placeholder = L10n.Settings.txtTocRuleNamePlaceholder
        patternField.textField.placeholder = L10n.Settings.txtTocRulePatternPlaceholder
        exampleField.textField.placeholder = L10n.Settings.txtTocRuleExamplePlaceholder

        errorLabel.font = .systemFont(ofSize: 13)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true

        var saveConfiguration = UIButton.Configuration.filled()
        saveConfiguration.title = L10n.Common.save
        saveConfiguration.image = UIImage(systemName: "checkmark")
        saveConfiguration.imagePadding = 8
        saveConfiguration.baseBackgroundColor = AndroidReplicaTheme.accent
        saveConfiguration.baseForegroundColor = .white
        saveConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
        let saveButton = UIButton(configuration: saveConfiguration)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [nameField, patternField, exampleField, errorLabel, saveButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func fillRule() {
        nameField.textField.text = rule?.name
        patternField.textField.text = rule?.rule
        exampleField.textField.text = rule?.example
    }

    @objc private func saveTapped() {
        let name = nameField.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pattern = patternField.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let example = exampleField.textField.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.isEmpty == false, pattern.isEmpty == false else {
            errorLabel.text = L10n.Settings.txtTocRuleValidationMessage
            errorLabel.isHidden = false
            return
        }
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            let draft = TxtTocRule(
                id: self.rule?.id ?? Int64(Date().timeIntervalSince1970 * 1000),
                name: name,
                rule: pattern,
                example: example?.isEmpty == true ? nil : example,
                serialNumber: self.rule?.serialNumber ?? -1,
                enable: self.rule?.enable ?? true
            )
            self.onSave?(draft)
        }
    }
}

private final class AndroidReplicaTxtTocRuleDeleteConfirmViewController: UIViewController {
    var onDelete: (() -> Void)?

    private let ruleName: String

    init(ruleName: String) {
        self.ruleName = ruleName
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: 260)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Settings.txtTocRuleDeleteTitle
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        let titleLabel = UILabel()
        titleLabel.text = ruleName
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 2

        let messageLabel = UILabel()
        messageLabel.text = L10n.Settings.txtTocRuleDeleteMessage
        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.numberOfLines = 0

        let deleteButton = makeButton(
            title: L10n.Bookshelf.deleteAction,
            imageName: "trash",
            foregroundColor: .white,
            backgroundColor: .systemRed
        )
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)

        let cancelButton = makeButton(
            title: L10n.Common.cancel,
            imageName: "chevron.down.circle",
            foregroundColor: AndroidReplicaTheme.primaryText,
            backgroundColor: AndroidReplicaTheme.menuBackground
        )
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, deleteButton, cancelButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func makeButton(title: String, imageName: String, foregroundColor: UIColor, backgroundColor: UIColor) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePadding = 10
        configuration.baseForegroundColor = foregroundColor
        configuration.baseBackgroundColor = backgroundColor
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        return button
    }

    @objc private func deleteTapped() {
        dismiss(animated: true) { [weak self] in
            self?.onDelete?()
        }
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }
}

private final class AndroidReplicaTxtTocRuleField: UIView {
    let textField = UITextField()
    private let titleLabel = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AndroidReplicaTheme.secondaryText

        textField.font = .systemFont(ofSize: 15)
        textField.textColor = AndroidReplicaTheme.primaryText
        textField.backgroundColor = AndroidReplicaTheme.menuBackground
        textField.layer.cornerRadius = 8
        textField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        textField.leftViewMode = .always
        textField.clearButtonMode = .whileEditing

        let stack = UIStackView(arrangedSubviews: [titleLabel, textField])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            textField.heightAnchor.constraint(equalToConstant: 44),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
