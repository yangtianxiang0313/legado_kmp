import UIKit

@MainActor
final class ExternalReaderConfigImportPreviewViewController: UITableViewController {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClosed: (() -> Void)?
    private let document: ExternalReaderConfigImportDocument
    private let status = UILabel()
    private let footer = UIView()
    private lazy var confirm = UIBarButtonItem(title: "确认导入", style: .done, target: self, action: #selector(confirmImport))
    private lazy var close = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelImport))

    init(document: ExternalReaderConfigImportDocument) {
        self.document = document
        super.init(style: .plain)
        title = "导入阅读配置"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "externalReaderConfigImport.preview"
        tableView.accessibilityIdentifier = "externalReaderConfigImport.list"
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        navigationItem.leftBarButtonItem = close
        navigationItem.rightBarButtonItem = confirm
        confirm.accessibilityIdentifier = "externalReaderConfigImport.confirm"
        close.accessibilityIdentifier = "externalReaderConfigImport.cancel"
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = AndroidReplicaTheme.secondaryText
        status.accessibilityIdentifier = "externalReaderConfigImport.status"
        status.text = "同名配置将被替换。"
        footer.addSubview(status)
        tableView.tableFooterView = footer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = max(1, tableView.bounds.width - 32)
        let height = status.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height + 24
        if abs(footer.frame.height - height) > 0.5 || footer.frame.width != tableView.bounds.width {
            status.frame = CGRect(x: 16, y: 0, width: width, height: height)
            footer.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: height)
            tableView.tableFooterView = footer
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true
            || navigationController?.presentingViewController == nil
        {
            onClosed?()
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { document.resources.count + 1 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "config")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "config")
        let row = indexPath.row
        cell.textLabel?.text = row == 0 ? (document.name.isEmpty ? "未命名配置" : document.name) : document.resources[row - 1].title
        cell.detailTextLabel?.text = row == 0 ? "阅读配置名称" : document.resources[row - 1].detail
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "externalReaderConfigImport.row.\(row)"
        return cell
    }

    func setBusy(_ busy: Bool) {
        confirm.isEnabled = !busy
        navigationController?.isModalInPresentation = busy
        status.text = busy ? "正在导入阅读配置" : "同名配置将被替换。"
        view.setNeedsLayout()
    }

    func showFailure(_ error: Error) {
        setBusy(false)
        status.text = error.userFacingMessage
        view.setNeedsLayout()
    }

    @objc private func confirmImport() { onConfirm?() }
    @objc private func cancelImport() { onCancel?() }
}
