import UIKit

/// The owner dismisses the sheet and keeps its directory read lease until import settles.
@MainActor
final class LocalBookDirectorySelectionViewController: UITableViewController,
    UIAdaptivePresentationControllerDelegate, UISearchResultsUpdating, UISearchControllerDelegate
{
    private let rows: [DirectorySelectionRow]
    private let scanNotice: String?
    private let isTruncated: Bool
    private var onSelection: (([URL]?) -> Void)?
    private var selectedIndices = Set<Int>()
    private var matchingIndices: [Int] = []
    private var matchingSelectionCount = 0
    private var displayedCount = 0
    private let pageSize = 200
    private var sort: DirectorySelectionSort = .name
    private var sortedOrders: [DirectorySelectionSort: [Int]] = [:]
    private var query = ""
    private var requestID = UUID()
    private var filterTask: Task<Void, Never>?
    private var isUpdating = true
    private var hasCompleted = false
    private var isVisible = false
    private var environmentSuspended = false
    private var hasBoundContext = false
    private weak var sourceWindow: UIWindow?
    private weak var sourceScene: UIWindowScene?
    private weak var sourceRoot: UIViewController?
    private weak var presentationHost: UIViewController?

    private let search = UISearchController(searchResultsController: nil)
    private let controls = UIView()
    private let countLabel = UILabel()
    private let scopeLabel = UILabel()
    private let selectAllButton = UIButton(type: .system)
    private let invertButton = UIButton(type: .system)
    private let sortButton = UIButton(type: .system)

    init(
        files: [LocalBookDirectoryCandidate], issues: [LocalBookImportIssue], isTruncated: Bool,
        onSelection: @escaping ([URL]?) -> Void
    ) {
        rows = files.map(DirectorySelectionRow.init)
        self.isTruncated = isTruncated
        scanNotice = DirectorySelectionText.summary(issues: issues, isTruncated: isTruncated, count: files.count)
        self.onSelection = onSelection
        super.init(style: .insetGrouped)
        title = DirectorySelectionText.title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        filterTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.tintColor = AndroidReplicaTheme.accent
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 100
        tableView.sectionFooterHeight = UITableView.automaticDimension
        tableView.estimatedSectionFooterHeight = 36
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "local-book.directory-selection"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancelFromUI))
        navigationItem.leftBarButtonItem?.accessibilityLabel = L10n.Common.cancel
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: L10n.Common.confirm, style: .done, target: self, action: #selector(confirmSelection))
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.placeholder = DirectorySelectionText.searchPlaceholder
        search.searchBar.accessibilityLabel = DirectorySelectionText.searchPlaceholder
        search.searchBar.accessibilityIdentifier = "local-book.directory-selection.search"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        configureControls()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        refreshResults(debounced: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let host: UIViewController = navigationController ?? self
        if host.presentingViewController != nil {
            presentationHost = host
            host.presentationController?.delegate = self
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasBoundContext {
            hasBoundContext = true
            sourceWindow = view.window
            sourceScene = sourceWindow?.windowScene
            sourceRoot = sourceWindow?.rootViewController
        }
        isVisible = true
        environmentSuspended = false
        if !search.isActive { becomeFirstResponder() }
        updateControls()
        DispatchQueue.main.async { [weak self] in self?.updateControls() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        isVisible = false
        updateControls()
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let host = presentationHost,
            host.isBeingDismissed || host.presentingViewController == nil
        {
            complete(nil)
        } else if isMovingFromParent
            || (navigationController.map { navigation in
                !navigation.viewControllers.contains(where: { $0 === self })
            } ?? false)
        {
            complete(nil)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resizeControls()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { resizeControls() }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelFromUI))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        cancelSelection()
        return true
    }

    // Cancellation is also available to the owner while its scene is covered or inactive.
    func cancelSelection() { complete(nil) }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        canInteract
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { complete(nil) }

    func didPresentSearchController(_ searchController: UISearchController) { updateControls() }
    func didDismissSearchController(_ searchController: UISearchController) { updateControls() }

    func updateSearchResults(for searchController: UISearchController) {
        guard !hasCompleted else { return }
        let next = DirectorySelectionRow.searchKey(searchController.searchBar.text ?? "")
        guard next != query else { return }
        query = next
        refreshResults(debounced: true)
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return scanNotice == nil ? 0 : 1 }
        return displayedCount + (displayedCount < matchingIndices.count ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? DirectorySelectionText.filesHeader(matchingIndices.count) : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1, !isUpdating, matchingIndices.isEmpty else { return nil }
        if !query.isEmpty { return DirectorySelectionText.noMatches }
        return scanNotice == nil ? DirectorySelectionText.noFiles : DirectorySelectionText.scanEmpty
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "directory-result")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "directory-result")
        configure(cell, at: indexPath)
        return cell
    }

    private func configure(_ cell: UITableViewCell, at indexPath: IndexPath) {
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = AndroidReplicaTheme.primaryText
        content.textProperties.numberOfLines = 0
        content.textProperties.lineBreakMode = .byCharWrapping
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = AndroidReplicaTheme.secondaryText
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.lineBreakMode = .byCharWrapping
        content.imageProperties.maximumSize = CGSize(width: 26, height: 26)
        cell.accessoryType = .none
        cell.accessibilityValue = nil
        cell.accessibilityIdentifier = nil
        if indexPath.section == 0 {
            content.text = isTruncated ? DirectorySelectionText.truncatedTitle : DirectorySelectionText.scanIssueTitle
            content.secondaryText = scanNotice
            content.image = UIImage(systemName: "exclamationmark.triangle")
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
        } else if indexPath.row == displayedCount {
            content.text = DirectorySelectionText.showMore
            content.secondaryText = DirectorySelectionText.shown(displayedCount, total: matchingIndices.count)
            content.image = UIImage(systemName: "chevron.down")
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = "local-book.directory-selection.more"
        } else {
            let index = matchingIndices[indexPath.row]
            let row = rows[index]
            let selected = selectedIndices.contains(index)
            content.text = row.name
            var details = [row.directory, row.metadata]
            if let modifiedAt = row.candidate.modifiedAt {
                details.append(
                    DirectorySelectionText.modified(modifiedAt.formatted(date: .abbreviated, time: .shortened)))
            }
            content.secondaryText = details.joined(separator: "\n")
            content.image = UIImage(systemName: selected ? "checkmark.square.fill" : "square")
            cell.selectionStyle = .default
            cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
            cell.accessibilityValue = selected ? DirectorySelectionText.selected : DirectorySelectionText.unselected
            cell.accessibilityIdentifier = "local-book.directory-selection.file.\(index)"
        }
        cell.contentConfiguration = content
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canInteract, !isUpdating, indexPath.section == 1 else { return }
        if indexPath.row == displayedCount {
            appendPage()
            return
        }
        guard indexPath.row < displayedCount else { return }
        let index = matchingIndices[indexPath.row]
        if selectedIndices.remove(index) == nil {
            selectedIndices.insert(index)
            matchingSelectionCount += 1
        } else {
            matchingSelectionCount -= 1
        }
        if let cell = tableView.cellForRow(at: indexPath) { configure(cell, at: indexPath) }
        updateControls()
    }

    private func appendPage() {
        let oldCount = displayedCount
        guard oldCount < matchingIndices.count else { return }
        displayedCount = min(oldCount + pageSize, matchingIndices.count)
        // Replace the paging row, rather than reloading all earlier pages.
        tableView.performBatchUpdates {
            tableView.deleteRows(at: [IndexPath(row: oldCount, section: 1)], with: .none)
            let end = displayedCount + (displayedCount < matchingIndices.count ? 1 : 0)
            tableView.insertRows(at: (oldCount..<end).map { IndexPath(row: $0, section: 1) }, with: .none)
        }
        updateControls()
    }

    private func configureControls() {
        for label in [countLabel, scopeLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        countLabel.font = .preferredFont(forTextStyle: .headline)
        countLabel.textColor = AndroidReplicaTheme.primaryText
        countLabel.accessibilityIdentifier = "local-book.directory-selection.count"
        scopeLabel.font = .preferredFont(forTextStyle: .subheadline)
        scopeLabel.textColor = AndroidReplicaTheme.secondaryText
        scopeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = [selectAllButton, invertButton, sortButton]
        let symbols = ["checkmark.square", "arrow.triangle.2.circlepath", "arrow.up.arrow.down"]
        for (button, symbol) in zip(buttons, symbols) {
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.tintColor = AndroidReplicaTheme.accent
            button.setPreferredSymbolConfiguration(.init(pointSize: 20, weight: .regular), forImageIn: .normal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44),
            ])
        }
        selectAllButton.addTarget(self, action: #selector(toggleAll), for: .touchUpInside)
        selectAllButton.accessibilityIdentifier = "local-book.directory-selection.select-all"
        invertButton.addTarget(self, action: #selector(invertSelection), for: .touchUpInside)
        invertButton.accessibilityIdentifier = "local-book.directory-selection.invert"
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.accessibilityIdentifier = "local-book.directory-selection.sort"
        let tools = UIStackView(arrangedSubviews: [scopeLabel] + buttons)
        tools.alignment = .center
        tools.spacing = 4
        let stack = UIStackView(arrangedSubviews: [countLabel, tools])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: controls.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -20),
        ])
        controls.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 100)
        tableView.tableHeaderView = controls
        updateSortMenu()
    }

    private func resizeControls() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        let size = controls.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height)
        guard controls.frame.width != width || controls.frame.height != height else { return }
        controls.frame = CGRect(x: 0, y: 0, width: width, height: height)
        tableView.tableHeaderView = controls
    }

    private func updateSortMenu() {
        sortButton.menu = UIMenu(
            title: DirectorySelectionText.sortTitle,
            children: DirectorySelectionSort.allCases.map { option in
                UIAction(title: option.title, state: option == sort ? .on : .off) { [weak self] _ in
                    guard let self, canInteract, option != sort else { return }
                    sort = option
                    updateSortMenu()
                    refreshResults(debounced: false)
                }
            })
        sortButton.accessibilityLabel = DirectorySelectionText.sortLabel(sort.title)
        sortButton.toolTip = sortButton.accessibilityLabel
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let active = canInteract
        let canChoose = active && !isUpdating
        countLabel.text = DirectorySelectionText.selectionCount(selectedIndices.count, total: rows.count)
        if isUpdating {
            scopeLabel.text = query.isEmpty ? DirectorySelectionText.organizing : DirectorySelectionText.filtering
        } else if query.isEmpty {
            scopeLabel.text = DirectorySelectionText.shown(displayedCount, total: matchingIndices.count)
        } else {
            scopeLabel.text = DirectorySelectionText.matchingCount(
                matchingIndices.count, selected: matchingSelectionCount)
        }
        let allSelected = !matchingIndices.isEmpty && matchingSelectionCount == matchingIndices.count
        selectAllButton.setImage(UIImage(systemName: allSelected ? "minus.square" : "checkmark.square"), for: .normal)
        selectAllButton.accessibilityLabel = DirectorySelectionText.selectAllAction(
            deselect: allSelected, filtered: !query.isEmpty)
        selectAllButton.toolTip = selectAllButton.accessibilityLabel
        invertButton.accessibilityLabel = DirectorySelectionText.invertAction(filtered: !query.isEmpty)
        invertButton.toolTip = invertButton.accessibilityLabel
        selectAllButton.isEnabled = canChoose && !matchingIndices.isEmpty
        invertButton.isEnabled = canChoose && !matchingIndices.isEmpty
        sortButton.isEnabled = active && !rows.isEmpty
        navigationItem.leftBarButtonItem?.isEnabled = active
        navigationItem.rightBarButtonItem?.isEnabled = canChoose && !selectedIndices.isEmpty
        search.searchBar.isUserInteractionEnabled = active
        tableView.isUserInteractionEnabled = canChoose
        resizeControls()
    }

    @objc private func toggleAll() {
        guard canInteract, !isUpdating else { return }
        if matchingSelectionCount == matchingIndices.count {
            selectedIndices.subtract(matchingIndices)
            matchingSelectionCount = 0
        } else {
            selectedIndices.formUnion(matchingIndices)
            matchingSelectionCount = matchingIndices.count
        }
        selectionChanged()
    }

    @objc private func invertSelection() {
        guard canInteract, !isUpdating else { return }
        for index in matchingIndices {
            if selectedIndices.remove(index) == nil { selectedIndices.insert(index) }
        }
        matchingSelectionCount = matchingIndices.count - matchingSelectionCount
        selectionChanged()
    }

    private func selectionChanged() {
        for indexPath in tableView.indexPathsForVisibleRows ?? [] where indexPath.section == 1 {
            if let cell = tableView.cellForRow(at: indexPath) { configure(cell, at: indexPath) }
        }
        updateControls()
    }

    private func refreshResults(debounced: Bool) {
        filterTask?.cancel()
        let id = UUID()
        requestID = id
        isUpdating = true
        updateControls()
        let rows = rows
        let order = sortedOrders[sort]
        let requestedSort = sort
        let requestedQuery = query
        filterTask = Task { [weak self] in
            if debounced {
                do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .userInitiated) {
                DirectorySelectionIndex.make(rows: rows, order: order, sort: requestedSort, query: requestedQuery)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, !hasCompleted, requestID == id, let result else { return }
            sortedOrders[requestedSort] = result.order
            matchingIndices = result.matches
            matchingSelectionCount = result.matches.reduce(0) { $0 + (selectedIndices.contains($1) ? 1 : 0) }
            displayedCount = min(pageSize, result.matches.count)
            isUpdating = false
            filterTask = nil
            tableView.reloadData()
            updateControls()
        }
    }

    private var canInteract: Bool {
        guard isVisible, !hasCompleted, !environmentSuspended,
            UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
            let window = sourceWindow, viewIfLoaded?.window === window,
            window.windowScene === sourceScene, window.rootViewController === sourceRoot,
            sourceScene?.activationState == .foregroundActive,
            window.isKeyWindow, !window.isHidden, window.alpha > 0.01,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        var ancestor: UIViewController? = self
        while let current = ancestor {
            guard !current.isBeingPresented, !current.isBeingDismissed,
                !current.isMovingFromParent, !current.isMovingToParent,
                current.transitionCoordinator == nil,
                current.presentedViewController == nil || current.presentedViewController === search
            else { return false }
            if let navigation = current.parent as? UINavigationController,
                navigation.topViewController !== current
            {
                return false
            }
            if let tabs = current.parent as? UITabBarController,
                tabs.selectedViewController !== current
            {
                return false
            }
            ancestor = current.parent
        }
        return true
    }

    @objc private func environmentChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== sourceScene { return }
        if let window = notification.object as? UIWindow, window !== sourceWindow { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeHiddenNotification, .appLockWillCover:
            environmentSuspended = true
            view.endEditing(true)
        default:
            environmentSuspended = false
        }
        updateControls()
        DispatchQueue.main.async { [weak self] in self?.updateControls() }
    }

    @objc private func cancelFromUI() {
        guard canInteract else { return }
        cancelSelection()
    }

    @objc private func confirmSelection() {
        guard canInteract, !isUpdating, !selectedIndices.isEmpty else { return }
        let urls = rows.indices.compactMap { selectedIndices.contains($0) ? rows[$0].candidate.url : nil }
        complete(urls)
    }

    private func complete(_ urls: [URL]?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        filterTask?.cancel()
        filterTask = nil
        let callback = onSelection
        onSelection = nil
        viewIfLoaded?.endEditing(true)
        updateControls()
        callback?(urls)
    }
}

