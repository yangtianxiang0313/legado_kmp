import shared
import SnapKit
import UIKit

final class DiscoveryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {
    private let screen = DiscoveryScreenAdapter()
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let searchField = UISearchTextField()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private lazy var groupButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "line.3.horizontal.decrease.circle",
        target: self,
        action: #selector(handleGroupButton)
    )

    private var allSources: [BookSourcePart] = []
    private var visibleSources: [BookSourcePart] = []
    private var selectedGroup: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Discovery.title
        view.backgroundColor = .systemBackground
        scaffoldView.titleBarView.setTitle(L10n.Discovery.title)
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        configureSearchField()
        scaffoldView.titleBarView.setCenterView(searchField)

        groupButton.accessibilityIdentifier = UIIdentifiers.Discovery.groupButton
        scaffoldView.titleBarView.setRightViews([groupButton])

        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "DiscoverySourceCell")
        tableView.setPlaceholder(nil)
        tableView.accessibilityIdentifier = UIIdentifiers.Discovery.table
        tableView.dataSource = self
        tableView.delegate = self
        tableView.tableFooterView = UIView()

        scaffoldView.contentView.addSubview(tableView)
        scaffoldView.contentView.addSubview(stateView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        stateView.setTestingIdentifier(UIIdentifiers.Discovery.state)
        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        bootstrapDependencies()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    deinit {
        screen.unbind()
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        visibleSources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "DiscoverySourceCell", for: indexPath)
        let source = visibleSources[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = source.bookSourceName
        configuration.secondaryText = source.bookSourceGroup?.isEmpty == false
            ? source.bookSourceGroup
            : L10n.Discovery.sourceCellFallback
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = UIIdentifiers.Discovery.sourceCell
        return cell
    }

    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.row < visibleSources.count else { return }
        let controller = ExploreShowViewController(source: visibleSources[indexPath.row])
        controller.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(controller, animated: true)
    }

    func textFieldDidChangeSelection(_: UITextField) {
        applyFilters()
    }

    @objc private func handleGroupButton() {
        guard groupButton.menu != nil else {
            showTransientMessage(L10n.Discovery.groupUnavailable)
            return
        }
    }

    private func configureSearchField() {
        searchField.placeholder = L10n.Discovery.searchPlaceholder
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        searchField.accessibilityIdentifier = UIIdentifiers.Discovery.searchField
        searchField.snp.makeConstraints { make in
            make.width.equalTo(220)
            make.height.equalTo(34)
        }
    }

    @objc private func searchFieldChanged() {
        applyFilters()
    }

    private func bootstrapDependencies() {
        stateView.showLoading(message: L10n.Discovery.loading)
        screen.onSourcesChange = { [weak self] sources in
            guard let self else { return }
            self.handleSources(sources)
        }

        switch screen.bootstrap() {
        case .success:
            break
        case let .failure(error):
            stateView.showMessage(
                title: L10n.Discovery.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    private func handleSources(_ sources: [BookSourcePart]) {
        let wasNearTop = tableView.contentOffset.y < 50
        allSources = sources.sorted {
            if $0.weight != $1.weight {
                return $0.weight > $1.weight
            }
            return $0.customOrder < $1.customOrder
        }
        let availableGroups = Set(allSources.flatMap { splitGroups($0.bookSourceGroup) })
        if let selectedGroup, availableGroups.contains(selectedGroup) == false {
            self.selectedGroup = nil
        }
        updateGroupMenu()
        applyFilters()
        if wasNearTop, !visibleSources.isEmpty {
            tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        }
    }

    private func applyFilters() {
        let query = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleSources = allSources.filter { source in
            let matchesGroup: Bool
            if let selectedGroup, selectedGroup.isEmpty == false {
                matchesGroup = source.hasGroup(group: selectedGroup)
            } else {
                matchesGroup = true
            }
            guard matchesGroup else { return false }

            guard query.isEmpty == false else { return true }
            let haystack = [source.bookSourceName, source.bookSourceGroup ?? ""]
                .joined(separator: " ")
                .folding(options: .caseInsensitive, locale: .current)
            return haystack.contains(query.folding(options: .caseInsensitive, locale: .current))
        }

        tableView.accessibilityValue = "\(visibleSources.count)"
        tableView.reloadData()

        if allSources.isEmpty {
            tableView.setPlaceholder(L10n.Discovery.noSourcesPlaceholder)
            stateView.showMessage(
                title: L10n.Discovery.noSourcesTitle,
                message: L10n.Discovery.noSourcesMessage,
                actionTitle: L10n.Discovery.openSourceManagement
            ) { [weak self] in
                self?.openSourceManagement()
            }
            return
        }

        if visibleSources.isEmpty {
            tableView.setPlaceholder(L10n.Discovery.emptySearchResults)
        } else {
            tableView.setPlaceholder(nil)
        }
        stateView.hide()
    }

    private func updateGroupMenu() {
        let groups = Array(Set(allSources.flatMap { splitGroups($0.bookSourceGroup) })).sorted()
        guard groups.isEmpty == false else {
            groupButton.menu = nil
            groupButton.showsMenuAsPrimaryAction = false
            return
        }

        let actions = [UIAction(
            title: L10n.SourceManagement.allGroups,
            state: selectedGroup == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectedGroup = nil
            self?.applyFilters()
        }] + groups.map { group in
            UIAction(
                title: group,
                state: group == selectedGroup ? .on : .off
            ) { [weak self] _ in
                self?.selectedGroup = group
                self?.applyFilters()
            }
        }
        groupButton.menu = UIMenu(children: actions)
        groupButton.showsMenuAsPrimaryAction = true
    }

    private func splitGroups(_ rawValue: String?) -> [String] {
        rawValue?
            .split(whereSeparator: { ",;，；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false } ?? []
    }

    func tableView(_: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point _: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPath.row < visibleSources.count else { return nil }
        let source = visibleSources[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIAction] = []
            actions.append(UIAction(title: L10n.Discovery.searchThisSource, image: UIImage(systemName: "magnifyingglass")) { [weak self] _ in
                let searchVC = AndroidReplicaSearchViewController(preferredSourceURL: source.bookSourceUrl)
                searchVC.hidesBottomBarWhenPushed = true
                self?.navigationController?.pushViewController(searchVC, animated: true)
            })
            // F15 编辑书源
            actions.append(UIAction(title: L10n.Discovery.editSource, image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.navigateToEditSource(sourceUrl: source.bookSourceUrl)
            })
            // F16 置顶书源
            actions.append(UIAction(title: L10n.Discovery.pinSourceToTop, image: UIImage(systemName: "arrow.up.to.line")) { [weak self] _ in
                self?.pinSourceToTop(sourceUrl: source.bookSourceUrl)
            })
            // F18 登录书源
            actions.append(UIAction(title: L10n.Discovery.loginSource, image: UIImage(systemName: "person.crop.circle")) { [weak self] _ in
                self?.executeSourceLogin(sourceUrl: source.bookSourceUrl)
            })
            actions.append(UIAction(title: L10n.Discovery.deleteSource, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmDeleteSource(source)
            })
            return UIMenu(children: actions)
        }
    }

    private func confirmDeleteSource(_ source: BookSourcePart) {
        let screen = screen
        let alert = UIAlertController(
            title: L10n.Discovery.deleteSourceTitle,
            message: String(format: L10n.Discovery.deleteSourceMessage, source.bookSourceName),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Discovery.deleteSource, style: .destructive) { [weak self] _ in
            Task {
                do {
                    try await screen.deleteSource(sourceUrl: source.bookSourceUrl)
                } catch {
                    await MainActor.run {
                        self?.showTransientMessage(L10n.Discovery.deleteSourceFailed)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    // MARK: - F15 编辑书源

    private func navigateToEditSource(sourceUrl: String) {
        let sourceManagementScreen = SourceManagementScreenAdapter()
        switch sourceManagementScreen.bootstrap() {
        case .success:
            let editor = BookSourceEditViewController(
                mode: .edit(sourceUrl),
                screen: sourceManagementScreen
            ).configuredForDrillDownPresentation()
            navigationController?.pushViewController(editor, animated: true)
        case .failure:
            showTransientMessage(L10n.Discovery.editSourceUnavailable)
        }
    }

    // MARK: - F16 置顶书源

    private func pinSourceToTop(sourceUrl: String) {
        let sourceManagementScreen = SourceManagementScreenAdapter()
        switch sourceManagementScreen.bootstrap() {
        case .success:
            Task { [weak self] in
                do {
                    guard let fullSource = try await sourceManagementScreen.getSource(sourceUrl: sourceUrl) else {
                        await MainActor.run {
                            self?.showTransientMessage(L10n.Discovery.pinSourceToTopFailed)
                        }
                        return
                    }
                    let minOrder = self?.allSources.map(\.customOrder).min() ?? 0
                    let reordered = fullSource.copyForCustomOrder(minOrder - 1)
                    try await sourceManagementScreen.updateSourceOrders(sources: [reordered])
                    await MainActor.run {
                        self?.showTransientMessage(L10n.Discovery.pinSourceToTopDone)
                    }
                } catch {
                    await MainActor.run {
                        self?.showTransientMessage(L10n.Discovery.pinSourceToTopFailed)
                    }
                }
            }
        case .failure:
            showTransientMessage(L10n.Discovery.pinSourceToTopFailed)
        }
    }

    // MARK: - F18 登录书源

    private func executeSourceLogin(sourceUrl: String) {
        SourceLoginEntry.open(sourceURL: sourceUrl, from: self)
    }

    private func openSourceManagement() {
        let controller = AndroidReplicaSourceManagementViewController().configuredForDrillDownPresentation()
        navigationController?.pushViewController(controller, animated: true)
    }
}

final class DiscoveryScreenAdapter {
    private let bindings = ScreenBindingController(owner: "DiscoveryScreen")
    private var facade: DiscoveryFacade?
    private var sourceManagementFacade: SourceManagementFacade?
    private var bookshelfFacade: BookshelfFacade?
    private var lastSourcesSignature: String?
    private var lastBookshelfKeysSignature: String?

    var onSourcesChange: (([BookSourcePart]) -> Void)?
    var onBookshelfKeysChange: ((Set<String>) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()
        lastSourcesSignature = nil
        lastBookshelfKeysSignature = nil

        switch SharedRuntime.discoveryFacade() {
        case let .success(facade):
            self.facade = facade
            bindings.bind(facade.watchEnabledSourceParts { [weak self] sources in
                DispatchQueue.main.async {
                    self?.handleSources(sources)
                }
            })
            if case let .success(smf) = SharedRuntime.sourceManagementFacade() {
                sourceManagementFacade = smf
            }
            if case let .success(bookshelfFacade) = SharedRuntime.bookshelfFacade() {
                self.bookshelfFacade = bookshelfFacade
                bindings.bind(bookshelfFacade.watchBookshelfKeys { [weak self] keys in
                    DispatchQueue.main.async {
                        self?.handleBookshelfKeys(keys)
                    }
                })
            }
            return .success(())
        case let .failure(error):
            return .failure(error)
        }
    }

    func unbind() {
        bindings.cancelAll()
    }

    func loadExploreKinds(sourceURL: String, forceRefresh: Bool) async throws -> [ExploreKind] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadExploreKindsAsync(sourceUrl: sourceURL, forceRefresh: forceRefresh)
    }

    func loadExploreBooks(sourceURL: String, exploreURL: String, page: Int32) async throws -> [SearchBook] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadExploreBooksAsync(sourceUrl: sourceURL, exploreUrl: exploreURL, page: page)
    }

    func deleteSource(sourceUrl: String) async throws {
        guard let sourceManagementFacade else { throw runtimeNotReadyError() }
        try await sourceManagementFacade.deleteSourceAsync(sourceUrl: sourceUrl)
    }

    private func handleSources(_ sources: [BookSourcePart]) {
        let filtered = sources.filter { $0.enabled && $0.enabledExplore && $0.hasExploreUrl }
        let signature = filtered.map {
            "\($0.bookSourceUrl)#\($0.bookSourceName)#\($0.bookSourceGroup ?? "")#\($0.customOrder)#\($0.weight)"
        }.joined(separator: "|")
        guard signature != lastSourcesSignature else { return }
        lastSourcesSignature = signature
        onSourcesChange?(filtered)
    }

    private func handleBookshelfKeys(_ keys: Set<String>) {
        let signature = keys.sorted().joined(separator: "|")
        guard signature != lastBookshelfKeysSignature else { return }
        lastBookshelfKeysSignature = signature
        onBookshelfKeysChange?(keys)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.Discovery.unavailable]
        )
    }
}
