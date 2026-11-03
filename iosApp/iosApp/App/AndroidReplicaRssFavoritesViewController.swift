import shared
import UIKit

final class AndroidReplicaRssFavoritesViewController: UIViewController, UITableViewDelegate {
    private struct CellSizeChange {
        weak var cell: AndroidReplicaRssArticleCell?
        let key: RssFavoriteKey
        let configurationID: UUID
        let generation: UUID
        let cellGeneration: UUID
        let context: RssFavoriteContext
    }

    private let screen = RssScreenAdapter()
    private lazy var topBar = AndroidReplicaDetailBar(
        title: L10n.RSS.favoritesTitle, target: self, backAction: #selector(handleBack))
    private let groupButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private let tabs = RssFavoriteTabs()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let stateView = ContentStateView()
    private var dataSource: UITableViewDiffableDataSource<Int, RssFavoriteKey>!
    private var subscription: FlowSubscription?
    private var bindingID = UUID()
    private var presentationID = UUID()
    private var presentationResumeID: UUID?
    private var cellGeneration = UUID()
    private var cellBindings: [ObjectIdentifier: (key: RssFavoriteKey, id: UUID)] = [:]
    private var heightUpdateID: UUID?
    private var pendingHeightChanges: [ObjectIdentifier: CellSizeChange] = [:]
    private var hasAppeared = false
    private var suspended = false
    private var showsProgress = false
    private var hasSnapshot = false
    private var favorites: [RssFavoriteSnapshot] = []
    private var favoritesByKey: [RssFavoriteKey: RssFavoriteSnapshot] = [:]
    private var groups: [RssFavoriteGroup] = []
    private var selectedGroup: RssFavoriteGroup?
    private var operation: RssFavoriteRequest?
    private var selection: RssFavoriteRequest?
    private var openTask: Task<Void, Never>?

    deinit {
        NotificationCenter.default.removeObserver(self)
        openTask?.cancel()
        subscription?.cancel()
        screen.unbind()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification, .appLockWillCover,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(suspendActions(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.protectedDataDidBecomeAvailableNotification,
            UIScene.didActivateNotification, UIWindow.didBecomeKeyNotification, .appLockStatusDidChange,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(resumeActions(_:)), name: name, object: nil)
        }
        bindScreen()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        schedulePresentationResume()
        updateControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hasAppeared = false
        invalidateActions()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        topBar.updateLayout(availableSize: view.bounds.size)
        if let operation, operation.phase != .submitted, !ownsContext(operation) { invalidateActions() }
        updateControls()
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.separatorStyle = .none
        tableView.register(
            AndroidReplicaRssArticleCell.self, forCellReuseIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "rss.favorites.table"
        stateView.setTestingIdentifier("rss.favorites.state")
        stateView.backgroundColor = AndroidReplicaTheme.background
        let content = UIStackView(arrangedSubviews: [tabs, tableView])
        content.axis = .vertical
        for item in [topBar, content, stateView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stateView.topAnchor.constraint(equalTo: tableView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
        ])
        configureButton(
            groupButton, image: "list.bullet", title: RssFavoriteText.groups, identifier: "rss.favorites.groups")
        configureButton(moreButton, image: "ellipsis", title: RssFavoriteText.more, identifier: "rss.favorites.more")
        progress.color = AndroidReplicaTheme.toolbarText
        moreButton.addSubview(progress)
        progress.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: moreButton.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: moreButton.centerYAnchor),
        ])
        groupButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.groupActions() ?? [])
            }
        ])
        moreButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.deleteActions() ?? [])
            }
        ])
        tabs.onSelect = { [weak self] group in
            guard let self, let request = self.makeRequest(.group(group)) else { return }
            self.selectGroup(group, request: request)
        }
        dataSource = UITableViewDiffableDataSource<Int, RssFavoriteKey>(tableView: tableView) {
            [weak self] table, path, key in
            let cell =
                table.dequeueReusableCell(withIdentifier: AndroidReplicaRssArticleCell.reuseIdentifier, for: path)
                as! AndroidReplicaRssArticleCell
            cell.onSizeChange = nil
            cell.cancelThumbnailLoading()
            cell.accessibilityCustomActions = nil
            guard let self, let snapshot = self.favoritesByKey[key] else { return cell }
            cell.configure(favorite: snapshot.star)
            self.cellBindings[ObjectIdentifier(cell)] = (key, UUID())
            let generation = self.presentationID
            let context = self.captureContext()
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: L10n.Common.delete) { [weak self] _ in
                    guard let self, self.presentationID == generation, context?.matches(self, dialog: nil) == true,
                        let request = self.makeRequest(.article(snapshot))
                    else { return false }
                    self.confirmDeletion(request)
                    return true
                }
            ]
            return cell
        }
        tabs.isHidden = true
        updateControls()
    }

    private func configureButton(_ button: UIButton, image: String, title: String, identifier: String) {
        button.setImage(UIImage(systemName: image), for: .normal)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        button.showsMenuAsPrimaryAction = true
        topBar.addAction(button)
    }

    private func bindScreen() {
        bindingID = UUID()
        let id = bindingID
        subscription?.cancel()
        subscription = nil
        hasSnapshot = false
        stateView.showLoading(message: L10n.RSS.favoritesTitle)
        if case let .failure(error) = screen.bootstrap() { showBootstrapError(error); return }
        switch SharedRuntime.rssFacade() {
        case .success(let facade):
            // The adapter's abbreviated signature omits fields needed for stale-action checks.
            subscription = facade.watchFavorites { [weak self] stars in
                DispatchQueue.main.async {
                    guard let self, self.bindingID == id else { return }
                    self.receiveFavorites(stars)
                }
            }
        case .failure(let error): showBootstrapError(error)
        }
        updateControls()
    }

    private func showBootstrapError(_ error: SharedRuntimeError) {
        stateView.showMessage(title: L10n.RSS.unavailable, message: error.message, actionTitle: L10n.Common.retry) {
            [weak self] in
            guard let self, self.activeContext() != nil, self.operation == nil else { return }
            self.bindScreen()
        }
    }

    private func receiveFavorites(_ stars: [RssStar]) {
        let previousGroup = selectedGroup
        let previousGroups = groups
        let previousKeys = dataSource.snapshot().itemIdentifiers
        let firstPath = tableView.indexPathsForVisibleRows?.sorted().first
        let anchor = firstPath.flatMap { dataSource.itemIdentifier(for: $0) }
        let offset = firstPath.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y } ?? 0
        // The repository supplies starTime DESC; filtering must not rewrite or re-sort stars.
        favorites = stars.map(RssFavoriteSnapshot.init)
        favoritesByKey = Dictionary(uniqueKeysWithValues: favorites.map { ($0.key, $0) })
        groups = Array(Set(favorites.map { $0.group })).sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        if let previousGroup, groups.contains(previousGroup) {
            selectedGroup = previousGroup
        } else if let previousGroup, let index = previousGroups.firstIndex(of: previousGroup) {
            let neighbors = Array(previousGroups.dropFirst(index + 1)) + Array(previousGroups.prefix(index).reversed())
            selectedGroup = neighbors.first(where: { groups.contains($0) }) ?? groups.first
        } else {
            selectedGroup = groups.first
        }
        hasSnapshot = true
        selection = nil
        if let operation, operation.phase != .submitted, !isCurrent(operation) { invalidateActions() }
        renderRows()
        if selectedGroup == previousGroup, let anchor, let oldIndex = previousKeys.firstIndex(of: anchor) {
            let current = Set(dataSource.snapshot().itemIdentifiers)
            let candidates =
                [anchor] + Array(previousKeys.dropFirst(oldIndex + 1)) + Array(previousKeys.prefix(oldIndex).reversed())
            if let key = candidates.first(where: { current.contains($0) }), let path = dataSource.indexPath(for: key) {
                tableView.layoutIfNeeded()
                let minimum = -tableView.adjustedContentInset.top
                let maximum = max(
                    minimum,
                    tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                tableView.contentOffset.y = min(maximum, max(minimum, tableView.rectForRow(at: path).minY - offset))
            }
        } else if selectedGroup != previousGroup {
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        }
        updateControls()
    }

    private func renderRows() {
        cellGeneration = UUID()
        cancelVisibleThumbnails()
        cellBindings.removeAll()
        let rows = favorites.filter { $0.group == selectedGroup }
        var snapshot = NSDiffableDataSourceSnapshot<Int, RssFavoriteKey>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map { $0.key })
        dataSource.applySnapshotUsingReloadData(snapshot)
        tabs.display(groups: groups, selected: selectedGroup)
        if rows.isEmpty { stateView.showMessage(title: L10n.RSS.favoritesEmpty) } else { stateView.hide() }
    }

    private func reloadRows() {
        cellGeneration = UUID()
        cancelVisibleThumbnails()
        cellBindings.removeAll()
        tableView.reloadData()
        resumeVisibleThumbnails()
    }

    private func schedulePresentationResume() {
        guard hasAppeared, !suspended, presentationResumeID == nil else { return }
        let id = UUID()
        let generation = presentationID
        presentationResumeID = id
        let resume: () -> Void = { [weak self] in
            guard let self, self.presentationResumeID == id else { return }
            self.presentationResumeID = nil
            guard self.presentationID == generation, self.activeContext() != nil else { return }
            if self.hasSnapshot { self.reloadRows() }
            self.updateControls()
        }
        // UIKit may retain presentation links/coordinators through viewDidAppear and transition completion.
        let enqueue = { DispatchQueue.main.async(execute: resume) }
        if let coordinator = transitionCoordinator,
            coordinator.animate(alongsideTransition: nil, completion: { _ in enqueue() })
        {
            return
        }
        enqueue()
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard tableView === self.tableView, let cell = cell as? AndroidReplicaRssArticleCell else { return }
        resumeThumbnail(for: cell, at: indexPath)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard tableView === self.tableView, let cell = cell as? AndroidReplicaRssArticleCell else { return }
        pendingHeightChanges.removeValue(forKey: ObjectIdentifier(cell))
        cell.onSizeChange = nil
        cell.cancelThumbnailLoading()
    }

    private func resumeThumbnail(for cell: AndroidReplicaRssArticleCell, at indexPath: IndexPath) {
        guard let context = activeContext(), let key = dataSource.itemIdentifier(for: indexPath),
            cellBindings[ObjectIdentifier(cell)]?.key == key,
            let snapshot = favoritesByKey[key], snapshot.group == selectedGroup
        else {
            cell.onSizeChange = nil
            cell.cancelThumbnailLoading()
            return
        }
        let generation = presentationID
        let cellGeneration = self.cellGeneration
        let configurationID = UUID()
        cellBindings[ObjectIdentifier(cell)] = (key, configurationID)
        cell.onSizeChange = { [weak self, weak cell] resizedCell in
            guard let self, let cell, resizedCell === cell else { return }
            self.scheduleHeightUpdate(
                CellSizeChange(
                    cell: cell, key: key, configurationID: configurationID, generation: generation,
                    cellGeneration: cellGeneration, context: context))
        }
        cell.resumeThumbnailLoading()
    }

    private func resumeVisibleThumbnails() {
        guard activeContext() != nil else { return }
        for cell in tableView.visibleCells {
            guard let cell = cell as? AndroidReplicaRssArticleCell,
                let path = tableView.indexPath(for: cell), tableView.cellForRow(at: path) === cell,
                cell.window === viewIfLoaded?.window, !cell.isHidden,
                tableView.indexPathsForVisibleRows?.contains(path) == true
            else { continue }
            resumeThumbnail(for: cell, at: path)
        }
    }

    private func cancelVisibleThumbnails() {
        heightUpdateID = nil
        pendingHeightChanges.removeAll()
        for case let cell as AndroidReplicaRssArticleCell in tableView.visibleCells {
            cell.onSizeChange = nil
            cell.cancelThumbnailLoading()
        }
    }

    private func ownsCell(_ change: CellSizeChange) -> Bool {
        guard hasAppeared, !suspended, change.generation == presentationID,
            change.cellGeneration == cellGeneration, change.context.matches(self, dialog: nil),
            let cell = change.cell, let path = tableView.indexPath(for: cell),
            let binding = cellBindings[ObjectIdentifier(cell)], binding.key == change.key,
            binding.id == change.configurationID,
            tableView.cellForRow(at: path) === cell, dataSource.itemIdentifier(for: path) == change.key,
            let snapshot = favoritesByKey[change.key], snapshot.group == selectedGroup
        else { return false }
        return true
    }

    private func scheduleHeightUpdate(_ change: CellSizeChange) {
        guard ownsCell(change), let cell = change.cell else { return }
        pendingHeightChanges[ObjectIdentifier(cell)] = change
        guard heightUpdateID == nil else { return }
        let id = UUID()
        heightUpdateID = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.heightUpdateID == id else { return }
            self.heightUpdateID = nil
            let changes = Array(self.pendingHeightChanges.values)
            self.pendingHeightChanges.removeAll()
            guard
                changes.contains(where: { change in
                    guard self.ownsCell(change), let cell = change.cell,
                        cell.window === change.context.window, let path = self.tableView.indexPath(for: cell)
                    else { return false }
                    return self.tableView.indexPathsForVisibleRows?.contains(path) == true
                })
            else { return }
            UIView.performWithoutAnimation { self.tableView.performBatchUpdates(nil) }
        }
    }

    private func groupActions() -> [UIMenuElement] {
        groups.compactMap { group in
            guard let request = makeRequest(.group(group)) else { return nil }
            return UIAction(title: group.label, state: selectedGroup == group ? .on : .off) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.selectGroup(group, request: request) }
            }
        }
    }

    private func selectGroup(_ group: RssFavoriteGroup, request: RssFavoriteRequest) {
        guard consumeReady(request) else { return }
        request.phase = .finished
        guard group != selectedGroup else { return }
        invalidateActions()
        selectedGroup = group
        renderRows()
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: false)
        updateControls()
    }

    private func deleteActions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if let group = selectedGroup, let request = makeRequest(.group(group)) {
            actions.append(
                UIAction(
                    title: RssFavoriteText.deleteGroup, image: UIImage(systemName: "trash"), attributes: .destructive
                ) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.confirmDeletion(request) }
                })
        }
        if let request = makeRequest(.all) {
            actions.append(
                UIAction(
                    title: RssFavoriteText.deleteAll, image: UIImage(systemName: "trash"), attributes: .destructive
                ) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.confirmDeletion(request) }
                })
        }
        return actions
    }

    private func makeRequest(_ target: RssFavoriteTarget) -> RssFavoriteRequest? {
        guard operation == nil, hasSnapshot, let context = activeContext() else { return nil }
        let targets: [RssFavoriteSnapshot]
        if case .article(let snapshot) = target {
            targets = [snapshot]
        } else {
            targets = target.select(from: favorites)
        }
        guard !targets.isEmpty else { return nil }
        let request = RssFavoriteRequest(
            target: target, snapshots: targets, context: context, generation: presentationID)
        return isCurrent(request) ? request : nil
    }

    private func isCurrent(_ request: RssFavoriteRequest) -> Bool {
        let current = request.target.select(from: favorites)
        let byKey = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
        return current.count == request.snapshots.count
            && request.snapshots.allSatisfy { expected in
                guard let actual = byKey[expected.key] else { return false }
                return actual.fields == expected.fields && actual.star.starTime == expected.star.starTime
            }
    }

    private func consumeReady(_ request: RssFavoriteRequest) -> Bool {
        guard request.phase == .ready else { return false }
        request.phase = .cancelled
        return operation == nil && ownsContext(request) && isCurrent(request)
    }

    private func confirmDeletion(_ request: RssFavoriteRequest) {
        guard consumeReady(request) else { return }
        request.phase = .confirming
        operation = request
        let message: String
        switch request.target {
        case .article(let snapshot): message = String(format: RssFavoriteText.confirmArticle, snapshot.star.title)
        case .group(let group): message = String(format: RssFavoriteText.confirmGroup, group.label)
        case .all: message = RssFavoriteText.confirmAll
        }
        let dialog = ReaderRestoreProgressDialogViewController(
            title: L10n.RSS.favoritesTitle, message: message, accessibilityIdentifierPrefix: "rss.favorites.delete"
        ) { [weak self, weak request] confirmed in
            guard let self, let request, self.operation === request, request.phase == .confirming else { return }
            guard confirmed, self.ownsContext(request), self.isCurrent(request) else {
                request.phase = .finished
                self.operation = nil
                self.updateControls()
                return
            }
            request.phase = .authorized
            self.submitDeletion(request)
        }
        request.dialog = dialog
        dialog.canConfirm = { [weak self, weak request] in
            guard let self, let request else { return false }
            return self.operation === request && request.phase == .confirming && self.ownsContext(request)
                && self.isCurrent(request)
        }
        dialog.onClose = { [weak self, weak request] in
            guard let self else { return }
            if let request, self.operation === request, request.phase == .confirming {
                request.phase = .finished
                self.operation = nil
            }
            self.updateControls()
            self.schedulePresentationResume()
            DispatchQueue.main.async { [weak self] in self?.updateControls() }
        }
        updateControls()
        present(dialog, animated: true) { [weak self, request] in
            guard let self else { return }
            if self.operation !== request || !self.ownsContext(request) { self.dismissOwnedDialog(request) }
        }
    }

    private func submitDeletion(_ request: RssFavoriteRequest) {
        Task { @MainActor [weak self, request] in
            guard let self, self.operation === request, request.phase == .authorized else { return }
            guard self.ownsContext(request), self.isCurrent(request) else { self.invalidateActions(); return }
            do {
                let facade = try RssArticleFavoritesFacade.companion.create()
                // Leaving/locking invalidates UI delivery, not an already submitted database write.
                request.phase = .submitted
                self.updateControls()
                try await SharedAsync.void { completion in
                    switch request.target {
                    case .article(let snapshot):
                        facade.deleteFavorite(
                            origin: snapshot.key.origin, link: snapshot.key.link, completionHandler: completion)
                    case .group(let group): facade.deleteFavoriteGroup(group: group.raw, completionHandler: completion)
                    case .all: facade.deleteAllFavorites(completionHandler: completion)
                    }
                }
                self.finishDeletion(request, error: nil)
            } catch {
                self.finishDeletion(request, error: error)
            }
        }
    }

    private func finishDeletion(_ request: RssFavoriteRequest, error: Error?) {
        guard operation === request else { return }
        let canReport = ownsContext(request)
        request.phase = .finished
        operation = nil
        updateControls()
        if canReport, let error { showTransientMessage(error.userFacingMessage) }
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        selection = request(at: indexPath)
        return selection == nil ? nil : indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let request = selection
        selection = nil
        guard let request, case .article(let snapshot) = request.target,
            dataSource.itemIdentifier(for: indexPath) == snapshot.key,
            consumeReady(request)
        else { return }
        request.phase = .opening
        operation = request
        updateControls()
        openTask = Task { @MainActor [weak self, request] in
            guard let self else { return }
            defer {
                if self.operation === request {
                    request.phase = .finished
                    self.operation = nil
                    self.openTask = nil
                    self.updateControls()
                }
            }
            do {
                let sources = try await self.screen.loadAllSources()
                guard !Task.isCancelled, self.operation === request, self.ownsContext(request), self.isCurrent(request)
                else { return }
                let source = sources.first { RssFavoriteKey.equal($0.sourceUrl, snapshot.key.origin) }
                self.navigationController?.pushViewController(
                    AndroidReplicaRssArticleViewController(
                        article: snapshot.star.toRssArticle(read: false), source: source, screen: self.screen,
                        favorites: self.favorites.map { $0.star }), animated: true)
            } catch {
                if !Task.isCancelled, self.operation === request, self.ownsContext(request), self.isCurrent(request) {
                    self.showTransientMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func request(at indexPath: IndexPath) -> RssFavoriteRequest? {
        guard let key = dataSource.itemIdentifier(for: indexPath), let snapshot = favoritesByKey[key] else {
            return nil
        }
        return makeRequest(.article(snapshot))
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration?
    {
        guard let request = request(at: indexPath) else { return nil }
        let action = UIContextualAction(style: .destructive, title: L10n.Common.delete) {
            [weak self] _, _, completion in
            completion(false)
            DispatchQueue.main.async { [weak self] in self?.confirmDeletion(request) }
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint)
        -> UIContextMenuConfiguration?
    {
        guard let request = request(at: indexPath) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: L10n.Common.delete, image: UIImage(systemName: "trash"), attributes: .destructive) {
                    [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.confirmDeletion(request) }
                }
            ])
        }
    }

    private func activeContext() -> RssFavoriteContext? {
        guard hasAppeared, !suspended, let context = captureContext() else { return nil }
        return context.matches(self, dialog: nil) ? context : nil
    }

    private func captureContext() -> RssFavoriteContext? {
        guard let window = viewIfLoaded?.window, let scene = window.windowScene,
            let root = window.rootViewController, let navigation = navigationController,
            navigation.topViewController === self
        else { return nil }
        return RssFavoriteContext(window: window, scene: scene, root: root, navigation: navigation, top: self)
    }

    private func ownsContext(_ request: RssFavoriteRequest) -> Bool {
        hasAppeared && !suspended && request.generation == presentationID
            && request.context.matches(self, dialog: request.dialog)
    }

    private func updateControls() {
        guard isViewLoaded else { return }
        let enabled = operation == nil && activeContext() != nil && hasSnapshot
        tableView.isUserInteractionEnabled = enabled
        tabs.isUserInteractionEnabled = enabled
        groupButton.isEnabled = enabled && !groups.isEmpty
        moreButton.isEnabled = enabled && !favorites.isEmpty
        let busy = operation?.phase == .submitted || operation?.phase == .opening
        if busy != showsProgress {
            showsProgress = busy
            moreButton.setImage(busy ? nil : UIImage(systemName: "ellipsis"), for: .normal)
            moreButton.accessibilityValue = busy ? L10n.Common.loadingTitle : nil
            if busy { progress.startAnimating() } else { progress.stopAnimating() }
        }
    }

    private func invalidateActions() {
        presentationID = UUID()
        presentationResumeID = nil
        cancelVisibleThumbnails()
        selection = nil
        if let operation, operation.phase != .submitted {
            operation.phase = .cancelled
            self.operation = nil
            openTask?.cancel()
            openTask = nil
            dismissOwnedDialog(operation)
        }
        updateControls()
    }

    private func dismissOwnedDialog(_ request: RssFavoriteRequest) {
        guard let dialog = request.dialog, !dialog.isBeingPresented, let owner = dialog.presentingViewController,
            request.context.ancestry.contains(ObjectIdentifier(owner)), owner.presentedViewController === dialog,
            dialog.presentedViewController == nil
        else { return }
        dialog.dismiss(animated: false)
    }

    @objc private func suspendActions(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        suspended = true
        invalidateActions()
    }

    @objc private func resumeActions(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        if let window = notification.object as? UIWindow, window !== viewIfLoaded?.window { return }
        suspended = false
        if let operation, operation.phase != .submitted, !ownsContext(operation) { invalidateActions() }
        schedulePresentationResume()
        updateControls()
    }

    @objc private func handleBack() {
        guard activeContext() != nil else { return }
        invalidateActions()
        navigationController?.popViewController(animated: true)
    }
}
