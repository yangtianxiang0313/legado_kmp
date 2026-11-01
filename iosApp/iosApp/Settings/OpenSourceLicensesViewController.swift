import UIKit

@MainActor
final class OpenSourceLicensesViewController: UIViewController, NavigationCustomToolbarProviding,
    UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate
{
    private enum SearchScope: CaseIterable {
        case all, name, license

        var title: String {
            switch self {
            case .all: return OpenSourceLicensesText.allFields
            case .name: return OpenSourceLicensesText.name
            case .license: return OpenSourceLicensesText.license
            }
        }
    }

    private struct Section {
        let category: OpenSourceLicenseCategory
        let components: [OpenSourceLicenseComponent]
    }

    private let toolbar = OpenSourceLicensesToolbar(title: OpenSourceLicensesText.title)
    private let searchField = UISearchTextField()
    private let filterButton = OpenSourceLicensesUI.icon(
        "line.3.horizontal.decrease.circle", label: OpenSourceLicensesText.filter, identifier: "licenses.filter")
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let status = OpenSourceLicensesStatusView()
    private var components: [OpenSourceLicenseComponent] = []
    private var sections: [Section] = []
    private var scope: SearchScope = .all
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()
    private var needsLoad = true
    private var isVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OpenSourceLicensesText.title
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        refreshPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        refreshPalette()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if needsLoad { loadCatalog() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        view.endEditing(true)
        if loadTask != nil { needsLoad = true }
        cancelLoad()
    }

    deinit {
        loadTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureViews() {
        toolbar.backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        searchField.placeholder = OpenSourceLicensesText.search
        searchField.accessibilityLabel = OpenSourceLicensesText.search
        searchField.accessibilityIdentifier = "licenses.search"
        searchField.font = .preferredFont(forTextStyle: .body)
        searchField.adjustsFontForContentSizeCategory = true
        searchField.textAlignment = .natural
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.clearButtonMode = .whileEditing
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(queryChanged), for: .editingChanged)
        filterButton.showsMenuAsPrimaryAction = true
        updateFilterMenu()

        let searchBar = UIStackView(arrangedSubviews: [searchField, filterButton])
        searchBar.axis = .horizontal
        searchBar.alignment = .center
        searchBar.spacing = 8
        searchBar.isLayoutMarginsRelativeArrangement = true
        searchBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 8)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        tableView.register(OpenSourceLicensesComponentCell.self, forCellReuseIdentifier: OpenSourceLicensesComponentCell.reuseIdentifier)
        tableView.register(
            OpenSourceLicensesSectionHeader.self, forHeaderFooterViewReuseIdentifier: OpenSourceLicensesSectionHeader.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 78
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 46
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorInset = .zero
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.accessibilityIdentifier = "licenses.table"
        status.retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        for item in [toolbar, searchBar, tableView, status] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchBar.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            status.topAnchor.constraint(equalTo: tableView.topAnchor),
            status.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
        ])
        status.showLoading()
    }

    private func loadCatalog() {
        cancelLoad()
        let id = requestID
        needsLoad = true
        components = []
        sections = []
        tableView.reloadData()
        tableView.accessibilityValue = nil
        tableView.accessibilityElementsHidden = true
        status.showLoading()
        searchField.isEnabled = false
        filterButton.isEnabled = false

        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let values = try OpenSourceLicenseCatalog.load()
            guard !values.isEmpty else { throw OpenSourceLicensesContentError.emptyCatalog }
            try Task.checkCancellation()
            return values
        }
        loadTask = Task { [weak self] in
            do {
                let values = try await withTaskCancellationHandler(
                    operation: {
                        try await worker.value
                    }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, let self, self.requestID == id, self.isVisible else { return }
                self.loadTask = nil
                self.needsLoad = false
                self.components = values
                self.searchField.isEnabled = true
                self.filterButton.isEnabled = true
                self.applyFilter()
            } catch {
                guard !Task.isCancelled, let self, self.requestID == id, self.isVisible else { return }
                self.loadTask = nil
                self.needsLoad = false
                self.status.show(message: OpenSourceLicensesText.catalogFailure + "\n\n" + error.localizedDescription, retry: true)
            }
        }
    }

    private func cancelLoad() {
        requestID = UUID()
        loadTask?.cancel()
        loadTask = nil
    }

    private func applyFilter() {
        let query = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = components.filter { component in
            guard !query.isEmpty else { return true }
            let fields: [String]
            switch scope {
            case .all: fields = [component.title, component.license]
            case .name: fields = [component.title]
            case .license: fields = [component.license]
            }
            return fields.contains {
                $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
            }
        }
        sections = OpenSourceLicenseCategory.allCases.compactMap { category in
            let values = filtered.filter { $0.category == category }
            return values.isEmpty ? nil : Section(category: category, components: values)
        }
        tableView.accessibilityElementsHidden = filtered.isEmpty
        tableView.accessibilityValue = String(filtered.count)
        tableView.reloadData()
        if filtered.isEmpty {
            status.show(message: OpenSourceLicensesText.noMatches, retry: false)
        } else {
            status.hide()
        }
    }

    private func updateFilterMenu() {
        filterButton.accessibilityValue = scope.title
        filterButton.menu = UIMenu(
            title: OpenSourceLicensesText.filter, options: .singleSelection,
            children:
                SearchScope.allCases.map { value in
                    UIAction(title: value.title, state: scope == value ? .on : .off) { [weak self] _ in
                        guard let self, self.canPerformNavigationAction, !self.needsLoad else { return }
                        self.view.endEditing(true)
                        self.scope = value
                        self.updateFilterMenu()
                        self.applyFilter()
                    }
                })
    }

    @objc private func queryChanged() {
        guard !needsLoad else { return }
        applyFilter()
    }

    @objc private func retryLoad() {
        guard canPerformNavigationAction else { return }
        loadCatalog()
    }

    @objc private func goBack() {
        guard canPerformNavigationAction else { return }
        OpenSourceLicensesUI.close(self)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canPerformNavigationAction else { return false }
        goBack()
        return true
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func numberOfSections(in _: UITableView) -> Int { sections.count }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].components.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: OpenSourceLicensesComponentCell.reuseIdentifier, for: indexPath)
        (cell as? OpenSourceLicensesComponentCell)?.configure(sections[indexPath.section].components[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header =
            tableView.dequeueReusableHeaderFooterView(withIdentifier: OpenSourceLicensesSectionHeader.reuseIdentifier)
            as? OpenSourceLicensesSectionHeader
        header?.configure(category: sections[section].category, count: sections[section].components.count)
        return header
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard canPerformNavigationAction, !needsLoad, sections.indices.contains(indexPath.section),
            sections[indexPath.section].components.indices.contains(indexPath.row)
        else { return }
        view.endEditing(true)
        navigationController?.pushViewController(
            OpenSourceLicenseTextViewController(component: sections[indexPath.section].components[indexPath.row]), animated: true)
    }

    @objc private func refreshPalette() {
        view.backgroundColor = AndroidReplicaTheme.background
        toolbar.refreshPalette()
        status.refreshPalette()
        searchField.backgroundColor = AndroidReplicaTheme.menuBackground
        searchField.textColor = AndroidReplicaTheme.primaryText
        searchField.tintColor = AndroidReplicaTheme.accent
        searchField.attributedPlaceholder = NSAttributedString(
            string: OpenSourceLicensesText.search, attributes: [.foregroundColor: AndroidReplicaTheme.secondaryText])
        searchField.leftView?.tintColor = AndroidReplicaTheme.secondaryText
        filterButton.tintColor = AndroidReplicaTheme.primaryText
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorColor = AndroidReplicaTheme.divider
        for cell in tableView.visibleCells { (cell as? OpenSourceLicensesComponentCell)?.refreshPalette() }
        for section in sections.indices {
            (tableView.headerView(forSection: section) as? OpenSourceLicensesSectionHeader)?.refreshPalette()
        }
    }
}
