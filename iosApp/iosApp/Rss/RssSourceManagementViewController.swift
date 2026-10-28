import UIKit
import shared
import SnapKit

final class RssSourceManagementViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate {

    private let screen = RssSourceManagementScreenAdapter()
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let searchField = UISearchTextField()
    private let selectActionBar = UIView()
    private let selectScrollView = UIScrollView()
    private let selectStackView = UIStackView()
    private lazy var backButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "chevron.left",
        target: self,
        action: #selector(handleBack)
    )
    private lazy var moreButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "ellipsis.circle",
        target: self,
        action: #selector(handleMoreButton)
    )
    private lazy var groupButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "line.3.horizontal.decrease.circle",
        target: self,
        action: #selector(handleGroupButton)
    )

    private var allSources: [RssSource] = []
    private var displayedSources: [RssSource] = []
    private var groups: [String] = []
    private var selectedGroup: String?
    private var searchKeyword = ""
    private var lastDisplayedSignature: String?
    private var isSelectionMode = false
    private var selectedSourceURLs = Set<String>()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.RSS.sourceManagementTitle
        view.backgroundColor = .systemBackground
        scaffoldView.titleBarView.setTitle(L10n.RSS.sourceManagementTitle)
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        configureChrome()
        configureTable()
        configureStateView()
        configureSelectionBar()
        bootstrapDependencies()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    deinit {
        screen.unbind()
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        displayedSources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "rssSource", for: indexPath)
        let source = displayedSources[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = source.sourceName
        content.secondaryText = sourceSummary(for: source)
        content.secondaryTextProperties.numberOfLines = 2
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementSourceCell
        cell.selectionStyle = .default

        if isSelectionMode {
            cell.accessoryView = nil
            cell.accessoryType = selectedSourceURLs.contains(source.sourceUrl) ? .checkmark : .none
            cell.backgroundColor = selectedSourceURLs.contains(source.sourceUrl) ? UIColor.systemFill : .systemBackground
        } else {
            cell.accessoryType = .none
            cell.backgroundColor = .systemBackground
            let toggle = UISwitch()
            toggle.isOn = source.enabled
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(toggleSourceEnabled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        }
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let source = displayedSources[indexPath.row]
        if isSelectionMode {
            toggleSelection(for: source.sourceUrl)
        } else {
            openEditor(sourceUrl: source.sourceUrl)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !isSelectionMode else { return nil }
        let source = displayedSources[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive, title: L10n.RSS.sourceManagementDeleteAction) { [weak self] _, _, completion in
            self?.confirmDelete(sources: [source])
            completion(true)
        }
        let editAction = UIContextualAction(style: .normal, title: L10n.RSS.sourceManagementEditAction) { [weak self] _, _, completion in
            self?.openEditor(sourceUrl: source.sourceUrl)
            completion(true)
        }
        editAction.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [deleteAction, editAction])
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard !isSelectionMode else { return nil }
        let source = displayedSources[indexPath.row]
        return UIContextMenuConfiguration(identifier: source.sourceUrl as NSString, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            let edit = UIAction(title: L10n.RSS.sourceManagementEditAction, image: UIImage(systemName: "square.and.pencil")) { _ in
                self.openEditor(sourceUrl: source.sourceUrl)
            }
            let enable = UIAction(
                title: source.enabled ? L10n.RSS.sourceManagementDisableAction : L10n.RSS.sourceManagementEnableAction,
                image: UIImage(systemName: source.enabled ? "pause.circle" : "play.circle")
            ) { _ in
                self.setEnabled(sourceUrl: source.sourceUrl, enabled: !source.enabled)
            }
            let debug = UIAction(title: L10n.RSS.sourceDebugAction, image: UIImage(systemName: "ant")) { _ in
                self.openDebug(source: source)
            }
            let remove = UIAction(title: L10n.RSS.sourceManagementDeleteAction, image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.confirmDelete(sources: [source])
            }
            return UIMenu(children: [edit, debug, enable, remove])
        }
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        searchKeyword = textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        applySnapshot()
    }

    // MARK: - Actions

    @objc private func handleBack() {
        if isSelectionMode {
            setSelectionMode(false)
        } else {
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func handleGroupButton() {
        guard groupButton.menu != nil else { return }
    }

    @objc private func handleMoreButton() {
        guard moreButton.menu != nil else { return }
    }

    @objc private func toggleSourceEnabled(_ sender: UISwitch) {
        let source = displayedSources[sender.tag]
        setEnabled(sourceUrl: source.sourceUrl, enabled: sender.isOn, sender: sender)
    }

    // MARK: - Configure

    private func configureChrome() {
        searchField.placeholder = L10n.RSS.sourceManagementSearchPlaceholder
        searchField.clearButtonMode = .whileEditing
        searchField.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementSearchField
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        searchField.snp.makeConstraints { make in
            make.width.equalTo(220)
            make.height.equalTo(34)
        }
        scaffoldView.titleBarView.setCenterView(searchField)

        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        moreButton.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementMoreMenu
        groupButton.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementGroupMenu
        [moreButton, groupButton].forEach { button in
            button.snp.remakeConstraints { make in
                make.width.height.greaterThanOrEqualTo(32)
            }
        }
        scaffoldView.titleBarView.setLeftViews([backButton])
        scaffoldView.titleBarView.setRightViews([groupButton, moreButton])
        updateGroupMenu()
        updateMoreMenu()
    }

    private func configureTable() {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "rssSource")
        tableView.rowHeight = AppUI.Layout.sourceRowHeight
        tableView.setPlaceholder(nil)
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementTable
        tableView.dataSource = self
        tableView.delegate = self
        tableView.tableFooterView = UIView()

        scaffoldView.contentView.addSubview(tableView)
        scaffoldView.contentView.addSubview(selectActionBar)
        tableView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(selectActionBar.snp.top)
        }
        selectActionBar.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(0)
        }
    }

    private func configureStateView() {
        scaffoldView.contentView.addSubview(stateView)
        stateView.setTestingIdentifier(UIIdentifiers.RSS.sourceManagementState)
        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func configureSelectionBar() {
        selectActionBar.backgroundColor = .secondarySystemBackground
        selectActionBar.isHidden = true
        selectActionBar.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementSelectionBar
        selectScrollView.showsHorizontalScrollIndicator = false
        selectActionBar.addSubview(selectScrollView)
        selectScrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        selectStackView.axis = .horizontal
        selectStackView.spacing = 8
        selectStackView.alignment = .center
        selectScrollView.addSubview(selectStackView)
        selectStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(12)
            make.height.equalToSuperview().offset(-24)
        }

        let items: [(String, Selector)] = [
            (L10n.RSS.sourceManagementEnableAction, #selector(enableSelection)),
            (L10n.RSS.sourceManagementDisableAction, #selector(disableSelection)),
            (L10n.RSS.sourceManagementExportAction, #selector(exportSelection)),
            (L10n.RSS.sourceManagementDeleteAction, #selector(deleteSelection)),
        ]
        items.forEach { title, selector in
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.tinted()
            configuration.title = title
            configuration.cornerStyle = .capsule
            button.configuration = configuration
            button.addTarget(self, action: selector, for: .touchUpInside)
            selectStackView.addArrangedSubview(button)
        }
    }

    // MARK: - Bootstrap

    private func bootstrapDependencies() {
        stateView.showLoading(message: L10n.RSS.sourceManagementLoading)
        screen.onSourcesChange = { [weak self] sources in
            self?.allSources = sources
            self?.applySnapshot()
        }
        screen.onGroupsChange = { [weak self] groups in
            self?.handleGroups(groups)
        }

        switch screen.bootstrap() {
        case .success:
            Task { [weak self] in
                await self?.reloadSources()
            }
        case .failure(let error):
            stateView.showMessage(
                title: L10n.RSS.sourceManagementUnavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    private func handleGroups(_ groups: [String]) {
        self.groups = groups
        if let selectedGroup, !groups.contains(selectedGroup) {
            self.selectedGroup = nil
        }
        updateGroupMenu()
        applySnapshot()
    }

    private func reloadSources() async {
        do {
            let sources = try await screen.loadAllSources()
            await MainActor.run {
                self.stateView.hide()
                self.allSources = sources
                self.applySnapshot()
            }
        } catch {
            await MainActor.run {
                self.stateView.showMessage(
                    title: L10n.RSS.sourceManagementLoadFailed,
                    message: error.userFacingMessage,
                    actionTitle: L10n.Common.retry
                ) { [weak self] in
                    Task { await self?.reloadSources() }
                }
            }
        }
    }

    // MARK: - Data

    private func sourceSummary(for source: RssSource) -> String {
        let badges = [
            source.enabled ? L10n.RSS.sourceManagementEnabledBadge : L10n.RSS.sourceManagementDisabledBadge,
        ].compactMap { $0 }
        let meta = [
            source.sourceGroup?.nilIfEmpty,
            badges.joined(separator: " · ").nilIfEmpty,
            source.sourceUrl,
        ].compactMap { $0 }
        return meta.joined(separator: "\n")
    }

    private func applySnapshot() {
        let filtered = filterSources(allSources)
        let signature = filtered.map {
            [
                $0.sourceUrl,
                $0.sourceName,
                $0.sourceGroup ?? "",
                $0.enabled ? "1" : "0",
                selectedSourceURLs.contains($0.sourceUrl) ? "1" : "0",
            ].joined(separator: "#")
        }.joined(separator: "|") + "@\(searchKeyword)#\(selectedGroup ?? "all")#\(isSelectionMode ? "select" : "normal")"
        guard signature != lastDisplayedSignature else { return }
        lastDisplayedSignature = signature
        displayedSources = filtered
        selectedSourceURLs = selectedSourceURLs.intersection(Set(filtered.map(\.sourceUrl)).union(Set(allSources.map(\.sourceUrl))))
        tableView.accessibilityValue = "\(displayedSources.count)"

        if displayedSources.isEmpty {
            let placeholder = searchKeyword.isEmpty ? L10n.RSS.sourceManagementEmpty : L10n.RSS.sourceManagementNoMatch
            tableView.setPlaceholder(placeholder)
            if allSources.isEmpty {
                stateView.showMessage(
                    title: L10n.RSS.sourceManagementEmpty,
                    message: nil
                )
            }
        } else {
            tableView.setPlaceholder(nil)
            stateView.hide()
        }
        tableView.reloadData()
        updateMoreMenu()
    }

    private func filterSources(_ sources: [RssSource]) -> [RssSource] {
        var result = sources

        // Group filter
        if let selectedGroup {
            result = result.filter { source in
                guard let group = source.sourceGroup else { return false }
                return group.components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .contains(selectedGroup)
            }
        }

        // Keyword filter
        if !searchKeyword.isEmpty {
            let keyword = searchKeyword.lowercased()
            result = result.filter { source in
                source.sourceName.lowercased().contains(keyword) ||
                source.sourceUrl.lowercased().contains(keyword) ||
                (source.sourceGroup?.lowercased().contains(keyword) ?? false)
            }
        }

        return result
    }

    // MARK: - Menus

    private func updateGroupMenu() {
        var groupActions: [UIAction] = []
        groupActions.append(UIAction(
            title: L10n.RSS.sourceManagementAllGroups,
            state: selectedGroup == nil ? .on : .off
        ) { [weak self] _ in
            self?.selectedGroup = nil
            self?.applySnapshot()
            self?.updateGroupMenu()
        })
        for group in groups {
            groupActions.append(UIAction(
                title: group,
                state: selectedGroup == group ? .on : .off
            ) { [weak self] _ in
                self?.selectedGroup = group
                self?.applySnapshot()
                self?.updateGroupMenu()
            })
        }
        groupButton.menu = UIMenu(children: groupActions)
        groupButton.showsMenuAsPrimaryAction = true
    }

    private func updateMoreMenu() {
        let addAction = UIAction(
            title: L10n.RSS.sourceManagementAddAction,
            image: UIImage(systemName: "plus.circle")
        ) { [weak self] _ in
            self?.openEditor(sourceUrl: nil)
        }

        let importAction = UIAction(
            title: L10n.RSS.sourceManagementImportAction,
            image: UIImage(systemName: "square.and.arrow.down")
        ) { [weak self] _ in
            self?.handleImportSources()
        }

        let exportAction = UIAction(
            title: L10n.RSS.sourceManagementExportAction,
            image: UIImage(systemName: "square.and.arrow.up")
        ) { [weak self] _ in
            self?.handleExportAll()
        }

        let selectAction = UIAction(
            title: isSelectionMode ? L10n.RSS.sourceManagementFinishSelectAction : L10n.RSS.sourceManagementSelectAction,
            image: UIImage(systemName: isSelectionMode ? "checkmark.circle" : "checkmark.circle.fill")
        ) { [weak self] _ in
            guard let self else { return }
            self.setSelectionMode(!self.isSelectionMode)
        }

        moreButton.menu = UIMenu(children: [addAction, importAction, exportAction, selectAction])
        moreButton.showsMenuAsPrimaryAction = true
    }

    // MARK: - Selection

    private func setSelectionMode(_ enabled: Bool) {
        isSelectionMode = enabled
        selectedSourceURLs.removeAll()
        selectActionBar.isHidden = !enabled
        selectActionBar.snp.updateConstraints { make in
            make.height.equalTo(enabled ? 56 : 0)
        }
        UIView.animate(withDuration: 0.25) {
            self.view.layoutIfNeeded()
        }
        applySnapshot()
    }

    private func toggleSelection(for sourceUrl: String) {
        if selectedSourceURLs.contains(sourceUrl) {
            selectedSourceURLs.remove(sourceUrl)
        } else {
            selectedSourceURLs.insert(sourceUrl)
        }
        scaffoldView.titleBarView.setTitle(
            isSelectionMode ? L10n.RSS.sourceManagementSelectionTitle(selectedSourceURLs.count) : L10n.RSS.sourceManagementTitle
        )
        applySnapshot()
    }

    @objc private func enableSelection() {
        let urls = Array(selectedSourceURLs)
        Task { [weak self] in
            for url in urls {
                try? await self?.screen.setEnabled(sourceUrl: url, enabled: true)
            }
        }
    }

    @objc private func disableSelection() {
        let urls = Array(selectedSourceURLs)
        Task { [weak self] in
            for url in urls {
                try? await self?.screen.setEnabled(sourceUrl: url, enabled: false)
            }
        }
    }

    @objc private func exportSelection() {
        let urls = Array(selectedSourceURLs)
        guard !urls.isEmpty else { return }
        Task { [weak self] in
            do {
                let json = try await self?.screen.exportSources(sourceUrls: urls) ?? "[]"
                await MainActor.run {
                    let activityVC = UIActivityViewController(activityItems: [json], applicationActivities: nil)
                    if let popover = activityVC.popoverPresentationController {
                        popover.sourceView = self?.moreButton
                        popover.sourceRect = self?.moreButton.bounds ?? .zero
                    }
                    self?.present(activityVC, animated: true)
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    @objc private func deleteSelection() {
        let urls = Array(selectedSourceURLs)
        guard !urls.isEmpty else { return }
        let sourcesToDelete = allSources.filter { urls.contains($0.sourceUrl) }
        confirmDelete(sources: sourcesToDelete)
    }

    // MARK: - CRUD Operations

    private func setEnabled(sourceUrl: String, enabled: Bool, sender: UISwitch? = nil) {
        Task { [weak self] in
            do {
                try await self?.screen.setEnabled(sourceUrl: sourceUrl, enabled: enabled)
            } catch {
                await MainActor.run {
                    sender?.setOn(!enabled, animated: true)
                    self?.presentError(error)
                }
            }
        }
    }

    private func confirmDelete(sources: [RssSource]) {
        let message = sources.count == 1
            ? L10n.RSS.sourceManagementDeleteConfirm
            : String(format: L10n.RSS.sourceManagementDeleteConfirm)
        let alert = UIAlertController(
            title: L10n.RSS.sourceManagementDeleteAction,
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.RSS.sourceManagementDeleteAction, style: .destructive) { [weak self] _ in
            self?.performDelete(sourceUrls: sources.map(\.sourceUrl))
        })
        present(alert, animated: true)
    }

    private func performDelete(sourceUrls: [String]) {
        Task { [weak self] in
            do {
                try await self?.screen.deleteSources(sourceUrls: sourceUrls)
                await MainActor.run {
                    self?.selectedSourceURLs.subtract(sourceUrls)
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    private func openEditor(sourceUrl: String?) {
        let editor = RssSourceEditViewController(sourceUrl: sourceUrl, screen: screen)
        navigationController?.pushViewController(editor, animated: true)
    }

    private func openDebug(source: RssSource) {
        let debugVC = RssSourceDebugViewController(source: source)
        navigationController?.pushViewController(debugVC, animated: true)
    }

    // MARK: - Import/Export

    private func handleImportSources() {
        let alert = UIAlertController(
            title: L10n.RSS.sourceManagementImportTitle,
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = L10n.RSS.sourceManagementImportPlaceholder
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self] _ in
            guard let jsonText = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonText.isEmpty else { return }
            self?.performImport(jsonText: jsonText)
        })
        if let clipboard = UIPasteboard.general.string, !clipboard.isEmpty,
           clipboard.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") {
            alert.textFields?.first?.text = clipboard
        }
        present(alert, animated: true)
    }

    private func performImport(jsonText: String) {
        Task { [weak self] in
            do {
                let count = try await self?.screen.importSources(payload: jsonText) ?? 0
                await MainActor.run {
                    let resultAlert = UIAlertController(
                        title: L10n.RSS.sourceManagementImportAction,
                        message: L10n.RSS.sourceManagementImportSuccess(count),
                        preferredStyle: .alert
                    )
                    resultAlert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                    self?.present(resultAlert, animated: true)
                }
            } catch {
                await MainActor.run {
                    let errorAlert = UIAlertController(
                        title: L10n.RSS.sourceManagementImportFailed,
                        message: error.userFacingMessage,
                        preferredStyle: .alert
                    )
                    errorAlert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                    self?.present(errorAlert, animated: true)
                }
            }
        }
    }

    private func handleExportAll() {
        guard !allSources.isEmpty else {
            let alert = UIAlertController(
                title: L10n.RSS.sourceManagementExportAction,
                message: L10n.RSS.sourceManagementExportEmpty,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
            present(alert, animated: true)
            return
        }
        let urls = allSources.map(\.sourceUrl)
        Task { [weak self] in
            do {
                let json = try await self?.screen.exportSources(sourceUrls: urls) ?? "[]"
                await MainActor.run {
                    let activityVC = UIActivityViewController(activityItems: [json], applicationActivities: nil)
                    if let popover = activityVC.popoverPresentationController {
                        popover.sourceView = self?.moreButton
                        popover.sourceRect = self?.moreButton.bounds ?? .zero
                    }
                    self?.present(activityVC, animated: true)
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    @objc private func searchFieldChanged() {
        searchKeyword = searchField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        applySnapshot()
    }
}

// MARK: - RssSourceManagementScreenAdapter

final class RssSourceManagementScreenAdapter {
    private let bindings = ScreenBindingController(owner: "RssSourceManagementScreen")
    private var facade: RssFacade?
    private var lastSourcesSignature: String?

    var onSourcesChange: (([RssSource]) -> Void)?
    var onGroupsChange: (([String]) -> Void)?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindings.cancelAll()
        lastSourcesSignature = nil

        switch SharedRuntime.rssFacade() {
        case .success(let facade):
            self.facade = facade
            bindings.bind(facade.watchAllSources { [weak self] sources in
                DispatchQueue.main.async {
                    self?.handleSources(sources)
                }
            })
            bindings.bind(facade.watchGroups { [weak self] groups in
                DispatchQueue.main.async {
                    self?.onGroupsChange?(groups)
                }
            })
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindings.cancelAll()
    }

    func loadAllSources() async throws -> [RssSource] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getAllSourcesAsync()
    }

    func getSource(sourceUrl: String) async throws -> RssSource? {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.getSourceAsync(sourceUrl: sourceUrl)
    }

    func setEnabled(sourceUrl: String, enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setRssSourceEnabledAsync(sourceUrl: sourceUrl, enabled: enabled)
    }

    func saveSource(source: RssSource) async throws -> RssSource {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.saveRssSourceAsync(source: source)
    }

    func deleteSources(sourceUrls: [String]) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.deleteRssSourcesAsync(sourceUrls: sourceUrls)
    }

    func importSources(payload: String) async throws -> Int32 {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.importRssSourcesAsync(payload: payload)
    }

    func exportSources(sourceUrls: [String]) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.exportRssSourcesAsync(sourceUrls: sourceUrls)
    }

    private func handleSources(_ sources: [RssSource]) {
        let signature = sources.map { "\($0.sourceUrl)#\($0.enabled ? 1 : 0)#\($0.sourceName)#\($0.sourceGroup ?? "")#\($0.customOrder)" }.joined(separator: "|")
        guard signature != lastSourcesSignature else { return }
        lastSourcesSignature = signature
        onSourcesChange?(sources)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.RSS.sourceManagementUnavailable]
        )
    }
}
