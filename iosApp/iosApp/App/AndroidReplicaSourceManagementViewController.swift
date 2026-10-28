import SafariServices
import UIKit
import shared

final class AndroidReplicaSourceManagementViewController: UIViewController, UITextFieldDelegate, NavigationBackActionHandling {
    private let screen = SourceManagementScreenAdapter()
    private let topBar = SourceManagementToolbarView()
    private let toolbarBackground = UIView()
    private let bottomBackground = UIView()
    private var searchField: UITextField { topBar.searchField }
    private let listPreferences = SourceManagementListPreferences()
    private var listConfiguration = SourceManagementListConfiguration()
    private var sourceGroups: [String] = []
    private lazy var sourceMenus = SourceManagementMenuCoordinator(
        host: view, canPresent: { [weak self] in self?.canPresentMenu == true },
        onCoverageChange: { [weak self] in self?.sourceList.setMenuCovered($0) })
    private let statusLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private lazy var sourceList = SourceManagementListCoordinator(tableView: tableView, interactionView: view)
    private let emptyLabel = UILabel()
    private let selectionBar = SourceManagementSelectionBar()
    private var allSources: [BookSource] = []
    private var filteredSources: [BookSource] = []
    private var selectedSourceURLs = Set<String>()
    private var selectionRevision = 0
    private var sourcesRevision = 0
    private var loadRequestID = 0
    private var isUpdatingSources = false
    private var searchKeyword = ""
    private var listState = SourceManagementListState()
    private var statusHeightConstraint: NSLayoutConstraint?
    private var reloadOnReturnFromEditor = false
    private var hasAppeared = false
    private lazy var checkCoordinator = SourceManagementCheckCoordinator(
        presenter: self, screen: screen,
        canStart: { [weak self] in self?.canPresentMenu == true },
        onStatusChange: { [weak self] active, message in self?.renderSourceCheckStatus(active: active, message: message) },
        onMessage: { [weak self] in self?.showMessage($0) })
    private lazy var importCoordinator = BookSourceImportCoordinator(
        presenter: self,
        canPresent: { [weak self] in self?.canPresentMenu == true },
        onBusyChange: { [weak self] busy in self?.setUpdatingSources(busy) },
        onImported: { [weak self] in Task { await self?.reloadSources() } })
    private lazy var actionCoordinator = SourceManagementActionCoordinator(
        presenter: self, screen: screen,
        canStart: { [weak self] in self?.canPresentMenu == true },
        onBusyChange: { [weak self] in self?.setUpdatingSources($0) },
        onChanged: { [weak self] in await self?.reloadSources() })
    private lazy var deletionCoordinator = SourceManagementDeletionCoordinator(
        presenter: self, canStart: { [weak self] in self?.canPresentMenu == true })

    private enum SourceFlag {
        case enabled, explore
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        listConfiguration = listPreferences.load()
        configureViews()
        bindScreen()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        refreshPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard reloadOnReturnFromEditor else { return }
        reloadOnReturnFromEditor = false
        Task { await reloadSources() }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { BookshelfRootView.statusBarStyle(for: traitCollection) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        sourceList.setPresentationActive(true)
        checkCoordinator.pageDidAppear()
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] _ in self?.sourceList.resumeDelivery() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        topBar.updateLayout(availableSize: view.bounds.size)
        sourceMenus.refreshLayout()
        sourceList.resumeDelivery()
    }

    override func present(_ controller: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        guard ownsPresentation else { return }
        sourceList.observePresentation(of: controller)
        sourceMenus.dismiss()
        super.present(controller, animated: animated, completion: completion)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        hasAppeared = false
        sourceList.setPresentationActive(false)
        sourceMenus.dismiss()
        deletionCoordinator.cancelPresentation()
        checkCoordinator.pageWillDisappear()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            importCoordinator.cancelPresentation()
            actionCoordinator.cancelPresentation()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        screen.unbind()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshPalette()
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        view.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        toolbarBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        bottomBackground.backgroundColor = AndroidReplicaTheme.bottomBackground.resolvedColor(with: traitCollection)
        tableView.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        tableView.separatorColor = AndroidReplicaTheme.divider.resolvedColor(with: traitCollection)
        statusLabel.backgroundColor = AndroidReplicaTheme.menuBackground.resolvedColor(with: traitCollection)
        statusLabel.textColor = AndroidReplicaTheme.secondaryText.resolvedColor(with: traitCollection)
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText.resolvedColor(with: traitCollection)
        sourceMenus.refreshAppearance(interfaceStyle: traitCollection.userInterfaceStyle)
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
    }

