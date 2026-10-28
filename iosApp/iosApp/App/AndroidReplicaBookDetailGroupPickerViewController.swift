import UIKit
import shared

@MainActor
final class AndroidReplicaBookDetailGroupPickerViewController: UIViewController {
    var onGroupsChanged: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let loadGroups: () async throws -> [BookGroup]
    private let saveGroup: (Int64, BookGroupEditDraft) async throws -> BookGroup
    private let deleteGroup: (Int64) async throws -> Void
    private let reorderGroups: ([Int64]) async throws -> Void
    private let observeGroups: ((@escaping ([BookGroup]) -> Void) throws -> FlowSubscription)?
    private let commit: (Int64) async throws -> Void
    private let content = BookGroupPickerContentView()
    private var tableView: UITableView { content.tableView }
    private var groups: [BookGroup] = []
    private var pendingGroups: [BookGroup]?
    private var draftGroupID: Int64
    private var hasLoaded = false
    private var isLoading = false
    private var isSavingGroup = false
    private var isDeletingGroup = false
    private var isReordering = false
    private var isCommitting = false
    private var isDraggingGroups = false
    private var isActive = false
    private var isClosing = false
    private var loadError: String?
    private var commitError: String?
    private var shouldRetryCommit = false
    private var loadGeneration = UUID()
    private var observationGeneration = UUID()
    private var loadTask: Task<Void, Never>?
    private var observation: FlowSubscription?
    private weak var presentationOwner: UIViewController?
    private var editor: BookGroupEditorViewController?

    init(
        groupID: Int64, loadGroups: @escaping () async throws -> [BookGroup],
        saveGroup: @escaping (Int64, BookGroupEditDraft) async throws -> BookGroup,
        deleteGroup: @escaping (Int64) async throws -> Void,
        reorderGroups: @escaping ([Int64]) async throws -> Void,
        observeGroups: ((@escaping ([BookGroup]) -> Void) throws -> FlowSubscription)? = nil,
        commit: @escaping (Int64) async throws -> Void
    ) {
        draftGroupID = groupID
        self.loadGroups = loadGroups
        self.saveGroup = saveGroup
        self.deleteGroup = deleteGroup
        self.reorderGroups = reorderGroups
        self.observeGroups = observeGroups
        self.commit = commit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        loadTask?.cancel()
        observation?.cancel()
    }

