import UIKit
import shared

@MainActor
final class ReadRecordViewController: UIViewController, NavigationCustomToolbarProviding,
    UITableViewDataSource, UITableViewDelegate
{
    private let toolbar = ReadRecordToolbarView()
    private let summary = ReadRecordSummaryView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let status = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var facade: ReadRecordFacade?
    private var records: [ReadRecordShow] = []
    private var totalTime: Int64 = 0
    private var recordingEnabled = true
    private var sortMode = min(max(UserDefaults.standard.integer(forKey: "readRecordSort"), 0), 2)
    private var query = ""
    private var generation = UUID()
    private var visible = false
    private var covered = false
    private var loading = false
    private var busy = false
    private var hasLoadFailure = false
    private var loadTask: Task<Void, Never>?
    private var work: Task<Void, Never>?
    private weak var confirmation: ReaderRestoreProgressDialogViewController?
    private lazy var menus = SourceManagementMenuCoordinator(
        host: view, canPresent: { [weak self] in self?.canUsePage == true },
        onCoverageChange: { [weak self] covered in
            self?.covered = covered
            self?.refreshInteraction()
        })

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Settings.readRecordTitle
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = "readRecord.root"
        navigationController?.setNavigationBarHidden(true, animated: false)
        configureViews()
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
        do { facade = try BootstrapApiKt.sharedReadRecordFacade() } catch { showFailure(error) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        generation = UUID()
        loadTask?.cancel()
        menus.dismiss()
        view.endEditing(true)
        confirmation?.dismiss(animated: false)
        refreshInteraction()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        menus.refreshLayout()
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private var ownsPage: Bool {
        visible && !isMovingFromParent && !isBeingDismissed
            && navigationController?.topViewController === self
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var canUsePage: Bool { ownsPage && !busy && presentedViewController == nil }

    private func configureViews() {
        toolbar.onBack = { [weak self] in self?.navigationController?.popViewController(animated: true) }
        toolbar.onQueryChange = { [weak self] value in
            guard let self else { return }
            self.query = value
            self.reload(debounce: true)
        }
        toolbar.onSubmit = { [weak self] in self?.view.endEditing(true) }
        toolbar.onSort = { [weak self] in self?.showSort() }
        toolbar.onMore = { [weak self] in self?.showMore() }
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = AndroidReplicaTheme.background
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 92
        table.keyboardDismissMode = .onDrag
        table.register(ReadRecordTableViewCell.self, forCellReuseIdentifier: ReadRecordTableViewCell.reuseIdentifier)
        table.accessibilityIdentifier = "readRecord.table"
        status.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        status.titleLabel?.numberOfLines = 0
        status.setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
        status.addTarget(self, action: #selector(retry), for: .touchUpInside)
        status.accessibilityIdentifier = "readRecord.status"
        for item in [toolbar, summary, table, status, spinner] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summary.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: summary.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            status.centerXAnchor.constraint(equalTo: table.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: table.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            spinner.centerXAnchor.constraint(equalTo: table.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: table.centerYAnchor),
        ])
        renderSummary()
    }

    @objc private func retry() { reload() }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, viewIfLoaded?.window?.windowScene === scene else { return }
        if notification.name == UIScene.didActivateNotification {
            if visible { reload() }
        } else {
            generation = UUID()
            loadTask?.cancel()
            menus.dismiss()
            confirmation?.dismiss(animated: false)
        }
        refreshInteraction()
    }

    private func reload(debounce: Bool = false) {
        guard visible, !busy, let facade else { return }
        loadTask?.cancel()
        let id = UUID()
        generation = id
        let requestedQuery = query
        loading = true
        hasLoadFailure = false
        status.isHidden = true
        if records.isEmpty { spinner.startAnimating() }
        refreshInteraction()
        loadTask = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(nanoseconds: 180_000_000) }
                try Task.checkCancellation()
                let snapshot = try await facade.load(query: requestedQuery)
                try Task.checkCancellation()
                guard let self, self.generation == id, self.ownsPage else { return }
                self.totalTime = snapshot.totalReadTime
                self.recordingEnabled = snapshot.enabled
                self.records = self.sorted(snapshot.records)
                self.loading = false
                self.spinner.stopAnimating()
                self.status.setTitle(L10n.Settings.readRecordEmpty, for: .normal)
                self.status.isEnabled = false
                self.status.isHidden = !self.records.isEmpty
                self.table.reloadData()
                self.renderSummary()
                self.refreshInteraction()
                self.loadTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.generation == id, self.ownsPage else { return }
                self.loading = false
                self.loadTask = nil
                self.showFailure(error)
            }
        }
    }

    private func sorted(_ rows: [ReadRecordShow]) -> [ReadRecordShow] {
        rows.sorted { left, right in
            if sortMode == 1, left.readTime != right.readTime { return left.readTime > right.readTime }
            if sortMode == 2, left.lastRead != right.lastRead { return left.lastRead > right.lastRead }
            return left.bookName.compare(right.bookName, options: [], locale: Locale(identifier: "zh_CN")) == .orderedAscending
        }
    }

    private func showSort() {
        guard canUsePage, !loading else { return }
        let titles = ["名称排序", "阅读时长排序", "阅读时间排序"]
        menus.showSort(
            anchor: toolbar.sortButton,
            items: titles.enumerated().map { index, title in
                SearchOverflowMenuView.Item(
                    id: "readRecord.sort.\(index)", title: title, selection: .radio, isSelected: sortMode == index)
            }
        ) { [weak self] value in
            guard let self, let index = Int(value.split(separator: ".").last ?? ""), (0...2).contains(index) else { return }
            self.sortMode = index
            UserDefaults.standard.set(index, forKey: "readRecordSort")
            self.records = self.sorted(self.records)
            self.table.reloadData()
        }
    }

    private func showMore() {
        guard canUsePage, !loading else { return }
        menus.showSort(
            anchor: toolbar.moreButton,
            items: [.init(id: "readRecord.enabled", title: "开启记录", selection: .checkbox, isSelected: recordingEnabled)]
        ) { [weak self] _ in
            guard let self, let facade = self.facade else { return }
            let enabled = !self.recordingEnabled
            self.mutate { try await facade.setEnabled(enabled: enabled) }
        }
    }

    private func renderSummary() {
        summary.configure(
            totalTime: ReadRecordPresentation.duration(totalTime), canClear: !busy && !loading && !covered && !hasLoadFailure
        ) { [weak self] in
            self?.confirmDelete(bookName: nil)
        }
    }

    private func refreshInteraction() {
        let enabled = canUsePage && !covered
        toolbar.setInteractionEnabled(enabled)
        toolbar.sortButton.isEnabled = enabled && !loading
        toolbar.moreButton.isEnabled = enabled && !loading
        toolbar.backButton.isEnabled = true
        table.isUserInteractionEnabled = enabled && !loading && !hasLoadFailure
        renderSummary()
    }

    private func confirmDelete(bookName: String?) {
        guard canUsePage, !loading, !covered else { return }
        let id = generation
        let dialog = ReaderRestoreProgressDialogViewController(
            title: "删除", message: bookName.map { "是否确认删除 \($0)？" } ?? "是否确认删除？",
            accessibilityIdentifierPrefix: "readRecord.delete"
        ) { [weak self] approved in
            guard approved, let self, self.generation == id, self.canUsePage, let facade = self.facade else { return }
            self.mutate {
                if let bookName { try await facade.deleteByName(bookName: bookName) } else { try await facade.clear() }
            }
        }
        dialog.canConfirm = { [weak self] in
            guard let self else { return false }
            return self.ownsPage && !self.busy && self.generation == id
                && (bookName == nil || self.records.contains { $0.bookName == bookName })
        }
        confirmation = dialog
        dialog.onClose = { [weak self] in self?.confirmation = nil }
        present(dialog, animated: true)
    }

    private func mutate(_ operation: @escaping () async throws -> Void) {
        guard canUsePage, work == nil else { return }
        loadTask?.cancel()
        generation = UUID()
        busy = true
        refreshInteraction()
        work = Task { [weak self] in
            var failure: Error?
            do { try await operation() } catch { failure = error }
            guard let self else { return }
            self.work = nil
            self.busy = false
            guard self.ownsPage else { return }
            if let failure { self.showFailure(failure) } else { self.reload() }
        }
    }

    private func showFailure(_ error: Error) {
        hasLoadFailure = true
        spinner.stopAnimating()
        status.setTitle(error.userFacingMessage + "\n" + L10n.Common.retry, for: .normal)
        status.isEnabled = true
        status.isHidden = false
        refreshInteraction()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { records.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: ReadRecordTableViewCell.reuseIdentifier, for: indexPath)
            as! ReadRecordTableViewCell
        let record = records[indexPath.row]
        cell.configure(
            bookName: record.bookName, time: ReadRecordPresentation.duration(record.readTime),
            lastRead: ReadRecordPresentation.date(record.lastRead), canClear: !busy && !loading
        ) { [weak self] in
            self?.confirmDelete(bookName: record.bookName)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard canUsePage, !loading, !covered, records.indices.contains(indexPath.row), let facade else { return }
        let name = records[indexPath.row].bookName
        let id = generation
        busy = true
        refreshInteraction()
        work = Task { [weak self] in
            do {
                let book = try await facade.findBook(bookName: name)
                guard let self else { return }
                self.work = nil
                self.busy = false
                guard self.generation == id, self.canUsePage else {
                    if self.ownsPage { self.reload() }
                    return
                }
                self.refreshInteraction()
                if let book {
                    BookReadingDestination.open(book, from: self)
                } else {
                    self.navigationController?.pushViewController(
                        AndroidReplicaSearchViewController(initialKeyword: name).configuredForDrillDownPresentation(),
                        animated: true)
                }
            } catch {
                guard let self else { return }
                self.work = nil
                self.busy = false
                if self.generation == id, self.ownsPage { self.showFailure(error) }
            }
        }
    }
}

enum ReadRecordPresentation {
    static func duration(_ milliseconds: Int64) -> String {
        let seconds = max(milliseconds, 0) / 1000
        let units: [(Int64, String)] = [
            (seconds / 86400, "天"), ((seconds % 86400) / 3600, "小时"), ((seconds % 3600) / 60, "分钟"), (seconds % 60, "秒"),
        ]
        let value = units.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined()
        return value.isEmpty ? "0秒" : value
    }

    static func date(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}