private enum DirectorySelectionSort: CaseIterable, Sendable {
    case name, size, modifiedAt

    var title: String {
        switch self {
        case .name: return DirectorySelectionText.sortName
        case .size: return DirectorySelectionText.sortSize
        case .modifiedAt: return DirectorySelectionText.sortModified
        }
    }
}

private struct DirectorySelectionRow: Sendable {
    let candidate: LocalBookDirectoryCandidate
    let path: String
    let name: String
    let directory: String
    let searchName: String
    let metadata: String

    init(_ candidate: LocalBookDirectoryCandidate) {
        self.candidate = candidate
        path = candidate.relativePath
        let component = (candidate.relativePath as NSString).lastPathComponent
        name = component.isEmpty ? candidate.url.lastPathComponent : component
        let parent = (candidate.relativePath as NSString).deletingLastPathComponent
        directory = parent.isEmpty || parent == "." ? DirectorySelectionText.selectedDirectory : parent
        searchName = Self.searchKey(name + "\n" + candidate.relativePath)
        let ext = candidate.url.pathExtension.uppercased()
        let format =
            LocalBookArchiveType(fileName: candidate.url.lastPathComponent).map {
                DirectorySelectionText.archive($0.displayName)
            } ?? ext
        let size =
            candidate.byteCount < 0
            ? DirectorySelectionText.unknownSize
            : ByteCountFormatter.string(fromByteCount: candidate.byteCount, countStyle: .file)
        metadata = [format, size].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    static func searchKey(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }
}

private struct DirectorySelectionIndex: Sendable {
    let order: [Int]
    let matches: [Int]

