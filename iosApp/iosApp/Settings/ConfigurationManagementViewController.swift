import UIKit
import shared

@MainActor
final class ConfigurationManagementViewController: UITableViewController {
    private let category: ConfigurationManagementCategory
    private var facade: BackupCapabilitiesFacade?
    private var records: [ConfigurationManagementRecord] = []
    private var loadTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var loadID = UUID()
    private var isVisible = false
    private var isLoading = false
    private var loadFailed = false
    private var pendingMessage: String?
    private var activeServerID: Int64?

    init(category: ConfigurationManagementCategory) {
        self.category = category
        super.init(style: .insetGrouped)
        title = category.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "configuration.\(category.rawValue).list"
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(add)),
            UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reload)),
        ]
        navigationItem.rightBarButtonItems?[0].accessibilityIdentifier = "configuration.\(category.rawValue).add"
        navigationItem.rightBarButtonItems?[1].accessibilityIdentifier = "configuration.\(category.rawValue).refresh"
        let refresh = UIRefreshControl()
        refresh.accessibilityIdentifier = "configuration.\(category.rawValue).pullToRefresh"
        refresh.addTarget(self, action: #selector(reload), for: .valueChanged)
        refreshControl = refresh
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        navigationController?.setNavigationBarHidden(false, animated: animated)
        if actionTask == nil { reload() } else { updateControls() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let message = pendingMessage {
            pendingMessage = nil
            showMessage(message)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        invalidateLoad()
    }

    private func invalidateLoad() {
        loadID = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        refreshControl?.endRefreshing()
    }

    @objc private func reload() {
        guard isVisible, actionTask == nil else {
            refreshControl?.endRefreshing()
            return
        }
        invalidateLoad()
        do {
            if facade == nil { facade = try BootstrapApiKt.sharedBackupCapabilitiesFacade() }
        } catch {
            loadFailed = true
            updateControls()
            tableView.reloadData()
            return
        }
        guard let facade else { return }
        let token = UUID()
        loadID = token
        isLoading = true
        loadFailed = false
        updateControls()
        tableView.reloadData()
        let category = category
        loadTask = Task { [weak self] in
            do {
                let loaded = try await category.load(using: facade)
                try Task.checkCancellation()
                guard let self, self.isVisible, self.loadID == token else { return }
                self.records = loaded
                self.finishLoad(failed: false)
            } catch {
                guard let self, self.isVisible, self.loadID == token else { return }
                self.finishLoad(failed: true)
            }
        }
    }

    private func finishLoad(failed: Bool) {
        loadTask = nil
        isLoading = false
        loadFailed = failed
        refreshControl?.endRefreshing()
        updateControls()
        tableView.reloadData()
    }

    private func updateControls() {
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = actionTask == nil && !isLoading }
        tableView.isUserInteractionEnabled = actionTask == nil
        if actionTask == nil { navigationItem.prompt = nil }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, records.count) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if loadFailed, !records.isEmpty { return "刷新失败，当前显示上次数据。" }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 2
        guard !records.isEmpty else {
            cell.textLabel?.text = isLoading ? "正在加载…" : (loadFailed ? "加载失败，点击重试" : "暂无数据")
            cell.accessibilityIdentifier = "configuration.\(category.rawValue).\(loadFailed ? "retry" : "empty")"
            cell.selectionStyle = loadFailed ? .default : .none
            if isLoading {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            }
            return cell
        }
        let record = records[indexPath.row]
        cell.textLabel?.text = record.name.isEmpty ? "未命名" : record.name
        cell.detailTextLabel?.text = record.summary
        if case let .server(item) = record, activeServerID == item.id {
            cell.detailTextLabel?.text = "WebDAV · 已启用"
        }
        cell.accessibilityIdentifier = "configuration.row.\(record.identity)"
        let controls = UIStackView()
        controls.axis = .horizontal
        controls.alignment = .center
        controls.spacing = 12
        if case let .subscription(item) = record {
            let toggle = UISwitch()
            toggle.isOn = item.autoUpdate
            toggle.accessibilityLabel = "启动时自动更新 \(item.name)"
            toggle.accessibilityIdentifier = "configuration.\(record.identity).autoUpdate"
            toggle.addAction(
                UIAction { [weak self, weak toggle] _ in
                    guard let self, let toggle, self.actionTask == nil, !self.isLoading else {
                        toggle?.setOn(item.autoUpdate, animated: false)
                        return
                    }
                    self.setAutoUpdate(record: record, enabled: toggle.isOn)
                }, for: .valueChanged)
            controls.addArrangedSubview(toggle)
        }
        let menu = UIButton(type: .system)
        menu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        menu.accessibilityLabel = "\(record.name)的操作"
        menu.accessibilityIdentifier = "configuration.\(record.identity).actions"
        menu.showsMenuAsPrimaryAction = true
        menu.menu = recordMenu(record)
        menu.widthAnchor.constraint(equalToConstant: 44).isActive = true
        menu.heightAnchor.constraint(equalToConstant: 44).isActive = true
        controls.addArrangedSubview(menu)
        controls.frame.size = CGSize(
            width: controls.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).width, height: 44)
        cell.accessoryView = controls
        return cell
    }

    private func recordMenu(_ record: ConfigurationManagementRecord) -> UIMenu {
        var actions = [UIAction(title: "编辑", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.edit(record) }]
        switch record {
        case .subscription:
            actions.append(
                UIAction(title: "立即更新", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.updateSubscription(record)
                })
        case .server:
            actions.append(
                UIAction(title: "启用服务器", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                    self?.selectServer(record)
                })
        default: break
        }
        actions.append(
            UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDelete(record)
            })
        return UIMenu(children: actions)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !records.isEmpty else {
            if loadFailed { reload() }
            return
        }
        edit(records[indexPath.row])
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard records.indices.contains(indexPath.row), !isLoading, actionTask == nil else { return nil }
        let record = records[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            completion(false)
            self?.confirmDelete(record)
        }
        action.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard records.indices.contains(indexPath.row), !isLoading, actionTask == nil else { return nil }
        let record = records[indexPath.row]
        let title: String
        switch record {
        case .subscription: title = "立即更新"
        case .server: title = "启用"
        default: return nil
        }
        let action = UIContextualAction(style: .normal, title: title) { [weak self] _, _, completion in
            completion(true)
            switch record {
            case .subscription: self?.updateSubscription(record)
            case .server: self?.selectServer(record)
            default: break
            }
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    @objc private func add() { edit(nil) }

    private func edit(_ record: ConfigurationManagementRecord?) {
        guard isVisible, !isLoading, actionTask == nil, let facade, presentedViewController == nil else { return }
        let maximum = records.map(\.order).max() ?? 0
        let nextOrder = maximum < Int32.max ? maximum + 1 : maximum
        let editor = ConfigurationEditorViewController(category: category, record: record, nextOrder: nextOrder, facade: facade)
        editor.onSave = { [weak self] saved in
            guard let self else { return }
            if let record, let index = self.records.firstIndex(where: { $0.identity == record.identity }) {
                self.records[index] = saved
            } else {
                self.records.append(saved)
            }
        }
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }

    private func confirmDelete(_ record: ConfigurationManagementRecord) {
        guard isVisible, actionTask == nil, !isLoading, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "删除", message: "是否确认删除“\(record.name)”？", preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "configuration.delete.confirmation"
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
                self?.performAction(prompt: "正在删除…") { facade in
                    try await record.delete(using: facade)
                    return nil
                } onSuccess: { [weak self] in
                    self?.records.removeAll { $0.identity == record.identity }
                    if case let .server(item) = record, self?.activeServerID == item.id {
                        self?.activeServerID = nil
                    }
                }
            })
        present(alert, animated: true)
    }

    private func updateSubscription(_ record: ConfigurationManagementRecord) {
        guard case let .subscription(item) = record else { return }
        performAction(prompt: "正在更新订阅…") { facade in
            let count: KotlinInt = try await SharedAsync.value { facade.updateSubscription(id: item.id, completionHandler: $0) }
            return "已应用 \(count.intValue) 项订阅数据"
        }
    }

    private func selectServer(_ record: ConfigurationManagementRecord) {
        guard case let .server(item) = record else { return }
        performAction(prompt: "正在启用服务器…") { facade in
            try await SharedAsync.void { facade.selectServer(id: item.id, completionHandler: $0) }
            return "已启用服务器，可进入远程书籍浏览"
        } onSuccess: { [weak self] in
            self?.activeServerID = item.id
        }
    }

    private func setAutoUpdate(record: ConfigurationManagementRecord, enabled: Bool) {
        guard case let .subscription(item) = record else { return }
        performAction(prompt: "正在保存…") { facade in
            try await SharedAsync.void { facade.setSubscriptionAutoUpdate(id: item.id, enabled: enabled, completionHandler: $0) }
            return nil
        }
    }

    private func performAction(
        prompt: String, operation: @escaping (BackupCapabilitiesFacade) async throws -> String?,
        onSuccess: (() -> Void)? = nil
    ) {
        guard isVisible, !isLoading, actionTask == nil, let facade else { return }
        invalidateLoad()
        navigationItem.prompt = prompt
        actionTask = Task { [weak self] in
            var message: String?
            do {
                message = try await operation(facade)
                try Task.checkCancellation()
                onSuccess?()
            } catch {
                message = error is CancellationError ? "操作已取消，可重试" : "操作失败，请检查网络、重复记录和配置后重试"
            }
            guard let self else { return }
            self.actionTask = nil
            // Storage work may finish after navigation. Only the next appearance may refresh that UI.
            guard self.isVisible else {
                self.pendingMessage = message
                return
            }
            self.updateControls()
            self.reload()
            if let message { self.showMessage(message) }
        }
        updateControls()
    }

    private func showMessage(_ message: String) {
        guard isVisible, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "configuration.management.message"
        alert.addAction(UIAlertAction(title: "确定", style: .default))
        present(alert, animated: true)
    }
}
