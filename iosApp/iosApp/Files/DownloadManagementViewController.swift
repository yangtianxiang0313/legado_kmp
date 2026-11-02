import UIKit
import shared

@MainActor
final class DownloadManagementViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    var onOpenFile: ((URL) -> Void)?

    private let client = DownloadManagementClient()
    private var tasks: [FileDownloadTask] = []
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var visible = false
    private var refreshID = UUID()
    private var pageGeneration = UUID()
    private var rowSelection: (task: FileDownloadTask, generation: UUID)?
    private var actionID: UUID?
    private var pendingAlert: UIAlertController?
    private var shareController: UIActivityViewController?
    private var sharePresentationCompleted = false
    private var pendingShareCompletion: (error: Error?, generation: UUID)?
    private var finishingShare = false
    private var handingOffFile = false
    private var ready = false

    init() {
        super.init(style: .plain)
        title = DownloadPresentationText.title
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
        for name in [Notification.Name.appLockWillCover, UIApplication.willResignActiveNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageWillBeCovered), name: name, object: nil)
        }
        applyPalette()
        updateActions()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visible = true
        pageGeneration = UUID()
        navigationController?.setNavigationBarHidden(false, animated: animated)
        do {
            try client.bind()
            ready = true
        } catch {
            ready = false
            navigationItem.prompt = DownloadPresentationText.serviceRetry
        }
        render()
        updateActions()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reloadDownloads()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        ready = false
        invalidatePage()
        client.unbind()
    }

    @objc private func pageWillBeCovered(_ notification: Notification) {
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        invalidatePage()
    }

    private func invalidatePage() {
        pageGeneration = UUID()
        rowSelection = nil
        refreshID = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        refreshControl?.endRefreshing()
        if let alert = pendingAlert, let id = actionID {
            pendingAlert = nil
            dismissPresentation(alert) { [weak self] in self?.finishAction(id) }
        } else if commandTask == nil, shareController == nil, !handingOffFile, let id = actionID {
            deliveryTask?.cancel()
            deliveryTask = nil
            finishAction(id)
        }
        // Commands already handed to shared/NSURLSession are never cancelled by page lifecycle.
        render()
        updateActions()
    }

    private func isCurrentPage(_ generation: UUID) -> Bool {
        visible && pageGeneration == generation && canPerformNavigationAction
            && AppLockManager.shared.isUnlocked(in: viewIfLoaded?.window)
    }

    private func beginAction(generation: UUID) -> UUID? {
        guard ready, actionID == nil, isCurrentPage(generation) else { return nil }
        // Consuming any action also invalidates older cell, toolbar, alert and menu callbacks.
        pageGeneration = UUID()
        rowSelection = nil
        let id = UUID()
        actionID = id
        render()
        updateActions()
        return id
    }

    private func finishAction(_ id: UUID) {
        guard actionID == id else { return }
        if ready, let current = try? client.currentTasks() { tasks = current }
        actionID = nil
        pageGeneration = UUID()
        render()
        updateActions()
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
        empty.text = ready ? DownloadPresentationText.empty : DownloadPresentationText.serviceUnavailable
        empty.textColor = AndroidReplicaTheme.secondaryText
        empty.textAlignment = .center
        empty.numberOfLines = 0
        empty.font = .preferredFont(forTextStyle: .body)
        empty.adjustsFontForContentSizeCategory = true
        tableView.backgroundView = tasks.isEmpty ? empty : nil
    }

    private func updateActions() {
        let generation = pageGeneration
        let add = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in
                self?.newDownload(generation: generation)
            })
        add.accessibilityLabel = DownloadPresentationText.add
        add.accessibilityIdentifier = "downloads.add"
        add.isEnabled = visible && ready && actionID == nil
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [
                UIAction(title: L10n.Common.refresh, image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.refreshDownloads(generation: generation)
                },
                UIAction(
                    title: DownloadPresentationText.clear, image: UIImage(systemName: "trash"),
                    attributes: ready ? .destructive : [.destructive, .disabled]
                ) { [weak self] _ in self?.confirmClear(generation: generation) },
            ]))
        more.accessibilityLabel = DownloadPresentationText.more
        more.isEnabled = visible && actionID == nil
        navigationItem.rightBarButtonItems = [more, add]
    }

    @objc private func reloadDownloads() { refreshDownloads(generation: pageGeneration) }

    private func refreshDownloads(generation: UUID) {
        guard actionID == nil, isCurrentPage(generation) else {
            refreshControl?.endRefreshing()
            return
        }
        if !ready {
            do {
                try client.bind()
                ready = true
                updateActions()
            } catch {
                refreshControl?.endRefreshing()
                navigationItem.prompt = DownloadPresentationText.serviceRetry
                render()
                return
            }
        }
        let id = UUID()
        refreshID = id
        refreshTask?.cancel()
        refreshTask = Task { [weak self, client] in
            defer {
                if let self, self.refreshID == id {
                    self.refreshControl?.endRefreshing()
                    self.refreshTask = nil
                }
            }
            guard self?.isCurrentPage(generation) == true, !Task.isCancelled else { return }
            do {
                try await client.refresh()
                guard let self, self.refreshID == id, self.isCurrentPage(generation), !Task.isCancelled else { return }
                self.navigationItem.prompt = nil
            } catch {
                guard let self, self.refreshID == id, self.isCurrentPage(generation), !Task.isCancelled else { return }
                self.navigationItem.prompt = DownloadPresentationText.directoryUnavailable
            }
        }
    }

    private func newDownload(generation: UUID) {
        guard let id = beginAction(generation: generation) else { return }
        let generation = pageGeneration
        let alert = UIAlertController(title: DownloadPresentationText.add, message: nil, preferredStyle: .alert)
        pendingAlert = alert
        alert.addTextField { field in
            field.placeholder = DownloadPresentationText.urlPlaceholder
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "downloads.url"
        }
        alert.addTextField { field in
            field.placeholder = DownloadPresentationText.fileNamePlaceholder
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "downloads.filename"
        }
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let alert else { return }
                self?.consumeAlert(alert, id: id, generation: generation, command: nil)
            })
        alert.addAction(
            UIAlertAction(title: L10n.Reader.menuDownload, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, let fields = alert.textFields, fields.count == 2 else { return }
                let url = (fields[0].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let enteredName = (fields[1].text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let fileName = enteredName.isEmpty ? URL(string: url)?.lastPathComponent ?? "" : enteredName
                self.consumeAlert(alert, id: id, generation: generation) { [client = self.client] in
                    try await client.start(url: url, fileName: fileName)
                }
            })
        present(alert, animated: true)
    }

    private func confirmClear(generation: UUID) {
        guard let id = beginAction(generation: generation) else { return }
        let generation = pageGeneration
        let taskIDs = Set(tasks.map(\.id))
        let alert = UIAlertController(
            title: DownloadPresentationText.clear, message: DownloadPresentationText.clearMessage,
            preferredStyle: .alert)
        pendingAlert = alert
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let alert else { return }
                self?.consumeAlert(alert, id: id, generation: generation, command: nil)
            })
        alert.addAction(
            UIAlertAction(title: L10n.Common.clear, style: .destructive) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                self.consumeAlert(alert, id: id, generation: generation) { [weak self, client = self.client] in
                    try await client.clear(expectedTaskIDs: taskIDs) { [weak self] in
                        self?.actionID == id && self?.isCurrentPage(generation) == true
                    }
                }
            })
        present(alert, animated: true)
    }

    private func consumeAlert(
        _ alert: UIAlertController, id: UUID, generation: UUID, command: (@MainActor () async throws -> Void)?
    ) {
        guard pendingAlert === alert, actionID == id, pageGeneration == generation else { return }
        pendingAlert = nil
        dismissPresentation(alert) { [weak self] in
            guard let self, self.actionID == id else { return }
            guard self.isCurrentPage(generation), let command else {
                self.finishAction(id)
                return
            }
            self.performCommand(id, generation: generation, command)
        }
    }

    private func performCommand(_ id: UUID, generation: UUID, _ command: @escaping @MainActor () async throws -> Void) {
        commandTask = Task { [weak self] in
            defer {
                self?.commandTask = nil
                self?.finishAction(id)
            }
            guard self?.actionID == id, self?.isCurrentPage(generation) == true else { return }
            do { try await command() } catch {
                guard let self, self.isCurrentPage(generation) else { return }
                self.showTransientMessage(DownloadPresentationText.commandError(error))
            }
        }
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { tasks.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let task = tasks[indexPath.row]
        let generation = pageGeneration
        let action = primaryAction(for: task)
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: DownloadTaskCell.reuseIdentifier, for: indexPath) as! DownloadTaskCell
        cell.configure(task, actionEnabled: ready && actionID == nil) { [weak self] in
            guard let action else { return }
            self?.performTaskAction(task, action: action, generation: generation)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        rowSelection = nil
        guard actionID == nil, isCurrentPage(pageGeneration), tasks.indices.contains(indexPath.row),
            tasks[indexPath.row].status == .completed
        else { return nil }
        rowSelection = (tasks[indexPath.row], pageGeneration)
        return indexPath
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let selection = rowSelection else { return }
        rowSelection = nil
        performTaskAction(selection.task, action: .open, generation: selection.generation)
    }

    override func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint)
        -> UIContextMenuConfiguration?
    {
        let generation = pageGeneration
        guard actionID == nil, isCurrentPage(generation), tasks.indices.contains(indexPath.row) else { return nil }
        let task = tasks[indexPath.row]
        let actions: [DownloadTaskAction]
        if task.status == .completed {
            actions = [.open, .share]
        } else if task.canPause {
            actions = [.pause, .cancel]
        } else if task.canResume {
            actions = [.resume, .cancel]
        } else if task.canRetry {
            actions = [.retry]
        } else {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self, self.actionID == nil, self.pageGeneration == generation else { return nil }
            return UIMenu(
                children: actions.map { action in
                    UIAction(
                        title: action.title, image: UIImage(systemName: action.symbol),
                        attributes: action == .cancel ? .destructive : []
                    ) { [weak self] _ in
                        self?.performTaskAction(task, action: action, generation: generation)
                    }
                })
        }
    }

    private func primaryAction(for task: FileDownloadTask) -> DownloadTaskAction? {
        if task.canPause { return .pause }
        if task.canResume { return .resume }
        if task.canRetry { return .retry }
        return task.status == .completed ? .share : nil
    }

    private func currentTask(_ original: FileDownloadTask, action: DownloadTaskAction) -> FileDownloadTask? {
        try? client.currentTask(original, action: action)
    }

    private func performTaskAction(_ original: FileDownloadTask, action: DownloadTaskAction, generation: UUID) {
        guard let task = currentTask(original, action: action), let id = beginAction(generation: generation) else {
            return
        }
        let generation = pageGeneration
        if action == .open || action == .share {
            deliver(task, sharing: action == .share, id: id, generation: generation)
            return
        }
        performCommand(id, generation: generation) { [weak self, client] in
            guard self?.currentTask(task, action: action) != nil else { return }
            switch action {
            case .pause: try await client.pause(id: task.id)
            case .resume: try await client.resume(id: task.id)
            case .cancel: try await client.cancel(id: task.id)
            case .retry: try await client.retry(id: task.id)
            case .open, .share: break
            }
        }
    }

    private func deliver(_ task: FileDownloadTask, sharing: Bool, id: UUID, generation: UUID) {
        deliveryTask = Task { [weak self, client] in
            do {
                let file = try await client.completedFile(task)
                guard let self, self.actionID == id else { return }
                self.deliveryTask = nil
                guard self.isCurrentPage(generation), !Task.isCancelled,
                    self.currentTask(task, action: sharing ? .share : .open) != nil
                else {
                    self.finishAction(id)
                    return
                }
                if sharing {
                    self.presentShare(file, id: id, generation: generation)
                } else {
                    self.openFile(file, id: id)
                }
            } catch {
                guard let self, self.actionID == id else { return }
                self.deliveryTask = nil
                let canReport = self.isCurrentPage(generation) && !Task.isCancelled
                self.finishAction(id)
                if canReport {
                    self.showTransientMessage(DownloadPresentationText.fileUnavailable)
                    self.reloadDownloads()
                }
            }
        }
    }

    private func presentShare(_ file: URL, id: UUID, generation: UUID) {
        guard actionID == id, isCurrentPage(generation) else {
            finishAction(id)
            return
        }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        shareController = share
        sharePresentationCompleted = false
        pendingShareCompletion = nil
        finishingShare = false
        share.completionWithItemsHandler = { [weak self, weak share] _, _, _, error in
            Task { @MainActor [weak self, weak share] in
                guard let share else { return }
                self?.finishShare(share, id: id, generation: generation, error: error)
            }
        }
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(
            x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        // Remote preparation may have no presenter, window or transition; only UIKit's completion acknowledges presentation.
        present(share, animated: true) { [weak self, weak share] in
            guard let self, let share, self.shareController === share, self.actionID == id else { return }
            self.sharePresentationCompleted = true
            share.presentationController?.delegate = self
            if let result = self.pendingShareCompletion {
                self.pendingShareCompletion = nil
                self.finishShare(share, id: id, generation: result.generation, error: result.error)
            }
        }
    }

    private func finishShare(_ share: UIActivityViewController, id: UUID, generation: UUID, error: Error?) {
        guard shareController === share, actionID == id, !finishingShare else { return }
        guard sharePresentationCompleted else {
            // Preserve an early real activity result without ending the still-pending presentation.
            if pendingShareCompletion == nil { pendingShareCompletion = (error: error, generation: generation) }
            return
        }
        finishingShare = true
        share.completionWithItemsHandler = nil
        dismissPresentation(share) { [weak self, weak share] in
            guard let self, let share, self.shareController === share, self.actionID == id else { return }
            let canReport = self.isCurrentPage(generation)
            self.shareController = nil
            self.sharePresentationCompleted = false
            self.pendingShareCompletion = nil
            self.finishingShare = false
            self.finishAction(id)
            if error != nil, canReport { self.showTransientMessage(DownloadPresentationText.shareFailed) }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let share = shareController, presentationController.presentedViewController === share, let id = actionID
        else {
            return
        }
        finishShare(share, id: id, generation: pageGeneration, error: nil)
    }

    private func openFile(_ file: URL, id: UUID) {
        handingOffFile = true
        if let onOpenFile {
            onOpenFile(file)
        } else {
            let destination = FileDocumentViewController(url: file)
            if let navigationController {
                navigationController.pushViewController(destination, animated: true)
            } else {
                present(UINavigationController(rootViewController: destination), animated: true)
            }
        }
        let destination = presentedViewController ?? navigationController?.topViewController
        guard let destination, destination !== self else {
            handingOffFile = false
            finishAction(id)
            if isCurrentPage(pageGeneration) { showTransientMessage(DownloadPresentationText.openFailed) }
            return
        }
        let coordinator = destination.transitionCoordinator ?? navigationController?.transitionCoordinator
        if let coordinator,
            coordinator.animate(
                alongsideTransition: nil,
                completion: { [weak self] _ in
                    self?.handingOffFile = false
                    self?.finishAction(id)
                })
        {
            return
        }
        handingOffFile = false
        finishAction(id)
    }

    private func dismissPresentation(_ controller: UIViewController, completion: @escaping () -> Void) {
        if controller.isBeingPresented || controller.isBeingDismissed,
            let coordinator = controller.transitionCoordinator,
            coordinator.animate(
                alongsideTransition: nil,
                completion: { [weak self, weak controller] _ in
                    DispatchQueue.main.async {
                        guard let self, let controller else {
                            completion()
                            return
                        }
                        self.dismissPresentation(controller, completion: completion)
                    }
                })
        {
            return
        }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true) { DispatchQueue.main.async(execute: completion) }
        } else {
            DispatchQueue.main.async(execute: completion)
        }
    }
}