    static func make(
        rows: [DirectorySelectionRow], order: [Int]?, sort: DirectorySelectionSort, query: String
    ) -> Self? {
        guard !Task.isCancelled else { return nil }
        let sorted =
            order
            ?? rows.indices.sorted { left, right in
                let lhs = rows[left]
                let rhs = rows[right]
                switch sort {
                case .name: break
                case .size:
                    if lhs.candidate.byteCount != rhs.candidate.byteCount {
                        return lhs.candidate.byteCount > rhs.candidate.byteCount
                    }
                case .modifiedAt:
                    switch (lhs.candidate.modifiedAt, rhs.candidate.modifiedAt) {
                    case let (a?, b?) where a != b: return a > b
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: break
                    }
                }
                let comparison = lhs.path.localizedStandardCompare(rhs.path)
                return comparison == .orderedSame ? left < right : comparison == .orderedAscending
            }
        guard !Task.isCancelled else { return nil }
        if query.isEmpty { return Self(order: sorted, matches: sorted) }
        var matches: [Int] = []
        for (offset, index) in sorted.enumerated() {
            if offset.isMultiple(of: 128), Task.isCancelled { return nil }
            if rows[index].searchName.contains(query) { matches.append(index) }
        }
        return Self(order: sorted, matches: matches)
    }
}

enum DirectorySelectionText {
    static let title = text("title", "选择书籍")
    static let searchPlaceholder = text("search_placeholder", "按文件名或路径筛选")
    static let noMatches = text("no_matches", "没有文件名或路径匹配的文件")
    static let noFiles = text("no_files", "没有可导入的文件")
    static let scanEmpty = text("scan_empty", "本次扫描未找到可导入的文件")
    static let truncatedTitle = text("truncated_title", "仅显示部分扫描结果")
    static let scanIssueTitle = text("scan_issue_title", "部分项目未能扫描")
    static let showMore = text("show_more", "继续显示")
    static let selected = text("selected", "已选择")
    static let unselected = text("unselected", "未选择")
    static let selectedDirectory = text("selected_directory", "所选目录")
    static let unknownSize = text("unknown_size", "大小未知")
    static let sortTitle = text("sort_title", "排序")
    static let sortName = text("sort_name", "名称（自然路径升序）")
    static let sortSize = text("sort_size", "大小（从大到小）")
    static let sortModified = text("sort_modified", "修改时间（从新到旧）")
    static let organizing = text("organizing", "正在整理文件…")
    static let filtering = text("filtering", "正在筛选…")
    static let readFailure = text("read_failure", "无法读取该项目，请检查访问权限及文件是否可用。")
    static let unreadableItem = text("unreadable_item", "无法读取该项目。")
    static let filePath = text("file_path", "[文件路径]")