    private func configureViews() {
        toolbarBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbarBackground.isUserInteractionEnabled = false
        bottomBackground.backgroundColor = AndroidReplicaTheme.bottomBackground
        bottomBackground.isUserInteractionEnabled = false
        topBar.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        topBar.moreButton.addTarget(self, action: #selector(showImportMenu), for: .touchUpInside)
        topBar.sortButton.addTarget(self, action: #selector(showSortMenu), for: .touchUpInside)
        topBar.groupButton.addTarget(self, action: #selector(showGroupMenu), for: .touchUpInside)

        statusLabel.backgroundColor = AndroidReplicaTheme.menuBackground
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 1
        statusLabel.isHidden = true
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleVerifySourceCheck)))

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.accessibilityIdentifier = UIIdentifiers.SourceManagement.table
        tableView.separatorColor = AndroidReplicaTheme.divider
        configureSourceList()

        emptyLabel.text = L10n.SourceManagement.loading
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0

        selectionBar.onSelectAll = { [weak self] in self?.toggleSelectAll() }
        selectionBar.onInvert = { [weak self] in self?.invertSelection() }
        selectionBar.onDelete = { [weak self] in self?.deleteSelection() }
        selectionBar.onMore = { [weak self] in self?.showBatchMenu() }

        statusHeightConstraint = SourceManagementPageLayout.install(
            in: view, toolbarBackground: toolbarBackground, bottomBackground: bottomBackground,
            toolbar: topBar, status: statusLabel, table: tableView, placeholder: emptyLabel, selectionBar: selectionBar)
    }

    private func configureSourceList() {
        sourceList.canUsePage = { [weak self] in self?.canUsePage == true }
        sourceList.onSelectionChange = { [weak self] in self?.toggleSelection(sourceURL: $0) }
        sourceList.onEnabledChange = { [weak self] url, enabled in
            self?.updateSourceFlags(urls: [url], flag: .enabled, enabled: enabled)
        }
        sourceList.onEdit = { [weak self] in self?.edit(source: $0) }
        sourceList.onMore = { [weak self] binding, anchor in self?.showMenu(for: binding, from: anchor) }
        sourceList.onDeliver = { [weak self] count, _ in
            guard let self else { return }
            self.tableView.accessibilityValue = String(count)
            self.renderListState(deliveredCount: count)
            self.updateSelectionBar()
        }
        sourceList.onPresentationChange = { [weak self] active in
            self?.updateInputAvailability(active)
        }
        sourceList.onPresentationInvalidated = { [weak self] in self?.sourceMenus.dismiss() }
        topBar.canInteract = { [weak self] in self?.sourceList.isInputActive == true }
        selectionBar.canInteract = { [weak self] in self?.sourceList.isInputActive == true }
        sourceList.setPresentationActive(false)
    }

    private func updateInputAvailability(_ active: Bool) {
        topBar.setPresentationActive(active)
        selectionBar.setPresentationActive(active)
        for button in [topBar.sortButton, topBar.groupButton, topBar.moreButton] {
            button.isEnabled = active && !isUpdatingSources
        }
        if active { checkCoordinator.refreshPresentation() }
    }

    private func bindScreen() {
        screen.onSourcesChange = { [weak self] sources in
            self?.receiveSources(sources)
        }
        screen.onSourceCheckStateChange = { [weak self] state in
            self?.checkCoordinator.receive(state)
            self?.sourceMenus.invalidateIfNeeded()
        }
        screen.onGroupsChange = { [weak self] groups in
            self?.sourceGroups = groups
            self?.sourceMenus.invalidateIfNeeded()
        }
        switch screen.bootstrap() {
        case .success:
            Task { await reloadSources() }
        case .failure(let error):
            listState.didFail(error.message)
            renderListState(deliveredCount: 0)
        }
    }

