import shared
import UIKit

final class AndroidReplicaRssFavoritesViewController: UIViewController, UITableViewDelegate {
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
        if hasSnapshot { tableView.reloadData() }
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
            guard let self, let snapshot = self.favoritesByKey[key] else { return cell }
            cell.configure(title: snapshot.star.title, detail: snapshot.star.pubDate)
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
        let rows = favorites.filter { $0.group == selectedGroup }
        var snapshot = NSDiffableDataSourceSnapshot<Int, RssFavoriteKey>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows.map { $0.key })
        dataSource.applySnapshotUsingReloadData(snapshot)
        tabs.display(groups: groups, selected: selectedGroup)
        if rows.isEmpty { stateView.showMessage(title: L10n.RSS.favoritesEmpty) } else { stateView.hide() }
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
        if activeContext() != nil { tableView.reloadData() }
        updateControls()
    }

    @objc private func handleBack() {
        guard activeContext() != nil else { return }
        invalidateActions()
        navigationController?.popViewController(animated: true)
    }
}

private struct RssFavoriteKey: Hashable {
    let origin: String
    let link: String
    static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func == (lhs: Self, rhs: Self) -> Bool { equal(lhs.origin, rhs.origin) && equal(lhs.link, rhs.link) }
    func hash(into hasher: inout Hasher) { hasher.combine(Data(origin.utf8)); hasher.combine(Data(link.utf8)) }
}

private struct RssFavoriteGroup: Hashable {
    let raw: String
    var bytes: Data { Data(raw.utf8) }
    var label: String { raw.isEmpty ? RssFavoriteText.emptyGroup : raw }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

private struct RssFavoriteSnapshot {
    let star: RssStar
    let key: RssFavoriteKey
    let group: RssFavoriteGroup
    let fields: [Data?]
    init(_ star: RssStar) {
        self.star = star
        key = RssFavoriteKey(origin: star.origin, link: star.link)
        group = RssFavoriteGroup(raw: star.group)
        let values: [String?] = [
            star.origin, star.link, star.sort, star.title, star.group, star.pubDate,
            star.description_, star.content, star.image, star.variable,
        ]
        fields = values.map { $0.map { Data($0.utf8) } }
    }
}

private enum RssFavoriteTarget {
    case article(RssFavoriteSnapshot), group(RssFavoriteGroup), all
    func select(from favorites: [RssFavoriteSnapshot]) -> [RssFavoriteSnapshot] {
        switch self {
        case .article(let snapshot): return favorites.filter { $0.key == snapshot.key }
        case .group(let group): return favorites.filter { $0.group == group }
        case .all: return favorites
        }
    }
}

@MainActor
private final class RssFavoriteRequest {
    enum Phase { case ready, confirming, authorized, opening, submitted, finished, cancelled }
    let target: RssFavoriteTarget
    let snapshots: [RssFavoriteSnapshot]
    let context: RssFavoriteContext
    let generation: UUID
    var phase: Phase = .ready
    var dialog: ReaderRestoreProgressDialogViewController?
    init(target: RssFavoriteTarget, snapshots: [RssFavoriteSnapshot], context: RssFavoriteContext, generation: UUID) {
        self.target = target
        self.snapshots = snapshots
        self.context = context
        self.generation = generation
    }
}

@MainActor
private final class RssFavoriteContext {
    weak var window: UIWindow?
    weak var scene: UIWindowScene?
    weak var root: UIViewController?
    weak var navigation: UINavigationController?
    weak var top: UIViewController?
    let ancestry: [ObjectIdentifier]

    init(
        window: UIWindow, scene: UIWindowScene, root: UIViewController, navigation: UINavigationController,
        top: UIViewController
    ) {
        self.window = window
        self.scene = scene
        self.root = root
        self.navigation = navigation
        self.top = top
        var ancestry: [ObjectIdentifier] = []
        var current: UIViewController? = top
        while let controller = current { ancestry.append(ObjectIdentifier(controller)); current = controller.parent }
        self.ancestry = ancestry
    }

