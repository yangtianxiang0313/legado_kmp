import SQLite3
import UIKit
import shared

/// The two modes retain independent drafts; only confirmation changes the search scope.
final class SearchScopeViewController: UIViewController {
    var onScopeSelected: ((SearchScopeSelection) -> Void)?

    private let dialogTransitioningDelegate = SearchScopeDialogTransitioningDelegate()
    private let groups: [String]
    private let allSources: [BookSource]
    private var filteredSources: [BookSource]
    private var selectedGroups: [String] = []
    private var selectedSource: (url: String, name: String)?
    private var sourceQuery = ""
    private var hasFinished = false
    private var isDeparting = false

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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = "searchScope.dialog"
        view.accessibilityViewIsModal = true
        toolbar.onQueryChanged = { [weak self] query in self?.applyQuery(query) }
        modeControl.accessibilityIdentifier = "searchScope.mode"
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        actions.onAllSources = { [weak self] in self?.finish(with: .allEnabled) }
        actions.onCancel = { [weak self] in self?.cancelSelection() }
        actions.onConfirm = { [weak self] in self?.confirm() }
        configureTable()
        configureLayout()
        toolbar.setSourceMode(!isGroupMode)
        updateControls()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isDeparting = false
        if isViewLoaded { fastScroller.isEnabled = !hasFinished }
        updateControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDeparting = true
        fastScroller.isEnabled = false
        if isBeingDismissed {
            hasFinished = true
            onScopeSelected = nil
        }
        updateControls()
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
        return true
    }

    private var isGroupMode: Bool { modeControl.selectedSegmentIndex == 0 }
    private var canEdit: Bool { !hasFinished && !isDeparting && !fastScroller.isScrubbing }

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
        let enabled = canEdit
        toolbar.setControlsEnabled(enabled)
        modeControl.isEnabled = enabled
        modeControl.isUserInteractionEnabled = enabled
        actions.setControlsEnabled(enabled)
        tableView.allowsSelection = enabled
    }

    func cancelSelection(animated: Bool = true) {
        finish(with: nil, animated: animated)
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
        guard !hasFinished, !isBeingDismissed else { return }
        hasFinished = true
        fastScroller.isEnabled = false
        view.endEditing(true)
        updateControls()
        let callback = onScopeSelected
        onScopeSelected = nil
        if let scope { callback?(scope) }
        dismiss(animated: animated)
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