    private func reloadSources() async {
        loadRequestID += 1
        let requestID = loadRequestID
        let revision = sourcesRevision
        do {
            let sources = try await screen.loadSources()
            await MainActor.run {
                // A newer watch snapshot or reload always wins over this suspended read.
                guard requestID == loadRequestID, revision == sourcesRevision else { return }
                receiveSources(sources)
            }
        } catch {
            await MainActor.run {
                guard requestID == loadRequestID, revision == sourcesRevision else { return }
                listState.didFail(error.userFacingMessage)
                if allSources.isEmpty {
                    renderListState(deliveredCount: tableView.numberOfSections > 0 ? tableView.numberOfRows(inSection: 0) : 0)
                } else {
                    showMessage(error.userFacingMessage)
                }
            }
        }
    }

    private func receiveSources(_ sources: [BookSource]) {
        sourcesRevision += 1
        listState.didLoad()
        allSources = sources
        applyFilter()
    }

    private func renderListState(deliveredCount: Int) {
        let message = listState.placeholder(deliveredCount: deliveredCount, hasSources: !allSources.isEmpty, query: searchKeyword)
        emptyLabel.text = message
        emptyLabel.isHidden = message == nil
    }

    private func applyFilter() {
        filteredSources = SourceManagementListPolicy.apply(
            sources: allSources, query: searchKeyword, configuration: listConfiguration)
        selectedSourceURLs.formIntersection(filteredSources.map(\.bookSourceUrl))
        selectionRevision += 1
        checkCoordinator.invalidateConfirmationIfNeeded()
        deletionCoordinator.invalidateIfNeeded()
        sourceList.setSelection(selectedSourceURLs)
        sourceList.render(
            sources: filteredSources, query: searchKeyword, configuration: listConfiguration, showsEmpty: allSources.isEmpty)
        sourceMenus.invalidateIfNeeded()
    }

    private func updateSelection(_ urls: Set<String>) {
        selectedSourceURLs = urls.intersection(filteredSources.map(\.bookSourceUrl))
        selectionRevision += 1
        checkCoordinator.invalidateConfirmationIfNeeded()
        deletionCoordinator.invalidateIfNeeded()
        updateSelectionBar()
        sourceList.setSelection(selectedSourceURLs)
    }

    private func toggleSelection(sourceURL: String) {
        guard sourceList.isInputActive, filteredSources.contains(where: { $0.bookSourceUrl == sourceURL }) else { return }
        var urls = selectedSourceURLs
        if urls.contains(sourceURL) { urls.remove(sourceURL) } else { urls.insert(sourceURL) }
        updateSelection(urls)
    }

    private func toggleSelectAll() {
        guard sourceList.isInputActive else { return }
        let urls = Set(filteredSources.map(\.bookSourceUrl))
        updateSelection(selectedSourceURLs == urls ? [] : urls)
    }

    private func invertSelection() {
        guard sourceList.isInputActive else { return }
        updateSelection(Set(filteredSources.map(\.bookSourceUrl)).subtracting(selectedSourceURLs))
    }

    private func updateSelectionBar() {
        selectionBar.update(
            selectedCount: selectedSourceURLs.count, totalCount: filteredSources.count, isUpdating: isUpdatingSources)
    }

    private func showBatchMenu() {
        guard !isUpdatingSources, !selectedSourceURLs.isEmpty else { return }
        let revision = selectionRevision
        var items: [ReaderOverflowMenuView.Item] = [
            batchOption(title: "启用所选", flag: .enabled, enabled: true, revision: revision),
            batchOption(title: "禁用所选", flag: .enabled, enabled: false, revision: revision),
            batchAction("menu_add_group", title: "添加分组", revision: revision) { coordinator, urls, _ in
                coordinator.editGroup(sourceURLs: urls, removing: false)
            },
            batchAction("menu_remove_group", title: "移除分组", revision: revision) { coordinator, urls, _ in
                coordinator.editGroup(sourceURLs: urls, removing: true)
            },
        ]
        // book_source_sel.xml always includes these commands; the row menu is conditional.
        items += [
            batchOption(title: "启用发现", flag: .explore, enabled: true, revision: revision),
            batchOption(title: "禁用发现", flag: .explore, enabled: false, revision: revision),
        ]
        items += [
            batchAction("menu_top_sel", title: "置顶所选", revision: revision) { coordinator, urls, _ in
                coordinator.move(sourceURLs: urls, toStart: true)
            },
            batchAction("menu_bottom_sel", title: "置底所选", revision: revision) { coordinator, urls, _ in
                coordinator.move(sourceURLs: urls, toStart: false)
            },
            batchAction("menu_export_selection", title: "导出所选", revision: revision) { coordinator, urls, anchor in
                coordinator.export(sourceURLs: urls, sharing: false, anchor: anchor)
            },
            batchAction("menu_share_source", title: "分享选中源", revision: revision) { coordinator, urls, anchor in
                coordinator.export(sourceURLs: urls, sharing: true, anchor: anchor)
            },
        ]
        items += [
            menuItem("menu_check_source", title: "校验所选") { $0.verifySelectedSources(revision: revision) },
            menuItem("menu_check_selected_interval", title: "选中所选区间") { $0.checkSelectedInterval(revision: revision) },
        ]
        presentPopup(items, anchor: selectionBar.menuAnchor) { [weak self] in self?.selectionRevision == revision }
    }