    static func filesHeader(_ count: Int) -> String { format("files_header", "文件（%d）", count) }
    static func shown(_ count: Int, total: Int) -> String { format("shown", "已显示 %1$d / %2$d 项", count, total) }
    static func modified(_ date: String) -> String { format("modified", "修改于 %@", date) }
    static func selectionCount(_ count: Int, total: Int) -> String {
        format("selection_count", "已选 %1$d 项，共 %2$d 项", count, total)
    }
    static func matchingCount(_ count: Int, selected: Int) -> String {
        format("matching_count", "匹配 %1$d 项，已选 %2$d 项", count, selected)
    }
    static func sortLabel(_ title: String) -> String { format("sort_label", "排序：%@", title) }
    static func archive(_ type: String) -> String { format("archive", "%@ 压缩包", type) }

    static func selectAllAction(deselect: Bool, filtered: Bool) -> String {
        if deselect { return filtered ? text("deselect_filtered", "取消选择筛选结果") : text("deselect_all", "取消选择全部结果") }
        return filtered ? text("select_filtered", "全选筛选结果") : text("select_all", "全选全部结果")
    }

    static func invertAction(filtered: Bool) -> String {
        filtered ? text("invert_filtered", "反选筛选结果") : text("invert_all", "反选全部结果")
    }

