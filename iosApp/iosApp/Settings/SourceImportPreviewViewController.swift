import UIKit
import shared

final class SourceImportPreviewViewController: UIViewController, UIAdaptivePresentationControllerDelegate,
    UIViewControllerTransitioningDelegate, UIScrollViewDelegate
{
    var onConfirm: (([BookSource], SourceImportOptions) async throws -> Void)? {
        didSet { if isViewLoaded { updateControls() } }
    }
    var onCancel: (() -> Void)?
    var onImported: (() -> Void)?

    private let state: SourceImportPreviewState
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let footer = SourceImportPreviewFooterView(showsSelection: true)
    private let moreButton = SourceImportPreviewActionButton(type: .system)
    private let groupButton = SourceImportPreviewAndroidStyle.actionButton(
        title: SourceImportPreviewText.customGroup, identifier: "sourceImport.preview.group", singleLine: true,
        weight: .medium)
    private lazy var toolbar = SourceImportPreviewToolbar(
        title: SourceImportPreviewText.title, actions: [groupButton, moreButton])
    private let chromeScrollView = SourceImportPreviewScrollView()
    private let contentView = UIView()
    private let summaryView = UIView()
    private let summaryLabel = UILabel()
    private let emptyView = UIView()
    private let emptyLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let sizingCell = SourceImportPreviewCell(style: .default, reuseIdentifier: nil)
    private lazy var list = SourceImportPreviewList(state: state, table: tableView, sizingCell: sizingCell)
    private lazy var presentation = AndroidSearchPresentationState(view: view) { [weak self] in
        self?.presentationChanged()
    }
    private var overflowMenu: ReaderOverflowMenuView?
    private var menuActionID: UUID?
    private var childRequestID: UUID?
    private weak var ownedEditor: UIViewController?
    private var importTask: Task<Void, Never>?
    private var preparePreview: (() async throws -> SourceImportPreview)?
    private var preparationTask: Task<Void, Never>?
    private var preparationID: UUID?
    private var isPreparing = false
    private var pendingImportError: Error?
    private var isSaving = false
    private var isClosing = false
    private var didImport = false
    private var didReportCompletion = false
    private var isLeavingPresentation = false
    private var isVisible = false

    init(preview: SourceImportPreview) {
        state = SourceImportPreviewState(preview: preview)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = self
    }

    convenience init(preparePreview: @escaping () async throws -> SourceImportPreview) {
        self.init(preview: SourceImportPreview(candidates: [], totalCount: 0, duplicateCount: 0, invalidCount: 0))
        self.preparePreview = preparePreview
        isPreparing = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        preparationTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard !isSaving, !isClosing else { return [] }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTapped))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SourceImportPreviewText.title
        view.backgroundColor = AndroidReplicaTheme.background
        view.clipsToBounds = true
        view.accessibilityIdentifier = "sourceImport.preview.root"
        view.accessibilityViewIsModal = true
        configureToolbarActions()
        configureContent()
        footer.selectionButton.addTarget(self, action: #selector(toggleAll), for: .touchUpInside)
        footer.cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        footer.confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        for button in [moreButton, groupButton, footer.selectionButton, footer.cancelButton, footer.confirmButton] {
            button.canInteract = { [weak self] in self?.canInteract == true }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
        applyPalette()
        updateControls()
        startPreparationIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isLeavingPresentation = false
        isVisible = true
        presentation.refreshHierarchy()
        presentation.setPresentationActive(true)
        presentationController?.delegate = self
        becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.presentPendingImportError() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        presentation.setPresentationActive(false)
        cancelPendingTracking()
        dismissOverflowMenu()
        resignFirstResponder()
        isLeavingPresentation = SourceImportPreviewDialogContainer.isLeavingPresentation(self)
        if isLeavingPresentation {
            childRequestID = nil
            cancelPreparation()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Presenting a group/draft editor is not cancellation of the import preview.
        guard isLeavingPresentation, !isClosing, !isSaving else { return }
        isClosing = true
        childRequestID = nil
        updateControls()
        reportCompletion()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil, !isBeingDismissed {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard !isSaving || isClosing else { return }
        guard !didReportCompletion else {
            completion?()
            return
        }
        isClosing = true
        childRequestID = nil
        cancelPreparation()
        dismissOverflowMenu()
        if isViewLoaded { updateControls() }
        super.dismiss(animated: flag) { [self] in
            reportCompletion()
            completion?()
        }
    }

    override func present(_ controller: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
        if isViewLoaded {
            cancelPendingTracking()
            dismissOverflowMenu()
        }
        super.present(controller, animated: flag, completion: completion)
    }

    func cancelWorkflowPresentation() {
        guard !isSaving, !didReportCompletion else { return }
        isClosing = true
        childRequestID = nil
        ownedEditor = nil
        cancelPreparation()
        dismissOverflowMenu()
        if isViewLoaded { updateControls() }
        // Dismiss from the owner so an open draft/group closes together with this preview.
        if let presenter = presentingViewController, presenter.presentedViewController === self {
            presenter.dismiss(animated: false) { [self] in reportCompletion() }
        } else {
            reportCompletion()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        cancelPendingTracking()
        dismissOverflowMenu()
        list.rememberAnchor()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            summaryLabel.font = SourceImportPreviewAndroidStyle.font(
                13, style: .footnote, compatibleWith: traitCollection)
            emptyLabel.font = SourceImportPreviewAndroidStyle.font(
                14, style: .subheadline, compatibleWith: traitCollection)
            list.invalidateMeasurements()
        }
        applyPalette()
        invalidateDialogLayout()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract || (overflowMenu != nil && canUsePreview) else { return false }
        cancelTapped()
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        guard width > 0 else { return }
        presentation.refreshHierarchy()
        list.layoutPreservingAnchor { layoutContent(width: width) }
        if overflowMenu != nil, !canUsePreview { dismissOverflowMenu() }
        presentPendingImportError()
    }

    private func layoutContent(width: CGFloat) {
        let toolbarHeight = toolbar.sizeThatFits(CGSize(width: width, height: 0)).height
        let footerHeight = footer.sizeThatFits(CGSize(width: width, height: 0)).height
        let listHeight = listContentHeight(width: width, limit: view.bounds.height)
        let minimumListHeight = min(52, listHeight)
        // In a very short AX window the chrome must scroll, never overlap or hide the actions.
        let scrollsChrome = toolbarHeight + footerHeight + minimumListHeight > view.bounds.height
        let viewportHeight =
            scrollsChrome
            ? minimumListHeight
            : max(0, view.bounds.height - toolbarHeight - footerHeight)
        chromeScrollView.frame = view.bounds
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        tableView.frame = CGRect(x: 0, y: toolbarHeight, width: width, height: viewportHeight)
        layoutListMessages(width: width)
        footer.frame = CGRect(x: 0, y: tableView.frame.maxY, width: width, height: footerHeight)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: footer.frame.maxY)
        chromeScrollView.contentSize = contentView.bounds.size
        chromeScrollView.isScrollEnabled = scrollsChrome
        let offsetY = min(max(0, chromeScrollView.contentOffset.y), max(0, contentView.bounds.height - view.bounds.height))
        if chromeScrollView.contentOffset.y != offsetY {
            chromeScrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        }
        tableView.isScrollEnabled = listHeight > viewportHeight
        overflowMenu?.setNeedsLayout()
    }

    private var canUsePreview: Bool {
        guard isVisible, presentation.isActive, !isSaving, !isClosing, !didReportCompletion,
            !isBeingDismissed, !isBeingPresented, !isLeavingPresentation,
            !SourceImportPreviewDialogContainer.isLeavingPresentation(self),
            presentedViewController == nil, presentingViewController?.presentedViewController === self,
            viewIfLoaded?.window?.isKeyWindow == true, transitionCoordinator == nil,
            !tableView.isDragging, !tableView.isDecelerating,
            !chromeScrollView.isDragging, !chromeScrollView.isDecelerating,
            let window = viewIfLoaded?.window
        else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            guard current.isUserInteractionEnabled else { return false }
            ancestor = current.superview
        }
        let visible = view.convert(view.bounds, to: window).intersection(window.bounds)
        guard !visible.isEmpty, !visible.isNull,
            let hit = window.hitTest(CGPoint(x: visible.midX, y: visible.midY), with: nil)
        else { return false }
        return hit === view || hit.isDescendant(of: view)
            || overflowMenu.map { hit === $0 || hit.isDescendant(of: $0) } == true
    }

    private var canInteract: Bool { canUsePreview && overflowMenu == nil }

    private func presentationChanged() {
        guard isViewLoaded else { return }
        if !presentation.isActive {
            cancelPendingTracking()
            dismissOverflowMenu()
        } else {
            presentPendingImportError()
        }
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === viewIfLoaded?.window else { return }
        if notification.name == UIWindow.didResignKeyNotification {
            cancelPendingTracking()
            dismissOverflowMenu()
        } else {
            presentPendingImportError()
        }
        presentation.update()
    }

    private func cancelPendingTracking() {
        list.cancelPendingTracking()
        (presentationController as? SourceImportPreviewPresentationController)?.cancelPendingTracking()
        for button in [moreButton, groupButton, footer.selectionButton, footer.cancelButton, footer.confirmButton] {
            button.cancelTracking(with: nil)
        }
    }

    @objc private func applyPalette() {
        guard isViewLoaded else { return }
        dismissOverflowMenu()
        let palette = ReaderTocPalette(traits: traitCollection)
        view.backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        summaryLabel.textColor = palette.secondaryText
        emptyLabel.textColor = palette.secondaryText
        loadingIndicator.color = palette.accent
        toolbar.applyPalette()
        footer.applyPalette()
        list.applyPalette()
    }

    private func configureToolbarActions() {
        moreButton.setImage(ReaderMenuAndroidIcon.more.image() ?? UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.accessibilityLabel = SourceImportPreviewText.more
        moreButton.accessibilityIdentifier = "sourceImport.preview.more"
        moreButton.addInteraction(UIToolTipInteraction(defaultToolTip: SourceImportPreviewText.more))
        groupButton.addTarget(self, action: #selector(editGroup), for: .touchUpInside)
        moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
    }

    private func configureContent() {
        chromeScrollView.contentInsetAdjustmentBehavior = .never
        chromeScrollView.bounces = false
        chromeScrollView.showsHorizontalScrollIndicator = false
        chromeScrollView.scrollsToTop = false
        chromeScrollView.delegate = self
        chromeScrollView.canCancelContentTouches = true
        view.addSubview(chromeScrollView)
        chromeScrollView.addSubview(contentView)
        for item in [toolbar, tableView, footer] { contentView.addSubview(item) }
        sizingCell.isHidden = true
        view.addSubview(sizingCell)

        summaryLabel.text = SourceImportPreviewText.ignoredCounts(
            duplicates: state.duplicateCount, invalid: state.invalidCount)
        summaryLabel.textColor = AndroidReplicaTheme.secondaryText
        summaryLabel.font = SourceImportPreviewAndroidStyle.font(13, style: .footnote, compatibleWith: traitCollection)
        summaryLabel.adjustsFontForContentSizeCategory = false
        summaryLabel.numberOfLines = 0
        summaryLabel.accessibilityIdentifier = "sourceImport.preview.summary"
        summaryView.addSubview(summaryLabel)

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.alwaysBounceVertical = false
        tableView.showsVerticalScrollIndicator = false
        tableView.canCancelContentTouches = true
        tableView.accessibilityIdentifier = "sourceImport.preview.list"
        list.canInteract = { [weak self] in self?.canInteract == true }
        list.onToggle = { [weak self] identity in self?.toggleCandidate(identity) }
        list.onOpen = { [weak self] identity in self?.openCandidate(identity) }
        list.onBeginDragging = { [weak self] in
            self?.cancelPendingTracking()
            self?.dismissOverflowMenu()
        }
        emptyLabel.text = SourceImportPreviewText.empty
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.font = SourceImportPreviewAndroidStyle.font(14, style: .subheadline, compatibleWith: traitCollection)
        emptyLabel.numberOfLines = 0
        emptyLabel.adjustsFontForContentSizeCategory = false
        emptyLabel.textAlignment = .natural
        emptyLabel.accessibilityIdentifier = "sourceImport.preview.empty"
        emptyView.addSubview(emptyLabel)
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.accessibilityIdentifier = "sourceImport.preview.loading"
        loadingIndicator.accessibilityLabel = SourceImportPreviewText.parsing
        emptyView.addSubview(loadingIndicator)
    }

    private func startPreparationIfNeeded() {
        guard let preparePreview else { return }
        self.preparePreview = nil
        let id = UUID()
        preparationID = id
        preparationTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let preview = try await preparePreview()
                try Task.checkCancellation()
                guard let self, self.preparationID == id, !self.isClosing, !self.didReportCompletion else { return }
                self.preparationTask = nil
                self.preparationID = nil
                self.isPreparing = false
                self.dismissOverflowMenu()
                self.list.receivePreparedPreview(preview)
                self.summaryLabel.text = SourceImportPreviewText.ignoredCounts(
                    duplicates: self.state.duplicateCount, invalid: self.state.invalidCount)
                self.updateControls()
            } catch {
                guard !Task.isCancelled, let self, self.preparationID == id, !self.isClosing, !self.didReportCompletion else { return }
                self.preparationTask = nil
                self.preparationID = nil
                self.isPreparing = false
                self.emptyLabel.text = "ImportError:\(error.userFacingMessage)"
                self.updateControls()
            }
        }
    }

    private func cancelPreparation() {
        preparationID = nil
        preparationTask?.cancel()
        preparationTask = nil
        preparePreview = nil
    }

    private var showsSummary: Bool { state.duplicateCount > 0 || state.invalidCount > 0 }

    private func summaryHeight(width: CGFloat) -> CGFloat {
        guard showsSummary else { return 0 }
        return ceil(summaryLabel.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)).height) + 16
    }

    private func emptyHeight(width: CGFloat) -> CGFloat {
        if isPreparing { return 80 }
        return max(80, ceil(emptyLabel.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)).height) + 32)
    }

    private func layoutListMessages(width: CGFloat) {
        if showsSummary {
            let height = summaryHeight(width: width)
            summaryLabel.frame = CGRect(x: 16, y: 8, width: max(1, width - 32), height: height - 16)
            if summaryView.frame.size != CGSize(width: width, height: height) || tableView.tableHeaderView == nil {
                summaryView.frame = CGRect(x: 0, y: 0, width: width, height: height)
                tableView.tableHeaderView = summaryView
            }
        } else {
            tableView.tableHeaderView = nil
        }
        if state.candidates.isEmpty {
            let height = emptyHeight(width: width)
            emptyLabel.isHidden = isPreparing
            emptyLabel.frame = CGRect(x: 16, y: 16, width: max(1, width - 32), height: height - 32)
            loadingIndicator.frame = CGRect(x: (width - 36) / 2, y: (height - 36) / 2, width: 36, height: 36)
            if emptyView.frame.size != CGSize(width: width, height: height) || tableView.tableFooterView == nil {
                emptyView.frame = CGRect(x: 0, y: 0, width: width, height: height)
                tableView.tableFooterView = emptyView
            }
        } else {
            tableView.tableFooterView = nil
        }
    }

    private func listContentHeight(width: CGFloat, limit: CGFloat) -> CGFloat {
        var height = summaryHeight(width: width)
        if state.candidates.isEmpty { return height + emptyHeight(width: width) }
        // Only measure enough rows to fill the dialog, even when importing thousands of sources.
        for index in state.candidates.indices {
            height += list.rowHeight(at: index, width: width)
            if height > limit { break }
        }
        return height
    }

    func dialogSize(fitting size: CGSize) -> CGSize {
        loadViewIfNeeded()
        let width = max(1, size.width)
        let chromeHeight =
            toolbar.sizeThatFits(CGSize(width: width, height: 0)).height
            + footer.sizeThatFits(CGSize(width: width, height: 0)).height
        let height = chromeHeight + listContentHeight(width: width, limit: max(0, size.height - chromeHeight))
        return CGSize(width: width, height: min(size.height, height))
    }

    private func invalidateDialogLayout() {
        view.setNeedsLayout()
        presentationController?.containerView?.setNeedsLayout()
    }

    private func updateControls() {
        let enabled = !isSaving && !isClosing
        isModalInPresentation = !enabled
        tableView.isUserInteractionEnabled = enabled
        list.setInteractive(enabled)
        moreButton.isEnabled = enabled
        groupButton.isEnabled = enabled
        let group = state.groupName ?? ""
        let groupTitle =
            group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SourceImportPreviewText.customGroup : (state.appendGroup ? "+" : "") + "【\(group)】"
        groupButton.configuration?.title = SourceImportPreviewAndroidStyle.singleLine(groupTitle)
        groupButton.accessibilityLabel = groupTitle
        footer.cancelButton.isEnabled = enabled
        footer.confirmButton.isEnabled = enabled && !isPreparing && !state.candidates.isEmpty && onConfirm != nil
        footer.selectionButton.isEnabled = enabled && !state.candidates.isEmpty
        let count = isPreparing ? "" : state.selectionTitle
        footer.selectionButton.configuration?.title = count
        footer.selectionButton.accessibilityLabel = count
        footer.selectionButton.accessibilityValue = state.isAllSelected ? SourceImportPreviewText.selected : nil
        footer.setSaving(isSaving)
        if isPreparing { loadingIndicator.startAnimating() } else { loadingIndicator.stopAnimating() }
        if !enabled {
            childRequestID = nil
            cancelPendingTracking()
            dismissOverflowMenu()
        }
        invalidateDialogLayout()
    }

    @objc private func moreTapped() {
        if overflowMenu != nil {
            guard canUsePreview else { return }
            dismissOverflowMenu()
            return
        }
        guard canInteract else { return }
        let id = UUID()
        menuActionID = id
        let snapshot = list.identities
        // The group command is always in the toolbar; these are Android's five overflow items.
        var items: [ReaderOverflowMenuView.Item] = [
            selectionItem(title: SourceImportPreviewText.selectNew, key: "new", isNew: true),
            selectionItem(title: SourceImportPreviewText.selectUpdate, key: "update", isNew: false),
        ]
        items += SourceImportPreviewState.PreservedValue.allCases.map { value in
            .init(identifier: value.identifier, title: value.title, isChecked: state.isPreserved(value)) { [weak self] in
                guard let self, self.canInteract else { return }
                self.state.togglePreserved(value)
                self.updateControls()
            }
        }
        items = items.map { item in
            .init(identifier: item.identifier, title: item.title, isChecked: item.isChecked, isEnabled: item.isEnabled) { [weak self] in
                guard let self, self.menuActionID == id, self.canInteract, self.list.matches(snapshot) else { return }
                self.menuActionID = nil
                item.handler()
            }
        }
        let menu = ReaderOverflowMenuView(items: items, anchorView: moreButton, interfaceStyle: traitCollection.userInterfaceStyle)
        menu.accessibilityIdentifier = "sourceImport.preview.overflowMenu"
        menu.canActivateItem = { [weak self, weak menu] in
            guard let self, let menu, self.overflowMenu === menu else { return false }
            return self.menuActionID == id && self.canUsePreview && self.list.matches(snapshot)
        }
        menu.onDismiss = { [weak self, weak menu] in
            guard let self, let menu, self.overflowMenu === menu else { return }
            self.overflowMenu = nil
            self.view.accessibilityElementsHidden = false
            // ReaderOverflowMenuView delivers the chosen item synchronously after onDismiss.
            DispatchQueue.main.async { [weak self] in
                if self?.menuActionID == id { self?.menuActionID = nil }
            }
        }
        cancelPendingTracking()
        overflowMenu = menu
        let host: UIView = presentationController?.containerView ?? view
        if host !== view { view.accessibilityElementsHidden = true }
        menu.present(in: host)
        if menu.superview == nil { dismissOverflowMenu() }
    }

    private func selectionItem(title: String, key: String, isNew: Bool) -> ReaderOverflowMenuView.Item {
        .init(identifier: "sourceImport.preview.select.\(key)", title: title) { [weak self] in
            guard let self, self.canInteract else { return }
            let indices = self.state.indices(isNew: isNew)
            self.list.rememberAnchor()
            let previous = self.state.selections
            self.state.toggleSelection(in: indices)
            self.selectionDidChange(previous: previous, indices: indices)
        }
    }

    private func dismissOverflowMenu() {
        menuActionID = nil
        overflowMenu?.dismiss()
        overflowMenu = nil
        if isViewLoaded { view.accessibilityElementsHidden = false }
    }

    private func selectionDidChange(previous: [Bool], indices: [Int]) {
        let changed = indices.filter { previous.indices.contains($0) && previous[$0] != state.selections[$0] }
        list.updateSelections(at: changed)
        updateControls()
    }

    @objc private func toggleAll() {
        guard canInteract else { return }
        list.rememberAnchor()
        let previous = state.selections
        let indices = Array(state.candidates.indices)
        state.toggleSelection(in: indices)
        selectionDidChange(previous: previous, indices: indices)
    }

    @objc private func editGroup() {
        guard canInteract else { return }
        let controller = SourceImportPreviewGroupViewController(groupName: state.groupName, appendGroup: state.appendGroup)
        let requestID = beginEditing(controller)
        controller.onSave = { [weak self, weak controller] groupName, appendGroup in
            guard let self, let controller, self.acceptEditorResult(requestID, from: controller) else { return }
            self.childRequestID = nil
            self.ownedEditor = nil
            self.list.rememberAnchor()
            self.state.groupName = groupName
            self.state.appendGroup = appendGroup
            self.updateControls()
        }
        present(controller, animated: true)
    }

    private func openCandidate(_ identity: SourceImportPreviewIdentity) {
        guard canInteract, let index = list.index(for: identity) else { return }
        do {
            let facade = try SharedRuntime.sourceManagementFacade().get()
            let controller = try SourceImportPreviewDraftViewController(source: state.candidates[index].source, facade: facade)
            let requestID = beginEditing(controller)
            controller.onSave = { [weak self, weak controller] candidate in
                guard let self, let controller, self.acceptEditorResult(requestID, from: controller),
                    self.list.index(for: identity) != nil
                else { return }
                self.childRequestID = nil
                self.ownedEditor = nil
                guard self.list.replaceCandidate(identity, with: candidate) else { return }
                self.updateControls()
            }
            present(controller, animated: true)
        } catch {
            presentError(error)
        }
    }

    private func beginEditing(_ controller: UIViewController) -> UUID {
        cancelPendingTracking()
        dismissOverflowMenu()
        let id = UUID()
        childRequestID = id
        ownedEditor = controller
        controller.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        controller.loadViewIfNeeded()
        controller.view.addSubview(
            SourceImportPreviewEditorLifetime { [weak self, weak controller] in
                guard let self, self.childRequestID == id, self.ownedEditor === controller,
                    controller?.presentingViewController == nil
                else { return }
                self.childRequestID = nil
                self.ownedEditor = nil
            })
        return id
    }

    private func acceptEditorResult(_ id: UUID, from controller: UIViewController) -> Bool {
        childRequestID == id && ownedEditor === controller && !isSaving && !isClosing && !didReportCompletion
            && isVisible && presentation.isActive
            && !isLeavingPresentation && !SourceImportPreviewDialogContainer.isLeavingPresentation(self)
            && presentingViewController?.presentedViewController === self && presentedViewController == nil
            && controller.presentingViewController == nil && viewIfLoaded?.window?.isKeyWindow == true
            && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    @objc private func confirmTapped() {
        guard canInteract, !isPreparing, let onConfirm else { return }
        let sources = state.selectedSources
        // Android confirms an empty selection by closing, without inserting or reporting an import.
        guard !sources.isEmpty else {
            closePreview()
            return
        }
        let options = state.options
        isSaving = true
        updateControls()
        importTask = Task { @MainActor [self] in
            do {
                try await onConfirm(sources, options)
                importTask = nil
                didImport = true
                closePreview()
            } catch {
                importTask = nil
                isSaving = false
                if isLeavingPresentation || presentingViewController == nil {
                    closePreview()
                } else {
                    updateControls()
                    pendingImportError = error
                    presentPendingImportError()
                }
            }
        }
    }

    private func presentPendingImportError() {
        guard let error = pendingImportError, canInteract else { return }
        pendingImportError = nil
        cancelPendingTracking()
        presentError(error)
    }

    @objc private func cancelTapped() {
        if overflowMenu != nil {
            guard canUsePreview else { return }
            dismissOverflowMenu()
            return
        }
        guard canInteract, !didReportCompletion else { return }
        closePreview()
    }

    private func closePreview() {
        guard !isClosing, !didReportCompletion else { return }
        isClosing = true
        childRequestID = nil
        updateControls()
        resignFirstResponder()
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            reportCompletion()
        }
    }

    private func reportCompletion() {
        guard !didReportCompletion else { return }
        didReportCompletion = true
        cancelPreparation()
        pendingImportError = nil
        let completion = didImport ? onImported : onCancel
        onCancel = nil
        onImported = nil
        onConfirm = nil
        completion?()
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { canInteract }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !isSaving else { return }
        isClosing = true
        reportCompletion()
    }

    private func toggleCandidate(_ identity: SourceImportPreviewIdentity) {
        guard canInteract, let index = list.index(for: identity) else { return }
        list.rememberAnchor()
        state.toggleSelection(at: index)
        list.updateSelections(at: [index])
        updateControls()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelPendingTracking()
        dismissOverflowMenu()
    }

    func presentationController(
        forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController
    ) -> UIPresentationController? {
        let controller = SourceImportPreviewPresentationController(presentedViewController: presented, presenting: presenting)
        controller.delegate = self
        return controller
    }

    func animationController(
        forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        SourceImportPreviewTransition(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        SourceImportPreviewTransition(isPresenting: false)
    }
}
