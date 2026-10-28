import UIKit
import shared

@MainActor
final class BookshelfGroupManagementViewController: UIViewController, UITableViewDataSource,
    UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate, UIAdaptivePresentationControllerDelegate
{
    var onGroupsChanged: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let content = BookshelfGroupManagementContentView()
    private var facade: BookshelfFacade?
    private var groups: [BookGroup] = []
    private var pendingGroups: [BookGroup]?
    private var pendingObservationError: String?
    private var errorMessage: String?
    private var subscription: FlowSubscription?
    private var editor: BookGroupEditorViewController?
    private var pendingEditorResult: (editor: BookGroupEditorViewController, error: String?)?
    private var pendingChangeNotification = false
    private var sceneObservers: [NSObjectProtocol] = []
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var loadID: UUID?
    private var mutationID: UUID?
    private var lifetimeID = UUID()
    private var observationID = UUID()
    private var observationRevision = 0
    private var hasSnapshot = false
    private var requiresReadback = true
    private var isActive = false
    private var isClosing = false
    private var isDragging = false
    private var dragOrder: [Int64] = []
    private var draggedGroupID: Int64?

    init() {
        super.init(nibName: nil, bundle: nil)
        title = "分组管理"
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        subscription?.cancel()
        loadTask?.cancel()
        for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
        // A submitted mutation owns its cover until persistence finishes, even after this UI leaves.
    }

    override func loadView() { view = content }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canClose else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
        escape.wantsPriorityOverSystemBehavior = true
        escape.discoverabilityTitle = "关闭"
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        content.tableView.dataSource = self
        content.tableView.delegate = self
        content.tableView.dragDelegate = self
        content.tableView.dropDelegate = self
        content.tableView.dragInteractionEnabled = true
        content.addButton.addTarget(self, action: #selector(addGroup), for: .touchUpInside)
        content.confirmButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        content.backdrop.addTarget(self, action: #selector(close), for: .touchUpInside)
        content.retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        observeScene()
        render()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isActive = true
        presentationController?.delegate = self
        if let editor, editor.presentingViewController == nil { self.editor = nil }
        finishPendingEditorResult()
        if facade == nil {
            connect()
        } else if subscription == nil, mutationID == nil {
            startObservation()
            reloadGroups()
        }
        flushPendingGroups()
        deliverChangeNotification()
        render()
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in
            self?.flushPendingGroups()
            self?.render()
        }
        if editor == nil {
            becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: content.panel)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isLeavingPresentation { invalidate() }
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isLeavingPresentation || (presentingViewController == nil && parent == nil) { invalidate() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // Dismissing the editor may route through its presenter; do not tear down the manager then.
        if presentedViewController == nil || isLeavingPresentation { invalidate() }
        super.dismiss(animated: flag) { [weak self] in
            if let self, self.presentingViewController == nil {
                let callback = self.onDismiss
                self.onDismiss = nil
                callback?()
            }
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        close()
        return true
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === self {
            invalidate()
        } else if presentationController.presentedViewController === editor {
            editor = nil
            flushPendingGroups()
            render()
        }
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private var acceptsResults: Bool {
        isActive && !isClosing && !isLeavingPresentation && viewIfLoaded?.window != nil
            && (presentingViewController != nil || parent != nil)
    }

    private var isForeground: Bool { viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive }
    private var isBusy: Bool { loadID != nil || mutationID != nil }
    private var defersGroups: Bool { isBusy || isDragging || editor != nil || presentedViewController != nil || !isForeground }
    private var canRetry: Bool {
        acceptsResults && isForeground && !isBusy && !isDragging && editor == nil
            && presentedViewController == nil && !isBeingPresented && transitionCoordinator == nil
    }
    private var canAct: Bool { canRetry && hasSnapshot && !requiresReadback && facade != nil }
    private var canClose: Bool {
        acceptsResults && isForeground && mutationID == nil && !isDragging && editor == nil
            && presentedViewController == nil && !isBeingPresented
    }

    private func connect() {
        guard acceptsResults else { return }
        do {
            facade = try SharedRuntime.bookshelfFacade().get()
            startObservation()
            reloadGroups()
        } catch {
            requiresReadback = true
            errorMessage = error.localizedDescription
            render()
        }
    }

    private func startObservation() {
        stopObservation()
        guard acceptsResults, isForeground, let facade else { return }
        pendingObservationError = nil
        let id = observationID
        let lifetime = lifetimeID
        subscription = facade.watchManagedGroups(
            onUpdate: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.acceptsResults, self.lifetimeID == lifetime, self.observationID == id else { return }
                    self.observationRevision += 1
                    self.pendingGroups = snapshot
                    self.requiresReadback = false
                    self.flushPendingGroups()
                    self.render()
                }
            },
            onError: { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.acceptsResults, self.lifetimeID == lifetime, self.observationID == id else { return }
                    self.stopObservation()
                    self.pendingObservationError = message
                    self.flushPendingGroups()
                    self.render()
                }
            })
    }

    private func stopObservation() {
        observationID = UUID()
        subscription?.cancel()
        subscription = nil
    }

    private func reloadGroups() {
        guard acceptsResults, mutationID == nil, !isDragging, let facade else { return }
        loadTask?.cancel()
        let id = UUID()
        let lifetime = lifetimeID
        let revision = observationRevision
        loadID = id
        errorMessage = nil
        render()
        loadTask = Task { @MainActor [weak self] in
            do {
                let snapshot = try await facade.loadGroupsAsync()
                guard !Task.isCancelled, let self, self.acceptsResults, self.lifetimeID == lifetime, self.loadID == id else { return }
                self.loadID = nil
                self.loadTask = nil
                if self.observationRevision == revision || self.pendingGroups == nil { self.pendingGroups = snapshot }
                self.requiresReadback = self.subscription == nil
                self.flushPendingGroups()
                self.render()
            } catch {
                guard !Task.isCancelled, let self, self.acceptsResults, self.lifetimeID == lifetime, self.loadID == id else { return }
                self.loadID = nil
                self.loadTask = nil
                self.requiresReadback = self.pendingGroups == nil || self.subscription == nil
                self.errorMessage = error.localizedDescription
                self.flushPendingGroups()
                self.render()
            }
        }
    }

    private func flushPendingGroups() {
        guard acceptsResults, !defersGroups else { return }
        if let snapshot = pendingGroups {
            pendingGroups = nil
            let changed = hasSnapshot && !groups.elementsEqual(snapshot, by: { $0.isEqual($1) })
            groups = snapshot
            hasSnapshot = true
            content.tableView.reloadData()
            if changed { notifyGroupsChanged() }
        }
        if let message = pendingObservationError {
            pendingObservationError = nil
            requiresReadback = true
            errorMessage = message
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        content.panel.accessibilityElementsHidden = editor != nil
        content.render(
            loading: isBusy, error: errorMessage, hasRows: !groups.isEmpty,
            canAct: canAct, canRetry: canRetry, canClose: canClose)
        for case let cell as BookshelfGroupManagementCell in content.tableView.visibleCells {
            cell.setActionsEnabled(canAct)
        }
    }

    private func notifyGroupsChanged() {
        pendingChangeNotification = true
        deliverChangeNotification()
    }

    private func deliverChangeNotification() {
        guard pendingChangeNotification, acceptsResults, isForeground else { return }
        pendingChangeNotification = false
        onGroupsChanged?()
    }

    @objc private func retry() {
        guard canRetry else { return }
        pendingObservationError = nil
        if facade == nil {
            connect()
        } else {
            startObservation()
            reloadGroups()
        }
    }

    @objc private func addGroup() {
        guard canAct else { return }
        guard BookshelfManagedGroupMutation.canAdd(in: groups) else {
            errorMessage = "分组已达上限"
            render()
            return
        }
        openEditor(group: nil)
    }

    private func openEditor(group: BookGroup?) {
        guard canAct else { return }
        if let group, !groups.contains(where: { $0.groupId == group.groupId }) { return }
        let controller = BookGroupEditorViewController(group: group)
        controller.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        controller.onSave = { [weak self, weak controller] draft in
            guard let controller else { return }
            guard let self, self.acceptsResults, self.editor === controller, self.mutationID == nil else {
                controller.setBusy(false)
                return
            }
            self.mutate(.save(group?.groupId, draft), editor: controller)
        }
        controller.onDelete = { [weak self, weak controller] in
            guard let controller else { return }
            guard let self, let group, group.groupId > 0, self.acceptsResults,
                self.editor === controller, self.mutationID == nil, controller.presentedViewController == nil
            else {
                controller.setBusy(false)
                return
            }
            self.confirmDeletion(groupID: group.groupId, editor: controller)
        }
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller, self.editor === controller, self.mutationID == nil else { return }
            self.closeEditor(controller)
        }
        editor = controller
        render()
        present(controller, animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak controller] in
            guard let self, self.acceptsResults, self.editor === controller else { return }
            controller?.presentationController?.delegate = self
        }
    }

    private func confirmDeletion(groupID: Int64, editor: BookGroupEditorViewController) {
        let lifetime = lifetimeID
        BookshelfGroupDeletionConfirmation.present(
            in: editor,
            isCurrent: { [weak self, weak editor] in
                guard let self, let editor else { return false }
                return self.acceptsResults && self.isForeground && self.lifetimeID == lifetime
                    && self.editor === editor && self.mutationID == nil && groupID > 0
                    && (self.pendingGroups ?? self.groups).contains { $0.groupId == groupID }
            },
            onConfirm: { [weak self, weak editor] in
                guard let editor else { return }
                guard let self, self.acceptsResults, self.editor === editor, self.mutationID == nil else {
                    editor.setBusy(false)
                    return
                }
                self.mutate(.delete(groupID), editor: editor)
            })
    }

    private func closeEditor(_ controller: BookGroupEditorViewController) {
        guard editor === controller else { return }
        controller.onSave = nil
        controller.onDelete = nil
        controller.onCancel = nil
        controller.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [weak self, weak controller] in
            guard let self, self.acceptsResults, self.editor === controller else { return }
            self.editor = nil
            self.flushPendingGroups()
            if self.requiresReadback, self.loadID == nil { self.reloadGroups() }
            self.render()
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.content.addButton)
        }
    }

    private func setVisible(_ visible: Bool, groupID: Int64) {
        guard canAct, groups.contains(where: { $0.groupId == groupID }) else { return }
        mutate(.visibility(groupID, visible))
    }

    private func mutate(
        _ change: BookshelfManagedGroupMutation, editor submittedEditor: BookGroupEditorViewController? = nil,
        focusID: Int64? = nil
    ) {
        guard acceptsResults, !isBusy, !isDragging, let facade else {
            submittedEditor?.setBusy(false)
            return
        }
        let id = UUID()
        let lifetime = lifetimeID
        mutationID = id
        pendingGroups = nil
        errorMessage = nil
        submittedEditor?.setBusy(true)
        render()
        // Deliberately independent of the screen lifetime: closing a UI cannot undo a submitted write.
        mutationTask = Task { @MainActor [weak self, submittedEditor] in
            var writeError: Error?
            do {
                try await change.perform(using: facade)
                if change.savesCover { submittedEditor?.markCoverCommitted() }
            } catch {
                writeError = error
                submittedEditor?.setBusy(false)
            }
            var snapshot: [BookGroup]?
            var readError: Error?
            do { snapshot = try await facade.loadGroupsAsync() } catch { readError = error }
            guard let self, self.acceptsResults, self.lifetimeID == lifetime, self.mutationID == id else { return }
            self.mutationID = nil
            self.mutationTask = nil
            if let snapshot { self.pendingGroups = snapshot }
            self.requiresReadback = snapshot == nil
            self.errorMessage = writeError.map { $0.localizedDescription }
            if let readError {
                self.errorMessage = [self.errorMessage, "读取实际分组状态失败：\(readError.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
            }
            // Discard queued intermediate reorder emissions; the new subscription starts from the database.
            self.startObservation()
            if let submittedEditor, self.editor === submittedEditor {
                self.pendingEditorResult = (submittedEditor, writeError?.localizedDescription)
                self.finishPendingEditorResult()
            }
            self.flushPendingGroups()
            self.render()
            if writeError == nil || change.mayPartiallyDelete { self.notifyGroupsChanged() }
            guard self.acceptsResults, self.lifetimeID == lifetime, self.editor == nil else { return }
            if let message = self.errorMessage, self.isForeground {
                UIAccessibility.post(notification: .announcement, argument: message)
            } else if writeError == nil, let focusID {
                self.focusGroup(focusID)
            }
        }
    }

    private func finishPendingEditorResult(afterTransition: Bool = false) {
        guard acceptsResults, isForeground, let pending = pendingEditorResult else { return }
        guard editor === pending.editor else {
            pendingEditorResult = nil
            return
        }
        if !afterTransition, let transition = pending.editor.transitionCoordinator {
            if transition.animate(
                alongsideTransition: nil,
                completion: { [weak self] _ in
                    self?.finishPendingEditorResult(afterTransition: true)
                })
            {
                return
            }
        }
        guard pendingEditorResult != nil else { return }
        pendingEditorResult = nil
        if let message = pending.error {
            pending.editor.showError(message)
        } else {
            pending.editor.setBusy(false)
            closeEditor(pending.editor)
        }
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { groups.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard groups.indices.contains(indexPath.row) else { return 64 }
        return BookshelfGroupManagementCell.rowHeight(
            group: groups[indexPath.row], width: tableView.bounds.width, traits: tableView.traitCollection)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard groups.indices.contains(indexPath.row),
            let cell = tableView.dequeueReusableCell(
                withIdentifier: BookshelfGroupManagementCell.reuseID, for: indexPath) as? BookshelfGroupManagementCell
        else { return UITableViewCell() }
        let group = groups[indexPath.row]
        cell.configure(group: group, index: indexPath.row, count: groups.count, enabled: canAct)
        cell.onEdit = { [weak self] in
            guard let self, let latest = self.groups.first(where: { $0.groupId == group.groupId }) else { return }
            self.openEditor(group: latest)
        }
        cell.onToggle = { [weak self] visible in self?.setVisible(visible, groupID: group.groupId) }
        cell.onMove = { [weak self] direction in self?.moveGroup(group.groupId, by: direction) ?? false }
        return cell
    }

    func tableView(_: UITableView, canMoveRowAt _: IndexPath) -> Bool { canAct || isDragging }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        guard canAct, groups.count > 1, groups.indices.contains(indexPath.row) else { return [] }
        var child = tableView.hitTest(session.location(in: tableView), with: nil)
        while let current = child, current !== content.tableView {
            if current is UIControl { return [] }
            child = current.superview
        }
        let id = groups[indexPath.row].groupId
        let item = UIDragItem(itemProvider: NSItemProvider(object: String(id) as NSString))
        item.localObject = id
        session.localContext = tableView
        return [item]
    }

    func tableView(_: UITableView, itemsForAddingTo _: UIDragSession, at _: IndexPath, point _: CGPoint) -> [UIDragItem] { [] }

    func tableView(_: UITableView, dragSessionAllowsMoveOperation _: UIDragSession) -> Bool { true }
    func tableView(_: UITableView, dragSessionIsRestrictedToDraggingApplication _: UIDragSession) -> Bool { true }

    func tableView(_: UITableView, dragSessionWillBegin session: UIDragSession) {
        guard acceptsResults, !isBusy, editor == nil else { return }
        dragOrder = groups.map { $0.groupId }
        draggedGroupID = session.items.first?.localObject as? Int64
        isDragging = true
        render()
    }

    func tableView(_: UITableView, dragSessionDidEnd _: UIDragSession) {
        guard isDragging else { return }
        finishDrag()
    }

    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        (session.localDragSession?.localContext as? UITableView) === tableView
    }

    func tableView(
        _ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath _: IndexPath?
    ) -> UITableViewDropProposal {
        let local = (session.localDragSession?.localContext as? UITableView) === tableView
        let canDrop = local && acceptsResults && isForeground && isDragging && !isBusy && editor == nil
        return UITableViewDropProposal(operation: canDrop ? .move : .cancel, intent: .insertAtDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard acceptsResults, isForeground, isDragging, !isBusy, editor == nil,
            (coordinator.session.localDragSession?.localContext as? UITableView) === tableView,
            coordinator.items.count == 1, let item = coordinator.items.first,
            let id = item.dragItem.localObject as? Int64,
            let source = groups.firstIndex(where: { $0.groupId == id })
        else { return }
        let target = min(max(0, coordinator.destinationIndexPath?.row ?? groups.count - 1), groups.count - 1)
        if source != target {
            let group = groups.remove(at: source)
            groups.insert(group, at: target)
            tableView.moveRow(at: IndexPath(row: source, section: 0), to: IndexPath(row: target, section: 0))
        }
        coordinator.drop(item.dragItem, toRowAt: IndexPath(row: target, section: 0))
    }

    private func finishDrag() {
        let focusID = draggedGroupID
        isDragging = false
        draggedGroupID = nil
        let order = groups.map { $0.groupId }
        if order != dragOrder {
            mutate(.reorder(order), focusID: focusID)
        } else {
            flushPendingGroups()
            content.tableView.reloadData()
            render()
        }
        dragOrder = []
    }

    private func moveGroup(_ id: Int64, by direction: Int) -> Bool {
        guard canAct, [-1, 1].contains(direction), let index = groups.firstIndex(where: { $0.groupId == id }),
            groups.indices.contains(index + direction)
        else { return false }
        let group = groups.remove(at: index)
        groups.insert(group, at: index + direction)
        content.tableView.reloadData()
        mutate(.reorder(groups.map { $0.groupId }), focusID: id)
        return true
    }

    private func focusGroup(_ id: Int64) {
        guard isForeground, !defersGroups, let row = groups.firstIndex(where: { $0.groupId == id }) else { return }
        let index = IndexPath(row: row, section: 0)
        content.tableView.scrollToRow(at: index, at: .none, animated: false)
        UIAccessibility.post(notification: .layoutChanged, argument: content.tableView.cellForRow(at: index))
        UIAccessibility.post(notification: .announcement, argument: "已移至第\(row + 1)项")
    }

    private func observeScene() {
        let center = NotificationCenter.default
        sceneObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isClosing else { return }
                    self.stopObservation()
                    self.loadTask?.cancel()
                    self.loadTask = nil
                    self.loadID = nil
                    self.isDragging = false
                    self.draggedGroupID = nil
                    self.dragOrder = []
                    self.requiresReadback = true
                    self.render()
                }
            })
        sceneObservers.append(
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.acceptsResults else { return }
                    self.finishPendingEditorResult()
                    if self.facade == nil {
                        self.connect()
                    } else {
                        self.startObservation()
                        if self.mutationID == nil { self.reloadGroups() }
                    }
                    self.flushPendingGroups()
                    self.deliverChangeNotification()
                    self.render()
                }
            })
    }

    @objc private func close() {
        guard canClose else { return }
        invalidate()
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func invalidate() {
        guard !isClosing else { return }
        isClosing = true
        isActive = false
        lifetimeID = UUID()
        stopObservation()
        loadTask?.cancel()
        loadTask = nil
        loadID = nil
        mutationTask = nil
        mutationID = nil
        isDragging = false
        pendingGroups = nil
        pendingObservationError = nil
        pendingEditorResult = nil
        pendingChangeNotification = false
        editor?.onSave = nil
        editor?.onDelete = nil
        editor?.onCancel = nil
        editor = nil
        for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
        sceneObservers = []
        onGroupsChanged = nil
        render()
    }
}