    static func summary(issues: [LocalBookImportIssue], isTruncated: Bool, count: Int) -> String? {
        guard isTruncated || !issues.isEmpty else { return nil }
        var lines: [String] = []
        if isTruncated { lines.append(format("truncated_message", "扫描提前结束，以下 %d 个文件不代表整个目录。", count)) }
        if !issues.isEmpty {
            lines.append(format("scan_issues", "扫描遇到 %d 项问题。部分项目无法完整读取，请核对以下提示。", issues.count))
            for issue in issues.prefix(3) {
                let normalized = issue.fileName.replacingOccurrences(of: "\\", with: "/")
                let component = (normalized as NSString).lastPathComponent
                let name = component.isEmpty || component == "." || component == "/" ? selectedDirectory : component
                lines.append(format("issue_line", "%1$@：%2$@", String(name.prefix(80)), message(issue.message)))
            }
            if issues.count > 3 { lines.append(format("more_issues", "另有 %d 项扫描问题。", issues.count - 3)) }
        }
        return lines.joined(separator: "\n")
    }

    private static func message(_ raw: String) -> String {
        let technical = ["Error Domain=", "NSCocoaError", "NSPOSIXError", "UserInfo=", "NSError", "stack trace"]
        guard !technical.contains(where: { raw.localizedCaseInsensitiveContains($0) }) else {
            return readFailure
        }
        let pathPattern = #"(?i)(?<![a-z0-9_])(?:file://|[a-z]:[\\/]|~/|/)[^\s\"'<>，。；：！？（）【】]+"#
        let owned = ownedIssue(raw)
        let sanitized = (owned ?? raw).replacingOccurrences(
            of: pathPattern, with: filePath, options: .regularExpression
        )
        .components(separatedBy: .newlines).joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { return unreadableItem }
        return owned == nil && sanitized.count > 160 ? String(sanitized.prefix(160)) + "…" : sanitized
    }

