import UIKit
import shared

/// Book source GroupManageDialog.kt at Legado 5f5d314. The host owns adapter bindings.
@MainActor
final class BookSourceGroupManagementDialogViewController: UIViewController, UITableViewDataSource, UITableViewDelegate
{
    private let screen: SourceManagementScreenAdapter
    private var onChanged: (() -> Void)?
    private var sources: [BookSource] = []
    private var groups: [String] = []
    private var isActive = false
    private var isClosing = false
    private var didLoadSources = false
    private var lifetimeID = UUID()
    private var loadID: UUID?
    private var mutationID: UUID?
    private var loadTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let toolbar = BookSourceGroupManagementToolbar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let errorScrollView = BookSourceGroupManagementScrollView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    init(screen: SourceManagementScreenAdapter, onChanged: (() -> Void)? = nil) {
        self.screen = screen
        self.onChanged = onChanged
        super.init(nibName: nil, bundle: nil)
        title = BookSourceGroupManagementText.title
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        loadTask?.cancel()
        mutationTask?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isActive = true
        if !didLoadSources, loadID == nil { reloadSources() }
        updateInteraction()
        if presentedViewController == nil { becomeFirstResponder() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isLeavingPresentation { invalidate() }
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isLeavingPresentation || presentingViewController == nil { invalidate() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // UIKit can route the name editor's dismissal through its presenter.
        if presentedViewController == nil || isLeavingPresentation { invalidate() }
        super.dismiss(animated: flag, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        close()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        toolbar.refreshTypography()
        errorLabel.font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        retryButton.titleLabel?.font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        tableView.reloadData()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let size = CGSize(
            width: min(safe.width, view.bounds.width * 0.9), height: min(safe.height, view.bounds.height * 0.9))
        guard size.width > 0, size.height > 0 else { return }
        dialogView.frame = CGRect(
            x: safe.midX - size.width / 2, y: safe.midY - size.height / 2, width: size.width, height: size.height)
        let toolbarHeight = toolbar.sizeThatFits(CGSize(width: size.width, height: 0)).height
        let scrolls = toolbarHeight + 44 > size.height
        let showsError = !errorScrollView.isHidden
        let oldHeaderHeight = tableView.tableHeaderView?.frame.height
        let toolbarParent = scrolls && showsError ? errorScrollView : dialogView
        if scrolls && !showsError {
            if tableView.tableHeaderView !== toolbar {
                toolbar.removeFromSuperview()
                tableView.tableHeaderView = toolbar
            }
        } else {
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
            if toolbar.superview !== toolbarParent { toolbarParent.addSubview(toolbar) }
        }
        toolbar.frame = CGRect(x: 0, y: 0, width: size.width, height: toolbarHeight)
        if scrolls && !showsError, oldHeaderHeight != toolbarHeight {
            tableView.tableHeaderView = toolbar
        }
        let top = scrolls ? 0 : toolbarHeight
        let tableFrame = CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))
        if tableView.frame.width != tableFrame.width {
            tableView.frame = tableFrame
            tableView.reloadData()
        }
        tableView.frame = tableFrame
        let body = scrolls ? dialogView.bounds : tableFrame
        loadingIndicator.center = CGPoint(x: body.midX, y: body.midY)
        errorScrollView.frame = body
        let errorWidth = max(1, body.width - 32)
        let errorHeight = ceil(
            errorLabel.sizeThatFits(CGSize(width: errorWidth, height: .greatestFiniteMagnitude)).height)
        let retryHeight = max(44, ceil(retryButton.titleLabel?.font.lineHeight ?? 20) + 16)
        let header = scrolls && showsError ? toolbarHeight : 0
        let contentHeight = errorHeight + retryHeight + 8
        let errorY = header + max(0, (body.height - header - contentHeight) / 2)
        errorLabel.frame = CGRect(x: 16, y: errorY, width: errorWidth, height: errorHeight)
        retryButton.frame = CGRect(x: 16, y: errorLabel.frame.maxY + 8, width: errorWidth, height: retryHeight)
        errorScrollView.contentSize = CGSize(width: body.width, height: max(body.height, errorY + contentHeight))
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "sourceManagement.groupManage"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(close), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true
        toolbar.addButton.addTarget(self, action: #selector(addGroup), for: .touchUpInside)
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        tableView.separatorInset = .zero
        tableView.tableFooterView = UIView()
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(BookSourceGroupManagementCell.self, forCellReuseIdentifier: "group")
        tableView.accessibilityIdentifier = "sourceManagement.groupManage.list"
        errorLabel.font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        errorLabel.textColor = AndroidReplicaTheme.secondaryText
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "sourceManagement.groupManage.error"
        errorScrollView.contentInsetAdjustmentBehavior = .never
        errorScrollView.showsHorizontalScrollIndicator = false
        errorScrollView.isHidden = true
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        retryButton.titleLabel?.font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.accessibilityIdentifier = "sourceManagement.groupManage.retry"
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.color = AndroidReplicaTheme.accent
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        for item in [tableView, toolbar, loadingIndicator, errorScrollView] { dialogView.addSubview(item) }
        errorScrollView.addSubview(errorLabel)
        errorScrollView.addSubview(retryButton)
        updateInteraction()
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private var canAcceptResult: Bool {
        isActive && !isClosing && !isLeavingPresentation && presentingViewController != nil
            && viewIfLoaded?.window != nil
    }

    private var canStartAction: Bool {
        canAcceptResult && presentedViewController == nil && !isBeingPresented && transitionCoordinator == nil
            && view.window?.windowScene?.activationState == .foregroundActive && mutationID == nil && loadID == nil
    }

    private var canClose: Bool {
        canAcceptResult && presentedViewController == nil && mutationID == nil && !isBeingPresented
            && view.window?.windowScene?.activationState == .foregroundActive
    }

    private func reloadSources() {
        guard canAcceptResult, mutationID == nil else { return }
        loadTask?.cancel()
        let id = UUID()
        let lifetime = lifetimeID
        let screen = screen
        loadID = id
        showError(nil)
        updateInteraction()
        loadTask = Task { @MainActor [weak self] in
            do {
                let sources = try await screen.loadSources()
                guard !Task.isCancelled, let self, self.canAcceptResult, self.lifetimeID == lifetime, self.loadID == id
                else { return }
                self.loadID = nil
                self.loadTask = nil
                self.didLoadSources = true
                self.apply(sources: sources)
                self.updateInteraction()
            } catch {
                guard !Task.isCancelled, let self, self.canAcceptResult, self.lifetimeID == lifetime, self.loadID == id
                else { return }
                self.loadID = nil
                self.loadTask = nil
                self.showError(error.localizedDescription)
                self.updateInteraction()
            }
        }
    }

    private func apply(sources: [BookSource]) {
        self.sources = sources
        groups = BookSourceGroupManagementGroups.names(in: sources)
        tableView.reloadData()
    }

    private func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        retryButton.isHidden = message == nil
        errorScrollView.isHidden = message == nil
        tableView.isHidden = message != nil
        view.setNeedsLayout()
        if let message { UIAccessibility.post(notification: .announcement, argument: message) }
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let busy = mutationID != nil || loadID != nil
        toolbar.addButton.isEnabled = isActive && !isClosing && !busy
        tableView.isUserInteractionEnabled = isActive && !isClosing && !busy
        retryButton.isEnabled = isActive && !isClosing && !busy
        outsideControl.isEnabled = isActive && !isClosing && mutationID == nil
        if loadID != nil { loadingIndicator.startAnimating() } else { loadingIndicator.stopAnimating() }
        for case let cell as BookSourceGroupManagementCell in tableView.visibleCells {
            cell.setActionsEnabled(isActive && !busy && !isClosing)
        }
    }

    @objc private func addGroup() { openEditor(group: nil) }

    private func openEditor(group: String?) {
        guard canStartAction else { return }
        if let group, !groups.contains(group) { return }
        let editor = BookSourceGroupManagementEditorViewController(group: group)
        editor.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        editor.onSubmit = { [weak self, weak editor] name in
            guard let self, let editor else { return }
            let change: BookSourceGroupManagementChange = group.map { .rename(old: $0, new: name) } ?? .add(name)
            self.save(change, editor: editor)
        }
        present(editor, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func save(
        _ change: BookSourceGroupManagementChange, editor: BookSourceGroupManagementEditorViewController? = nil
    ) {
        guard canAcceptResult, mutationID == nil, loadID == nil else { return }
        if let editor {
            guard presentedViewController === editor, editor.canSubmit else { return }
        } else {
            guard canStartAction else { return }
        }
        let id = UUID()
        let lifetime = lifetimeID
        let screen = screen
        let previousSources = sources
        let hasEditor = editor != nil
        mutationID = id
        editor?.setSaving(true)
        showError(nil)
        updateInteraction()
        mutationTask = Task { @MainActor [weak self, weak editor] in
            do {
                let updated = try await change.save(using: screen)
                guard !Task.isCancelled else { return }
                // A successful empty result is a no-op, not a separately persisted group.
                let snapshot = try? await screen.loadSources()
                guard !Task.isCancelled, let self, self.canAcceptResult, self.lifetimeID == lifetime,
                    self.mutationID == id
                else { return }
                self.mutationID = nil
                self.mutationTask = nil
                if hasEditor, editor?.acceptsSaveResult != true || self.presentedViewController !== editor {
                    if let snapshot { self.apply(sources: snapshot) }
                    self.updateInteraction()
                    return
                }
                if updated.isEmpty {
                    if let snapshot { self.apply(sources: snapshot) }
                    self.updateInteraction()
                    if let editor {
                        editor.showFailure(change.emptyResultMessage)
                    } else {
                        self.showError(change.emptyResultMessage)
                    }
                    return
                }
                // If the follow-up read fails, use only the genuinely saved returned sources.
                let changed = Dictionary(updated.map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { _, last in last })
                let merged =
                    previousSources.map { changed[$0.bookSourceUrl] ?? $0 }
                    + updated.filter { item in !previousSources.contains { $0.bookSourceUrl == item.bookSourceUrl } }
                self.apply(sources: snapshot ?? merged)
                self.updateInteraction()
                self.onChanged?()
                guard self.canAcceptResult, self.lifetimeID == lifetime else { return }
                editor?.finishSaving()
            } catch {
                guard !Task.isCancelled, let self, self.canAcceptResult, self.lifetimeID == lifetime,
                    self.mutationID == id
                else { return }
                self.mutationID = nil
                self.mutationTask = nil
                self.updateInteraction()
                if hasEditor, editor?.acceptsSaveResult != true || self.presentedViewController !== editor { return }
                if let editor {
                    editor.showFailure(error.localizedDescription)
                } else {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc private func retry() {
        guard canStartAction else { return }
        reloadSources()
    }

    @objc private func close() {
        guard canClose else { return }
        invalidate()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func invalidate() {
        guard !isClosing else { return }
        isClosing = true
        isActive = false
        lifetimeID = UUID()
        loadID = nil
        mutationID = nil
        loadTask?.cancel()
        mutationTask?.cancel()
        loadTask = nil
        mutationTask = nil
        onChanged = nil
        updateInteraction()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { groups.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard groups.indices.contains(indexPath.row) else { return 0 }
        return BookSourceGroupManagementCell.height(
            group: groups[indexPath.row], width: tableView.bounds.width, traits: traitCollection)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(withIdentifier: "group", for: indexPath)
                as? BookSourceGroupManagementCell,
            groups.indices.contains(indexPath.row)
        else { return UITableViewCell() }
        let group = groups[indexPath.row]
        cell.configure(
            group: group, enabled: mutationID == nil && loadID == nil,
            onEdit: { [weak self] in
                self?.openEditor(group: group)
            },
            onDelete: { [weak self] in
                guard let self, self.groups.contains(group) else { return }
                self.save(.delete(group))
            })
        return cell
    }
}
