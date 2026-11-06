import UIKit
import shared

@MainActor
final class AutomaticBackupSettingsViewController: UITableViewController, UITextFieldDelegate {
    private final class AttachmentProbe: UIView {
        var onWindowChanged: (() -> Void)?
        private var wasAttached = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { wasAttached = true }
            if wasAttached { onWindowChanged?() }
        }
    }

    private let coordinator = AutomaticBackupCoordinator.shared
    private let passwordField = UITextField()
    private let confirmationField = UITextField()
    private var rememberOnDevice = false
    private var plan: AutomaticBackupConfiguration?
    private var schedule: AutomaticBackupResult?
    private var passwordMode: AutomaticBackupCoordinator.PasswordMode = .missing
    private var loadError: String?
    private weak var ownedWindow: UIWindow?
    private weak var ownedScene: UIWindowScene?
    private weak var ownedRoot: UIViewController?
    private weak var ownedNavigation: UINavigationController?
    private weak var ownedTop: UIViewController?
    private var visible = false
    private var viewGeneration: UUID?
    private var attachmentProbe: AttachmentProbe?
    private var monitor: Task<Void, Never>?
    private var forgetID: UUID?
    private var forgetPrompt: UIAlertController?
    private var forgetProbe: AttachmentProbe?
    private weak var forgetPresenter: UIViewController?
    private var forgetConsuming = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("backup.automatic.title", value: "自动备份", comment: "Automatic backup settings title")
        tableView.accessibilityIdentifier = "settings.automaticBackup"
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        configure(
            passwordField,
            placeholder: NSLocalizedString("backup.local.password.title", value: "备份密码", comment: "Backup password title"),
            identifier: "automaticBackup.password", returnKey: .next)
        configure(
            confirmationField,
            placeholder: NSLocalizedString("backup.local.password.repeat", value: "再次输入密码", comment: "Repeat backup password"),
            identifier: "automaticBackup.confirmation", returnKey: .done)
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusChanged), name: AutomaticBackupCoordinator.statusDidChange, object: coordinator)
        NotificationCenter.default.addObserver(
            self, selector: #selector(lockChanged), name: .appLockStatusDidChange, object: AppLockManager.shared)
        reloadConfiguration()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        reloadConfiguration()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginOwnership()
    }

    override func viewWillDisappear(_ animated: Bool) {
        visible = false
        invalidatePage()
        monitor?.cancel()
        monitor = nil
        super.viewWillDisappear(animated)
    }

    deinit {
        monitor?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

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
        case 0: return NSLocalizedString("backup.automatic.configuration", value: "当前配置", comment: "Current backup configuration")
        case 1: return NSLocalizedString("backup.local.password.title", value: "备份密码", comment: "Backup password title")
        case 2: return NSLocalizedString("backup.automatic.storage", value: "密码保存方式", comment: "Password storage section")
        default: return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            return NSLocalizedString(
                "backup.automatic.schedule.footer",
                value: "距上次成功超过 24 小时后，在解锁或保存阅读进度时尝试；后台仅使用 iOS 提供的有限执行时间，锁定后暂停，不保证每日后台运行。",
                comment: "Automatic backup scheduling limitations")
        case 1:
            return NSLocalizedString(
                "backup.automatic.password.footer", value: "使用与跨设备恢复相同的备份密码。ZIP 仅保护服务器及 WebDAV 凭据，并非整体加密。",
                comment: "Automatic backup password purpose")
        case 2:
            return NSLocalizedString(
                "backup.automatic.storage.footer",
                value: "会话密码在应用锁定或进程结束后清除。本机保存仅存 AES-GCM 密文，设备密钥由 Keychain 保护，不同步到其他设备。",
                comment: "Password storage protection")
        default:
            return NSLocalizedString(
                "backup.automatic.startup.footer", value: "启动时优先检查较新的云备份，检查或恢复提示尚未处理时，不会自动上传。",
                comment: "Startup restore takes priority")
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
            cell.textLabel?.text =
                device
                ? NSLocalizedString("backup.automatic.storage.device", value: "加密保存到本机", comment: "Store password on device")
                : NSLocalizedString("backup.automatic.storage.session", value: "仅本次解锁会话", comment: "Keep password for unlocked session")
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
        guard readyForAction() else { return }
        if indexPath.section == 2 {
            guard matchesDisplayedConfiguration() else { return }
            rememberOnDevice = indexPath.row == 1
            tableView.reloadSections(IndexSet(integer: 2), with: .none)
        } else if indexPath.section == 3 {
            switch indexPath.row {
            case 0: applyPassword()
            case 1: confirmForget()
            default:
                guard coordinator.isRunning else { return }
                coordinator.cancel()
            }
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard readyForAction(), matchesDisplayedConfiguration() else {
            clearFields()
            return false
        }
        if textField === passwordField { confirmationField.becomeFirstResponder() } else { textField.resignFirstResponder() }
        return true
    }

    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        readyForAction() && matchesDisplayedConfiguration()
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
        field.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                if !self.readyForAction() || !self.matchesDisplayedConfiguration() { self.clearFields() }
            }, for: .editingChanged)
    }

    private func configureSummary(_ cell: UITableViewCell, row: Int) {
        switch row {
        case 0:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.local_path", value: "本地目录", comment: "Local backup directory")
            cell.detailTextLabel?.text =
                plan?.configuredPath
                ?? (plan?.hasCloudDestination == true
                    ? NSLocalizedString("backup.automatic.local_path.default", value: "应用文件 / Backups", comment: "Default backup directory")
                    : NSLocalizedString("backup.automatic.not_configured", value: "未配置", comment: "Backup destination not configured"))
        case 1:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.cloud", value: "云备份", comment: "Cloud backup destination")
            cell.detailTextLabel?.text =
                plan?.hasCloudDestination == true
                ? NSLocalizedString("backup.automatic.cloud.configured", value: "使用已配置的 WebDAV 目标", comment: "Configured cloud destination")
                : NSLocalizedString("backup.automatic.cloud.missing", value: "未配置完整目标，不自动选择服务器", comment: "Missing cloud destination")
        case 2:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.retention", value: "本地保留策略", comment: "Local retention policy")
            cell.detailTextLabel?.text =
                plan?.onlyLatest == true
                ? NSLocalizedString("backup.automatic.retention.latest", value: "仅最新 backup.zip", comment: "Keep only latest backup")
                : NSLocalizedString("backup.automatic.retention.dated", value: "按日期及设备名保存", comment: "Keep dated device backups")
        case 3:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.status", value: "执行状态", comment: "Automatic backup status")
            cell.detailTextLabel?.text = loadError ?? coordinator.status
            cell.accessibilityIdentifier = "automaticBackup.status"
        case 4:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.last_success", value: "上次成功", comment: "Last successful backup")
            cell.detailTextLabel?.text =
                date(schedule?.lastSuccessTime ?? 0)
                ?? NSLocalizedString("backup.automatic.last_success.none", value: "尚无成功记录", comment: "No successful backup yet")
        default:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.password.status", value: "密码状态", comment: "Backup password status")
            switch passwordMode {
            case .missing:
                cell.detailTextLabel?.text = NSLocalizedString(
                    "backup.automatic.password.missing", value: "未设置，自动备份不会运行", comment: "Missing automatic backup password")
            case .session:
                cell.detailTextLabel?.text = NSLocalizedString(
                    "backup.automatic.storage.session", value: "仅本次解锁会话", comment: "Keep password for unlocked session")
            case .device:
                cell.detailTextLabel?.text = NSLocalizedString(
                    "backup.automatic.password.saved", value: "已加密保存到本机", comment: "Password encrypted on device")
            }
        }
    }

    private func configureAction(_ cell: UITableViewCell, row: Int) {
        cell.selectionStyle = .default
        cell.accessibilityTraits = .button
        switch row {
        case 0:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.password.apply", value: "应用备份密码", comment: "Apply backup password")
            cell.imageView?.image = UIImage(systemName: "lock.badge.checkmark")
            cell.accessibilityIdentifier = "automaticBackup.password.apply"
            cell.isUserInteractionEnabled = plan?.isConfigured == true
            cell.textLabel?.textColor = plan?.isConfigured == true ? view.tintColor : .tertiaryLabel
        case 1:
            cell.textLabel?.text = NSLocalizedString(
                "backup.automatic.password.forget", value: "清除当前目标密码", comment: "Forget current target password")
            cell.imageView?.image = UIImage(systemName: "trash")
            cell.textLabel?.textColor = .systemRed
            cell.accessibilityIdentifier = "automaticBackup.password.forget"
        default:
            cell.textLabel?.text = NSLocalizedString("backup.automatic.cancel", value: "取消本次备份", comment: "Cancel current automatic backup")
            cell.imageView?.image = UIImage(systemName: "xmark.circle")
            cell.textLabel?.textColor = coordinator.isRunning ? view.tintColor : .tertiaryLabel
            cell.isUserInteractionEnabled = coordinator.isRunning
            cell.accessibilityIdentifier = "automaticBackup.cancel"
        }
    }

    private func reloadConfiguration() {
        do {
            updatePlan(try coordinator.currentConfiguration())
            schedule = try coordinator.scheduleSnapshot()
            passwordMode = try coordinator.passwordMode()
            rememberOnDevice = passwordMode == .device
            loadError = nil
        } catch {
            updatePlan(nil)
            schedule = nil
            passwordMode = .missing
            rememberOnDevice = false
            loadError = NSLocalizedString(
                "backup.automatic.configuration.unavailable", value: "配置或安全存储暂不可用，请解锁设备后重试",
                comment: "Backup configuration or secure storage unavailable")
        }
        tableView.reloadData()
    }

    @objc private func statusChanged() {
        updatePlan(try? coordinator.currentConfiguration())
        schedule = try? coordinator.scheduleSnapshot()
        passwordMode = (try? coordinator.passwordMode()) ?? .missing
        if plan != nil { loadError = nil }
        tableView.reloadSections(IndexSet([0, 2, 3]), with: .none)
    }

    private func applyPassword() {
        guard readyForAction(), let target = plan, target.isConfigured, matchesDisplayedConfiguration(target) else { return }
        let password = passwordField.text ?? ""
        let repeated = confirmationField.text
        clearFields()
        guard !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, password == repeated else {
            showError(
                NSLocalizedString(
                    "backup.automatic.password.invalid", value: "请输入相同的非空备份密码", comment: "Backup password validation failed"))
            return
        }
        guard readyForAction(), matchesDisplayedConfiguration(target) else { return }
        do {
            try coordinator.authorizePassword(password, rememberOnDevice: rememberOnDevice, configuration: target)
            reloadConfiguration()
        } catch {
            showError(
                NSLocalizedString(
                    "backup.automatic.password.apply_failed", value: "密码未应用，请解锁设备并检查备份配置后重试",
                    comment: "Backup password authorization failed without sensitive details"))
        }
    }

    private func confirmForget() {
        guard readyForAction(), let generation = viewGeneration, let target = plan,
            matchesDisplayedConfiguration(target), forgetID == nil
        else { return }
        clearFields()
        let id = UUID()
        let prompt = UIAlertController(
            title: NSLocalizedString("backup.automatic.password.forget.title", value: "清除当前目标密码？", comment: "Forget backup password title"),
            message: NSLocalizedString(
                "backup.automatic.password.forget.message", value: "不会删除已有备份或 WebDAV 配置。", comment: "Forget password explanation"),
            preferredStyle: .alert)
        forgetID = id
        forgetPrompt = prompt
        forgetConsuming = false
        let probe = AttachmentProbe(frame: .zero)
        probe.isHidden = true
        probe.isUserInteractionEnabled = false
        probe.onWindowChanged = { [weak self, weak prompt] in
            guard let self, let prompt, self.forgetID == id else { return }
            if let window = prompt.viewIfLoaded?.window {
                if window !== self.ownedWindow { self.invalidatePage() }
            } else if !self.forgetConsuming {
                self.invalidatePage()
            }
        }
        forgetProbe = probe
        prompt.view.addSubview(probe)
        prompt.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak prompt] _ in
                guard let self, let prompt else { return }
                self.consumeForget(prompt, id: id, generation: generation, target: target, forget: false)
            })
        prompt.addAction(
            UIAlertAction(
                title: NSLocalizedString("backup.automatic.password.forget.confirm", value: "清除", comment: "Confirm forgetting password"),
                style: .destructive
            ) { [weak self, weak prompt] _ in
                guard let self, let prompt else { return }
                self.consumeForget(prompt, id: id, generation: generation, target: target, forget: true)
            })
        present(prompt, animated: true) { [weak self, weak prompt] in
            guard let self, self.forgetID == id, let prompt else { return }
            self.forgetPresenter = prompt.presentingViewController
            if !self.hasOwnedContext(allowing: prompt) || !self.ownsForget(prompt, allowingDismissal: false) { self.invalidatePage() }
        }
    }

    private func consumeForget(
        _ prompt: UIAlertController, id: UUID, generation: UUID, target: AutomaticBackupConfiguration, forget: Bool
    ) {
        // Check the request before clearing anything: an old callback must not touch a newer target's fields.
        guard forgetID == id, viewGeneration == generation, forgetPrompt === prompt, !forgetConsuming else { return }
        guard hasOwnedContext(allowing: prompt), ownsForget(prompt, allowingDismissal: true), matchesDisplayedConfiguration(target)
        else {
            invalidatePage()
            return
        }
        forgetConsuming = true
        Task { [weak self] in
            await Self.dismiss(prompt)
            guard let self, self.forgetID == id, self.viewGeneration == generation, self.forgetPrompt === prompt else { return }
            guard self.readyForAction(allowingForget: id), prompt.presentingViewController == nil,
                self.matchesDisplayedConfiguration(target)
            else {
                self.invalidatePage()
                return
            }
            self.forgetID = nil
            self.forgetProbe?.onWindowChanged = nil
            self.forgetProbe?.removeFromSuperview()
            self.forgetProbe = nil
            self.forgetPrompt = nil
            self.forgetPresenter = nil
            self.forgetConsuming = false
            guard forget else { return }
            do {
                try self.coordinator.forgetPassword(configuration: target)
                self.clearFields()
                self.reloadConfiguration()
            } catch {
                self.showError(
                    NSLocalizedString(
                        "backup.automatic.password.forget_failed", value: "清除失败，请解锁设备后重试",
                        comment: "Forget backup password failed without sensitive details"))
            }
        }
    }

    private func updatePlan(_ updated: AutomaticBackupConfiguration?) {
        let unchanged: Bool
        if let plan, let updated {
            unchanged = plan.matchesConfiguration(other: updated)
        } else {
            unchanged = plan == nil && updated == nil
        }
        if !unchanged {
            invalidatePage()
            rememberOnDevice = false
        }
        plan = updated
    }

    private func matchesDisplayedConfiguration(_ expected: AutomaticBackupConfiguration? = nil) -> Bool {
        guard let plan, let current = try? coordinator.currentConfiguration(),
            (expected ?? plan).matchesConfiguration(other: plan), plan.matchesConfiguration(other: current)
        else {
            invalidatePage()
            reloadConfiguration()
            return false
        }
        return true
    }

    private func clearFields() {
        passwordField.text = nil
        confirmationField.text = nil
        passwordField.resignFirstResponder()
        confirmationField.resignFirstResponder()
    }

    private func showError(_ message: String) {
        guard readyForAction() else { return }
        invalidatePage()
        showTransientMessage(message)
    }

    private func beginOwnership() {
        invalidatePage()
        monitor?.cancel()
        if let ownedScene { NotificationCenter.default.removeObserver(self, name: nil, object: ownedScene) }
        if let ownedWindow { NotificationCenter.default.removeObserver(self, name: nil, object: ownedWindow) }
        attachmentProbe?.onWindowChanged = nil
        attachmentProbe?.removeFromSuperview()
        ownedWindow = viewIfLoaded?.window
        ownedScene = ownedWindow?.windowScene
        ownedRoot = ownedWindow?.rootViewController
        ownedNavigation = navigationController
        ownedTop = navigationController?.topViewController
        visible = true
        if let ownedScene {
            for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(invalidateForLifecycle), name: name, object: ownedScene)
            }
        }
        if let ownedWindow {
            for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover] {
                NotificationCenter.default.addObserver(self, selector: #selector(invalidateForLifecycle), name: name, object: ownedWindow)
            }
        }
        let probe = AttachmentProbe(frame: .zero)
        probe.isHidden = true
        probe.isUserInteractionEnabled = false
        probe.onWindowChanged = { [weak self] in
            guard let self, self.viewIfLoaded?.window !== self.ownedWindow else { return }
            self.invalidatePage()
        }
        attachmentProbe = probe
        view.addSubview(probe)
        refreshOwnership()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                guard let self, self.visible else { return }
                self.refreshOwnership()
            }
        }
    }

    private func refreshOwnership() {
        if viewGeneration != nil {
            guard hasOwnedContext(allowing: forgetPrompt) else {
                invalidatePage()
                return
            }
            if let prompt = forgetPrompt, !forgetConsuming, !prompt.isBeingPresented,
                !ownsForget(prompt, allowingDismissal: false)
            {
                invalidatePage()
            }
        } else if hasOwnedContext(), canPerformNavigationAction {
            // Re-entry starts a fresh generation; it never revives a previous confirmation.
            reloadConfiguration()
            viewGeneration = UUID()
        }
    }

    @objc private func invalidateForLifecycle() { invalidatePage() }

    @objc private func lockChanged() {
        if !AppLockManager.shared.isUnlocked(in: ownedWindow) { invalidatePage() }
    }

    private func invalidatePage() {
        viewGeneration = nil
        clearFields()
        let prompt = forgetPrompt
        forgetID = nil
        forgetProbe?.onWindowChanged = nil
        forgetProbe?.removeFromSuperview()
        forgetProbe = nil
        forgetPrompt = nil
        forgetPresenter = nil
        forgetConsuming = false
        if let prompt { Task { await Self.dismiss(prompt) } }
    }

    private func readyForAction(allowingForget id: UUID? = nil) -> Bool {
        guard forgetID == nil || forgetID == id else { return false }
        guard viewGeneration != nil, hasOwnedContext(), canPerformNavigationAction else {
            invalidatePage()
            return false
        }
        return true
    }

    private func hasOwnedContext(allowing prompt: UIAlertController? = nil) -> Bool {
        guard visible, let window = ownedWindow, let scene = ownedScene, let root = ownedRoot,
            let navigation = ownedNavigation, let top = ownedTop,
            viewIfLoaded?.window === window, navigationController === navigation, navigation.topViewController === top,
            window.windowScene === scene, window.rootViewController === root, isVisibleInNavigationStack,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            window.isKeyWindow, !window.isHidden, window.alpha > 0, window.isUserInteractionEnabled,
            !window.accessibilityElementsHidden, AppLockManager.shared.isUnlocked(in: window),
            !root.isBeingDismissed, !root.isMovingFromParent
        else { return false }
        var candidate: UIViewController? = self
        while let controller = candidate {
            guard controller.viewIfLoaded?.window === window, controller.viewIfLoaded?.isHidden == false,
                (controller.viewIfLoaded?.alpha ?? 0) > 0, !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.presentedViewController == nil || (prompt != nil && controller.presentedViewController === prompt)
            else { return false }
            if let transition = controller.transitionCoordinator {
                guard let prompt, transition.viewController(forKey: .from) === prompt || transition.viewController(forKey: .to) === prompt
                else { return false }
            }
            candidate = controller.parent
        }
        if let prompt, prompt.presentedViewController != nil { return false }
        return true
    }

    private func ownsForget(_ prompt: UIAlertController, allowingDismissal: Bool) -> Bool {
        guard forgetPrompt === prompt, let presenter = forgetPresenter, prompt.presentingViewController === presenter,
            presenter.presentedViewController === prompt, prompt.viewIfLoaded?.window === ownedWindow,
            prompt.presentedViewController == nil, !prompt.isBeingPresented, allowingDismissal || !prompt.isBeingDismissed
        else { return false }
        return true
    }

    private static func dismiss(_ prompt: UIAlertController) async {
        while prompt.isBeingPresented || prompt.isBeingDismissed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
            }
        }
        if let presenter = prompt.presentingViewController, presenter.presentedViewController === prompt,
            prompt.presentedViewController == nil
        {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                prompt.dismiss(animated: prompt.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive) {
                    continuation.resume()
                }
            }
        }
    }

    private func date(_ milliseconds: Int64) -> String? {
        guard milliseconds > 0 else { return nil }
        return DateFormatter.localizedString(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1000), dateStyle: .medium, timeStyle: .short)
    }
}
