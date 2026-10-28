import UIKit
import shared

@MainActor
final class CloudBackupViewController: UITableViewController {
    private let screen = CloudBackupScreenAdapter()
    private var files: [CloudBackupFile] = []
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var visible = false
    private var loading = false
    private var processing = false
    private var failure: String?
    private var pendingMessage: String?
    private var initialRestore: CloudBackupFile?
    private var previousInteractivePop: Bool?
    var onRestored: (() -> Void)?
    var onReturn: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if parent == nil, let callback = onReturn {
            onReturn = nil
            callback()
        }
    }

    init(initialRestore: CloudBackupFile? = nil) {
        self.initialRestore = initialRestore
        super.init(style: .plain)
        title = "云端备份"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.accessibilityIdentifier = "backup.cloud.list"
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reloadBackups), for: .valueChanged)
        refreshControl = refresh
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        applyPalette()
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canPerformNavigationAction else { return }
            if let message = self.pendingMessage {
                self.pendingMessage = nil
                self.showResult(message)
            } else if self.task == nil {
                self.reloadBackups()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        if !processing {
            requestID = UUID()
            task?.cancel()
            task = nil
            loading = false
            refreshControl?.endRefreshing()
        }
    }

    @objc private func applyPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.reloadData()
    }

    @objc private func becameActive() {
        DispatchQueue.main.async { [weak self] in
            guard let self, visible, canPerformNavigationAction, let message = pendingMessage else { return }
            pendingMessage = nil
            showResult(message)
        }
    }

    private func updateControls() {
        let upload = UIBarButtonItem(
            image: UIImage(systemName: "icloud.and.arrow.up"), style: .plain, target: self, action: #selector(uploadBackup))
        upload.accessibilityLabel = "备份到云端"
        upload.accessibilityIdentifier = "backup.cloud.upload"
        upload.isEnabled = !loading && !processing
        let refresh = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadBackups))
        refresh.accessibilityIdentifier = "backup.cloud.refresh"
        refresh.isEnabled = !loading && !processing
        navigationItem.rightBarButtonItems = [upload, refresh]
        navigationItem.hidesBackButton = processing
        if processing, previousInteractivePop == nil {
            previousInteractivePop = navigationController?.interactivePopGestureRecognizer?.isEnabled
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        } else if !processing, let previousInteractivePop {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = previousInteractivePop
            self.previousInteractivePop = nil
        }
        tableView.isUserInteractionEnabled = !processing
    }

    @objc private func reloadBackups() {
        guard visible, !processing else { refreshControl?.endRefreshing(); return }
        task?.cancel()
        let id = UUID()
        requestID = id
        loading = true
        failure = nil
        updateControls()
        tableView.reloadData()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await screen.list()
                guard visible, requestID == id, !Task.isCancelled else { return }
                files = loaded
            } catch is CancellationError {
                return
            } catch {
                guard visible, requestID == id else { return }
                failure = error.userFacingMessage
            }
            task = nil
            loading = false
            refreshControl?.endRefreshing()
            updateControls()
            tableView.reloadData()
            if let selected = initialRestore, failure == nil {
                initialRestore = nil
                if let file = files.first(where: { $0.name == selected.name && $0.lastModified == selected.lastModified }) {
                    DispatchQueue.main.async { [weak self] in self?.confirmRestore(file) }
                } else {
                    showResult("云端备份已变化，请重新选择")
                }
            }
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { max(1, files.count) }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        files.isEmpty ? nil : failure.map { "刷新失败，当前保留上次列表。\n" + $0 }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.textLabel?.textColor = AndroidReplicaTheme.primaryText
        cell.detailTextLabel?.textColor = AndroidReplicaTheme.secondaryText
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        guard !files.isEmpty else {
            cell.textLabel?.text = loading ? "正在加载…" : (failure == nil ? "暂无云端备份" : "加载失败，点击重试")
            cell.detailTextLabel?.text = failure
            cell.accessibilityIdentifier = failure == nil ? "backup.cloud.empty" : "backup.cloud.retry"
            cell.selectionStyle = failure == nil ? .none : .default
            return cell
        }
        let file = files[indexPath.row]
        cell.textLabel?.text = file.name
        let date =
            file.lastModified > 0
            ? DateFormatter.localizedString(
                from: Date(timeIntervalSince1970: Double(file.lastModified) / 1000), dateStyle: .medium, timeStyle: .short)
            : "时间未知"
        cell.detailTextLabel?.text = date + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "backup.cloud.file.\(file.name)"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading, !processing else { return }
        guard !files.isEmpty else { if failure != nil { reloadBackups() }; return }
        confirmRestore(files[indexPath.row])
    }

    @objc private func uploadBackup() {
        guard canPerformNavigationAction, task == nil else { return }
        BackupPasswordPrompt.present(from: self, creating: true) { [weak self] password in
            self?.performUpload(password)
        }
    }

    func confirmRestore(_ file: CloudBackupFile) {
        guard canPerformNavigationAction, task == nil else { return }
        BackupPasswordPrompt.present(from: self, creating: false, fileName: file.name) { [weak self] password in
            self?.performRestore(file, password: password)
        }
    }

    private func performUpload(_ password: String) {
        guard canPerformNavigationAction, task == nil else { return }
        processing = true
        updateControls()
        let hud = progressAlert("正在上传备份", cancellable: true)
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                let result = try await screen.upload(password: password)
                message = (["已备份到云端：\(result.file.name)"] + result.warnings).joined(separator: "\n")
            } catch is CancellationError {
                message = "已停止等待，请刷新确认云端状态"
            } catch {
                message = error.userFacingMessage
            }
            finish(hud: hud, message: message)
        }
    }

    private func performRestore(_ file: CloudBackupFile, password: String) {
        guard canPerformNavigationAction, task == nil else { return }
        processing = true
        updateControls()
        // Once restoring starts, do not expose a cancellation that promises to roll back written rows.
        let hud = progressAlert("正在恢复备份", cancellable: false)
        present(hud, animated: true)
        task = Task { [weak self] in
            guard let self else { return }
            let message: String
            do {
                let restored = try await screen.restore(file: file, password: password)
                onRestored?()
                message = (["恢复完成：书架 \(restored.result.bookCount)，书源 \(restored.result.bookSourceCount)"] + restored.warnings)
                    .joined(separator: "\n")
            } catch {
                message = error.userFacingMessage
            }
            finish(hud: hud, message: message)
        }
    }

    private func progressAlert(_ title: String, cancellable: Bool) -> UIAlertController {
        let hud = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        hud.view.accessibilityIdentifier = "backup.cloud.processing"
        if cancellable {
            hud.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self] _ in self?.task?.cancel() })
        }
        return hud
    }

    private func finish(hud: UIAlertController, message: String) {
        task = nil
        processing = false
        updateControls()
        let completion = { [weak self] in
            guard let self else { return }
            if visible, canPerformNavigationAction, UIApplication.shared.applicationState == .active {
                showResult(message)
            } else {
                pendingMessage = message
            }
        }
        if hud.presentingViewController != nil { hud.dismiss(animated: true, completion: completion) } else { completion() }
    }

    private func showResult(_ message: String) {
        guard canPerformNavigationAction else { pendingMessage = message; return }
        let alert = UIAlertController(title: "云端备份", message: message, preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "backup.cloud.result"
        alert.addAction(
            UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self] _ in
                DispatchQueue.main.async { self?.reloadBackups() }
            })
        present(alert, animated: true)
    }
}
