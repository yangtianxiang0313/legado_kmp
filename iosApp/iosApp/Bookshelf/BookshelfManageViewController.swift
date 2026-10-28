import UIKit
import shared

@MainActor
final class BookshelfManageViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UITableViewDragDelegate, UITableViewDropDelegate
{
    let data: BookshelfManageDataController
    let toolbar = BookshelfManageToolbar()
    private let selectionBar = BookshelfManageSelectionBar()
    private let table = UITableView(frame: .zero, style: .plain)
    private lazy var fastScroller = ReaderListFastScroller(tableView: table)
    private lazy var dragSelection = BookshelfDragSelectionController(table: table)
    private lazy var actions = BookshelfManageActions(presenter: self)
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retryButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let statusStack = UIStackView()
    private var rows: [Book] = []
    private struct RowIdentity: Equatable {
        let url: String
        let name: String
        let author: String
        let origin: String
        let group: Int64
        init(_ book: Book) {
            url = book.bookUrl
            name = book.name
            author = book.author
            origin = book.originName
            group = book.group
        }
    }
    private var rowSignature: [RowIdentity] = []
    private var overflow: ReaderOverflowMenuView?
    private var operationTask: Task<Void, Never>?
    private var operationTitle: String?
    private var operationCanCancel = false
    private var operationError: String?
    private var isDraggingRows = false
    private var isScrubbing = false
    private var isActive = false
    private var deferredRender = false
    private var oldInteractivePopEnabled: Bool?
    private(set) var isBusy = false

