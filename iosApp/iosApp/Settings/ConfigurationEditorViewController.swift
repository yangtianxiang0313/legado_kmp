import UIKit
import shared

@MainActor
final class ConfigurationEditorViewController: UITableViewController {
    var onSave: ((ConfigurationManagementRecord) -> Void)?
    private let facade: BackupCapabilitiesFacade
    private var draft: ConfigurationEditorDraft
    private var saveTask: Task<Void, Never>?
    private var operationID = UUID()
    private var isVisible = false
    private var isSaving = false
    private var didSave = false
    private var pendingSave: ConfigurationManagementRecord?
    private var pendingError: String?

    init(
        category: ConfigurationManagementCategory, record: ConfigurationManagementRecord?, nextOrder: Int32,
        facade: BackupCapabilitiesFacade
    ) {
        self.facade = facade
        draft = ConfigurationEditorDraft(category: category, original: record, nextOrder: nextOrder)
        super.init(style: .insetGrouped)
        title = (record == nil ? "新增" : "编辑") + category.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "configuration.\(draft.category.rawValue).editor"
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 90
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(save))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "configuration.editor.cancel"
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "configuration.editor.save"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        setSaving(isSaving)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingSave != nil {
            deliverSavedRecord()
        } else if let message = pendingError {
            pendingError = nil
            showError(message)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            operationID = UUID()
            saveTask?.cancel()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { draft.sections.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        draft.sections[section].title
    }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        draft.sections[section].footer
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        draft.sections[section].fields.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let definition = draft.sections[indexPath.section].fields[indexPath.row]
        let identifier = "configuration.\(draft.category.rawValue).field.\(definition.key)"
        switch definition.kind {
        case .toggle:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            cell.textLabel?.text = definition.title
            cell.textLabel?.numberOfLines = 0
            let toggle = UISwitch()
            toggle.isOn = draft.switches[definition.key] ?? false
            toggle.accessibilityLabel = definition.title
            toggle.accessibilityIdentifier = identifier
            toggle.addAction(
                UIAction { [weak self, weak toggle] _ in
                    guard let self, !self.isSaving, let toggle else { return }
                    self.draft.switches[definition.key] = toggle.isOn
                }, for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case let .options(options):
            let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
            cell.textLabel?.text = definition.title
            cell.textLabel?.numberOfLines = 0
            let button = UIButton(type: .system)
            let selected = draft.value(definition.key)
            button.setTitle(options.first(where: { $0.0 == selected })?.1 ?? options.first?.1, for: .normal)
            button.accessibilityLabel = definition.title
            button.accessibilityIdentifier = identifier
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(
                children: options.map { value, title in
                    UIAction(title: title, state: value == selected ? .on : .off) { [weak self] _ in
                        guard let self, !self.isSaving else { return }
                        self.draft.text[definition.key] = value
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    }
                })
            button.sizeToFit()
            cell.accessoryView = button
            cell.selectionStyle = .none
            return cell
        default:
            let cell = ConfigurationEditorFieldCell(
                definition: definition, value: draft.value(definition.key), identifier: identifier)
            cell.onChange = { [weak self] value in
                guard let self, !self.isSaving else { return }
                self.draft.text[definition.key] = value
            }
            return cell
        }
    }

    @objc private func cancel() {
        guard !isSaving else { return }
        view.endEditing(true)
        operationID = UUID()
        dismiss(animated: true)
    }

    @objc private func save() {
        guard isVisible, !isSaving, !didSave, saveTask == nil else { return }
        view.endEditing(true)
        let record: ConfigurationManagementRecord
        do { record = try draft.makeRecord() } catch let error as ConfigurationEditorError {
            showError(error.message, field: error.field)
            return
        } catch {
            showError("配置无法保存，请检查字段后重试")
            return
        }
        let token = UUID()
        operationID = token
        setSaving(true)
        let facade = facade
        let original = draft.original
        saveTask = Task { [weak self] in
            do {
                let saved = try await record.save(using: facade, original: original)
                try Task.checkCancellation()
                guard let self, self.operationID == token else { return }
                self.saveTask = nil
                self.isSaving = false
                self.didSave = true
                self.pendingSave = saved
                if self.isVisible { self.deliverSavedRecord() }
            } catch {
                guard let self, self.operationID == token else { return }
                self.saveTask = nil
                self.isSaving = false
                let message = error is CancellationError ? "保存已取消，可重试" : "保存失败，请检查必填项、重复记录和配置后重试"
                if self.isVisible {
                    self.setSaving(false)
                    self.showError(message)
                } else {
                    self.pendingError = message
                }
            }
        }
    }

    private func deliverSavedRecord() {
        guard isVisible, let saved = pendingSave else { return }
        pendingSave = nil
        setSaving(false)
        onSave?(saved)
        dismiss(animated: true)
    }

    private func setSaving(_ saving: Bool) {
        isSaving = saving
        navigationController?.isModalInPresentation = saving
        isModalInPresentation = saving
        navigationItem.leftBarButtonItem?.isEnabled = !saving && !didSave
        navigationItem.rightBarButtonItem?.isEnabled = !saving && !didSave
        tableView.isUserInteractionEnabled = !saving && !didSave
    }

    private func showError(_ message: String, field: String? = nil) {
        guard isVisible, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "未保存", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "configuration.editor.error"
        alert.addAction(
            UIAlertAction(title: "确定", style: .default) { [weak self] _ in
                guard let self, let field, self.isVisible else { return }
                for (section, group) in self.draft.sections.enumerated() {
                    if let row = group.fields.firstIndex(where: { $0.key == field }) {
                        let path = IndexPath(row: row, section: section)
                        self.tableView.scrollToRow(at: path, at: .middle, animated: false)
                        self.tableView.layoutIfNeeded()
                        (self.tableView.cellForRow(at: path) as? ConfigurationEditorFieldCell)?.focus()
                        break
                    }
                }
            })
        present(alert, animated: true)
    }
}