    override func loadView() { view = content }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.addButton.addTarget(self, action: #selector(addGroup), for: .touchUpInside)
        content.cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        content.backdrop.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        content.confirmButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        content.retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if presentationOwner == nil {
            var owner = presentingViewController
            while let current = owner {
                if let navigation = current as? UINavigationController {
                    owner = navigation.topViewController
                } else if let tabs = current as? UITabBarController {
                    owner = tabs.selectedViewController
                } else {
                    break
                }
            }
            presentationOwner = owner
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isActive = true
        if editor == nil { becomeFirstResponder() }
        if !hasLoaded, !isLoading, loadError == nil { reloadGroups() }
        startObserving()
        render()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || presentingViewController == nil
            || presentingViewController?.isBeingDismissed == true
            || presentationOwner?.isBeingDismissed == true || presentationOwner?.isMovingFromParent == true
        {
            deactivate()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        cancel()
        return true
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        super.dismiss(animated: flag) { [weak self] in
            if let self, self.presentingViewController == nil {
                let callback = self.onDismiss
                self.onDismiss = nil
                callback?()
            }
            completion?()
        }
    }

    private var canUseUI: Bool {
        guard isActive, !isClosing, !isBeingDismissed, viewIfLoaded?.window != nil,
            let presenter = presentingViewController, !presenter.isBeingDismissed,
            let owner = presentationOwner, !owner.isBeingDismissed, !owner.isMovingFromParent,
            owner.viewIfLoaded?.window != nil
        else { return false }
        if let navigation = owner.navigationController, navigation.topViewController !== owner { return false }
        if let tabs = owner.tabBarController, let selected = tabs.selectedViewController,
            selected !== owner, selected !== owner.navigationController
        {
            return false
        }
        return true
    }

    private var isBusy: Bool { isSavingGroup || isDeletingGroup || isReordering || isCommitting }
    private var canMove: Bool { canUseUI && hasLoaded && !isLoading && !isBusy && editor == nil }
    private var canEdit: Bool { canMove && !isDraggingGroups && presentedViewController == nil }

    private func render() {
        content.addButton.isEnabled = canEdit
        content.confirmButton.isEnabled = canEdit
        content.cancelButton.isEnabled = canUseUI && !isBusy && !isDraggingGroups && editor == nil
        content.backdrop.isUserInteractionEnabled = content.cancelButton.isEnabled
        tableView.allowsSelection = canEdit
        isModalInPresentation = isBusy || isDraggingGroups
        for case let cell as BookGroupPickerRowCell in tableView.visibleCells { cell.setEnabled(canEdit) }
        let error = loadError ?? commitError
        let loading = isLoading || (!hasLoaded && error == nil)
        content.statusStack.isHidden = !loading && error == nil
        content.statusLabel.text = loading ? L10n.Common.loadingTitle : error
        content.statusLabel.textColor = error == nil ? AndroidReplicaTheme.secondaryText : .systemRed
        content.spinner.isHidden = !loading
        loading ? content.spinner.startAnimating() : content.spinner.stopAnimating()
        content.retryButton.isHidden = loading || error == nil
        content.retryButton.isEnabled = canUseUI && !isBusy && editor == nil
        content.setNeedsLayout()
    }

    private func sortedGroups(_ values: [BookGroup]) -> [BookGroup] {
        var seen = Set<Int64>()
        return values.enumerated().filter { $0.element.groupId >= 0 && seen.insert($0.element.groupId).inserted }
            .sorted { $0.element.order == $1.element.order ? $0.offset < $1.offset : $0.element.order < $1.element.order }
            .map(\.element)
    }

    private func acceptGroups(_ loaded: [BookGroup]) {
        guard canUseUI else { return }
        let values = sortedGroups(loaded)
        loadTask?.cancel()
        loadTask = nil
        loadGeneration = UUID()
        hasLoaded = true
        isLoading = false
        loadError = nil
        if isBusy || isDraggingGroups || editor != nil {
            pendingGroups = values
            render()
            return
        }
        groups = values
        tableView.reloadData()
        render()
    }

    private func flushGroups() {
        guard !isBusy, !isDraggingGroups, editor == nil, let pending = pendingGroups else { return }
        pendingGroups = nil
        acceptGroups(pending)
    }

    private func startObserving() {
        guard observation == nil, let observeGroups, canUseUI else { return }
        let generation = UUID()
        observationGeneration = generation
        do {
            observation = try observeGroups { [weak self] values in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.observationGeneration == generation else { return }
                    self.acceptGroups(values)
                }
            }
        } catch {
            loadError = error.userFacingMessage
            render()
        }
    }

    private func reloadGroups() {
        guard canUseUI, !isBusy else { return }
        loadTask?.cancel()
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadError = nil
        render()
        let operation = loadGroups
        loadTask = Task { @MainActor [weak self, operation] in
            do {
                let loaded = try await operation()
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.acceptGroups(loaded)
            } catch {
                guard !Task.isCancelled, let self, self.canUseUI, self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.isLoading = false
                self.loadError = error.userFacingMessage
                self.render()
            }
        }
    }

    @objc private func retry() {
        guard canUseUI, !isBusy, editor == nil else { return }
        if loadError != nil {
            reloadGroups()
            startObserving()
        } else if commitError != nil {
            if shouldRetryCommit {
                confirm()
            } else {
                commitError = nil
                reloadGroups()
            }
        }
    }

    @objc private func confirm() {
        guard canEdit else { return }
        isCommitting = true
        commitError = nil
        shouldRetryCommit = false
        render()
        let value = draftGroupID
        let operation = commit
        Task { @MainActor [weak self, operation] in
            do {
                try await operation(value)
                guard let self else { return }
                self.isCommitting = false
                guard self.canUseUI else { return }
                self.isClosing = true
                self.deactivate()
                self.dismiss(animated: true)
            } catch {
                guard let self else { return }
                self.isCommitting = false
                guard self.canUseUI else { return }
                self.commitError = error.userFacingMessage
                self.shouldRetryCommit = true
                self.render()
            }
        }
    }

    @objc private func addGroup() { openEditor(group: nil) }

    private func openEditor(group: BookGroup?) {
        guard canEdit else { return }
        let controller = BookGroupEditorViewController(group: group)
        controller.onSave = { [weak self] draft in self?.save(draft: draft, groupID: group?.groupId ?? 0) }
        controller.onDelete = { [weak self] in
            guard let self, let group, group.groupId > 0, let editor = self.editor,
                editor.presentedViewController == nil, !self.isBusy
            else { return }
            let confirmation = UIAlertController(title: L10n.Common.delete, message: "确定删除？", preferredStyle: .alert)
            confirmation.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak editor] _ in editor?.setBusy(false) })
            confirmation.addAction(UIAlertAction(title: L10n.Common.confirm, style: .destructive) { [weak self] _ in self?.removeGroup(group.groupId) })
            editor.present(confirmation, animated: true)
        }
        controller.onCancel = { [weak self] in self?.cancelEditor() }
        editor = controller
        content.panel.accessibilityElementsHidden = true
        render()
        present(controller, animated: true)
    }

    private func save(draft: BookGroupEditDraft, groupID: Int64) {
        guard canUseUI, !isBusy, let editor, editor.presentingViewController === self, !editor.isBeingDismissed else { return }
        isSavingGroup = true
        editor.setBusy(true)
        render()
        let operation = saveGroup
        Task { @MainActor [weak self, operation, editor] in
            do {
                _ = try await operation(groupID, draft)
                // A successful file-backed write owns the image even if its UI has left.
                editor.markCoverCommitted()
                guard let self else { return }
                self.isSavingGroup = false
                self.onGroupsChanged?()
                guard self.canUseUI, let editor = self.editor else { return }
                self.closeEditor(editor, reload: true)
            } catch {
                editor.setBusy(false)
                guard let self else { return }
                self.isSavingGroup = false
                guard self.canUseUI, let editor = self.editor else { return }
                editor.showError(error.userFacingMessage)
                self.render()
            }
        }
    }

    private func removeGroup(_ id: Int64) {
        guard canUseUI, !isBusy, let editor, editor.presentingViewController === self else { return }
        isDeletingGroup = true
        editor.setBusy(true)
        render()
        let operation = deleteGroup
        Task { @MainActor [weak self, operation] in
            do {
                try await operation(id)
                guard let self else { return }
                self.isDeletingGroup = false
                self.draftGroupID &= ~id
                self.onGroupsChanged?()
                guard self.canUseUI, let editor = self.editor else { return }
                self.closeEditor(editor, reload: true)
            } catch {
                guard let self else { return }
                self.isDeletingGroup = false
                guard self.canUseUI, let editor = self.editor else { return }
                editor.setBusy(false)
                editor.showError(error.userFacingMessage)
                self.render()
            }
        }
    }

    private func cancelEditor() {
        guard !isBusy, let editor, !editor.isBeingDismissed else { return }
        if let child = editor.presentedViewController {
            child.dismiss(animated: true) { [weak editor] in editor?.setBusy(false) }
            return
        }
        closeEditor(editor, reload: false)
    }

    private func closeEditor(_ editor: BookGroupEditorViewController, reload: Bool) {
        editor.onSave = nil
        editor.onDelete = nil
        editor.onCancel = nil
        editor.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            self.editor = nil
            guard self.canUseUI else { return }
            self.content.panel.accessibilityElementsHidden = false
            self.flushGroups()
            if reload { self.reloadGroups() }
            self.render()
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.content.addButton)
        }
    }

    @objc private func cancel() {
        guard !isBusy, !isDraggingGroups, !isClosing else { return }
        if editor != nil {
            cancelEditor()
            return
        }
        isClosing = true
        deactivate()
        dismiss(animated: true)
    }

    private func deactivate() {
        isActive = false
        loadGeneration = UUID()
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        observationGeneration = UUID()
        observation?.cancel()
        observation = nil
        pendingGroups = nil
    }

    private func toggle(_ id: Int64) {
        guard canEdit, groups.contains(where: { $0.groupId == id }) else { return }
        if draftGroupID & id != 0 { draftGroupID &= ~id } else { draftGroupID |= id }
        commitError = nil
        tableView.reloadData()
        render()
    }

    @discardableResult
    func moveGroup(_ id: Int64, to destination: Int) -> Bool {
        guard canMove, let source = groups.firstIndex(where: { $0.groupId == id }),
            groups.indices.contains(destination), source != destination
        else { return false }
        let moved = groups.remove(at: source)
        groups.insert(moved, at: destination)
        tableView.moveRow(at: IndexPath(row: source, section: 0), to: IndexPath(row: destination, section: 0))
        isReordering = true
        commitError = nil
        shouldRetryCommit = false
        render()
        let ids = groups.map(\.groupId)
        let operation = reorderGroups
        Task { @MainActor [weak self, operation] in
            do {
                try await operation(ids)
                guard let self else { return }
                self.isReordering = false
                self.onGroupsChanged?()
                guard self.canUseUI else { return }
                self.flushGroups()
                self.reloadGroups()
                self.render()
            } catch {
                guard let self else { return }
                self.isReordering = false
                guard self.canUseUI else { return }
                // Partial backend writes are possible; reload the real order, never fake rollback.
                self.commitError = error.userFacingMessage
                self.pendingGroups = nil
                self.reloadGroups()
                self.render()
            }
        }
        return true
    }
}