    private func checkSelectedInterval(revision: Int) {
        guard selectionRevision == revision,
            let first = filteredSources.firstIndex(where: { selectedSourceURLs.contains($0.bookSourceUrl) }),
            let last = filteredSources.lastIndex(where: { selectedSourceURLs.contains($0.bookSourceUrl) })
        else { return }
        // BookSourceAdapter.checkSelectedInterval at 5f5d314 fills the visible selection, not a timed check.
        updateSelection(selectedSourceURLs.union(filteredSources[first...last].map(\.bookSourceUrl)))
    }

    private func verifySelectedSources(revision: Int) {
        guard selectionRevision == revision, !selectedSourceURLs.isEmpty else { return }
        if checkCoordinator.isChecking {
            showSourceCheckControlMenu()
            return
        }
        let urls = filteredSources.filter { selectedSourceURLs.contains($0.bookSourceUrl) }.map(\.bookSourceUrl)
        checkCoordinator.confirm(sourceURLs: urls) { [weak self] in
            guard let self else { return false }
            return self.selectionRevision == revision && self.selectedSourceURLs == Set(urls)
                && Set(urls).isSubset(of: Set(self.filteredSources.map(\.bookSourceUrl)))
        }
    }

    private func batchAction(
        _ id: String, title: String, revision: Int,
        action: @escaping (SourceManagementActionCoordinator, [String], UIView) -> Void
    ) -> ReaderOverflowMenuView.Item {
        menuItem(id, title: title) { controller in
            guard controller.selectionRevision == revision else {
                controller.showMessage("列表或选择已更新，请重新选择批量操作")
                return
            }
            let urls = controller.filteredSources.filter { controller.selectedSourceURLs.contains($0.bookSourceUrl) }
                .map(\.bookSourceUrl)
            guard !urls.isEmpty else { return }
            action(controller.actionCoordinator, urls, controller.selectionBar.menuAnchor)
        }
    }

    private func batchOption(title: String, flag: SourceFlag, enabled: Bool, revision: Int)
        -> ReaderOverflowMenuView.Item
    {
        menuItem("batch.\(flag).\(enabled)", title: title) { controller in
            guard controller.selectionRevision == revision else {
                controller.showMessage("列表或选择已更新，请重新选择批量操作")
                return
            }
            let urls = controller.filteredSources.filter { controller.selectedSourceURLs.contains($0.bookSourceUrl) }
                .map(
                    \.bookSourceUrl)
            controller.updateSourceFlags(urls: urls, flag: flag, enabled: enabled, requiresSelection: true)
        }
    }

    @objc private func handleBack() {
        if sourceMenus.dismissIfPresented() { return }
        guard sourceList.isInputActive, let navigation = navigationController, navigation.topViewController === self else { return }
        view.endEditing(true)
        if navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else if let presenter = navigation.presentingViewController,
            presenter.presentedViewController === navigation, !navigation.isBeingDismissed
        {
            navigation.dismiss(animated: true)
        }
    }

    func interceptNavigationBackGesture() -> Bool {
        guard ownsPresentation else { return false }
        if sourceMenus.dismissIfPresented() { return true }
        if searchField.isFirstResponder {
            searchField.resignFirstResponder()
            return true
        }
        return false
    }

