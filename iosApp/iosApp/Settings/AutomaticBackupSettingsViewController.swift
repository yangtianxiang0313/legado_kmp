import UIKit
import shared

@MainActor
final class AutomaticBackupSettingsViewController: UITableViewController, UITextFieldDelegate {
    private let coordinator = AutomaticBackupCoordinator.shared
    private let passwordField = UITextField()
    private let confirmationField = UITextField()
    private var rememberOnDevice = false
    private var plan: AutomaticBackupConfiguration?
    private var schedule: AutomaticBackupResult?
    private var passwordMode: AutomaticBackupCoordinator.PasswordMode = .missing
    private var loadError: String?

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "自动备份"
        tableView.accessibilityIdentifier = "settings.automaticBackup"
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        configure(passwordField, placeholder: "备份密码", identifier: "automaticBackup.password", returnKey: .next)
        configure(confirmationField, placeholder: "再次输入备份密码", identifier: "automaticBackup.confirmation", returnKey: .done)
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged), name: AutomaticBackupCoordinator.statusDidChange, object: coordinator)
        reloadConfiguration()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reloadConfiguration()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clearFields()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func numberOfSections(in tableView: UITableView) -> Int { 4 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 6
        case 1: return 2
        case 2: return 2
        default: return 3
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return "当前配置"
        case 1: return "备份密码"
        case 2: return "密码保存方式"
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return "距上次成功超过 24 小时后，在解锁或保存阅读进度时尝试执行；退到后台或应用锁定后暂停，iOS 不保证每日后台运行。"
        case 1:
            return "使用与跨设备恢复相同的备份密码。ZIP 仅保护服务器及 WebDAV 凭据，并非整体加密。"
        case 2:
            return "会话密码在应用锁定或进程结束后清除。本机保存仅存 AES-GCM 密文，设备密钥由 Keychain 保护，不同步到其他设备。"
        default:
            return "启动时优先检查较新的云备份，检查或恢复提示尚未处理时，不会自动上传。"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.selectionStyle = .none
        switch indexPath.section {
        case 0: configureSummary(cell, row: indexPath.row)
        case 1:
            let field = indexPath.row == 0 ? passwordField : confirmationField
            cell.contentView.addSubview(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                field.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                field.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
                field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            ])
        case 2:
            let device = indexPath.row == 1
            cell.textLabel?.text = device ? "加密保存到本机" : "仅本次解锁会话"
            cell.imageView?.image = UIImage(systemName: device ? "lock.iphone" : "lock.open")
            cell.accessoryType = device == rememberOnDevice ? .checkmark : .none
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = device ? "automaticBackup.mode.device" : "automaticBackup.mode.session"
            cell.accessibilityTraits = device == rememberOnDevice ? [.button, .selected] : .button
        default: configureAction(cell, row: indexPath.row)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 {
            rememberOnDevice = indexPath.row == 1
            tableView.reloadSections(IndexSet(integer: 2), with: .none)
        } else if indexPath.section == 3 {
            switch indexPath.row {
            case 0: applyPassword()
            case 1: confirmForget()
            default: coordinator.cancel()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === passwordField { confirmationField.becomeFirstResponder() } else { textField.resignFirstResponder() }
        return true
    }

    private func configure(
        _ field: UITextField, placeholder: String, identifier: String, returnKey: UIReturnKeyType
    ) {
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.isSecureTextEntry = true
        field.textContentType = .newPassword
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = returnKey
        field.delegate = self
    }

    private func configureSummary(_ cell: UITableViewCell, row: Int) {
        switch row {
        case 0:
            cell.textLabel?.text = "本地目录"
            cell.detailTextLabel?.text = plan?.configuredPath ?? (plan?.hasCloudDestination == true ? "应用文件 / Backups" : "未配置")
        case 1:
            cell.textLabel?.text = "云备份"
            cell.detailTextLabel?.text = plan?.hasCloudDestination == true ? "使用已配置的 WebDAV 目标" : "未配置完整目标，不自动选择服务器"
        case 2:
            cell.textLabel?.text = "本地保留策略"
            cell.detailTextLabel?.text = plan?.onlyLatest == true ? "仅最新 backup.zip" : "按日期及设备名保存"
        case 3:
            cell.textLabel?.text = "执行状态"
            cell.detailTextLabel?.text = loadError ?? coordinator.status
            cell.accessibilityIdentifier = "automaticBackup.status"
        case 4:
            cell.textLabel?.text = "上次成功"
            cell.detailTextLabel?.text = date(schedule?.lastSuccessTime ?? 0) ?? "尚无成功记录"
        default:
            cell.textLabel?.text = "密码状态"
            switch passwordMode {
            case .missing: cell.detailTextLabel?.text = "未设置，自动备份不会运行"
            case .session: cell.detailTextLabel?.text = "仅本次解锁会话"
            case .device: cell.detailTextLabel?.text = "已加密保存到本机"
            }
        }
    }

    private func configureAction(_ cell: UITableViewCell, row: Int) {
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
        switch row {
        case 0:
            cell.textLabel?.text = "应用备份密码"
            cell.imageView?.image = UIImage(systemName: "lock.badge.checkmark")
            cell.accessibilityIdentifier = "automaticBackup.password.apply"
            cell.isUserInteractionEnabled = plan?.isConfigured == true
            cell.textLabel?.textColor = plan?.isConfigured == true ? view.tintColor : .tertiaryLabel
        case 1:
            cell.textLabel?.text = "清除当前目标密码"
            cell.imageView?.image = UIImage(systemName: "trash")
            cell.textLabel?.textColor = .systemRed
            cell.accessibilityIdentifier = "automaticBackup.password.forget"
        default:
            cell.textLabel?.text = "取消本次备份"
            cell.imageView?.image = UIImage(systemName: "xmark.circle")
            cell.textLabel?.textColor = coordinator.isRunning ? view.tintColor : .tertiaryLabel
            cell.isUserInteractionEnabled = coordinator.isRunning
            cell.accessibilityIdentifier = "automaticBackup.cancel"
        }
    }

    private func reloadConfiguration() {
        do {
            plan = try coordinator.currentConfiguration()
            schedule = try coordinator.scheduleSnapshot()
            passwordMode = try coordinator.passwordMode()
            rememberOnDevice = passwordMode == .device
            loadError = nil
        } catch {
            plan = nil
            schedule = nil
            loadError = "配置或安全存储暂不可用，请解锁设备后重试"
        }
        tableView.reloadData()
    }

    @objc private func statusChanged() {
        let updated = try? coordinator.currentConfiguration()
        if let plan, updated == nil || !plan.matchesConfiguration(other: updated!) {
            clearFields()
            rememberOnDevice = false
        }
        plan = updated
        schedule = try? coordinator.scheduleSnapshot()
        passwordMode = (try? coordinator.passwordMode()) ?? .missing
        tableView.reloadSections(IndexSet([0, 2, 3]), with: .none)
    }

    private func applyPassword() {
        guard let password = passwordField.text, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            password == confirmationField.text
        else { showError("请输入相同的非空备份密码"); return }
        do {
            try coordinator.authorizePassword(password, rememberOnDevice: rememberOnDevice)
            clearFields()
            view.endEditing(true)
            reloadConfiguration()
        } catch {
            showError((error as NSError).localizedDescription)
        }
    }

    private func confirmForget() {
        let prompt = UIAlertController(title: "清除当前目标密码？", message: "不会删除已有备份或 WebDAV 配置。", preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        prompt.addAction(
            UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
                guard let self else { return }
                do { try coordinator.forgetPassword(); clearFields(); reloadConfiguration() } catch { showError("清除失败，请解锁设备后重试") }
            })
        present(prompt, animated: true)
    }

    private func clearFields() { passwordField.text = nil; confirmationField.text = nil }

    private func showError(_ message: String) {
        let prompt = UIAlertController(title: "自动备份", message: message, preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
        present(prompt, animated: true)
    }

    private func date(_ milliseconds: Int64) -> String? {
        guard milliseconds > 0 else { return nil }
        return DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1000), dateStyle: .medium, timeStyle: .short)
    }
}