@MainActor
private enum BookshelfManagedGroupMutation {
    case save(Int64?, BookGroupEditDraft)
    case visibility(Int64, Bool)
    case reorder([Int64])
    case delete(Int64)

    var savesCover: Bool {
        if case .save = self { return true }
        return false
    }
    var mayPartiallyDelete: Bool {
        if case .delete = self { return true }
        return false
    }

    static func canAdd(in groups: [BookGroup]) -> Bool {
        groups.filter { $0.groupId > 0 }.reduce(Int64(0)) { $0 | $1.groupId } != Int64.max
    }

    func perform(using facade: BookshelfFacade) async throws {
        switch self {
        case .save(let id, let draft):
            if let id {
                _ = try await facade.saveManagedGroupDetailsAsync(
                    groupId: id, name: draft.name, cover: draft.cover,
                    enableRefresh: draft.enableRefresh, bookSort: draft.bookSort)
            } else {
                guard Self.canAdd(in: try await facade.loadGroupsAsync()) else {
                    throw NSError(
                        domain: "io.legado.kmp.ios", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "分组已达上限"])
                }
                _ = try await facade.saveGroupDetailsAsync(
                    groupId: 0, name: draft.name, cover: draft.cover,
                    enableRefresh: draft.enableRefresh, bookSort: draft.bookSort)
            }
        case .visibility(let id, let visible):
            _ = try await facade.setManagedGroupVisibleAsync(groupId: id, visible: visible)
        case .reorder(let ids):
            try await facade.reorderManagedGroupsAsync(groupIds: ids.map { KotlinLong(value: $0) })
        case .delete(let id):
            guard id > 0 else {
                throw NSError(
                    domain: "io.legado.kmp.ios", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "系统分组不能删除"])
            }
            try await facade.deleteGroupAsync(groupId: id)
        }
    }
}
