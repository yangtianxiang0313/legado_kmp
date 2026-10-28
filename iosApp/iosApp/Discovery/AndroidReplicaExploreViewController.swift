import UIKit
import shared

final class AndroidReplicaExploreViewController: UIViewController, UITableViewDelegate {
    private let adapter = ExploreScreenAdapter()
    private let sourceScreen = SourceManagementScreenAdapter()
    private let toolbar = ExploreToolbarView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = AndroidExploreTextLabel()
    private let stateView = ContentStateView()
    private var sources: [BookSourcePart] = []
    private lazy var sourceList = ExploreSourceListCoordinator(tableView: tableView, interactionView: view)
    private var expandedSourceURL: String?
    private var kindsCache: [String: [ExploreKind]] = [:]
    private var invalidatedSourceURLs: Set<String> = []
    private var isLoadingKinds = false
    private var isBusy = false
    private var isActive = false
    private var sceneSuspended = false
    private var presentationCovered = false
    private var lastControlsActive: Bool?
    private var lastPreservesSearchFocus: Bool?
    private var presentationID = UUID()
    private var requestGeneration = 0
    private var kindsTask: Task<Void, Never>?
    private weak var menu: ReaderOverflowMenuView?
    private weak var menuAnchor: UIView?
    private weak var menuOriginalAnchor: UIView?
    private var menuValidation: (() -> Bool)?
    private var menuActionID: UUID?
    private var sourceActionBinding: ExploreSourceListCoordinator.Binding?
    private lazy var actions = ExploreSourceActionCoordinator(
        presenter: self, screen: sourceScreen,
        canStart: { [weak self] in
            guard let self, self.canPresent, self.menu == nil else { return false }
            return self.sourceActionBinding.map { self.sourceList.hasCurrentSource($0) } ?? true
        },
        onBusyChange: { [weak self] busy in
            guard let self else { return }
            self.isBusy = busy
            self.tableView.isUserInteractionEnabled = !busy
            self.updatePresentationControls()
            if busy {
                self.sourceList.invalidateInput()
            } else {
                self.sourceList.resumeDelivery()
                DispatchQueue.main.async { [weak self] in self?.sourceActionBinding = nil }
            }
        })

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        bootstrap()
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneStateChanged(_:)), name: name, object: nil)
        }
        for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowStateChanged(_:)), name: name, object: nil)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isActive = true
        sceneSuspended = view.window?.windowScene?.activationState != .foregroundActive
        resumePresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        toolbar.updateLayout(availableSize: view.bounds.size)
        updatePresentationControls()
        if let menuAnchor, let original = menuOriginalAnchor {
            menuAnchor.frame = original.convert(original.bounds, to: view)
        }
        sourceList.resumeDelivery()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded,
            previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
        {
            emptyLabel.font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isActive = false
        suspendPresentation()
    }

    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        guard canPresent else { return }
        // Alerts/sheets may cover this root without another appearance callback on dismissal.
        presentationCovered = true
        presentationID = UUID()
        sourceList.invalidateInput()
        menu?.dismiss()
        updatePresentationControls()
        controller.loadViewIfNeeded()
        let observer = ExploreSourcePresentationObserver(frame: .zero)
        observer.isUserInteractionEnabled = false
        observer.isAccessibilityElement = false
        observer.onRemoval = { [weak self, weak controller] in
            let resume = { [weak self] in
                self?.presentationCovered = false
                self?.resumePresentation()
            }
            if let transition = controller?.transitionCoordinator {
                if !transition.animate(alongsideTransition: nil, completion: { _ in resume() }) { resume() }
            } else {
                resume()
            }
        }
        controller.view.addSubview(observer)
        super.present(controller, animated: animated, completion: completion)
    }

    deinit {
        kindsTask?.cancel()
        adapter.unbind()
        sourceScreen.unbind()
        NotificationCenter.default.removeObserver(self)
    }

    private var canPresent: Bool {
        guard isActive, !sceneSuspended, isVisibleInNavigationStack,
            let window = viewIfLoaded?.window, window.isKeyWindow, !window.isHidden, window.alpha > 0.01,
            window.windowScene?.activationState == .foregroundActive,
            navigationController?.transitionCoordinator == nil
        else { return false }
        var candidate: UIViewController? = self
        while let controller = candidate {
            guard controller.presentedViewController == nil,
                !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false, (controller.viewIfLoaded?.alpha ?? 0) > 0.01
            else { return false }
            candidate = controller.parent
        }
        return true
    }

    private func resumePresentation() {
        sourceList.setPresentationActive(isActive && !sceneSuspended)
        updatePresentationControls()
        if canPresent, let url = expandedSourceURL, invalidatedSourceURLs.contains(url), !isLoadingKinds {
            loadKinds(sourceURL: url, forceRefresh: true)
        }
        sourceList.resumeDelivery()
    }

    private func suspendPresentation() {
        presentationID = UUID()
        sourceList.setPresentationActive(false)
        menu?.dismiss()
        actions.invalidatePresentation()
        toolbar.searchField.resignFirstResponder()
        updatePresentationControls()
    }

    private var controlsActive: Bool { canPresent && !presentationCovered && !isBusy && menu == nil }

    func handleTabReselection() {
        guard controlsActive, stateView.isHidden, sourceList.consumeTabReselection() else { return }
        if expandedSourceURL != nil {
            sourceList.noteUserInteraction()
            collapseSource()
            applyFilter()
        } else {
            sourceList.scrollToTop(
                animated: UserDefaults.standard.string(forKey: "theme_mode") != "E_INK"
                    && !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func updatePresentationControls() {
        let active = controlsActive
        let preservesSearchFocus =
            isActive && !sceneSuspended && !presentationCovered
            && canPresent && (menu != nil || isBusy)
        // Busy -> presented keeps controls inactive but must release the underlying editor.
        guard lastControlsActive != active || lastPreservesSearchFocus != preservesSearchFocus else { return }
        lastControlsActive = active
        lastPreservesSearchFocus = preservesSearchFocus
        toolbar.setInteractionEnabled(active, preservingSearchFocus: preservesSearchFocus)
        for cell in tableView.visibleCells {
            (cell as? AndroidExploreSourceCell)?.setPresentationActive(active)
        }
    }

    @objc private func sceneStateChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === viewIfLoaded?.window?.windowScene else { return }
        sceneSuspended = notification.name != UIScene.didActivateNotification
        if sceneSuspended { suspendPresentation() } else { resumePresentation() }
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === viewIfLoaded?.window else { return }
        if notification.name == UIWindow.didResignKeyNotification {
            presentationID = UUID()
            sourceList.invalidateInput()
            menu?.dismiss()
            actions.invalidatePresentation()
            updatePresentationControls()
        } else {
            resumePresentation()
        }
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbar.onQueryChange = { [weak self] in
            self?.sourceList.noteUserInteraction()
            self?.applyFilter()
        }
        toolbar.onSubmit = { [weak self] in
            guard let self, self.controlsActive else { return }
            self.sourceList.noteUserInteraction()
            self.toolbar.hideKeyboardKeepingFocus()
        }
        toolbar.onGroup = { [weak self] in self?.showGroups() }
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.keyboardDismissMode = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.delegate = self
        tableView.accessibilityIdentifier = UIIdentifiers.Discovery.table
        configureSourceList()
        emptyLabel.text = "当前没有发现源！"
        emptyLabel.font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        emptyLabel.adjustsFontForContentSizeCategory = false
        emptyLabel.textColor = AndroidReplicaTheme.primaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.accessibilityIdentifier = "discovery.empty"
        stateView.setTestingIdentifier(UIIdentifiers.Discovery.state)
        for item in [toolbar, tableView, emptyLabel, stateView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        let preferredListBottom = tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        preferredListBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            preferredListBottom,
            tableView.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stateView.topAnchor.constraint(equalTo: tableView.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
        ])
        updatePresentationControls()
    }

    private func configureSourceList() {
        sourceList.canUsePage = { [weak self] in
            self?.canPresent == true && self?.presentationCovered == false && self?.isBusy == false
        }
        sourceList.onDeliver = { [weak self] count, showsEmpty in
            self?.tableView.accessibilityValue = String(count)
            self?.emptyLabel.isHidden = !showsEmpty
            self?.stateView.hide()
            self?.updatePresentationControls()
        }
        sourceList.onToggle = { [weak self] binding in
            guard let self, let source = self.sourceList.source(for: binding) else { return }
            self.toggle(source)
        }
        sourceList.onKindSelected = { [weak self] binding, kind in
            guard let self, let source = self.sourceList.source(for: binding) else { return }
            self.sourceList.noteUserInteraction()
            self.open(kind, source: source)
        }
        sourceList.onShowMenu = { [weak self] binding, anchor in self?.showSourceMenu(binding, anchor: anchor) }
    }

    private func bootstrap() {
        // ExploreFragment starts with an empty recycler and a hidden empty message.
        // Only expanded source headers display a loading indicator on this screen.
        stateView.hide()
        emptyLabel.isHidden = true
        adapter.onSourcesChange = { [weak self] sources in
            guard let self else { return }
            let previous = self.sources.first { $0.bookSourceUrl == self.expandedSourceURL }
            self.sources = sources
            let validURLs = Set(sources.map(\.bookSourceUrl))
            self.kindsCache = self.kindsCache.filter { validURLs.contains($0.key) }
            if let url = self.expandedSourceURL {
                let updated = sources.first { $0.bookSourceUrl == url }
                if updated == nil {
                    self.collapseSource()
                } else if previous?.lastUpdateTime != updated?.lastUpdateTime {
                    self.kindsCache[url] = nil
                    self.invalidatedSourceURLs.insert(url)
                    self.loadKinds(sourceURL: url, forceRefresh: true)
                }
            }
            self.applyFilter()
        }
        if case .failure(let error) = sourceScreen.bootstrap() {
            showBootstrapError(error.message)
        } else if case .failure(let error) = adapter.bootstrap() {
            showBootstrapError(error.message)
        }
    }

    private func showBootstrapError(_ message: String) {
        stateView.showMessage(title: L10n.Discovery.unavailable, message: message, actionTitle: L10n.Common.retry) { [weak self] in
            guard let self, self.canPresent, !self.isBusy else { return }
            self.bootstrap()
        }
    }

    private func showGroups() {
        guard controlsActive else { return }
        let groups = ExploreSourceListPolicy.groups(sources)
        guard !groups.isEmpty else { return }
        sourceList.noteUserInteraction()
        let context = sourceList.contextID
        let presentation = presentationID
        presentMenu(
            groups.map { group in
                ReaderOverflowMenuView.Item(identifier: "discovery.group." + group, title: group) { [weak self] in
                    guard let self, self.canPresent, !self.isBusy,
                        self.sourceList.contextID == context, self.presentationID == presentation,
                        ExploreSourceListPolicy.groups(self.sources).contains(group)
                    else { return }
                    self.toolbar.setQuery("group:" + group, submit: true)
                }
            }, anchor: toolbar.groupButton,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.canPresent && !self.isBusy && self.sourceList.contextID == context
                    && self.presentationID == presentation
            })
    }

    private func presentMenu(_ items: [ReaderOverflowMenuView.Item], anchor: UIView, isCurrent: @escaping () -> Bool) {
        menu?.dismiss()
        let id = UUID()
        menuActionID = id
        let boundItems = items.map { item in
            ReaderOverflowMenuView.Item(
                identifier: item.identifier, title: item.title, image: item.image,
                isChecked: item.isChecked, isEnabled: item.isEnabled
            ) { [weak self] in
                guard let self, self.menuActionID == id, isCurrent() else { return }
                self.menuActionID = nil
                item.handler()
            }
        }
        // The underlying button is paused while covered; popup ownership uses its page-local rect.
        let proxy = UIView(frame: anchor.convert(anchor.bounds, to: view))
        proxy.isAccessibilityElement = false
        view.addSubview(proxy)
        menuAnchor = proxy
        menuOriginalAnchor = anchor
        let menu = ReaderOverflowMenuView(
            items: boundItems, anchorView: proxy, interfaceStyle: traitCollection.userInterfaceStyle, placement: .automatic)
        self.menu = menu
        menuValidation = isCurrent
        menu.canActivateItem = { [weak self, weak menu] in self?.menu === menu && isCurrent() }
        menu.onDismiss = { [weak self, weak menu, weak proxy] in
            guard let self, self.menu === menu else { return }
            self.menu = nil
            self.menuAnchor = nil
            self.menuOriginalAnchor = nil
            self.menuValidation = nil
            self.sourceList.setMenuCovered(false)
            self.updatePresentationControls()
            // ReaderOverflowMenuView invokes the selected item immediately after onDismiss.
            // Keep its context anchor attached through that synchronous delivery.
            DispatchQueue.main.async { [weak self, weak proxy] in
                proxy?.removeFromSuperview()
                if self?.menuActionID == id { self?.menuActionID = nil }
            }
        }
        sourceList.setMenuCovered(true)
        updatePresentationControls()
        menu.present(in: view)
        if menu.superview == nil {
            proxy.removeFromSuperview()
            self.menu = nil
            menuAnchor = nil
            menuOriginalAnchor = nil
            menuValidation = nil
            menuActionID = nil
            sourceList.setMenuCovered(false)
            updatePresentationControls()
        }
    }

    private func applyFilter() {
        let query = toolbar.searchField.text ?? ""
        if let url = expandedSourceURL,
            !ExploreSourceListPolicy.apply(sources, query: query).contains(where: { $0.bookSourceUrl == url })
        {
            collapseSource()
        }
        sourceList.render(
            sources: sources, query: query, expandedSourceURL: expandedSourceURL,
            kindsCache: kindsCache, isLoading: isLoadingKinds)
        if menuValidation?() == false { menu?.dismiss() }
    }

    private func collapseSource() {
        requestGeneration &+= 1
        kindsTask?.cancel()
        kindsTask = nil
        expandedSourceURL = nil
        isLoadingKinds = false
        sourceList.cancelExpansionScroll()
    }

    private func toggle(_ source: BookSourcePart) {
        guard canPresent, !isBusy, menu == nil else { return }
        sourceList.noteUserInteraction()
        if expandedSourceURL == source.bookSourceUrl {
            collapseSource()
            applyFilter()
            return
        }
        collapseSource()
        expandedSourceURL = source.bookSourceUrl
        sourceList.requestExpansionScroll(sourceURL: source.bookSourceUrl)
        loadKinds(sourceURL: source.bookSourceUrl, forceRefresh: false)
    }

    private func loadKinds(sourceURL: String, forceRefresh: Bool) {
        guard expandedSourceURL == sourceURL,
            let source = sources.first(where: { $0.bookSourceUrl == sourceURL })
        else { return }
        requestGeneration &+= 1
        let generation = requestGeneration
        kindsTask?.cancel()
        kindsTask = nil
        let shouldRefresh = forceRefresh || invalidatedSourceURLs.contains(sourceURL)
        if !shouldRefresh, kindsCache[sourceURL] != nil {
            isLoadingKinds = false
            applyFilter()
            return
        }
        isLoadingKinds = true
        applyFilter()
        kindsTask = Task { @MainActor [weak self, adapter] in
            do {
                let kinds = try await adapter.loadKinds(
                    sourceURL: sourceURL, forceRefresh: shouldRefresh)
                guard let self, !Task.isCancelled, self.requestGeneration == generation, self.expandedSourceURL == sourceURL,
                    self.sources.first(where: { $0.bookSourceUrl == sourceURL })?.lastUpdateTime == source.lastUpdateTime
                else { return }
                self.kindsCache[sourceURL] = kinds
                self.invalidatedSourceURLs.remove(sourceURL)
                self.isLoadingKinds = false
                self.kindsTask = nil
                self.applyFilter()
            } catch {
                guard let self, !Task.isCancelled, self.requestGeneration == generation, self.expandedSourceURL == sourceURL,
                    self.sources.first(where: { $0.bookSourceUrl == sourceURL })?.lastUpdateTime == source.lastUpdateTime
                else { return }
                // BookSource.exploreKinds caches failures as ordinary, tappable ERROR categories.
                self.kindsCache[sourceURL] = [
                    ExploreKind(title: "ERROR:" + error.localizedDescription, url: error.userFacingMessage, style: nil)
                ]
                self.invalidatedSourceURLs.remove(sourceURL)
                self.isLoadingKinds = false
                self.kindsTask = nil
                self.applyFilter()
            }
        }
    }

    func scrollViewWillBeginDragging(_: UIScrollView) { sourceList.didBeginDragging() }
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? AndroidExploreSourceCell)?.setPresentationActive(controlsActive)
    }
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if let current = tableView.indexPath(for: cell), tableView.cellForRow(at: current) === cell { return }
        (cell as? AndroidExploreSourceCell)?.setPresentationActive(false)
    }
    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { sourceList.finishScrolling() }
    }
    func scrollViewDidEndDecelerating(_: UIScrollView) { sourceList.finishScrolling() }
    func scrollViewDidEndScrollingAnimation(_: UIScrollView) { sourceList.finishScrolling() }
    func scrollViewShouldScrollToTop(_: UIScrollView) -> Bool {
        sourceList.noteUserInteraction()
        return true
    }
    func scrollViewDidScrollToTop(_: UIScrollView) { sourceList.finishScrolling() }

    private func open(_ kind: ExploreKind, source: BookSourcePart) {
        guard canPresent, !isBusy, menu == nil,
            let url = kind.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        if kind.title.hasPrefix("ERROR:") {
            present(ExploreErrorTextDialogViewController(text: url, owner: self), animated: true)
        } else {
            navigationController?.pushViewController(AndroidReplicaExploreDetailViewController(source: source, initialKind: kind), animated: true)
        }
    }

    private func showSourceMenu(_ binding: ExploreSourceListCoordinator.Binding, anchor: UIView) {
        guard canPresent, !isBusy, menu == nil, let source = sourceList.source(for: binding)
        else { return }
        sourceList.noteUserInteraction()
        let presentation = presentationID
        let entries: [(String, String)] = [
            ("edit", "编辑"), ("top", "置顶"), ("login", "登录"), ("search", "搜索"), ("refresh", "刷新"), ("delete", "删除"),
        ].filter {
            $0.0 != "login" || source.hasLoginUrl
                || sourceScreen.cachedSource(sourceUrl: source.bookSourceUrl)?.hasManagementLoginURL == true
        }
        presentMenu(
            entries.map { action, title in
                ReaderOverflowMenuView.Item(identifier: "discovery.source." + action, title: title) { [weak self] in
                    self?.perform(action, binding: binding)
                }
            }, anchor: anchor,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return self.presentationID == presentation && self.sourceList.source(for: binding, allowingMenu: true) != nil
            })
    }

    private func perform(_ action: String, binding: ExploreSourceListCoordinator.Binding) {
        guard canPresent, !isBusy, menu == nil, let source = sourceList.source(for: binding, allowingMenu: true)
        else { return }
        sourceList.noteUserInteraction()
        switch action {
        case "edit":
            let editor = BookSourceEditViewController(mode: .edit(source.bookSourceUrl), screen: sourceScreen)
            editor.onSourceSaved = { [weak self] saved in
                guard let self else { return }
                self.kindsCache[source.bookSourceUrl] = nil
                self.kindsCache[saved.bookSourceUrl] = nil
                self.invalidatedSourceURLs.insert(saved.bookSourceUrl)
                if self.expandedSourceURL == source.bookSourceUrl || self.expandedSourceURL == saved.bookSourceUrl {
                    self.requestGeneration &+= 1
                    self.kindsTask?.cancel()
                    self.kindsTask = nil
                    self.isLoadingKinds = false
                }
                if source.bookSourceUrl != saved.bookSourceUrl, self.expandedSourceURL == source.bookSourceUrl {
                    self.collapseSource()
                }
                self.applyFilter()
            }
            navigationController?.pushViewController(editor, animated: true)
        case "top":
            sourceActionBinding = binding
            actions.moveToTop(sourceURL: source.bookSourceUrl)
        case "login":
            sourceActionBinding = binding
            actions.login(sourceURL: source.bookSourceUrl)
        case "search":
            navigationController?.pushViewController(
                AndroidReplicaSearchViewController(initialScope: .source(url: source.bookSourceUrl, name: source.bookSourceName)), animated: true)
        case "refresh":
            kindsCache[source.bookSourceUrl] = nil
            invalidatedSourceURLs.insert(source.bookSourceUrl)
            if expandedSourceURL == source.bookSourceUrl {
                loadKinds(sourceURL: source.bookSourceUrl, forceRefresh: true)
            } else {
                let presentation = presentationID
                Task { @MainActor [weak self, adapter] in
                    do { try await adapter.clearKinds(sourceURL: source.bookSourceUrl) } catch {
                        guard let self, self.presentationID == presentation,
                            self.sourceList.source(for: binding) != nil, self.menu == nil
                        else { return }
                        self.showTransientMessage(error.userFacingMessage)
                    }
                }
            }
        case "delete":
            sourceActionBinding = binding
            actions.confirmDelete(sourceURL: source.bookSourceUrl, name: source.bookSourceName)
        default: break
        }
    }
}