    override func accessibilityPerformEscape() -> Bool {
        guard ownsPresentation else { return false }
        handleEscape()
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape))
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func handleEscape() {
        guard ownsPresentation else { return }
        if !interceptNavigationBackGesture() { handleBack() }
    }

    @objc private func searchTextChanged() {
        guard sourceList.isInputActive else { return }
        searchKeyword = searchField.text ?? ""
        applyFilter()
    }

    @objc private func showImportMenu() {
        presentPopup(
            [
                menuItem("menu_add_book_source", title: "新建书源") { $0.createSource() },
                menuItem("menu_import_local", title: "本地导入") { $0.importCoordinator.openFile() },
                menuItem("menu_import_onLine", title: "网络导入") { $0.importCoordinator.openOnline() },
                menuItem("menu_import_qr", title: "二维码导入") { $0.importCoordinator.openQR() },
                menuItem("menu_group_sources_by_domain", title: "按域名分组", checked: listConfiguration.groupsByDomain) {
                    $0.listConfiguration.groupsByDomain.toggle()
                    $0.saveListConfiguration()
                },
                menuItem("menu_help", title: "帮助") { $0.showSourceHelp() },
            ], anchor: topBar.moreButton)
    }

    @objc private func showSortMenu() {
        guard canPresentMenu else { return }
        let titles = ["手动排序", "智能排序", "名称排序", "地址排序", "更新时间排序", "响应时间排序", "是否启用"]
        let items =
            [
                SearchOverflowMenuView.Item(
                    id: "menu_sort_desc", title: "反序", selection: .checkbox, isSelected: !listConfiguration.ascending)
            ]
            + zip(SourceManagementListSort.allCases, titles).map { sort, title in
                .init(id: sort.rawValue, title: title, selection: .radio, isSelected: listConfiguration.sort == sort)
            }
        sourceMenus.showSort(anchor: topBar.sortButton, items: items) { [weak self] id in
            guard let self, self.canPresentMenu else { return }
            if id == "menu_sort_desc" {
                self.listConfiguration.ascending.toggle()
            } else if let sort = SourceManagementListSort(rawValue: id) {
                self.listConfiguration.sort = sort
            }
            self.saveListConfiguration()
        }
    }

    private func saveListConfiguration() {
        listPreferences.save(listConfiguration)
        applyFilter()
    }

    @objc private func showGroupMenu() {
        let groups = sourceGroups
        let filters = [
            SourceManagementListPolicy.FilterQuery.enabled, SourceManagementListPolicy.FilterQuery.disabled,
            SourceManagementListPolicy.FilterQuery.needsLogin, SourceManagementListPolicy.FilterQuery.ungrouped,
            SourceManagementListPolicy.FilterQuery.exploreEnabled,
            SourceManagementListPolicy.FilterQuery.exploreDisabled,
        ]
        var items = [
            menuItem("menu_group_manage", title: "分组管理") { controller in
                controller.present(
                    BookSourceGroupManagementDialogViewController(screen: controller.screen) { [weak controller] in
                        Task { await controller?.reloadSources() }
                    }, animated: true)
            }
        ]
        items += filters.enumerated().map { index, query in
            menuItem("group.filter.\(index)", title: query) { $0.setFilterQuery(query) }
        }
        items += groups.enumerated().map { index, group in
            menuItem("group.name.\(index)", title: group) { $0.setFilterQuery("group:" + group) }
        }
        presentPopup(items, anchor: topBar.groupButton) { [weak self] in self?.sourceGroups == groups }
    }

    private func setFilterQuery(_ query: String) {
        searchField.text = query
        searchKeyword = query
        topBar.queryChanged()
        applyFilter()
    }

    private func createSource() {
        reloadOnReturnFromEditor = true
        navigationController?.pushViewController(
            AndroidReplicaBookSourceEditViewController(mode: .create, screen: screen)
                .configuredForDrillDownPresentation(),
            animated: true)
    }

    private func showSourceHelp() {
        guard
            let url = URL(
                string:
                    "https://github.com/gedoor/legado/blob/master/app/src/main/assets/web/help/md/SourceMBookHelp.md")
        else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    private var ownsPresentation: Bool {
        hasAppeared && !isMovingFromParent && !isBeingDismissed && presentedViewController == nil
            && navigationController?.topViewController === self
            && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.isKeyWindow == true
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var canUsePage: Bool { ownsPresentation && navigationController?.transitionCoordinator == nil }

    private var canPresentMenu: Bool { canUsePage && !isUpdatingSources }

    private func menuItem(
        _ id: String, title: String, checked: Bool? = nil,
        handler: @escaping (AndroidReplicaSourceManagementViewController) -> Void
    ) -> ReaderOverflowMenuView.Item {
        .init(identifier: "sourceManagement." + id, title: title, isChecked: checked) { [weak self] in
            guard let self, self.canPresentMenu else { return }
            handler(self)
        }
    }

    private func presentPopup(
        _ items: [ReaderOverflowMenuView.Item], anchor: UIView, isCurrent: @escaping () -> Bool = { true }
    ) {
        sourceMenus.show(items, anchor: anchor, isCurrent: isCurrent)
    }

    @objc private func handleVerifySourceCheck() {
        guard sourceList.isMutationActive else { return }
        if checkCoordinator.isChecking {
            showSourceCheckControlMenu()
            return
        }
        let revision = sourcesRevision
        let urls = allSources.filter(\.enabled).map(\.bookSourceUrl)
        checkCoordinator.confirm(sourceURLs: urls) { [weak self] in
            self?.sourcesRevision == revision
        }
    }

    private func showSourceCheckControlMenu() {
        let revision = checkCoordinator.controlRevision
        presentPopup(checkCoordinator.controlMenuItems(), anchor: statusLabel) { [weak self] in
            self?.checkCoordinator.controlRevision == revision && self?.checkCoordinator.isChecking == true
        }
    }

    private func renderSourceCheckStatus(active: Bool, message: String) {
        guard statusLabel.text != message || statusLabel.isHidden == active else { return }
        statusLabel.text = message
        statusLabel.isHidden = !active
        statusLabel.accessibilityTraits = .button
        statusLabel.accessibilityHint = "暂停、继续或取消校验"
        statusHeightConstraint?.constant = active ? 28 : 0
        view.layoutIfNeeded()
    }

    private func updateSourceFlags(urls: [String], flag: SourceFlag, enabled: Bool, requiresSelection: Bool = false) {
        guard sourceList.isMutationActive, !urls.isEmpty else { return }
        let requested = Set(urls)
        let targetURLs = filteredSources.filter {
            requested.contains($0.bookSourceUrl)
                && (!requiresSelection || selectedSourceURLs.contains($0.bookSourceUrl))
                && (flag != .explore || requiresSelection || $0.hasExploreUrl)
        }.map(\.bookSourceUrl)
        guard !targetURLs.isEmpty else { return }
        setUpdatingSources(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failures: [String] = []
            var completed = 0
            // The click-time URL snapshot is immutable; later filters/selections never retarget this job.
            for url in targetURLs {
                do {
                    switch flag {
                    case .enabled:
                        try await self.screen.setEnabled(sourceUrl: url, enabled: enabled)
                    case .explore:
                        try await self.screen.setEnabledExplore(sourceUrl: url, enabled: enabled)
                    }
                    completed += 1
                } catch {
                    failures.append("\(url)\n\(error.userFacingMessage)")
                }
            }
            await self.reloadSources()
            self.setUpdatingSources(false)
            if !failures.isEmpty {
                let message =
                    "已更新 \(completed)/\(targetURLs.count) 条，失败 \(failures.count) 条。已成功的修改不会回滚。\n\n"
                    + failures.joined(separator: "\n\n")
                let alert = UIAlertController(
                    title: L10n.Common.unavailableTitle, message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.Common.close, style: .default))
                self.topmostPresentedViewController.present(alert, animated: true)
            }
        }
    }

    private func setUpdatingSources(_ updating: Bool) {
        guard isUpdatingSources != updating else { return }
        isUpdatingSources = updating
        loadRequestID += 1
        deletionCoordinator.invalidateIfNeeded()
        updateSelectionBar()
        sourceList.setMutationsEnabled(!updating)
        updateInputAvailability(sourceList.isInputActive)
    }

    private func toggleExplore(sourceURL: String) {
        guard let source = filteredSources.first(where: { $0.bookSourceUrl == sourceURL }) else { return }
        updateSourceFlags(urls: [sourceURL], flag: .explore, enabled: !source.enabledExplore)
    }

    private func deleteSelection() {
        let urls = filteredSources.filter { selectedSourceURLs.contains($0.bookSourceUrl) }.map(\.bookSourceUrl)
        confirmDelete(urls: urls)
    }

    private func confirmDelete(
        urls: [String], sourceName: String = "", binding: SourceManagementListCoordinator.Binding? = nil
    ) {
        guard canPresentMenu, !urls.isEmpty else { return }
        let revision = selectionRevision
        let requestID = loadRequestID
        let requestedURLs = Set(urls)
        deletionCoordinator.confirm(
            sourceURLs: urls, sourceName: binding == nil ? nil : sourceName,
            isCurrent: { [weak self] in
                guard let self, self.hasAppeared, !self.isUpdatingSources,
                    self.selectionRevision == revision, self.loadRequestID == requestID,
                    requestedURLs.isSubset(of: Set(self.filteredSources.map(\.bookSourceUrl)))
                else { return false }
                if let binding {
                    return requestedURLs == Set([binding.sourceURL]) && self.sourceList.hasCurrentSource(binding)
                }
                return self.selectedSourceURLs == requestedURLs
            },
            onConfirm: { [weak self] urls in
                guard let self else { return }
                self.setUpdatingSources(true)
                Task { @MainActor in
                    do { try await self.screen.deleteSources(sourceUrls: urls) } catch {
                        self.showMessage(error.userFacingMessage)
                    }
                    await self.reloadSources()
                    self.setUpdatingSources(false)
                }
            })
    }

    private func edit(source: BookSource) {
        reloadOnReturnFromEditor = true
        navigationController?.pushViewController(
            AndroidReplicaBookSourceEditViewController(mode: .edit(source.bookSourceUrl), screen: screen)
                .configuredForDrillDownPresentation(),
            animated: true
        )
    }

    private func showMenu(for binding: SourceManagementListCoordinator.Binding, from anchor: UIView) {
        guard let source = sourceList.mutationSource(for: binding) else { return }
        let url = source.bookSourceUrl
        var items: [ReaderOverflowMenuView.Item] = []
        if listConfiguration.sort == .manual {
            let ascending = listConfiguration.ascending
            items += [
                menuItem("source.top", title: "置顶") { controller in
                    guard controller.listConfiguration.sort == .manual,
                        controller.listConfiguration.ascending == ascending,
                        controller.filteredSources.contains(where: { $0.bookSourceUrl == url })
                    else { return }
                    controller.actionCoordinator.move(sourceURLs: [url], toStart: ascending)
                },
                menuItem("source.bottom", title: "置底") { controller in
                    guard controller.listConfiguration.sort == .manual,
                        controller.listConfiguration.ascending == ascending,
                        controller.filteredSources.contains(where: { $0.bookSourceUrl == url })
                    else { return }
                    controller.actionCoordinator.move(sourceURLs: [url], toStart: !ascending)
                },
            ]
        }
        if source.hasManagementLoginURL {
            items.append(
                menuItem("source.login", title: L10n.SourceEdit.loginAction) { controller in
                    guard controller.filteredSources.contains(where: { $0.bookSourceUrl == url }) else { return }
                    controller.actionCoordinator.login(sourceURL: url)
                })
        }
        items += [
            menuItem("source.search", title: L10n.SourceManagement.searchSourceAction) { controller in
                guard controller.filteredSources.contains(where: { $0.bookSourceUrl == url }) else { return }
                controller.navigationController?.pushViewController(
                    AndroidReplicaSearchViewController(
                        initialScope: .source(url: source.bookSourceUrl, name: source.bookSourceName)
                    ), animated: true)
            },
            menuItem("source.debug", title: L10n.SourceEdit.debugAction) { controller in
                guard controller.filteredSources.contains(where: { $0.bookSourceUrl == url }) else { return }
                controller.navigationController?.pushViewController(
                    BookSourceDebugViewController(sourceUrl: url, screen: controller.screen)
                        .configuredForDrillDownPresentation(), animated: true)
            },
            menuItem("source.delete", title: L10n.SourceManagement.deleteAction) { controller in
                guard let current = controller.filteredSources.first(where: { $0.bookSourceUrl == url }) else { return }
                controller.confirmDelete(urls: [url], sourceName: current.bookSourceName, binding: binding)
            },
        ]
        if source.hasExploreUrl {
            items.append(
                menuItem("source.explore", title: source.enabledExplore ? "禁用发现" : "启用发现") {
                    $0.toggleExplore(sourceURL: url)
                })
        }
        presentPopup(items, anchor: anchor) { [weak self] in
            self?.sourceList.mutationSource(for: binding, allowingMenu: true) != nil
        }
    }

    private func showMessage(_ message: String) {
        showTransientMessage(message)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
