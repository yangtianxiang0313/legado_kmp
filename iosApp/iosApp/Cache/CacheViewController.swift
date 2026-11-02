import UIKit
import shared

@MainActor
final class CacheViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let toolbar = CacheManagementToolbarView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = AndroidCacheTextLabel()
    private let screen = CacheScreenAdapter()
    private let downloads = CacheDownloadCoordinator.shared
    private let exporter = CacheBookExporter()
    private let exportPreferences = CacheExportPreferences()
    private let exportOptionsPreferences = CacheExportOptionsPreferences()
    private let typePopup = SearchOverflowMenuView()
    private var popup: ReaderOverflowMenuView?
    private var groupID: Int64
    private var groups: [BookGroup] = []
    private var books: [Book] = []
    private var visibleBooks: [Book] = []
    private var displayedURLs: [String] = []
    private var cacheInfo: [String: BookCacheInfo] = [:]
    private var cacheErrors: [String: String] = [:]
    private var contentRevisions: [String: UUID] = [:]
    private var infoRevisions: [String: UUID] = [:]
    private var snapshots: [String: CacheDownloadCoordinator.Snapshot] = [:]
    private var downloadRevisions: [String: UUID] = [:]
    private var downloadObservation: UUID?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var exportTask: Task<Void, Never>?
    private var exportID: UUID?
    private var exportBookURL: String?
    private var exportProgress: CacheExportProgress?
    private var exportCancellationRequested = false
    private var exportSharing: CacheExportSharing?
    private var cloudDelivery: CacheExportCloudDelivery?
    private var exportResults: [String: String] = [:]
    private var exportFormat: CacheExportFormat = .txt
    private var menuRequest: CacheExportRequestScope?
    private var exportRequest: CacheExportRequestScope?
    private var rowContext: CacheExportOwnerContext?
    private var rowRefreshTask: Task<Void, Never>?
    private var ready = false
    private var hasLeftPage = false

    init(groupID: Int64 = -1) {
        self.groupID = groupID == -100 ? -1 : groupID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        loadTask?.cancel()
        exportTask?.cancel()
        rowRefreshTask?.cancel()
        Task { @MainActor [screen, downloads, downloadObservation, exportSharing, cloudDelivery] in
            exportSharing?.cancelUndelivered()
            cloudDelivery?.cancel()
            screen.unbind()
            if let downloadObservation { downloads.removeObserver(downloadObservation) }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.CacheManagement.title
        exportFormat = exportPreferences.load()
        configureViews()
        screen.onBooksChange = { [weak self] books in
            self?.books = books
            self?.loadItems()
        }
        screen.onGroupsChange = { [weak self] groups in
            guard let self, !self.hasLeftPage else { return }
            self.groups = groups
            if self.groupID != -1, !groups.contains(where: { $0.groupId == self.groupID }) {
                self.selectGroup(-1)
            } else {
                self.updateToolbar()
                self.loadItems()
            }
        }
        screen.onSortChange = { [weak self] in self?.loadItems() }
        screen.onGroupError = { [weak self] message in
            guard let self, !self.hasLeftPage else { return }
            self.showTransientMessage(message)
        }
        do {
            try screen.bootstrap(groupID: groupID)
            ready = true
        } catch {
            emptyLabel.text = error.userFacingMessage
        }
        downloadObservation = downloads.observe { [weak self] snapshots in
            guard let self, !self.hasLeftPage else { return }
            let previous = self.snapshots
            self.snapshots = snapshots
            var finished = false
            for (url, snapshot) in snapshots {
                if previous[url]?.isActive != snapshot.isActive { self.downloadRevisions[url] = UUID() }
                if previous[url]?.phase != snapshot.phase || previous[url]?.cached != snapshot.cached
                    || previous[url]?.total != snapshot.total
                {
                    self.contentRevisions[url] = UUID()
                }
                if previous[url]?.isActive == true, !snapshot.isActive { finished = true }
            }
            self.updateToolbar()
            self.reloadList()
            if finished { self.loadItems() }
        }
        updateToolbar()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        refreshRowContext()
        reloadList()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            emptyLabel.font = ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .footnote, compatibleWith: traitCollection)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        popup?.dismiss()
        typePopup.dismiss()
        menuRequest?.finish()
        rowContext?.finish()
        rowContext = nil
        rowRefreshTask?.cancel()
        rowRefreshTask = nil
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            exportRequest?.invalidate()
            cancelExport()
            exportSharing?.cancelUndelivered()
            cloudDelivery?.cancel()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard
            isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true
                || navigationController?.viewControllers.contains(where: { $0 === self }) == false
        else { return }
        hasLeftPage = true
        loadID = UUID()
        loadTask?.cancel()
        cancelExport()
        exportSharing?.cancelUndelivered()
        cloudDelivery?.cancel()
        screen.unbind()
        if let downloadObservation { downloads.removeObserver(downloadObservation) }
        downloadObservation = nil
        // CacheBook work belongs to the process, not this page's navigation lifetime.
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.background
        let backdrop = UIView()
        backdrop.backgroundColor = AndroidReplicaTheme.toolbarBackground
        backdrop.isUserInteractionEnabled = false
        toolbar.backButton.addTarget(self, action: #selector(back), for: .touchUpInside)
        toolbar.downloadButton.addTarget(self, action: #selector(toggleDownloads), for: .touchUpInside)
        toolbar.groupButton.addTarget(self, action: #selector(showGroups), for: .touchUpInside)
        toolbar.moreButton.addTarget(self, action: #selector(showMore), for: .touchUpInside)
        toolbar.downloadButton.addGestureRecognizer(
            UILongPressGestureRecognizer(target: self, action: #selector(downloadLongPress(_:))))
        toolbar.downloadButton.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "下载选项", target: self, selector: #selector(downloadOptionsAccessibility))
        ]
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 92
        tableView.backgroundColor = AndroidReplicaTheme.background
        // CacheActivity installs no item decoration; item_download has no divider.
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.register(AndroidCacheBookCell.self, forCellReuseIdentifier: AndroidCacheBookCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "cacheManagement.table"
        emptyLabel.text = L10n.Common.loadingTitle
        emptyLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .footnote, compatibleWith: traitCollection)
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.accessibilityIdentifier = "cacheManagement.empty"
        for item in [backdrop, toolbar, tableView, emptyLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func updateToolbar() {
        let running = snapshots.values.contains(where: \.isActive)
        let groupName = groups.first { $0.groupId == groupID }?.groupName ?? "未分组"
        toolbar.update(
            subtitle: groupName, isRunning: running, enabled: ready,
            canDownload: running || visibleBooks.contains(where: { !$0.isLocal && exportBookURL != $0.bookUrl }),
            isStopping: running && !snapshots.values.contains(where: { $0.phase == .running }))
    }

    private func loadItems() {
        guard !hasLeftPage else { return }
        loadTask?.cancel()
        let id = UUID()
        loadID = id
        let group = groupID
        let sourceBooks = books
        loadTask = Task { [weak self, screen] in
            do {
                let mode = try await screen.sortMode(groupID: group)
                guard let self, !Task.isCancelled, self.loadID == id else { return }
                self.visibleBooks = CacheManagementListPolicy.sort(sourceBooks, mode: mode)
                self.emptyLabel.text = L10n.CacheManagement.empty
                self.emptyLabel.isHidden = !self.visibleBooks.isEmpty
                self.updateToolbar()
                self.reloadList()
                for book in self.visibleBooks {
                    let revision = self.contentRevisions[book.bookUrl]
                    do {
                        let info = try await screen.cacheInfo(book)
                        guard !Task.isCancelled, self.loadID == id, !self.hasLeftPage else { return }
                        guard self.contentRevisions[book.bookUrl] == revision else { continue }
                        self.cacheInfo[book.bookUrl] = info
                        self.infoRevisions[book.bookUrl] = revision
                        self.cacheErrors[book.bookUrl] = nil
                    } catch {
                        guard !Task.isCancelled, self.loadID == id, !self.hasLeftPage else { return }
                        guard self.contentRevisions[book.bookUrl] == revision else { continue }
                        self.cacheErrors[book.bookUrl] = error.userFacingMessage
                    }
                    self.reloadList()
                }
                if self.loadID == id { self.loadTask = nil }
            } catch {
                guard let self, !Task.isCancelled, self.loadID == id, !self.hasLeftPage else { return }
                self.loadTask = nil
                self.emptyLabel.text = error.userFacingMessage
                self.emptyLabel.isHidden = !self.visibleBooks.isEmpty
                if !self.visibleBooks.isEmpty { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func reloadList() {
        refreshRowContext()
        let offset = tableView.contentOffset
        let urls = visibleBooks.map(\.bookUrl)
        if displayedURLs == urls {
            // Progress payloads update the existing controls, preserving an in-flight touch.
            UIView.performWithoutAnimation {
                for case let cell as AndroidCacheBookCell in tableView.visibleCells {
                    guard let index = tableView.indexPath(for: cell)?.row, visibleBooks.indices.contains(index) else {
                        continue
                    }
                    configure(cell, book: visibleBooks[index])
                }
                tableView.performBatchUpdates(nil)
            }
        } else {
            displayedURLs = urls
            tableView.reloadData()
        }
        tableView.layoutIfNeeded()
        let y = min(max(0, offset.y), max(0, tableView.contentSize.height - tableView.bounds.height))
        tableView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
    }

    private var canInteract: Bool {
        guard ready, !hasLeftPage, canPerformNavigationAction,
            let window = viewIfLoaded?.window, AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        return true
    }

    private func refreshRowContext() {
        guard canInteract, rowContext?.isCurrent() != true else { return }
        rowContext?.finish()
        rowContext = CacheExportOwnerContext(owner: self)
        rowContext?.startMonitoring(
            allowing: { nil },
            onInvalidated: { [weak self] in
                self?.rowRefreshTask?.cancel()
                self?.rowRefreshTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                        guard let self, !self.hasLeftPage else { return }
                        if self.canInteract {
                            self.rowRefreshTask = nil
                            self.reloadList()
                            return
                        }
                    }
                }
            })
    }

    private func request(_ targets: [Book]? = nil, format: CacheExportFormat? = nil) -> CacheExportRequestScope? {
        guard canInteract else { return nil }
        let group = groupID
        return CacheExportRequestScope(
            owner: self, groupID: group, targets: targets ?? visibleBooks, groups: groups,
            format: format ?? exportFormat,
            selectionIsCurrent: { [weak self] in self?.groupID == group && self?.hasLeftPage == false })
    }

    @objc private func back() {
        guard canInteract else { return }
        navigationController?.popViewController(animated: true)
    }

    @objc private func toggleDownloads() {
        guard canInteract else { return }
        if snapshots.values.contains(where: \.isActive) {
            downloads.stopAll()
        } else {
            startDownloads(visibleBooks, fromCurrent: true)
        }
    }

    private func startDownloads(_ targets: [Book], fromCurrent: Bool) {
        guard canInteract else { return }
        for book in targets where !book.isLocal && exportBookURL != book.bookUrl {
            downloads.start(book: book, startIndex: fromCurrent ? max(0, Int(book.durChapterIndex)) : 0)
        }
    }

    @objc private func downloadLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { showDownloadOptions() }
    }

    @objc private func downloadOptionsAccessibility() -> Bool {
        guard canInteract else { return false }
        showDownloadOptions()
        return true
    }

    private func showDownloadOptions() {
        guard let request = request() else { return }
        let stopping = downloadRevisions.filter { snapshots[$0.key]?.isActive == true }
        presentPopup(
            [
                item("download.after", title: "下载之后章节", request: request) {
                    $0.performDownloadOption(request, stopping: stopping, fromCurrent: true)
                },
                item("download.all", title: "下载全部章节", request: request) {
                    $0.performDownloadOption(request, stopping: stopping, fromCurrent: false)
                },
            ], anchor: toolbar.downloadButton, request: request)
    }

    private func performDownloadOption(_ request: CacheExportRequestScope, stopping: [String: UUID], fromCurrent: Bool)
    {
        if stopping.isEmpty {
            guard !snapshots.values.contains(where: \.isActive) else { return }
            startDownloads(request.targets, fromCurrent: fromCurrent)
        } else {
            for (url, revision) in stopping where downloadRevisions[url] == revision && snapshots[url]?.isActive == true
            {
                downloads.stop(bookURL: url)
            }
        }
    }

    @objc private func showGroups() {
        guard let request = request() else { return }
        let entries = request.groups.enumerated().map { index, group in
            item("group.\(index)", title: group.groupName, request: request) { $0.selectGroup(group.groupId) }
        }
        presentPopup(entries, anchor: toolbar.groupButton, request: request)
    }

    private func selectGroup(_ id: Int64) {
        guard id != groupID else { return }
        menuRequest?.finish()
        exportRequest?.invalidate()
        rowContext?.finish()
        rowContext = nil
        groupID = id
        loadID = UUID()
        loadTask?.cancel()
        books = []
        visibleBooks = []
        displayedURLs = []
        emptyLabel.text = L10n.Common.loadingTitle
        emptyLabel.isHidden = false
        tableView.reloadData()
        updateToolbar()
        screen.selectGroup(id)
    }

    @objc private func showMore() {
        guard let request = request() else { return }
        var entries = [
            item(
                "export.all", title: "导出全部",
                enabled: exportRequest == nil && !request.targets.isEmpty, request: request
            ) { $0.configureExport(request.targets, format: request.format, anchor: $0.toolbar.moreButton) },
            item("export.type", title: "导出类型(\(request.format.title))", request: request) { $0.showExportTypes() },
            item("log", title: "日志", request: request) {
                $0.present(ReaderAppLogDialogViewController(), animated: true)
            },
        ]
        if exportTask != nil {
            let cancellationID = exportID
            entries.insert(
                item(
                    "export.cancel", title: exportCancellationRequested ? "正在取消导出..." : "取消导出",
                    enabled: !exportCancellationRequested, request: request
                ) { if $0.exportID == cancellationID { $0.cancelExport() } }, at: 1)
        }
        presentPopup(entries, anchor: toolbar.moreButton, request: request)
    }

    private func showExportTypes() {
        guard let request = request() else { return }
        menuRequest?.finish()
        menuRequest = request
        popup?.dismiss()
        typePopup.canActivateItem = { [weak request] in request?.isCurrent() == true }
        typePopup.onVisibilityChange = { visible in
            if !visible { Task { @MainActor in request.finish() } }
        }
        typePopup.show(
            in: view, anchor: toolbar.moreButton,
            items: CacheExportFormat.allCases.map {
                .init(id: $0.rawValue, title: $0.title, selection: .radio, isSelected: exportFormat == $0)
            }
        ) { [weak self] id in
            guard let self, self.canInteract, request.consume(), let format = CacheExportFormat(rawValue: id) else {
                return
            }
            request.finish()
            self.exportFormat = format
            self.exportPreferences.save(format)
            self.reloadList()
        }
    }

    private func item(
        _ id: String, title: String, enabled: Bool = true, request: CacheExportRequestScope,
        action: @escaping (CacheViewController) -> Void
    ) -> ReaderOverflowMenuView.Item {
        .init(identifier: "cacheManagement." + id, title: title, isEnabled: enabled) { [weak self] in
            guard let self, enabled, self.canInteract, request.consume() else { return }
            request.finish()
            action(self)
        }
    }

    private func presentPopup(_ items: [ReaderOverflowMenuView.Item], anchor: UIView, request: CacheExportRequestScope)
    {
        guard canInteract, anchor.window === view.window else { return }
        popup?.dismiss()
        typePopup.dismiss()
        menuRequest?.finish()
        menuRequest = request
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: anchor, interfaceStyle: traitCollection.userInterfaceStyle)
        popup = menu
        menu.onDismiss = { [weak self, weak menu] in
            if self?.popup === menu { self?.popup = nil }
            // Selection is dispatched synchronously after onDismiss; outside dismissals expire next turn.
            Task { @MainActor in request.finish() }
        }
        menu.present(in: view)
    }

    private func configureExport(_ targets: [Book], format: CacheExportFormat? = nil, anchor: UIView) {
        guard exportRequest == nil, !targets.isEmpty, let request = request(targets, format: format) else { return }
        exportRequest = request
        let controller = CacheExportOptionsViewController(
            options: exportOptionsPreferences.load(), format: request.format,
            isRequestCurrent: { [weak request] in request?.isCurrent() == true },
            onClose: { [weak self, weak request] in
                guard let self, let request, self.exportRequest === request, self.exportID == nil else { return }
                request.finish()
                self.exportRequest = nil
                self.reloadList()
            },
            onExport: { [weak self, weak anchor] options in
                guard let self, self.canInteract, self.exportRequest === request, request.consume(),
                    self.exportTask == nil,
                    self.exportSharing == nil, self.cloudDelivery == nil
                else { return }
                self.exportOptionsPreferences.save(options)
                request.presentation = nil
                self.export(
                    request.targets, format: request.format, options: options, anchor: anchor ?? self.toolbar.moreButton
                )
            })
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        request.presentation = navigation
        request.onInvalidated = { [weak controller] in controller?.invalidateRequest() }
        present(navigation, animated: true)
    }

    private func export(_ targets: [Book], format: CacheExportFormat, options: CacheExportOptions, anchor: UIView) {
        guard canInteract, let request = exportRequest, request.isCurrent(), exportTask == nil,
            exportSharing == nil, cloudDelivery == nil, !targets.isEmpty
        else { return }
        let capturedSession: BookExportCloudSession?
        do {
            capturedSession =
                options.destination == .webDAV
                ? try BookExportCloudFacade.companion.create().startSession() : nil
        } catch {
            request.finish()
            exportRequest = nil
            showTransientMessage(error.userFacingMessage)
            reloadList()
            return
        }
        let id = request.id
        exportID = id
        request.onInvalidated = { [weak self] in self?.cancelExport() }
        exportCancellationRequested = false
        exportProgress = nil
        for book in targets { exportResults[book.bookUrl] = nil }
        exportTask = Task { [weak self, exporter] in
            var pendingSession = capturedSession
            var prepared: [CacheExportSharing.Item] = []
            var failedCount = 0
            var wasCancelled = false
            var preparedUploadBytes: Int64 = 0
            defer {
                pendingSession?.close()
                for item in prepared {
                    item.result.cleanup()
                    if self?.exportID == id {
                        self?.exportResults[item.bookURL] = item.undeliveredMessage(
                            cancelled: Task.isCancelled || wasCancelled)
                    }
                }
                self?.finishExport(id: id)
            }
            for book in targets {
                guard let self, request.isCurrent(), !self.hasLeftPage, self.exportID == id, !Task.isCancelled else {
                    break
                }
                if self.snapshots[book.bookUrl]?.isActive == true {
                    self.exportResults[book.bookUrl] = "正在下载，请完成后导出"
                    failedCount += 1
                    self.reloadList()
                    continue
                }
                self.exportBookURL = book.bookUrl
                self.exportProgress = nil
                self.exportResults[book.bookUrl] = nil
                self.updateToolbar()
                self.reloadList()
                defer {
                    if self.exportID == id {
                        self.exportBookURL = nil
                        self.exportProgress = nil
                        if !self.hasLeftPage {
                            self.updateToolbar()
                            self.reloadList()
                        }
                    }
                }
                do {
                    let result = try await exporter.exportConfigured(book, format: format, options: options) {
                        [weak self] progress in
                        guard let self, self.exportID == id, self.exportBookURL == book.bookUrl,
                            !self.hasLeftPage, !self.exportCancellationRequested
                        else { return }
                        self.exportProgress = progress
                        self.reloadList()
                    }
                    guard !Task.isCancelled, request.isCurrent(), !self.hasLeftPage, self.exportID == id else {
                        result.cleanup()
                        self.exportResults[book.bookUrl] = "已取消导出"
                        wasCancelled = true
                        break
                    }
                    if options.destination == .webDAV {
                        let bytes = result.uploadPayloads.reduce(Int64(0)) { $0 + Int64($1.size) }
                        guard bytes <= 128 * 1024 * 1024 - preparedUploadBytes else {
                            result.cleanup()
                            throw NSError(
                                domain: "io.legado.cache.export", code: -5,
                                userInfo: [NSLocalizedDescriptionKey: "多书上传总量超过 128 MiB，请分批导出"])
                        }
                        preparedUploadBytes += bytes
                    }
                    prepared.append(.init(bookURL: book.bookUrl, result: result))
                    self.exportResults[book.bookUrl] =
                        result.isPartial
                        ? "内容不完整：\(result.missingContentMessage)（待交付）" : "已准备 \(result.files.count) 个文件，待交付"
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        self.exportResults[book.bookUrl] = "已取消导出"
                        wasCancelled = true
                        break
                    }
                    self.exportResults[book.bookUrl] = error.userFacingMessage
                    failedCount += 1
                }
            }
            guard let self, !self.hasLeftPage, self.exportID == id, !Task.isCancelled, !wasCancelled else { return }
            guard !prepared.isEmpty else {
                if failedCount > 0, self.canInteract {
                    self.showTransientMessage("导出失败 \(failedCount) 本，没有可分享的内容")
                }
                return
            }
            guard request.isCurrent(), self.canInteract else { return }
            // Delivery coordinators take over presentation monitoring; the request stays busy until their callback.
            request.endMonitoring()
            let items = prepared
            if options.destination == .webDAV {
                let delivery = CacheExportCloudDelivery(items: items, failedCount: failedCount, session: pendingSession)
                pendingSession = nil
                self.cloudDelivery = delivery
                prepared = []
                delivery.present(
                    from: self,
                    canContinue: { [weak self] in
                        guard let self else { return false }
                        return !self.hasLeftPage && self.exportID == id
                    }
                ) { [weak self, weak delivery] outcome in
                    guard let self, let delivery, self.cloudDelivery === delivery else { return }
                    self.cloudDelivery = nil
                    for item in items { self.exportResults[item.bookURL] = outcome.message(for: item) }
                    self.finishExport(id: id)
                    guard !self.hasLeftPage else { return }
                    self.reloadList()
                    guard self.canInteract else { return }
                    self.showTransientMessage(outcome.summary)
                }
                return
            }
            let sharing = CacheExportSharing(items: items, failedCount: failedCount)
            self.exportSharing = sharing
            prepared = []
            sharing.present(
                from: self, anchor: anchor, canPresent: { [weak self] in self?.canInteract == true }
            ) { [weak self, weak sharing] completed, error in
                guard let self, let sharing, self.exportSharing === sharing else { return }
                self.exportSharing = nil
                for item in items {
                    if error != nil {
                        self.exportResults[item.bookURL] = "分享失败，请重试"
                    } else if item.result.isPartial {
                        let status = completed ? "已分享，内容不完整" : "未分享，内容不完整"
                        self.exportResults[item.bookURL] = "\(status)：\(item.result.missingContentMessage)"
                    } else {
                        self.exportResults[item.bookURL] = completed ? "导出完成" : "已取消分享"
                    }
                }
                self.finishExport(id: id)
                guard !self.hasLeftPage else { return }
                self.reloadList()
                guard self.canInteract else { return }
                if error != nil {
                    self.showTransientMessage("分享失败，请重试")
                } else if completed {
                    self.showTransientMessage(
                        CacheExportSharing.completionMessage(for: items, failedCount: failedCount))
                }
            }
        }
    }

    private func cancelExport() {
        guard exportTask != nil, !exportCancellationRequested else { return }
        exportCancellationRequested = true
        exportProgress = nil
        exportTask?.cancel()
        if !hasLeftPage { reloadList() }
    }

    private func finishExport(id: UUID) {
        guard exportID == id else { return }
        exportBookURL = nil
        exportProgress = nil
        exportTask = nil
        guard exportSharing == nil, cloudDelivery == nil else { return }
        exportCancellationRequested = false
        exportID = nil
        exportRequest?.finish()
        exportRequest = nil
        guard !hasLeftPage else { return }
        updateToolbar()
        reloadList()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { visibleBooks.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: AndroidCacheBookCell.reuseIdentifier, for: indexPath)
            as! AndroidCacheBookCell
        configure(cell, book: visibleBooks[indexPath.row])
        return cell
    }

    private func configure(_ cell: AndroidCacheBookCell, book: Book) {
        let url = book.bookUrl
        let state = snapshots[url]
        let info = cacheInfo[url]
        let measured = state?.hasProgress == true && (info == nil || infoRevisions[url] != contentRevisions[url])
        let cached = measured ? state!.cached : Int(info?.cachedCount ?? 0)
        let total = measured ? state!.total : Int(info?.totalCount ?? 0)
        let text =
            book.isLocal
            ? L10n.CacheManagement.localBook
            : (measured || info != nil ? "已下载 \(cached)/\(total)" : L10n.Common.loadingTitle)
        let isExporting = exportBookURL == url
        let progress = isExporting ? exportProgress : nil
        // Keep independent failures visible; a stale export result must not hide a new stop/error payload.
        let messages: [String?] = [
            isExporting
                ? (exportCancellationRequested
                    ? "正在取消导出..."
                    : (progress?.fraction == nil ? L10n.CacheManagement.exporting : nil))
                : exportResults[url],
            state?.message, cacheErrors[url],
        ]
        var details: [String] = []
        for case let message? in messages where !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !details.contains(message) { details.append(message) }
        }
        if !details.isEmpty, let progress, progress.total > 0, !exportCancellationRequested {
            details.insert("\(L10n.CacheManagement.exporting) \(progress.completed)/\(progress.total)", at: 0)
        }
        let message = details.isEmpty ? nil : details.joined(separator: "\n")
        cell.configure(
            .init(
                bookURL: url, name: book.name, author: book.getRealAuthor(),
                cacheText: text, message: message, isLocal: book.isLocal,
                isRunning: state?.isActive == true, isStopping: state?.phase == .stopping,
                canDownload: ready && exportBookURL != url,
                canExport: exportRequest == nil && state?.isActive != true,
                isExporting: isExporting, exportProgress: progress?.fraction))
        let context = rowContext
        let group = groupID
        let format = exportFormat
        let downloadRevision = downloadRevisions[url]
        var consumed = false
        cell.onDownload = { [weak self] in
            guard let self, let context, self.rowContext === context, !consumed, group == self.groupID,
                context.isCurrent(), self.canInteract
            else { return }
            consumed = true
            if state?.isActive == true {
                guard self.downloadRevisions[url] == downloadRevision, self.snapshots[url]?.isActive == true else {
                    return
                }
                self.downloads.stop(bookURL: url)
            } else if self.exportBookURL != url, self.snapshots[url]?.isActive != true {
                self.downloads.start(book: book, startIndex: 0)
            }
        }
        cell.onExport = { [weak self, weak cell] in
            guard let self, let context, self.rowContext === context, !consumed, group == self.groupID,
                context.isCurrent(), self.canInteract
            else { return }
            consumed = true
            self.configureExport([book], format: format, anchor: cell?.exportAnchor ?? self.tableView)
        }
    }
}
