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
        scanNotice = DirectorySelectionNotice.summary(issues: issues, isTruncated: isTruncated, count: files.count)
        self.onSelection = onSelection
        super.init(style: .insetGrouped)
        title = "选择书籍"
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "确认", style: .done, target: self, action: #selector(confirmSelection))
        search.searchResultsUpdater = self
        search.delegate = self
        search.obscuresBackgroundDuringPresentation = false
        search.hidesNavigationBarDuringPresentation = false
        search.searchBar.placeholder = "按文件名或路径筛选"
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
        escape.discoverabilityTitle = "取消"
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
        section == 1 ? "文件（\(matchingIndices.count)）" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1, !isUpdating, matchingIndices.isEmpty else { return nil }
        if !query.isEmpty { return "没有文件名或路径匹配的文件" }
        return scanNotice == nil ? "没有可导入的文件" : "本次扫描未找到可导入的文件"
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
            content.text = isTruncated ? "仅显示部分扫描结果" : "部分项目未能扫描"
            content.secondaryText = scanNotice
            content.image = UIImage(systemName: "exclamationmark.triangle")
            cell.selectionStyle = .none
            cell.accessibilityTraits = .staticText
        } else if indexPath.row == displayedCount {
            content.text = "继续显示"
            content.secondaryText = "已显示 \(displayedCount) / \(matchingIndices.count) 项"
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
                details.append("修改于 " + modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }
            content.secondaryText = details.joined(separator: "\n")
            content.image = UIImage(systemName: selected ? "checkmark.square.fill" : "square")
            cell.selectionStyle = .default
            cell.accessibilityTraits = selected ? [.button, .selected] : [.button]
            cell.accessibilityValue = selected ? "已选择" : "未选择"
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
            label.lineBreakMode = .byCharWrapping
            label.adjustsFontForContentSizeCategory = true
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
            title: "排序",
            children: DirectorySelectionSort.allCases.map { option in
                UIAction(title: option.title, state: option == sort ? .on : .off) { [weak self] _ in
                    guard let self, canInteract, option != sort else { return }
                    sort = option
                    updateSortMenu()
                    refreshResults(debounced: false)
                }
            })
        sortButton.accessibilityLabel = "排序：\(sort.title)"
        sortButton.toolTip = sortButton.accessibilityLabel
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let active = canInteract
        let canChoose = active && !isUpdating
        countLabel.text = "已选 \(selectedIndices.count) 项，共 \(rows.count) 项"
        if isUpdating {
            scopeLabel.text = query.isEmpty ? "正在整理文件…" : "正在筛选…"
        } else if query.isEmpty {
            scopeLabel.text = "已显示 \(displayedCount) / \(matchingIndices.count) 项"
        } else {
            scopeLabel.text = "匹配 \(matchingIndices.count) 项，已选 \(matchingSelectionCount) 项"
        }
        let allSelected = !matchingIndices.isEmpty && matchingSelectionCount == matchingIndices.count
        let scope = query.isEmpty ? "全部结果" : "筛选结果"
        selectAllButton.setImage(UIImage(systemName: allSelected ? "minus.square" : "checkmark.square"), for: .normal)
        selectAllButton.accessibilityLabel = (allSelected ? "取消选择" : "全选") + scope
        selectAllButton.toolTip = selectAllButton.accessibilityLabel
        invertButton.accessibilityLabel = "反选" + scope
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
        case .name: return "名称（自然路径升序）"
        case .size: return "大小（从大到小）"
        case .modifiedAt: return "修改时间（从新到旧）"
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
        directory = parent.isEmpty || parent == "." ? "所选目录" : parent
        searchName = Self.searchKey(name + "\n" + candidate.relativePath)
        let ext = candidate.url.pathExtension.uppercased()
        let format = LocalBookArchiveType(fileName: candidate.url.lastPathComponent).map { "\($0.displayName) 压缩包" } ?? ext
        let size =
            candidate.byteCount < 0
            ? "大小未知"
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

private enum DirectorySelectionNotice {
    static func summary(issues: [LocalBookImportIssue], isTruncated: Bool, count: Int) -> String? {
        guard isTruncated || !issues.isEmpty else { return nil }
        var lines: [String] = []
        if isTruncated { lines.append("扫描提前结束，以下 \(count) 个文件不代表整个目录。") }
        if !issues.isEmpty {
            lines.append("扫描遇到 \(issues.count) 项问题。部分项目无法完整读取，请核对以下提示。")
            for issue in issues.prefix(3) {
                let normalized = issue.fileName.replacingOccurrences(of: "\\", with: "/")
                let component = (normalized as NSString).lastPathComponent
                let name = component.isEmpty || component == "." || component == "/" ? "所选目录" : component
                lines.append("\(String(name.prefix(80)))：\(message(issue.message))")
            }
            if issues.count > 3 { lines.append("另有 \(issues.count - 3) 项扫描问题。") }
        }
        return lines.joined(separator: "\n")
    }

    private static func message(_ raw: String) -> String {
        let technical = ["Error Domain=", "NSCocoaError", "NSPOSIXError", "UserInfo=", "NSError", "stack trace"]
        guard !technical.contains(where: { raw.localizedCaseInsensitiveContains($0) }) else {
            return "无法读取该项目，请检查访问权限及文件是否可用。"
        }
        let pathPattern = #"(?i)(?<![a-z0-9_])(?:file://|[a-z]:[\\/]|~/|/)[^\s\"'<>，。；：！？（）【】]+"#
        let sanitized = raw.replacingOccurrences(of: pathPattern, with: "[文件路径]", options: .regularExpression)
            .components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty { return "无法读取该项目。" }
        return sanitized.count > 160 ? String(sanitized.prefix(160)) + "…" : sanitized
    }
}