    init(groupID: Int64 = -1) {
        data = BookshelfManageDataController(groupID: groupID)
        super.init(nibName: nil, bundle: nil)
        title = "书架管理"
        _ = configuredForDrillDownPresentation()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        data.onChange = { [weak self] in self?.render() }
        toolbar.searchField.addTarget(self, action: #selector(filterChanged), for: .editingChanged)
        toolbar.searchField.addTarget(self, action: #selector(endSearch), for: .editingDidEndOnExit)
        toolbar.backButton.addTarget(self, action: #selector(back), for: .touchUpInside)
        toolbar.groupButton.addTarget(self, action: #selector(showGroups), for: .touchUpInside)
        toolbar.moreButton.addTarget(self, action: #selector(showMore), for: .touchUpInside)
        selectionBar.allButton.addTarget(self, action: #selector(selectAllBooks), for: .touchUpInside)
        selectionBar.invertButton.addTarget(self, action: #selector(invert), for: .touchUpInside)
        selectionBar.groupButton.addTarget(self, action: #selector(moveToGroup), for: .touchUpInside)
        selectionBar.moreButton.addTarget(self, action: #selector(showSelectionMore), for: .touchUpInside)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        stopButton.addTarget(self, action: #selector(cancelOperation), for: .touchUpInside)
        fastScroller.onScrubbingChanged = { [weak self] scrubbing in
            guard let self else { return }
            self.isScrubbing = scrubbing
            if !scrubbing && self.deferredRender {
                self.deferredRender = false
                self.render()
            }
            self.updateInteraction()
        }
        dragSelection.canBegin = { [weak self] in self?.canInteract == true && self?.data.isLoading == false }
        dragSelection.orderedURLs = { [weak self] in self?.rows.map(\.bookUrl) ?? [] }
        dragSelection.initialSelection = { [weak self] in self?.data.selection.selectedURLs ?? [] }
        dragSelection.onSelection = { [weak self] in self?.data.replaceSelection($0) }
        dragSelection.onActiveChanged = { [weak self] active in
            guard let self else { return }
            self.data.updatesSuspended = active || self.isBusy
            if !active {
                self.deferredRender = false
                self.render()
            }
            self.updateInteraction()
        }
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isActive = true
        data.bind()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        overflow?.dismiss()
        view.endEditing(true)
        fastScroller.cancelScrubbing()
        dragSelection.cancel()
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            isActive = false
            data.unbind()
            if operationCanCancel { operationTask?.cancel() }
            restoreInteractivePop()
        }
    }

    deinit { operationTask?.cancel() }

    var canInteract: Bool {
        isActive && isVisibleInNavigationStack && viewIfLoaded?.window != nil && !isBusy
            && !isDraggingRows && !isScrubbing && !dragSelection.isSelecting && presentedViewController == nil
    }

    private func configureViews() {
        table.dataSource = self
        table.delegate = self
        table.dragDelegate = self
        table.dropDelegate = self
        table.dragInteractionEnabled = true
        table.backgroundColor = AndroidReplicaTheme.background
        table.separatorStyle = .singleLine
        table.separatorColor = AndroidReplicaTheme.divider
        table.separatorInset = .zero
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 78
        table.contentInsetAdjustmentBehavior = .never
        table.keyboardDismissMode = .onDrag
        table.showsVerticalScrollIndicator = false
        table.accessibilityIdentifier = UIIdentifiers.Bookshelf.manageTable
        table.register(BookshelfManageCell.self, forCellReuseIdentifier: BookshelfManageCell.reuseIdentifier)
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 6
        statusStack.isLayoutMarginsRelativeArrangement = true
        statusStack.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "bookshelf.manage.status"
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.tintColor = AndroidReplicaTheme.accent
        retryButton.accessibilityIdentifier = "bookshelf.manage.retry"
        stopButton.setTitle(L10n.Common.cancel, for: .normal)
        stopButton.tintColor = AndroidReplicaTheme.accent
        stopButton.accessibilityIdentifier = "bookshelf.manage.cancelOperation"
        for child in [spinner, statusLabel, retryButton, stopButton] { statusStack.addArrangedSubview(child) }
        statusLabel.widthAnchor.constraint(equalTo: statusStack.layoutMarginsGuide.widthAnchor).isActive = true
        let body = UIStackView(arrangedSubviews: [toolbar, statusStack, table, selectionBar])
        body.axis = .vertical
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        view.addSubview(fastScroller)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            fastScroller.topAnchor.constraint(equalTo: table.topAnchor, constant: 8),
            fastScroller.bottomAnchor.constraint(equalTo: table.bottomAnchor, constant: -8),
            fastScroller.trailingAnchor.constraint(equalTo: table.trailingAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: 24),
        ])
        fastScroller.apply(accent: AndroidReplicaTheme.accent)
    }

    private func render() {
        guard isViewLoaded else { return }
        if isDraggingRows || isScrubbing {
            deferredRender = true
            return
        }
        if dragSelection.isSelecting {
            deferredRender = true
            updateInteraction()
            return
        }
        toolbar.setGroupName(data.groupName)
        let values = data.visibleBooks
        let signature = values.map(RowIdentity.init)
        rows = values
        if signature != rowSignature {
            let previous = table.indexPathsForVisibleRows?.first.flatMap { path in
                rowSignature.indices.contains(path.row) ? rowSignature[path.row].url : nil
            }
            rowSignature = signature
            table.reloadData()
            if let previous, let index = rows.firstIndex(where: { $0.bookUrl == previous }) {
                table.layoutIfNeeded()
                table.scrollToRow(at: IndexPath(row: index, section: 0), at: .top, animated: false)
            }
            fastScroller.reload()
        } else {
            for case let cell as BookshelfManageCell in table.visibleCells {
                guard let path = table.indexPath(for: cell), rows.indices.contains(path.row) else { continue }
                configure(cell, book: rows[path.row])
            }
        }
        let message = operationError ?? data.error
        let loading = isBusy || data.isLoading
        statusStack.isHidden = !loading && message == nil && !rows.isEmpty
        statusLabel.text = loading ? (operationTitle ?? L10n.Common.loadingTitle) : (message ?? "没有书籍")
        statusLabel.textColor = message == nil ? AndroidReplicaTheme.secondaryText : .systemRed
        spinner.isHidden = !loading
        loading ? spinner.startAnimating() : spinner.stopAnimating()
        retryButton.isHidden = message == nil || isBusy
        stopButton.isHidden = !isBusy || !operationCanCancel
        updateInteraction()
    }

    private func updateInteraction() {
        let enabled = canInteract
        toolbar.setEnabled(enabled)
        // The toolbar remains available for back/filter/group changes while the initial list loads.
        toolbar.backButton.isEnabled = isActive && !isBusy && !isDraggingRows && !isScrubbing
        selectionBar.configure(selected: data.selectedBooks.count, total: rows.count, enabled: enabled && !data.isLoading)
        table.allowsSelection = enabled && !data.isLoading
        fastScroller.isEnabled = isActive && !isBusy && !isDraggingRows && !dragSelection.isSelecting
        for case let cell as BookshelfManageCell in table.visibleCells {
            guard let path = table.indexPath(for: cell), rows.indices.contains(path.row) else { continue }
            configure(cell, book: rows[path.row])
        }
    }

    private func configure(_ cell: BookshelfManageCell, book: Book) {
        let url = book.bookUrl
        cell.configure(
            book: book, groupNames: data.groupNames(for: book.group),
            selected: data.selection.selectedURLs.contains(url), openTitle: data.openTitle,
            enabled: canInteract && !data.isLoading)
        cell.onToggle = { [weak self] in self?.toggle(url) }
        cell.onOpen = { [weak self] in
            guard let self, self.canInteract, self.data.openTitle else { return }
            self.navigationController?.pushViewController(AndroidReplicaBookDetailViewController(bookURL: url), animated: true)
        }
        cell.onGroup = { [weak self] in self?.actions.selectGroups(bookURLs: [url], initial: book.group, additive: false) }
        cell.onDelete = { [weak self] in self?.actions.confirmDelete(bookURLs: [url]) }
        cell.onMove = data.canReorder ? { [weak self] delta in self?.moveBook(url, delta: delta) ?? false } : nil
    }

    func presentationFinished() {
        guard isActive, isVisibleInNavigationStack, presentedViewController == nil else { return }
        data.reload()
        render()
    }

    private func toggle(_ url: String) { if canInteract { data.toggle(url) } }
    @objc private func filterChanged() { if !isBusy { data.query = toolbar.searchField.text ?? "" } }
    @objc private func endSearch() { toolbar.searchField.resignFirstResponder() }
    @objc private func back() { if canInteract { navigationController?.popViewController(animated: true) } }
    @objc private func selectAllBooks() { if canInteract { data.selectAll() } }
    @objc private func invert() { if canInteract { data.invert() } }
    @objc private func moveToGroup() { actions.selectGroups(bookURLs: data.selectedBooks.map(\.bookUrl), initial: 0, additive: false) }
    @objc private func retry() {
        operationError = nil
        data.reload()
    }
    @objc private func cancelOperation() { if operationCanCancel { operationTask?.cancel() } }

    @objc private func showGroups() {
        guard canInteract else { return }
        var items: [ReaderOverflowMenuView.Item] = [
            .init(identifier: "bookshelf.manage.groups.manage", title: "分组管理") { [weak self] in self?.actions.manageGroups() }
        ]
        items += data.groups.map { group in
            .init(identifier: "bookshelf.manage.group.\(group.groupId)", title: group.groupName, isChecked: group.groupId == data.groupID) { [weak self] in
                self?.data.selectGroup(group.groupId)
            }
        }
        showMenu(items, anchor: toolbar.groupButton)
    }

    @objc private func showMore() {
        guard canInteract else { return }
        showMenu(
            [
                .init(identifier: "bookshelf.manage.exportSources", title: "导出所有书的书源") { [weak self] in self?.actions.exportSources() },
                .init(identifier: "bookshelf.manage.openTitle", title: "点击书名打开详情", isChecked: data.openTitle) { [weak self] in self?.actions.toggleOpenTitle()
                },
            ], anchor: toolbar.moreButton)
    }

    @objc private func showSelectionMore() {
        guard canInteract, !data.selectedBooks.isEmpty else { return }
        let urls = data.selectedBooks.map(\.bookUrl)
        let entries: [(String, String, () -> Void)] = [
            ("delete", "删除", { [weak self] in self?.actions.confirmDelete(bookURLs: urls) }),
            ("enable", "允许更新", { [weak self] in self?.actions.setCanUpdate(bookURLs: urls, enabled: true) }),
            ("disable", "禁止更新", { [weak self] in self?.actions.setCanUpdate(bookURLs: urls, enabled: false) }),
            ("addGroup", "加入分组", { [weak self] in self?.actions.selectGroups(bookURLs: urls, initial: 0, additive: true) }),
            ("changeSource", "批量换源", { [weak self] in self?.actions.changeSource(bookURLs: urls) }),
            ("clearCache", "清除缓存", { [weak self] in self?.actions.confirmClearCache(bookURLs: urls) }),
            ("interval", "选中所选区间", { [weak self] in self?.data.selectInterval() }),
        ]
        showMenu(
            entries.map { id, title, action in
                .init(identifier: "bookshelf.manage.selection.\(id)", title: title, handler: action)
            }, anchor: selectionBar.moreButton)
    }

    private func showMenu(_ items: [ReaderOverflowMenuView.Item], anchor: UIView) {
        view.endEditing(true)
        overflow?.dismiss()
        let menu = ReaderOverflowMenuView(items: items, anchorView: anchor, interfaceStyle: traitCollection.userInterfaceStyle)
        overflow = menu
        menu.onDismiss = { [weak self, weak menu] in if self?.overflow === menu { self?.overflow = nil } }
        menu.present(in: view)
    }

    func performOperation(
        _ title: String, cancellable: Bool = false,
        operation: @escaping () async throws -> String?, completion: (() -> Void)? = nil
    ) {
        guard canInteract else { return }
        isBusy = true
        operationError = nil
        operationTitle = title
        operationCanCancel = cancellable
        data.updatesSuspended = true
        if let recognizer = navigationController?.interactivePopGestureRecognizer {
            oldInteractivePopEnabled = recognizer.isEnabled
            recognizer.isEnabled = false
        }
        render()
        operationTask = Task { @MainActor [weak self] in
            var message: String?
            do { message = try await operation() } catch is CancellationError {} catch { self?.operationError = error.userFacingMessage }
            guard let self else { return }
            self.isBusy = false
            self.operationTask = nil
            self.operationTitle = nil
            self.operationCanCancel = false
            self.restoreInteractivePop()
            self.data.updatesSuspended = false
            self.data.reload()
            self.render()
            guard self.isActive, self.isVisibleInNavigationStack, self.viewIfLoaded?.window != nil else { return }
            if let message { self.showTransientMessage(message) }
            completion?()
        }
    }

    func updateOperationProgress(_ current: Int32, total: Int32) {
        guard isBusy else { return }
        operationTitle = "批量换源 \(current)/\(total)"
        render()
    }

    private func restoreInteractivePop() {
        if let value = oldInteractivePopEnabled { navigationController?.interactivePopGestureRecognizer?.isEnabled = value }
        oldInteractivePopEnabled = nil
    }

    @discardableResult
    func moveBook(_ url: String, delta: Int) -> Bool {
        guard canInteract, data.canReorder, let from = rows.firstIndex(where: { $0.bookUrl == url }) else { return false }
        return reorderBook(from: from, to: from + delta)
    }

    private func reorderBook(from: Int, to: Int) -> Bool {
        guard data.canReorder, !isBusy, !isScrubbing, rows.indices.contains(from), rows.indices.contains(to), from != to else { return false }
        let old = rows
        var moved = rows
        moved.insert(moved.remove(at: from), at: to)
        let orders = Set(old.map(\.order)).count == old.count ? old.map(\.order) : old.indices.map { Int32($0 + 1) }
        let updates = zip(moved, orders).filter { $0.0.order != $0.1 }.map { ($0.0.bookUrl, $0.1) }
        data.previewOrder(moved)
        rows = moved
        rowSignature = moved.map(RowIdentity.init)
        table.moveRow(at: IndexPath(row: from, section: 0), to: IndexPath(row: to, section: 0))
        // Native drops keep their touch ancestor enabled; persistence starts after the drag settles.
        isDraggingRows = false
        data.updatesSuspended = false
        performOperation("保存排序") {
            let facade = try SharedRuntime.bookshelfFacade().get()
            for (url, order) in updates { try await facade.updateBookOrderAsync(bookUrl: url, newOrder: order) }
            return nil
        }
        return isBusy
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { rows.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard rows.indices.contains(indexPath.row),
            let cell = tableView.dequeueReusableCell(withIdentifier: BookshelfManageCell.reuseIdentifier, for: indexPath) as? BookshelfManageCell
        else { return UITableViewCell() }
        configure(cell, book: rows[indexPath.row])
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        if canInteract, rows.indices.contains(indexPath.row) { data.toggle(rows[indexPath.row].bookUrl) }
    }
    func tableView(_: UITableView, itemsForBeginning _: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard canInteract, data.canReorder, rows.indices.contains(indexPath.row) else { return [] }
        let url = rows[indexPath.row].bookUrl
        let item = UIDragItem(itemProvider: NSItemProvider(object: url as NSString))
        item.localObject = url
        return [item]
    }
    func tableView(_: UITableView, dragSessionWillBegin _: UIDragSession) {
        isDraggingRows = true
        data.updatesSuspended = true
        updateInteraction()
    }
    func tableView(_: UITableView, dragSessionDidEnd _: UIDragSession) {
        isDraggingRows = false
        if !isBusy { data.updatesSuspended = false }
        if deferredRender {
            deferredRender = false
            render()
        }
        updateInteraction()
    }
    func tableView(_: UITableView, canHandle session: UIDropSession) -> Bool { session.localDragSession != nil && data.canReorder }
    func tableView(_: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath _: IndexPath?) -> UITableViewDropProposal {
        .init(operation: data.canReorder && !isBusy && session.localDragSession != nil ? .move : .cancel, intent: .insertAtDestinationIndexPath)
    }
    func tableView(_: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let item = coordinator.items.first, let url = item.dragItem.localObject as? String,
            let from = rows.firstIndex(where: { $0.bookUrl == url }), !rows.isEmpty
        else { return }
        let to = min(rows.count - 1, max(0, coordinator.destinationIndexPath?.row ?? rows.count - 1))
        if reorderBook(from: from, to: to) { coordinator.drop(item.dragItem, toRowAt: IndexPath(row: to, section: 0)) }
    }
}
