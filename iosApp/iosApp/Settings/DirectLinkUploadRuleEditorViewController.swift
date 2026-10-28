import shared
import UIKit

@MainActor
final class DirectLinkUploadRuleEditorViewController: UITableViewController, NavigationBackActionHandling {
    private let facade: DirectLinkUploadFacade
    private let summaryField = UITextField()
    private let uploadField = UITextView()
    private let downloadField = UITextView()
    private let compressSwitch = UISwitch()
    private var isSaving = false
    var onSaved: ((DirectLinkUploadRule) -> Void)?

    init(facade: DirectLinkUploadFacade, rule: DirectLinkUploadRule?) {
        self.facade = facade
        super.init(style: .insetGrouped)
        summaryField.text = rule?.summary ?? ""
        uploadField.text = rule?.uploadUrl ?? ""
        downloadField.text = rule?.downloadUrlRule ?? ""
        compressSwitch.isOn = rule?.compress ?? false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "直链上传规则"
        tableView.accessibilityIdentifier = "uploadRule.editor"
        tableView.keyboardDismissMode = .interactive
        summaryField.font = .preferredFont(forTextStyle: .body)
        summaryField.clearButtonMode = .whileEditing
        summaryField.accessibilityLabel = "注释"
        summaryField.accessibilityIdentifier = "uploadRule.summary"
        for (field, label, identifier) in [
            (uploadField, "上传地址", "uploadRule.uploadUrl"),
            (downloadField, "下载链接规则", "uploadRule.downloadUrlRule"),
        ] {
            field.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.smartQuotesType = .no
            field.smartDashesType = .no
            field.accessibilityLabel = label
            field.accessibilityIdentifier = identifier
        }
        compressSwitch.accessibilityLabel = "上传前压缩"
        compressSwitch.accessibilityIdentifier = "uploadRule.compress"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "uploadRule.cancel"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "uploadRule.save"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["注释", "上传地址", "下载链接规则", "上传选项"][section]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        if indexPath.section == 3 {
            cell.textLabel?.text = "上传前压缩"
            cell.accessoryView = compressSwitch
            return cell
        }
        let field: UIView = [summaryField, uploadField, downloadField][indexPath.section]
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            field.heightAnchor.constraint(equalToConstant: indexPath.section == 0 ? 36 : 160),
        ])
        return cell
    }

    func interceptNavigationBackGesture() -> Bool { isSaving }

    @objc private func cancel() {
        guard !isSaving else { return }
        navigationController?.popViewController(animated: true)
    }

    @objc private func save() {
        guard !isSaving else { return }
        let rule = DirectLinkUploadRule(
            uploadUrl: uploadField.text ?? "", downloadUrlRule: downloadField.text ?? "",
            summary: summaryField.text ?? "", compress: compressSwitch.isOn)
        isSaving = true
        view.endEditing(true)
        view.isUserInteractionEnabled = false
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task {
            defer {
                isSaving = false
                view.isUserInteractionEnabled = true
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                try await SharedAsync.void { facade.saveRule(rule: rule, completionHandler: $0) }
                onSaved?(rule)
                if navigationController?.topViewController === self {
                    navigationController?.popViewController(animated: true)
                }
            } catch {
                guard isVisibleInNavigationStack, presentedViewController == nil else { return }
                let alert = UIAlertController(title: "保存失败", message: error.userFacingMessage, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                present(alert, animated: true)
            }
        }
    }
}