    func matches(_ host: UIViewController, dialog: UIViewController?) -> Bool {
        guard let window, let scene, let root, let navigation, let top, top === host,
            UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
            window.isKeyWindow, !window.isHidden, window.alpha > 0.01, window.isUserInteractionEnabled,
            !window.accessibilityElementsHidden, window.windowScene === scene, window.rootViewController === root,
            scene.activationState == .foregroundActive, AppLockManager.shared.isUnlocked(in: window),
            host.viewIfLoaded?.window === window, host.navigationController === navigation,
            navigation.topViewController === top
        else { return false }
        var actual: [ObjectIdentifier] = []
        var current: UIViewController? = host
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent, !controller.isMovingToParent else {
                return false
            }
            if let modal = controller.presentedViewController, modal !== dialog { return false }
            if let transition = controller.transitionCoordinator {
                guard let dialog,
                    transition.viewController(forKey: .from) === dialog
                        || transition.viewController(forKey: .to) === dialog
                else { return false }
            } else if controller.isBeingPresented {
                return false
            }
            if let tabs = controller as? UITabBarController, let child = actual.last,
                tabs.selectedViewController.map(ObjectIdentifier.init) != child
            {
                return false
            }
            actual.append(ObjectIdentifier(controller))
            current = controller.parent
        }
        guard actual == ancestry, actual.contains(ObjectIdentifier(root)) else { return false }
        if let dialog, let owner = dialog.presentingViewController {
            return ancestry.contains(ObjectIdentifier(owner)) && owner.presentedViewController === dialog
                && dialog.presentedViewController == nil
                && (dialog.viewIfLoaded?.window === window
                    || (dialog.isBeingPresented && dialog.viewIfLoaded?.window == nil))
        }
        return dialog?.presentedViewController == nil
            && dialog?.viewIfLoaded?.window == nil && dialog?.viewIfLoaded?.superview == nil
    }
}

@MainActor
private final class RssFavoriteTabs: UIScrollView {
    var onSelect: ((RssFavoriteGroup) -> Void)?
    private let stack = UIStackView()
    private var displayed: [RssFavoriteGroup] = []
    private var displayGeneration = UUID()
    private var selected: RssFavoriteGroup?
    private var revealSelection = false
    private var previousSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        showsHorizontalScrollIndicator = false
        accessibilityIdentifier = "rss.favorites.tabs"
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let height = heightAnchor.constraint(equalToConstant: 48)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height, stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func display(groups: [RssFavoriteGroup], selected: RssFavoriteGroup?) {
        isHidden = groups.count < 2
        guard groups != displayed || selected != self.selected else { return }
        displayGeneration = UUID()
        let generation = displayGeneration
        displayed = groups
        self.selected = selected
        revealSelection = true
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        for group in groups {
            let button = UIButton(type: .system)
            button.setTitle(group.label, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            button.titleLabel?.lineBreakMode = .byClipping
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            button.accessibilityLabel = group.label
            button.accessibilityTraits = group == selected ? [.button, .selected] : [.button]
            button.setTitleColor(
                group == selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.primaryText, for: .normal)
            button.addInteraction(UIToolTipInteraction(defaultToolTip: group.label))
            button.addAction(
                UIAction { [weak self, weak button, weak stack = self.stack] _ in
                    guard let self, let button, let stack,
                        self.displayGeneration == generation,
                        self.stack === stack, stack.superview === self,
                        button.superview === stack,
                        stack.arrangedSubviews.contains(where: { $0 === button })
                    else { return }
                    self.onSelect?(group)
                }, for: .touchUpInside)
            if group == selected {
                let indicator = UIView()
                indicator.backgroundColor = AndroidReplicaTheme.accent
                indicator.isUserInteractionEnabled = false
                indicator.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(indicator)
                NSLayoutConstraint.activate([
                    indicator.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    indicator.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    indicator.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                    indicator.heightAnchor.constraint(equalToConstant: 2),
                ])
            }
            stack.addArrangedSubview(button)
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isHidden, bounds.width > 0, revealSelection || previousSize != bounds.size else { return }
        revealSelection = false
        previousSize = bounds.size
        stack.layoutIfNeeded()
        if let index = displayed.firstIndex(where: { $0 == selected }) {
            let button = stack.arrangedSubviews[index]
            var rect = button.convert(button.bounds, to: self)
            rect.size.width = min(rect.width, bounds.width)
            scrollRectToVisible(rect, animated: false)
        }
    }
}

private enum RssFavoriteText {
    private static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }
    static let groups = text("rss.favorites.groups", "分组")
    static let more = text("rss.favorites.more_actions", "更多操作")
    static let emptyGroup = text("rss.favorites.empty_group", "未命名分组")
    static let deleteGroup = text("rss.favorites.delete_group", "删除当前分组")
    static let deleteAll = text("rss.favorites.delete_all", "删除全部收藏")
    static let confirmArticle = text("rss.favorites.confirm_article", "确定删除收藏？\n<%@>")
    static let confirmGroup = text("rss.favorites.confirm_group", "确定删除此分组的全部收藏？\n<%@>")
    static let confirmAll = text("rss.favorites.confirm_all", "确定删除全部收藏？此操作无法撤销。")
}
