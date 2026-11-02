import SQLite3
import UIKit
import shared

/// The two modes retain independent drafts; only confirmation changes the search scope.
@MainActor
final class SearchScopeViewController: UIViewController {
    var onScopeSelected: ((SearchScopeSelection) -> Void)?

    private let dialogTransitioningDelegate = SearchScopeDialogTransitioningDelegate()
    private let groups: [String]
    private let allSources: [BookSource]
    private var filteredSources: [BookSource]
    private var selectedGroups: [String] = []
    private var selectedSource: (url: String, name: String)?
    private var sourceQuery = ""
    private enum Phase { case waiting, active, closing, finished }
    private var phase = Phase.waiting
    private var isVisible = false
    private var hasBegunPresentation = false
    private var ownership: SearchScopeDialogOwnership?
    private var sourceExpired = false
    private var pendingScope: SearchScopeSelection?
    private var isAppSuspended = false
    private var isSceneSuspended = false
    private var isWindowSuspended = false
    private var isLockCovered = false
    private var isUpdatingControls = false
    private var lastControlsEnabled: Bool?
    private var lastCancellationEnabled: Bool?
    private var refreshTimer: Timer?
    private var dismissalCompletions: [() -> Void] = []
    private var detachmentCheckScheduled = false

    private let toolbar = SearchScopeToolbarView()
    private let modeControl = SearchScopeModeControl()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let actions = SearchScopeActionsView()
    private lazy var fastScroller = ReaderListFastScroller(tableView: tableView)

    init(groups: [String], sources: [BookSource], currentScope _: SearchScopeSelection) {
        self.groups = groups
        allSources = SearchScopeSourceFilter.apply(sources, query: "")
        filteredSources = allSources
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .custom
        transitioningDelegate = dialogTransitioningDelegate
        // Android creates a fresh group-mode draft on every opening; the active
        // search scope stays outside the dialog until the user confirms.
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        refreshTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let host = SearchScopeDialogHostView()
        host.onDetach = { [weak self] in self?.scheduleDetachmentCheck() }
        view = host
    }

