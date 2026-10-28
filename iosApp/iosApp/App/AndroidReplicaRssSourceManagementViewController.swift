import shared
import UIKit

final class AndroidReplicaRssSourceManagementViewController: UIViewController, NavigationCustomToolbarProviding,
    UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate
{
    private let screen = RssSourceManagementScreenAdapter()
    private let topBar = NavigationToolbarView()
    private let backButton = UIButton(type: .system)
    private let searchField = UITextField()
    private let importButton = UIButton(type: .system)
    private let filterBar = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let selectionBar = RssSourceManagementSelectionBar()
    private var selectionBarHeight: NSLayoutConstraint?
    private lazy var management = RssSourceManagementActions(screen: screen, presenter: self)
    private var allSources: [RssSource] { management.sources }
    private var filteredSources: [RssSource] = []
    private var searchKeyword = ""
    private var selectedFilter: SourceFilter = .all
    private var selectedGroup: String?
    private var originalPopGestureEnabled: Bool?

    private enum SourceFilter: CaseIterable {
        case all
        case enabled
        case disabled
        case grouped

        var title: String {
            switch self {
            case .all: return "全部"
            case .enabled: return "启用"
            case .disabled: return "禁用"
            case .grouped: return "分组"
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        configureKeyboardAvoidance()
        configureSelection()
        bindScreen()
    }

    deinit {
        screen.unbind()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        if originalPopGestureEnabled == nil {
            originalPopGestureEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
        }
        updateManagementControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let originalPopGestureEnabled {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = originalPopGestureEnabled
        }
        originalPopGestureEnabled = nil
    }

    private func configureViews() {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton

        searchField.placeholder = L10n.RSS.sourceManagementSearchPlaceholder
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.backgroundColor = AndroidReplicaTheme.menuBackground
        searchField.layer.cornerRadius = 18
        searchField.font = .systemFont(ofSize: 15)
        searchField.textColor = AndroidReplicaTheme.primaryText
        searchField.tintColor = AndroidReplicaTheme.accent
        searchField.leftView = paddedIconView(name: "magnifyingglass")
        searchField.leftViewMode = .always
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        searchField.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementSearchField

        importButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        importButton.tintColor = AndroidReplicaTheme.toolbarText
        importButton.accessibilityLabel = L10n.Bookshelf.moreActions
        importButton.showsMenuAsPrimaryAction = true
        importButton.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementMoreMenu

        filterBar.axis = .horizontal
        filterBar.alignment = .center
        filterBar.distribution = .fillEqually
        filterBar.spacing = 8
        filterBar.backgroundColor = AndroidReplicaTheme.background
        for (index, filter) in SourceFilter.allCases.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.setTitle(filter.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.layer.cornerRadius = 4
            button.addTarget(self, action: #selector(filterTapped(_:)), for: .touchUpInside)
            filterBar.addArrangedSubview(button)
        }
        updateFilterButtons()

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = 72
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 16, right: 0)
        tableView.scrollIndicatorInsets = tableView.contentInset
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(RssSourceManagementCell.self, forCellReuseIdentifier: RssSourceManagementCell.reuseIdentifier)
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementTable

        emptyLabel.text = L10n.RSS.sourceManagementLoading
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isUserInteractionEnabled = true
        emptyLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(retryReloadSources)))
        emptyLabel.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementState

        for item in [topBar, filterBar, tableView, emptyLabel, selectionBar] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [backButton, searchField, importButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }

        let barHeight = selectionBar.heightAnchor.constraint(equalToConstant: 0)
        selectionBarHeight = barHeight
        selectionBar.isHidden = true
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 48),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 48),
            backButton.heightAnchor.constraint(equalToConstant: 48),
            importButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            importButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            importButton.widthAnchor.constraint(equalToConstant: 48),
            importButton.heightAnchor.constraint(equalToConstant: 48),
            searchField.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            searchField.trailingAnchor.constraint(equalTo: importButton.leadingAnchor, constant: -4),
            searchField.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 36),
            filterBar.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            filterBar.heightAnchor.constraint(equalToConstant: 32),
            tableView.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 4),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: selectionBar.topAnchor),
            selectionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            barHeight,
            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableView.trailingAnchor, constant: -24),
        ])
    }

    private func configureKeyboardAvoidance() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tableView.addGestureRecognizer(tap)
    }

    private func configureSelection() {
        selectionBar.onSelectAll = { [weak self] in
            guard let self else { return }
            self.management.toggleAll(visibleURLs: self.filteredSources.map(\.sourceUrl))
        }
        selectionBar.onInvert = { [weak self] in
            guard let self else { return }
            self.management.invertSelection(visibleURLs: self.filteredSources.map(\.sourceUrl))
        }
        selectionBar.onDelete = { [weak self] in
            guard let self else { return }
            self.management.confirmDelete(sourceURLs: self.management.selectedURLs.sorted())
        }
        selectionBar.onCancel = { [weak self] in self?.management.cancelSelection() }
        updateManagementControls()
    }

    private func updateManagementControls() {
        let busy = management.isBusy
        let selecting = management.isSelecting
        if navigationController?.topViewController === self, let originalPopGestureEnabled {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = originalPopGestureEnabled && !busy && !selecting
        }
        backButton.isEnabled = !busy
        backButton.accessibilityLabel = selecting ? "取消选择" : "返回"
        backButton.setImage(UIImage(systemName: selecting ? "xmark" : "chevron.left"), for: .normal)
        searchField.isEnabled = !busy
        filterBar.isUserInteractionEnabled = !busy
        importButton.isEnabled = !busy && management.hasSnapshot
        importButton.menu = makeMoreMenu()
        selectionBar.isHidden = !selecting
        selectionBarHeight?.constant = selecting ? 48 : 0
        let visible = Set(filteredSources.map(\.sourceUrl))
        selectionBar.update(
            selected: management.selectedURLs.count,
            allVisibleSelected: !visible.isEmpty && visible.isSubset(of: management.selectedURLs),
            hasVisible: !visible.isEmpty,
            busy: busy,
            menu: management.selectionMenu(anchor: selectionBar)
        )
    }

    private func makeMoreMenu() -> UIMenu {
        let unavailable: UIMenuElement.Attributes = management.isSelecting ? [.disabled] : []
        let sourceURLs = allSources.map(\.sourceUrl)
        return UIMenu(children: [
            UIAction(
                title: "多选", image: UIImage(systemName: "checkmark.circle"),
                attributes: management.isSelecting || sourceURLs.isEmpty ? [.disabled] : []
            ) { [weak self] _ in
                self?.view.endEditing(true)
                self?.management.beginSelection()
            },
            management.groupMenu { [weak self] group in
                guard let self, !self.management.isBusy else { return }
                self.selectedGroup = group
                self.selectedFilter = .grouped
                self.applyFilter()
            },
            UIAction(
                title: "导出全部", image: UIImage(systemName: "square.and.arrow.up"),
                attributes: sourceURLs.isEmpty ? [.disabled] : []
            ) { [weak self] _ in
                guard let self else { return }
                self.view.endEditing(true)
                self.management.export(sourceURLs: sourceURLs, anchor: self.importButton)
            },
            UIAction(title: L10n.RSS.sourceEditCreateTitle, image: UIImage(systemName: "plus"), attributes: unavailable) {
                [weak self] _ in
                guard let self, !self.management.isBusy, !self.management.isSelecting else { return }
                self.navigationController?.pushViewController(
                    RssSourceEditViewController(sourceUrl: nil, screen: self.screen), animated: true)
            },
            UIAction(title: "JSON 导入", image: UIImage(systemName: "curlybraces"), attributes: unavailable) { [weak self] _ in
                guard let self, !self.management.isBusy, !self.management.isSelecting else { return }
                self.navigationController?.pushViewController(
                    AndroidReplicaRssImportViewController(screen: self.screen), animated: true)
            },
            UIAction(title: "导入内置源", image: UIImage(systemName: "square.and.arrow.down"), attributes: unavailable) {
                [weak self] _ in
                self?.importBundledSources()
            },
        ])
    }

    private func paddedIconView(name: String) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 38, height: 36))
        let imageView = UIImageView(image: UIImage(systemName: name))
        imageView.tintColor = AndroidReplicaTheme.secondaryText
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        return container
    }

    private func bindScreen() {
        management.onChange = { [weak self] in self?.applyFilter() }
        management.onGroupRenamed = { [weak self] oldName, newName in
            guard let self, self.selectedGroup == oldName else { return }
            self.selectedGroup = newName
        }
        management.onGroupRemoved = { [weak self] group in
            guard let self, self.selectedGroup == group else { return }
            self.selectedGroup = nil
            self.selectedFilter = .all
        }
        screen.onSourcesChange = { [weak self] sources in
            self?.management.receive(sources)
        }
        switch screen.bootstrap() {
        case .success:
            management.reload()
        case let .failure(error):
            emptyLabel.text = "\(error.message)\n\(L10n.Common.retry)"
            emptyLabel.isHidden = false
        }
    }

    private func applyFilter() {
        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var sources = allSources.sorted { $0.customOrder < $1.customOrder }
        switch selectedFilter {
        case .all:
            break
        case .enabled:
            sources = sources.filter { $0.enabled }
        case .disabled:
            sources = sources.filter { $0.enabled == false }
        case .grouped:
            if let selectedGroup {
                sources = sources.filter { source in
                    (source.sourceGroup ?? "").components(separatedBy: CharacterSet(charactersIn: ",;，；"))
                        .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == selectedGroup }
                }
            } else {
                sources = sources.filter { $0.sourceGroup?.nilIfEmpty != nil }
            }
        }
        if keyword.isEmpty {
            filteredSources = sources
        } else {
            let lower = keyword.lowercased()
            filteredSources = sources.filter { source in
                source.sourceName.lowercased().contains(lower) ||
                    source.sourceUrl.lowercased().contains(lower) ||
                    (source.sourceGroup?.lowercased().contains(lower) ?? false)
            }
        }
        emptyLabel.text = allSources.isEmpty ? L10n.RSS.sourceManagementEmpty : L10n.RSS.sourceManagementNoMatch
        if management.isBusy && !management.hasSnapshot {
            emptyLabel.text = L10n.RSS.sourceManagementLoading
        } else if let error = management.loadError {
            emptyLabel.text = "\(error)\n\(L10n.Common.retry)"
        }
        emptyLabel.isHidden = filteredSources.isEmpty == false
        tableView.reloadData()
        updateFilterButtons()
        updateManagementControls()
    }

    @objc private func handleBack() {
        guard !management.isBusy else { return }
        if management.isSelecting {
            management.cancelSelection()
            return
        }
        navigationController?.popViewController(animated: true)
    }

    @objc private func searchTextChanged() {
        searchKeyword = searchField.text ?? ""
        applyFilter()
    }

    @objc private func filterTapped(_ sender: UIButton) {
        guard !management.isBusy, SourceFilter.allCases.indices.contains(sender.tag) else { return }
        selectedFilter = SourceFilter.allCases[sender.tag]
        selectedGroup = nil
        applyFilter()
    }

    @objc private func importBundledSources() {
        guard !management.isBusy, !management.isSelecting else { return }
        guard let payload = Bundle.main.legadoDefaultRssSourcesPayload() else {
            showMessage(L10n.RSS.sourceManagementImportFailed)
            return
        }
        management.importBundled(payload: payload)
    }

    @objc private func retryReloadSources() {
        guard filteredSources.isEmpty, !management.isBusy else { return }
        bindScreen()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    private func setEnabled(source: RssSource, enabled: Bool) {
        management.setEnabled(sourceURLs: [source.sourceUrl], enabled: enabled)
    }

    private func delete(source: RssSource) {
        management.confirmDelete(sourceURLs: [source.sourceUrl], sourceName: source.sourceName)
    }

    private func edit(source: RssSource) {
        guard !management.isBusy, !management.isSelecting else { return }
        navigationController?.pushViewController(
            RssSourceEditViewController(sourceUrl: source.sourceUrl, screen: screen).configuredForDrillDownPresentation(),
            animated: true
        )
    }

    private func showMenu(for source: RssSource, from anchor: UIView) {
        management.showSourceMenu(source, anchor: anchor)
    }

    private func showMessage(_ message: String) {
        showTransientMessage(message)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard !management.isBusy, filteredSources.indices.contains(indexPath.row) else { return }
        let source = filteredSources[indexPath.row]
        if management.isSelecting {
            management.toggle(source.sourceUrl)
        } else {
            edit(source: source)
        }
    }

    func tableView(_: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard !management.isBusy, !management.isSelecting, filteredSources.indices.contains(indexPath.row) else { return nil }
        let source = filteredSources[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.RSS.sourceManagementDeleteAction) { [weak self] _, _, completion in
            self?.delete(source: source)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        let enable = UIContextualAction(style: .normal, title: source.enabled ? L10n.RSS.sourceManagementDisableAction : L10n.RSS.sourceManagementEnableAction) { [weak self] _, _, completion in
            self?.setEnabled(source: source, enabled: !source.enabled)
            completion(true)
        }
        enable.image = UIImage(systemName: source.enabled ? "pause.circle" : "play.circle")
        enable.backgroundColor = AndroidReplicaTheme.accent
        return UISwipeActionsConfiguration(actions: [delete, enable])
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        filteredSources.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: RssSourceManagementCell.reuseIdentifier, for: indexPath)
            as! RssSourceManagementCell
        let source = filteredSources[indexPath.row]
        cell.accessibilityIdentifier = UIIdentifiers.RSS.sourceManagementSourceCell
        cell.configure(
            source: source, selecting: management.isSelecting, selected: management.selectedURLs.contains(source.sourceUrl),
            busy: management.isBusy)
        cell.onSelection = { [weak self] in self?.management.toggle(source.sourceUrl) }
        cell.onEnabledChange = { [weak self] enabled in self?.setEnabled(source: source, enabled: enabled) }
        cell.onEdit = { [weak self] in self?.edit(source: source) }
        cell.onMore = { [weak self, weak cell] button in
            self?.showMenu(for: source, from: button ?? cell ?? tableView)
        }
        return cell
    }

    private func updateFilterButtons() {
        for (index, view) in filterBar.arrangedSubviews.enumerated() {
            guard let button = view as? UIButton, SourceFilter.allCases.indices.contains(index) else { continue }
            let filter = SourceFilter.allCases[index]
            let selected = filter == selectedFilter
            button.setTitle(filter == .grouped ? (selectedGroup ?? filter.title) : filter.title, for: .normal)
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.accessibilityLabel = filter == .grouped ? (selectedGroup ?? filter.title) : filter.title
            button.backgroundColor = selected ? AndroidReplicaTheme.accent.withAlphaComponent(0.14) : AndroidReplicaTheme.menuBackground
            button.setTitleColor(selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText, for: .normal)
            button.layer.borderWidth = selected ? 1 / UIScreen.main.scale : 0
            button.layer.borderColor = selected ? AndroidReplicaTheme.accent.withAlphaComponent(0.45).cgColor : nil
        }
    }
}
