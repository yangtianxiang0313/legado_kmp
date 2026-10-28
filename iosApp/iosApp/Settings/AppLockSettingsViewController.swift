import UIKit

@MainActor
final class AppLockSettingsViewController: UITableViewController {
    private let manager = AppLockManager.shared

    init() {
        super.init(style: .insetGrouped)
        title = "应用锁"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "app-lock.settings"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged), name: .appLockStatusDidChange, object: manager)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        tableView.reloadData()
        manager.refreshStatus()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return 1 }
        return manager.status == .enabled ? 2 : 1
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        switch manager.status {
        case .enabled: return "应用密码与备份密码相互独立。离开前台后，再次进入需解锁。"
        case .disabled: return "应用密码仅保存在本机，不随书籍备份导出。请妥善保管，无法通过备份找回。"
        case .checking: return nil
        case .unavailable: return "无法访问安全凭据，应用锁不会被自动关闭。请解锁设备后重试。"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        if indexPath.section == 0 {
            cell.textLabel?.text = "应用锁"
            switch manager.status {
            case .checking: cell.detailTextLabel?.text = "读取中"
            case .disabled: cell.detailTextLabel?.text = "未设置"
            case .enabled: cell.detailTextLabel?.text = "已设置"
            case .unavailable: cell.detailTextLabel?.text = "暂不可用"
            }
            cell.selectionStyle = .none
            cell.accessibilityIdentifier = "app-lock.settings.status"
        } else {
            switch manager.status {
            case .enabled:
                let disabling = indexPath.row == 1
                cell.textLabel?.text = disabling ? "关闭应用锁" : "修改密码"
                cell.textLabel?.textColor = disabling ? .systemRed : .label
                cell.accessibilityIdentifier = disabling ? "app-lock.settings.disable" : "app-lock.settings.change"
                cell.accessoryType = .disclosureIndicator
            case .disabled:
                cell.textLabel?.text = "设置密码"
                cell.accessibilityIdentifier = "app-lock.settings.enable"
                cell.accessoryType = .disclosureIndicator
            case .checking, .unavailable:
                cell.textLabel?.text = "重新读取凭据"
                cell.accessibilityIdentifier = "app-lock.settings.retry"
            }
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, canPerformNavigationAction else { return }
        let mode: AppLockPasswordViewController.Mode
        switch manager.status {
        case .enabled: mode = indexPath.row == 1 ? .disable : .change
        case .disabled: mode = .enable
        case .checking, .unavailable: manager.refreshStatus(); return
        }
        navigationController?.pushViewController(AppLockPasswordViewController(mode: mode), animated: true)
    }

    @objc private func statusChanged() { tableView.reloadData() }
}