    func bindSource(_ source: UIViewController) {
        guard phase == .waiting, ownership == nil else { return }
        ownership = SearchScopeDialogOwnership(source: source)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = "searchScope.dialog"
        view.accessibilityViewIsModal = true
        toolbar.canInteract = { [weak self] in self?.canEdit == true }
        toolbar.onEscape = { [weak self] in self?.cancelSelection() ?? false }
        toolbar.onQueryChanged = { [weak self] query in self?.applyQuery(query) }
        modeControl.canInteract = { [weak self] in self?.canEdit == true }
        modeControl.accessibilityIdentifier = "searchScope.mode"
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        actions.onAllSources = { [weak self] in self?.finish(with: .allEnabled) }
        actions.onCancel = { [weak self] in self?.cancelSelection() }
        actions.onConfirm = { [weak self] in self?.confirm() }
        configureTable()
        configureLayout()
        toolbar.setSourceMode(!isGroupMode)
        observeAvailability()
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasBegunPresentation = true
        if ownership == nil, let presenter = presentingViewController { bindSource(presenter) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        // Covering and cancelled dismissal do not commit either independent draft.
        if phase == .closing { pendingScope = nil }
        phase = .active
        isVisible = true
        startRefreshTimer()
        updateControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if isPresentationBeingDismissed {
            if phase != .closing { pendingScope = nil }
            phase = .closing
        } else {
            pendingScope = nil
        }
        updateControls()
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            if context.isCancelled { self?.restoreCancelledDismissal() }
            self?.scheduleDetachmentCheck()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // UIKit can forward an independent child's dismissal through this presenter.
        if presentedViewController != nil, !isPresentationBeingDismissed {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        if let completion { dismissalCompletions.append(completion) }
        guard phase != .finished else {
            drainDismissalCompletions()
            return
        }
        pendingScope = nil
        guard phase != .closing else { return }
        guard let presenter = presentingViewController, presenter.presentedViewController === self else {
            scheduleDetachmentCheck()
            if !hasBegunPresentation { drainDismissalCompletions() }
            return
        }
        beginDismissal(animated: flag)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        actions.prepareLayout(width: view.safeAreaLayoutGuide.layoutFrame.width)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        fastScroller.apply(accent: SearchScopeStyle.accent)
    }

    override func accessibilityPerformEscape() -> Bool {
        cancelSelection()
    }

    private var isGroupMode: Bool { modeControl.selectedSegmentIndex == 0 }
    private var isSuspended: Bool { isAppSuspended || isSceneSuspended || isWindowSuspended || isLockCovered }
    private var canCancel: Bool {
        phase == .active && isVisible && !isSuspended && SearchScopeDialogOwnership.ownsPresentation(self)
    }
    private var canUseDraft: Bool {
        canCancel && !sourceExpired && ownership?.isCurrent(allowing: self) == true
    }
    private var canEdit: Bool { canUseDraft && !fastScroller.isScrubbing }

    private var isPresentationBeingDismissed: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(SearchScopeOptionCell.self, forCellReuseIdentifier: SearchScopeOptionCell.reuseIdentifier)
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 48
        tableView.sectionHeaderTopPadding = 0
        tableView.alwaysBounceVertical = true
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.showsVerticalScrollIndicator = false
        tableView.accessibilityIdentifier = "SearchScopeTable"
        fastScroller.accessibilityIdentifier = "searchScope.fastScroll"
        fastScroller.apply(accent: SearchScopeStyle.accent)
        fastScroller.onScrubbingChanged = { [weak self] active in
            guard let self else { return }
            if active { self.view.endEditing(true) }
            self.updateControls()
        }
    }

    private func configureLayout() {
        for item in [toolbar, modeControl, tableView, actions, fastScroller] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: safe.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            modeControl.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            modeControl.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 11),
            modeControl.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -11),
            tableView.topAnchor.constraint(equalTo: modeControl.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: actions.topAnchor),
            actions.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            fastScroller.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: 24),
            fastScroller.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 8),
            fastScroller.bottomAnchor.constraint(equalTo: tableView.bottomAnchor, constant: -8),
        ])
    }

    @objc private func modeChanged() {
        guard canEdit else { return }
        toolbar.setSourceMode(!isGroupMode)
        reloadList()
    }

    private func applyQuery(_ query: String) {
        guard canEdit, sourceQuery != query else { return }
        sourceQuery = query
        filteredSources = SearchScopeSourceFilter.apply(allSources, query: query)
        if !isGroupMode { reloadList() }
    }

    private func reloadList() {
        fastScroller.cancelScrubbing()
        tableView.reloadData()
        fastScroller.reload()
    }

    private func updateControls() {
        guard isViewLoaded, !isUpdatingControls else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        if ownership?.hasSameSource == false { sourceExpired = true }
        if pendingScope != nil,
            isSuspended || sourceExpired || presentedViewController != nil || ownership?.isCurrent(allowing: self) != true
        {
            pendingScope = nil
        }
        let draftEnabled = canUseDraft
        fastScroller.isEnabled = draftEnabled
        let enabled = draftEnabled && !fastScroller.isScrubbing
        let changed = lastControlsEnabled != enabled
        if changed {
            lastControlsEnabled = enabled
            toolbar.setControlsEnabled(enabled)
            modeControl.isEnabled = enabled
            modeControl.isUserInteractionEnabled = enabled
            actions.setControlsEnabled(enabled)
            tableView.allowsSelection = enabled
            for cell in tableView.visibleCells {
                if enabled { cell.accessibilityTraits.remove(.notEnabled) } else { cell.accessibilityTraits.insert(.notEnabled) }
            }
        }
        tableView.isUserInteractionEnabled = draftEnabled
        // A stale source can still close its own modal, but must never confirm.
        let cancellationEnabled = canCancel
        if changed || lastCancellationEnabled != cancellationEnabled {
            lastCancellationEnabled = cancellationEnabled
            actions.setCancellationEnabled(cancellationEnabled)
        }
        if phase == .closing { finishDismissalIfDetached() }
    }

    @discardableResult
    func cancelSelection(animated: Bool = true) -> Bool {
        guard canCancel else { return false }
        pendingScope = nil
        beginDismissal(animated: animated)
        return true
    }

    private func confirm() {
        guard canEdit else { return }
        let scope: SearchScopeSelection
        if isGroupMode {
            if selectedGroups.isEmpty {
                scope = .allEnabled
            } else if selectedGroups.count == 1, let group = selectedGroups.first {
                scope = .group(group)
            } else {
                scope = .groups(selectedGroups)
            }
        } else if let selectedSource {
            scope = .source(url: selectedSource.url, name: selectedSource.name)
        } else {
            scope = .allEnabled
        }
        finish(with: scope)
    }

    private func finish(with scope: SearchScopeSelection?, animated: Bool = true) {
        guard canEdit else { return }
        pendingScope = scope
        beginDismissal(animated: animated)
    }

    private func beginDismissal(animated: Bool) {
        guard phase != .closing, phase != .finished else { return }
        phase = .closing
        isVisible = false
        view.endEditing(true)
        updateControls()
        super.dismiss(animated: animated) { [self] in
            finishDismissalIfDetached()
            scheduleDetachmentCheck()
        }
    }

    func presentationTransitionEnded(completed: Bool) {
        if !completed {
            pendingScope = nil
            phase = .closing
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateControls()
            self?.scheduleDetachmentCheck()
        }
    }

    func dismissalTransitionEnded(completed: Bool) {
        if !completed { restoreCancelledDismissal() }
        scheduleDetachmentCheck()
    }

    private func restoreCancelledDismissal() {
        guard phase == .closing else { return }
        pendingScope = nil
        phase = .active
        isVisible = viewIfLoaded?.window != nil
        updateControls()
    }

    private func scheduleDetachmentCheck() {
        guard hasBegunPresentation, phase != .finished, !detachmentCheckScheduled else { return }
        detachmentCheckScheduled = true
        DispatchQueue.main.async { [self] in
            detachmentCheckScheduled = false
            finishDismissalIfDetached()
        }
    }

    private func finishDismissalIfDetached() {
        guard hasBegunPresentation, phase != .finished,
            presentingViewController == nil, presentedViewController == nil, parent == nil,
            viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil
        else { return }
        phase = .finished
        isVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
        NotificationCenter.default.removeObserver(self)
        let scope = pendingScope
        let callback = onScopeSelected
        pendingScope = nil
        onScopeSelected = nil
        // Clear one-shot state before entering caller code, and validate without the modal.
        if let scope, !sourceExpired, !isSuspended, ownership?.isCurrent(completing: self) == true { callback?(scope) }
        drainDismissalCompletions()
    }

    private func drainDismissalCompletions() {
        let completions = dismissalCompletions
        dismissalCompletions.removeAll()
        for completion in completions { completion() }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(
            timeInterval: 0.1, target: RefreshTarget(owner: self),
            selector: #selector(RefreshTarget.tick(_:)), userInfo: nil, repeats: true)
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeAvailability() {
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(suspendAvailability(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification,
            UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(resumeAvailability(_:)), name: name, object: nil)
        }
    }

    private func belongsToSource(_ notification: Notification) -> Bool {
        let window = ownership?.window ?? viewIfLoaded?.window
        if let scene = notification.object as? UIScene { return scene === window?.windowScene }
        if let changedWindow = notification.object as? UIWindow { return changedWindow === window }
        return true
    }

    @objc private func suspendAvailability(_ notification: Notification) {
        guard belongsToSource(notification) else { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification: isAppSuspended = true
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification: isSceneSuspended = true
        case .appLockWillCover: isLockCovered = true
        default: isWindowSuspended = true
        }
        pendingScope = nil
        updateControls()
    }

    @objc private func resumeAvailability(_ notification: Notification) {
        guard belongsToSource(notification) else { return }
        switch notification.name {
        case UIApplication.didBecomeActiveNotification: isAppSuspended = false
        case UIScene.didActivateNotification: isSceneSuspended = false
        case UIWindow.didBecomeKeyNotification, UIWindow.didBecomeVisibleNotification: isWindowSuspended = false
        case .appLockStatusDidChange: isLockCovered = !AppLockManager.shared.isUnlocked(in: ownership?.window)
        default: break
        }
        updateControls()
    }

    @MainActor
    private final class RefreshTarget: NSObject {
        weak var owner: SearchScopeViewController?
        init(owner: SearchScopeViewController) { self.owner = owner }
        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.updateControls()
        }
    }
}

