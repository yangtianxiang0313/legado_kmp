import UIKit
import shared

@MainActor
final class DownloadManagementViewController: UITableViewController {
    var onOpenFile: ((URL) -> Void)?

    private let client = DownloadManagementClient()
    private var tasks: [FileDownloadTask] = []
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var visible = false
    private var refreshID = UUID()
    private var ready = false

    init() {
        super.init(style: .plain)
        title = "下载管理"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        refreshTask?.cancel()
        deliveryTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(DownloadTaskCell.self, forCellReuseIdentifier: DownloadTaskCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 112
        tableView.accessibilityIdentifier = "downloads.list"
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reloadDownloads), for: .valueChanged)
        refreshControl = refresh
        client.onChange = { [weak self] tasks in
            guard let self, self.visible else { return }
            self.tasks = tasks
            self.render()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        applyPalette()
        updateActions()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        navigationController?.setNavigationBarHidden(false, animated: animated)
        do {
            try client.bind()
            ready = true
            reloadDownloads()
        } catch {
            ready = false
            navigationItem.prompt = "下载服务暂不可用，请刷新重试"
            render()
        }
        updateActions()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        deliveryTask?.cancel()
        deliveryTask = nil
        refreshControl?.endRefreshing()
        client.unbind()
    }

    @objc private func applyPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        render()
    }

    private func render() {
        tableView.reloadData()
        let empty = UILabel()
        empty.text = ready ? "暂无下载" : "下载服务暂不可用"
        empty.textColor = AndroidReplicaTheme.secondaryText
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.font = .preferredFont(forTextStyle: .body)
        tableView.backgroundView = tasks.isEmpty ? empty : nil
    }

    private func updateActions() {
        let add = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(newDownload))
        add.accessibilityLabel = "新建下载"
        add.accessibilityIdentifier = "downloads.add"
        add.isEnabled = ready && commandTask == nil
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(title: "刷新", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reloadDownloads() },
                UIAction(title: "清空任务记录", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmClear()
                },
            ]))
        more.accessibilityLabel = "下载操作"
        more.isEnabled = commandTask == nil
        navigationItem.rightBarButtonItems = [more, add]
    }

    @objc private func reloadDownloads() {
        guard visible else { return }
        if !ready {
            do { try client.bind(); ready = true; updateActions() } catch { refreshControl?.endRefreshing(); return }
        }
        let id = UUID()
        refreshID = id
        refreshTask?.cancel()
        refreshTask = Task { [weak self, client] in
            do {
                try await client.refresh()
                guard let self, self.visible, self.refreshID == id, !Task.isCancelled else { return }
                self.navigationItem.prompt = nil
            } catch {
                guard let self, self.visible, self.refreshID == id, !Task.isCancelled else { return }
                self.navigationItem.prompt = "无法读取下载目录，请刷新重试"
            }
            guard let self, self.refreshID == id else { return }
            self.refreshControl?.endRefreshing()
            self.refreshTask = nil
        }
    }

    @objc private func newDownload() {
        guard ready, commandTask == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "新建下载", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "HTTP / HTTPS 地址"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "downloads.url"
        }
        alert.addTextField { field in
            field.placeholder = "文件名（含扩展名）"
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "downloads.filename"
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "下载", style: .default) { [weak self, weak alert] _ in
                guard let self, let fields = alert?.textFields, fields.count == 2 else { return }
                let url = (fields[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let enteredName = (fields[1].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fileName = enteredName.isEmpty ? URL(string: url)?.lastPathComponent ?? "" : enteredName
                self.performCommand { [client = self.client] in try await client.start(url: url, fileName: fileName) }
            })
        present(alert, animated: true)
    }

    private func confirmClear() {
        guard commandTask == nil, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "清空任务记录", message: "进行中的下载将取消，已下载文件不会删除。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
                guard let self else { return }
                self.performCommand { [client = self.client] in try await client.clear() }
            })
        present(alert, animated: true)
    }

    private func performCommand(_ command: @escaping @MainActor () async throws -> Void) {
        guard ready, commandTask == nil else { return }
        commandTask = Task { [weak self] in
            defer {
                self?.commandTask = nil
                self?.updateActions()
            }
            do { try await command() } catch {
                guard let self, self.visible, !Task.isCancelled else { return }
                let message = error.userFacingMessage
                self.showTransientMessage(
                    message.count <= 160 && !message.contains("://") && !message.contains("/")
                        ? message : "下载操作未完成，请检查输入、网络或存储空间后重试")
            }
        }
        updateActions()
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { tasks.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let task = tasks[indexPath.row]
        let cell =
            tableView.dequeueReusableCell(withIdentifier: DownloadTaskCell.reuseIdentifier, for: indexPath) as! DownloadTaskCell
        cell.configure(task) { [weak self] in self?.primaryAction(task) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard tasks.indices.contains(indexPath.row), tasks[indexPath.row].status == .completed else { return }
        deliver(tasks[indexPath.row], sharing: false)
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard tasks.indices.contains(indexPath.row) else { return nil }
        let task = tasks[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            if task.status == .completed {
                return UIMenu(children: [
                    UIAction(title: "打开 / 导入", image: UIImage(systemName: "doc")) { [weak self] _ in
                        self?.deliver(task, sharing: false)
                    },
                    UIAction(title: "分享", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                        self?.deliver(task, sharing: true)
                    },
                ])
            }
            if task.canPause || task.canResume {
                return UIMenu(children: [
                    UIAction(
                        title: task.canPause ? "暂停下载" : "继续下载",
                        image: UIImage(systemName: task.canPause ? "pause.circle" : "play.circle")
                    ) { [weak self] _ in self?.primaryAction(task) },
                    UIAction(title: "取消下载", image: UIImage(systemName: "xmark.circle"), attributes: .destructive) {
                        [weak self] _ in
                        guard let self else { return }
                        self.performCommand { [client = self.client] in try await client.cancel(id: task.id) }
                    },
                ])
            }
            guard task.canRetry else { return nil }
            return UIMenu(children: [
                UIAction(title: "重新下载", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.primaryAction(task)
                }
            ])
        }
    }

    private func primaryAction(_ task: FileDownloadTask) {
        if task.canPause {
            performCommand { [client] in try await client.pause(id: task.id) }
        } else if task.canResume {
            performCommand { [client] in try await client.resume(id: task.id) }
        } else if task.canRetry {
            performCommand { [client] in try await client.retry(id: task.id) }
        } else if task.status == .completed {
            deliver(task, sharing: true)
        }
    }

    private func deliver(_ task: FileDownloadTask, sharing: Bool) {
        guard deliveryTask == nil, visible, presentedViewController == nil else { return }
        deliveryTask = Task { [weak self, client] in
            defer { self?.deliveryTask = nil }
            do {
                let file = try await client.completedFile(task)
                guard let self, self.visible, !Task.isCancelled, self.presentedViewController == nil else { return }
                if sharing {
                    let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = self.view
                    share.popoverPresentationController?.sourceRect = CGRect(
                        x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                    self.present(share, animated: true)
                } else if let onOpenFile = self.onOpenFile {
                    onOpenFile(file)
                } else {
                    let destination = FileDocumentViewController(url: file)
                    if let navigationController = self.navigationController {
                        navigationController.pushViewController(destination, animated: true)
                    } else {
                        self.present(UINavigationController(rootViewController: destination), animated: true)
                    }
                }
            } catch {
                guard let self, self.visible, !Task.isCancelled else { return }
                self.showTransientMessage("下载文件已移动或无法访问，请刷新列表")
                self.reloadDownloads()
            }
        }
    }
}