    private static func ownedIssue(_ raw: String) -> String? {
        let keys = [
            "请选择有效的本地文件夹。": "invalid_folder",
            "文件提供程序返回了无效的文件夹地址。": "invalid_folder_address",
            "所选项目不是文件夹。": "not_folder",
            "不扫描隐藏文件夹、文件包或无法确认这些属性的文件夹。": "hidden_or_package_folder",
            "已达到 20,000 个扫描项目的上限，结果可能不完整。": "scan_limit",
            "等待读取目录期间文件夹位置发生变化，请重新扫描。": "folder_moved",
            "文件夹属性已变化或无法确认，已跳过读取。": "folder_attributes_changed",
            "无法读取文件夹中的项目。": "cannot_read_folder",
            "文件提供程序返回了无效的目录项目，已跳过。": "invalid_directory_item",
            "项目位于所选文件夹之外，已跳过。": "item_outside_folder",
            "等待读取文件属性期间项目位置发生变化，已跳过。": "item_moved",
            "无法确认项目是否隐藏，已跳过。": "unknown_hidden_attribute",
            "无法确认项目类型，已跳过。": "unknown_item_type",
            "无法确认文件夹是否为文件包，已跳过。": "unknown_package_attribute",
            "已达到 64 层目录深度的上限，更深层项目未扫描。": "depth_limit",
            "无法获取文件大小，暂以 0 字节显示。": "unknown_file_size",
            "文件位于所选文件夹之外，已跳过。": "file_outside_folder",
            "已达到 5,000 个候选文件的上限，结果可能不完整。": "candidate_limit",
            "未能获得文件提供程序的协调读取权限。": "no_coordinated_access",
            "文件提供程序返回了无效的项目地址。": "invalid_item_address",
            "项目位于隐藏文件夹中，已跳过。": "item_in_hidden_folder",
            "项目或其上级文件夹包含符号链接，已跳过。": "item_contains_symlink",
            "不扫描符号链接、替身或无法确认链接属性的项目。": "symlink_or_alias",
            "没有读取权限，请重新选择文件夹并授权。": "no_read_permission",
            "文件或文件夹已不存在，可能已被移动或删除。": "item_missing",
        ]
        if let key = keys[raw] { return text("error." + key, raw) }
        let prefix = "无法获取文件大小或修改时间，大小暂以 0 字节显示。"
        if raw.hasPrefix(prefix), let reason = ownedIssue(String(raw.dropFirst(prefix.count))) {
            return format("error.metadata_unavailable", "无法获取文件大小或修改时间，大小暂以 0 字节显示。%@", reason)
        }
        let pattern = #"\A无法读取项目，文件提供程序可能暂时不可用（错误码：(-?[0-9]+)）。\z"#
        if let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
            let range = Range(match.range(at: 1), in: raw)
        {
            return format("error.provider_unavailable", "无法读取项目，文件提供程序可能暂时不可用（错误码：%@）。", String(raw[range]))
        }
        return nil
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: "consumer.directory_selection." + key, value: fallback, table: nil)
    }

    private static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback), locale: Locale.current, arguments: arguments)
    }
}