extension AndroidReplicaBookDetailGroupPickerViewController: UITableViewDataSource, UITableViewDelegate,
    UITableViewDragDelegate, UITableViewDropDelegate
{
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { groups.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard groups.indices.contains(indexPath.row) else { return 56 }
        return BookGroupPickerRowCell.rowHeight(
            group: groups[indexPath.row], width: tableView.bounds.width, traits: tableView.traitCollection)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard groups.indices.contains(indexPath.row),
            let cell = tableView.dequeueReusableCell(withIdentifier: BookGroupPickerRowCell.reuseIdentifier, for: indexPath) as? BookGroupPickerRowCell
        else { return UITableViewCell() }
        let group = groups[indexPath.row]
        let id = group.groupId
        cell.configure(group: group, checked: draftGroupID & id != 0, enabled: canEdit)
        cell.onToggle = { [weak self] in self?.toggle(id) }
        cell.onEdit = { [weak self] in
            guard let self, let current = self.groups.first(where: { $0.groupId == id }) else { return }
            self.openEditor(group: current)
        }
        cell.onMove = { [weak self] delta in
            guard let self, self.canEdit, let index = self.groups.firstIndex(where: { $0.groupId == id }) else { return false }
            return self.moveGroup(id, to: index + delta)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard groups.indices.contains(indexPath.row) else { return }
        toggle(groups[indexPath.row].groupId)
    }

    func tableView(_: UITableView, dragSessionWillBegin _: UIDragSession) {
        isDraggingGroups = true
        render()
    }

    func tableView(_: UITableView, dragSessionDidEnd _: UIDragSession) {
        isDraggingGroups = false
        flushGroups()
        render()
    }

    func tableView(_: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard canEdit, groups.indices.contains(indexPath.row), groups[indexPath.row].groupId > 0 else { return [] }
        let id = groups[indexPath.row].groupId
        let item = UIDragItem(itemProvider: NSItemProvider(object: String(id) as NSString))
        item.localObject = id
        return [item]
    }

    func tableView(_: UITableView, canHandle session: UIDropSession) -> Bool { session.localDragSession != nil }

    func tableView(_: UITableView, dropSessionDidUpdate session: UIDropSession, withDestinationIndexPath destinationIndexPath: IndexPath?)
        -> UITableViewDropProposal
    {
        UITableViewDropProposal(operation: canMove && session.localDragSession != nil ? .move : .cancel, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard canMove, let item = coordinator.items.first, let id = item.dragItem.localObject as? Int64 else { return }
        let row = min(max(0, coordinator.destinationIndexPath?.row ?? groups.count - 1), groups.count - 1)
        if moveGroup(id, to: row) { coordinator.drop(item.dragItem, toRowAt: IndexPath(row: row, section: 0)) }
    }
}