extension SearchScopeViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        isGroupMode ? groups.count : filteredSources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(
                withIdentifier: SearchScopeOptionCell.reuseIdentifier, for: indexPath) as? SearchScopeOptionCell
        else { return UITableViewCell() }
        if isGroupMode, groups.indices.contains(indexPath.row) {
            let group = groups[indexPath.row]
            cell.configure(
                name: group, isGroup: true, isSelected: selectedGroups.contains(group),
                identifier: "searchScope.group.\(group)")
        } else if !isGroupMode, filteredSources.indices.contains(indexPath.row) {
            let source = filteredSources[indexPath.row]
            cell.configure(
                name: source.bookSourceName, isGroup: false,
                isSelected: selectedSource?.url == source.bookSourceUrl,
                identifier: "searchScope.source.\(source.bookSourceUrl)")
        }
        if !canEdit { cell.accessibilityTraits.insert(.notEnabled) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canEdit else { return }
        if isGroupMode {
            guard groups.indices.contains(indexPath.row) else { return }
            let group = groups[indexPath.row]
            if let selectedIndex = selectedGroups.firstIndex(of: group) {
                selectedGroups.remove(at: selectedIndex)
            } else {
                selectedGroups.append(group)
            }
            tableView.reloadRows(at: [indexPath], with: .none)
        } else {
            guard filteredSources.indices.contains(indexPath.row) else { return }
            let source = filteredSources[indexPath.row]
            let previousURL = selectedSource?.url
            selectedSource = (source.bookSourceUrl, source.bookSourceName)
            var changed = [indexPath]
            if let previous = filteredSources.firstIndex(where: { $0.bookSourceUrl == previousURL }),
                previous != indexPath.row
            {
                changed.append(IndexPath(row: previous, section: 0))
            }
            tableView.reloadRows(at: changed, with: .none)
        }
    }
}

/// Scope's flowSearch has no management-only "group:" or enabled-state commands.
enum SearchScopeSourceFilter {
    static func apply(_ sources: [BookSource], query: String) -> [BookSource] {
        let pattern = "%" + query + "%"
        return sources.enumerated().filter { entry in
            if query.isEmpty { return true }
            let source = entry.element
            let fields: [String?] = [
                source.bookSourceName, source.bookSourceUrl, source.bookSourceGroup, source.bookSourceComment,
            ]
            return fields.contains { value in value.map { sqlite3_strlike(pattern, $0, 0) == 0 } ?? false }
        }.sorted { lhs, rhs in
            lhs.element.customOrder == rhs.element.customOrder
                ? lhs.offset < rhs.offset : lhs.element.customOrder < rhs.element.customOrder
        }.map(\.element)
    }
}
