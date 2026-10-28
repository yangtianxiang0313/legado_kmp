import SafariServices
import UIKit
import UniformTypeIdentifiers
import shared

final class AndroidReplicaReplaceRuleViewController: UIViewController, NavigationCustomToolbarProviding,
    UITableViewDataSource, UITableViewDelegate,
    UITextFieldDelegate, UIDocumentPickerDelegate
{
    enum GroupFilter: Equatable {
        case all
        case named(String)
        case ungrouped
    }

    let screen = ReplaceRuleScreenAdapter()
    private let topBar = AndroidReplicaReplaceRuleToolbarView()
    private let selectionBar = AndroidReplicaReplaceRuleSelectionBar()
    private var searchField: UITextField { topBar.searchField }
    private var popup: ReaderOverflowMenuView?
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var allRules: [ReplaceRule] = []
    private var displayedRules: [ReplaceRule] = []
    private var allGroups: [String] = []
    private var searchKeyword = ""
    private var filterGroup: GroupFilter = .all
    private var selectedRuleIDs = Set<Int64>()
    private var initialRules: [ReplaceRule]?
    var onRulesChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        bindScreen()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        popup?.dismiss()
    }

    deinit {
        screen.unbind()
    }

    private func configureViews() {
        configureTopBar()
        configureTableView()
        configureEmptyView()

        for item in [topBar, tableView, emptyLabel, selectionBar] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),

            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: selectionBar.topAnchor),
            selectionBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            selectionBar.heightAnchor.constraint(equalToConstant: 56),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: tableView.leadingAnchor, constant: 28),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: tableView.trailingAnchor, constant: -28),
        ])
    }

    private func configureTopBar() {
        topBar.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        topBar.groupButton.addTarget(self, action: #selector(showGroupFilter), for: .touchUpInside)
        topBar.moreButton.addTarget(self, action: #selector(showMoreMenu), for: .touchUpInside)
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        selectionBar.allButton.addTarget(self, action: #selector(selectAllTapped), for: .touchUpInside)
        selectionBar.invertButton.addTarget(self, action: #selector(invertTapped), for: .touchUpInside)
        selectionBar.deleteButton.addTarget(self, action: #selector(deleteSelectionTapped), for: .touchUpInside)
        selectionBar.moreButton.addTarget(self, action: #selector(batchMoreTapped), for: .touchUpInside)
    }

    private func configureTableView() {
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.keyboardDismissMode = .interactive
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            AndroidReplicaReplaceRuleCell.self, forCellReuseIdentifier: AndroidReplicaReplaceRuleCell.reuseIdentifier)
    }

    private func configureEmptyView() {
        emptyLabel.text = L10n.ReplaceRule.importLoading
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .preferredFont(forTextStyle: .body)
    }

    private func bindScreen() {
        screen.onRulesChange = { [weak self] rules in
            self?.handleRulesUpdate(rules)
        }
        switch screen.bootstrap() {
        case .success:
            break
        case .failure(let error):
            emptyLabel.text = error.userFacingMessage
            emptyLabel.isHidden = false
        }
    }

    private func handleRulesUpdate(_ rules: [ReplaceRule]) {
        if let initialRules {
            if !initialRules.elementsEqual(rules, by: { $0.isEqual($1) }) { onRulesChanged?() }
        } else {
            initialRules = rules
        }
        allRules = rules.sorted { $0.order < $1.order }
        collectGroups()
        applyFilter()
    }

    private func collectGroups() {
        var seen = Set<String>()
        var groups: [String] = []
        for rule in allRules {
            guard let group = rule.group?.trimmingCharacters(in: .whitespacesAndNewlines), group.isEmpty == false else {
                continue
            }
            if seen.insert(group).inserted {
                groups.append(group)
            }
        }
        allGroups = groups.sorted()
    }

    private func applyFilter() {
        var filtered = allRules

        switch filterGroup {
        case .all:
            break
        case .named(let group):
            filtered = filtered.filter { $0.group == group }
        case .ungrouped:
            filtered = filtered.filter { $0.group == nil || $0.group?.isEmpty == true }
        }

        let keyword = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.isEmpty == false {
            let lowercasedKeyword = keyword.lowercased()
            if lowercasedKeyword.hasPrefix("group:") {
                let groupName = String(lowercasedKeyword.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                filtered = filtered.filter { $0.group?.lowercased().contains(groupName) == true }
            } else {
                filtered = filtered.filter { rule in
                    rule.name.lowercased().contains(lowercasedKeyword)
                        || rule.pattern.lowercased().contains(lowercasedKeyword)
                        || (rule.group?.lowercased().contains(lowercasedKeyword) == true)
                }
            }
        }

        displayedRules = filtered
        selectedRuleIDs = selectedRuleIDs.intersection(Set(displayedRules.map(\.id)))
        emptyLabel.text = nil
        emptyLabel.isHidden = true
        updateModeChrome()
        tableView.reloadData()
    }

    private func updateModeChrome() {
        selectionBar.update(selectedCount: selectedRuleIDs.count, totalCount: displayedRules.count)
        topBar.groupButton.accessibilityValue = filterTitle()
    }

    private func filterTitle() -> String {
        switch filterGroup {
        case .all:
            return L10n.ReplaceRule.title
        case .named(let group):
            return group
        case .ungrouped:
            return L10n.ReplaceRule.ungrouped
        }
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func searchTextChanged() {
        filterGroup = .all
        searchKeyword = searchField.text ?? ""
        applyFilter()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        displayedRules.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: AndroidReplicaReplaceRuleCell.reuseIdentifier, for: indexPath)
            as! AndroidReplicaReplaceRuleCell
        let rule = displayedRules[indexPath.row]
        cell.configure(
            rule: rule,
            selected: selectedRuleIDs.contains(rule.id),
            selectionMode: true
        )
        cell.onToggle = { [weak self] enabled in
            self?.setRule(rule, enabled: enabled)
        }
        cell.onMore = { [weak self, weak cell] in
            guard let self, let cell else { return }
            self.showRuleMenu(rule, from: cell)
        }
        cell.onEdit = { [weak self] in self?.openEditor(rule: rule) }
        cell.onSelect = { [weak self] in self?.toggleSelection(ruleID: rule.id) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let rule = displayedRules[indexPath.row]
        toggleSelection(ruleID: rule.id)
    }

    private func setRule(_ rule: ReplaceRule, enabled: Bool) {
        Task { [weak self] in
            do {
                try await self?.screen.updateEnabled(id: rule.id, enabled: enabled)
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func openEditor(rule: ReplaceRule?) {
        navigationController?.pushViewController(
            ReplaceRuleEditorViewController(rule: rule, facade: screen.facade),
            animated: true
        )
    }

    @objc private func showGroupFilter() {
        var items: [ReaderOverflowMenuView.Item] = [
            menuItem("menu_group_manage", title: L10n.ReplaceRule.groupManageAction) { $0.showGroupManage() },
            menuItem("menu_group_null", title: L10n.ReplaceRule.ungrouped) { $0.selectGroup(.ungrouped) },
        ]
        items.append(
            contentsOf: allGroups.enumerated().map { index, group in
                menuItem("replace_group_\(index)", title: group) { $0.selectGroup(.named(group)) }
            })
        presentPopup(items, anchor: topBar.groupButton)
    }

    private func selectGroup(_ group: GroupFilter) {
        filterGroup = group
        searchKeyword = ""
        switch group {
        case .all: searchField.text = ""
        case .ungrouped: searchField.text = L10n.ReplaceRule.ungrouped
        case .named(let name): searchField.text = "group:\(name)"
        }
        topBar.updateQueryChrome()
        searchField.resignFirstResponder()
        applyFilter()
    }

    @objc private func showMoreMenu() {
        presentPopup(
            [
                menuItem("menu_add_replace_rule", title: L10n.ReplaceRule.newRuleAction) { $0.openEditor(rule: nil) },
                menuItem("menu_import_local", title: L10n.ReplaceRule.importFromFile) { $0.showFileImportPicker() },
                menuItem("menu_import_onLine", title: L10n.ReplaceRule.importFromUrl) { $0.showUrlImportSheet() },
                menuItem("menu_import_qr", title: "二维码导入") { $0.openQRImport() },
                menuItem("menu_help", title: "帮助") { $0.openReplaceHelp() },
            ], anchor: topBar.moreButton)
    }

    private func openQRImport() {
        let scanner = QRCodeScannerViewController()
        scanner.onQRCodeScanned = { [weak self, weak scanner] text in
            guard let self, let scanner, self.navigationController?.topViewController === scanner else { return }
            self.navigationController?.popViewController(animated: true)
            let finish: () -> Void = { [weak self] in
                guard let self, self.navigationController?.topViewController === self else { return }
                if text.hasPrefix("http://") || text.hasPrefix("https://") {
                    self.validateAndImportUrl(text)
                } else {
                    self.showImportPreview(self.parseReplaceRulesJson(text))
                }
            }
            if let transition = self.navigationController?.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { context in
                    if !context.isCancelled { finish() }
                }
            } else {
                DispatchQueue.main.async(execute: finish)
            }
        }
        navigationController?.pushViewController(scanner, animated: true)
    }

    private func openReplaceHelp() {
        guard
            let url = URL(
                string:
                    "https://github.com/gedoor/legado/blob/5f5d31404af9957684703747ecee2b91e7161f1d/app/src/main/assets/web/help/md/replaceRuleHelp.md"
            )
        else { return }
        present(SFSafariViewController(url: url), animated: true)
    }

    private func menuItem(
        _ id: String, title: String, action: @escaping (AndroidReplicaReplaceRuleViewController) -> Void
    ) -> ReaderOverflowMenuView.Item {
        .init(identifier: "replaceRule.\(id)", title: title) { [weak self] in
            guard let self, self.viewIfLoaded?.window != nil, self.navigationController?.topViewController === self,
                self.presentedViewController == nil, !self.isMovingFromParent, !self.isBeingDismissed
            else { return }
            action(self)
        }
    }

    private func presentPopup(_ items: [ReaderOverflowMenuView.Item], anchor: UIView) {
        guard presentedViewController == nil, viewIfLoaded?.window != nil, anchor.window === view.window else { return }
        popup?.dismiss()
        view.endEditing(true)
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: anchor, interfaceStyle: traitCollection.userInterfaceStyle)
        popup = menu
        menu.onDismiss = { [weak self, weak menu] in
            if self?.popup === menu { self?.popup = nil }
        }
        menu.present(in: view)
    }

    private func showRuleMenu(_ rule: ReplaceRule, from cell: AndroidReplicaReplaceRuleCell) {
        guard let anchor = cell.moreMenuAnchor else { return }
        presentPopup(
            [
                menuItem("menu_top", title: L10n.ReplaceRule.moveToTopAction) { $0.moveToTop(rule: rule) },
                menuItem("menu_bottom", title: L10n.ReplaceRule.moveToBottomAction) { $0.moveToBottom(rule: rule) },
                menuItem("menu_del", title: L10n.ReplaceRule.deleteAction) { $0.confirmDelete(rule: rule) },
            ], anchor: anchor)
    }

    @objc private func batchMoreTapped() {
        let selected = displayedRules.filter { selectedRuleIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        presentPopup(
            [
                menuItem("menu_enable_selection", title: "启用所选") { $0.batchSetEnabled(true) },
                menuItem("menu_disable_selection", title: "禁用所选") { $0.batchSetEnabled(false) },
                menuItem("menu_top_sel", title: "所选置顶") { $0.batchMoveToTop() },
                menuItem("menu_bottom_sel", title: "所选置底") { $0.batchMoveToBottom() },
                menuItem("menu_export_selection", title: "导出所选") { $0.exportRules(selected) },
            ], anchor: selectionBar.moreButton)
    }

    @objc private func selectAllTapped() { toggleSelectAll() }
    @objc private func invertTapped() { invertSelection() }
    @objc private func deleteSelectionTapped() {
        let selected = displayedRules.filter { selectedRuleIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        confirmBatchDelete(selected)
    }

    private func exitSelectionMode() {
        selectedRuleIDs.removeAll()
        updateModeChrome()
        tableView.reloadData()
    }

    private func toggleSelection(ruleID: Int64) {
        if selectedRuleIDs.contains(ruleID) {
            selectedRuleIDs.remove(ruleID)
        } else {
            selectedRuleIDs.insert(ruleID)
        }
        updateModeChrome()
        tableView.reloadData()
    }

    private func toggleSelectAll() {
        let ids = Set(displayedRules.map(\.id))
        selectedRuleIDs = selectedRuleIDs.count == ids.count ? [] : ids
        updateModeChrome()
        tableView.reloadData()
    }

    private func invertSelection() {
        let ids = Set(displayedRules.map(\.id))
        selectedRuleIDs = ids.subtracting(selectedRuleIDs)
        updateModeChrome()
        tableView.reloadData()
    }

    private func confirmDelete(rule: ReplaceRule) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.ReplaceRule.deleteConfirmTitle,
            options: [
                .init(
                    title: String(format: L10n.ReplaceRule.deleteConfirmMessage, displayName(for: rule)),
                    systemImage: "trash", isSelected: false, isDestructive: true
                ) { [weak self] in
                    self?.deleteRule(rule)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        presentOptionSheet(controller)
    }

    private func deleteRule(_ rule: ReplaceRule) {
        Task { [weak self] in
            do {
                try await self?.screen.deleteRule(id: rule.id)
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func confirmBatchDelete(_ rules: [ReplaceRule]) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.ReplaceRule.batchDeleteConfirmTitle,
            options: [
                .init(
                    title: L10n.ReplaceRule.batchDeleteConfirmMessage(rules.count), systemImage: "trash",
                    isSelected: false, isDestructive: true
                ) { [weak self] in
                    self?.batchDelete(rules)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        presentOptionSheet(controller)
    }

    private func batchDelete(_ rules: [ReplaceRule]) {
        Task { [weak self] in
            do {
                try await self?.screen.deleteRules(rules)
                await MainActor.run { self?.exitSelectionMode() }
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func batchSetEnabled(_ enabled: Bool) {
        let ids = selectedRuleIDs
        Task { [weak self] in
            guard let self else { return }
            do {
                for id in ids {
                    try await self.screen.updateEnabled(id: id, enabled: enabled)
                }
            } catch {
                await MainActor.run { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func moveToTop(rule: ReplaceRule) {
        let minOrder = allRules.map(\.order).min() ?? 0
        Task { [weak self] in
            do {
                try await self?.screen.updateOrder(id: rule.id, order: minOrder - 1)
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func moveToBottom(rule: ReplaceRule) {
        let maxOrder = allRules.map(\.order).max() ?? 0
        Task { [weak self] in
            do {
                try await self?.screen.updateOrder(id: rule.id, order: maxOrder + 1)
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func batchMoveToTop() {
        let selected = displayedRules.filter { selectedRuleIDs.contains($0.id) }
        let minOrder = allRules.map(\.order).min() ?? 0
        Task { [weak self] in
            guard let self else { return }
            do {
                for (index, rule) in selected.enumerated() {
                    try await self.screen.updateOrder(
                        id: rule.id, order: minOrder - Int32(selected.count) + Int32(index))
                }
            } catch {
                await MainActor.run { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func batchMoveToBottom() {
        let selected = displayedRules.filter { selectedRuleIDs.contains($0.id) }
        let maxOrder = allRules.map(\.order).max() ?? 0
        Task { [weak self] in
            guard let self else { return }
            do {
                for (index, rule) in selected.enumerated() {
                    try await self.screen.updateOrder(id: rule.id, order: maxOrder + Int32(index) + 1)
                }
            } catch {
                await MainActor.run { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func showGroupManage() {
        var options = allGroups.map { group in
            AndroidReplicaOptionSheetViewController.Option(title: group, systemImage: "folder", isSelected: false) {
                [weak self] in
                self?.showGroupActions(group)
            }
        }
        options.append(
            .init(title: L10n.ReplaceRule.addGroupTitle, systemImage: "folder.badge.plus", isSelected: false) {
                [weak self] in
                self?.showGroupNameSheet(title: L10n.ReplaceRule.addGroupTitle, initialValue: nil) { [weak self] name in
                    self?.allGroups.append(name)
                    self?.allGroups.sort()
                }
            })
        options.append(.init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {})
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.ReplaceRule.groupManageTitle, options: options)
        presentOptionSheet(controller)
    }

    private func showGroupActions(_ group: String) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: group,
            options: [
                .init(title: L10n.ReplaceRule.renameGroupTitle, systemImage: "pencil", isSelected: false) {
                    [weak self] in
                    self?.showGroupNameSheet(title: L10n.ReplaceRule.renameGroupTitle, initialValue: group) {
                        [weak self] newName in
                        self?.renameGroup(from: group, to: newName)
                    }
                },
                .init(
                    title: L10n.ReplaceRule.deleteGroupTitle, systemImage: "folder.badge.minus", isSelected: false,
                    isDestructive: true
                ) { [weak self] in
                    self?.confirmDeleteGroup(group)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        presentOptionSheet(controller)
    }

    private func showGroupNameSheet(title: String, initialValue: String?, completion: @escaping (String) -> Void) {
        let controller = AndroidReplicaTextInputSheetViewController(
            titleText: title,
            placeholder: L10n.ReplaceRule.groupNamePlaceholder,
            initialValue: initialValue,
            keyboardType: .default
        ) { [weak self] text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false else { return }
            completion(name)
            self?.collectGroups()
            self?.applyFilter()
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 260), animated: true)
    }

    private func renameGroup(from oldName: String, to newName: String) {
        let affected = allRules.filter { $0.group == oldName }
        Task { [weak self] in
            guard let self else { return }
            do {
                for rule in affected {
                    try await self.screen.saveRule(rule.copyWithGroup(newName))
                }
            } catch {
                await MainActor.run { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func confirmDeleteGroup(_ group: String) {
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.ReplaceRule.deleteGroupTitle,
            options: [
                .init(
                    title: L10n.ReplaceRule.deleteGroupMessage(group), systemImage: "folder.badge.minus",
                    isSelected: false, isDestructive: true
                ) { [weak self] in
                    self?.deleteGroup(group)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        presentOptionSheet(controller)
    }

    private func deleteGroup(_ group: String) {
        let affected = allRules.filter { $0.group == group }
        Task { [weak self] in
            guard let self else { return }
            do {
                for rule in affected {
                    try await self.screen.saveRule(rule.copyWithGroup(nil))
                }
            } catch {
                await MainActor.run { self.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    private func presentOptionSheet(_ controller: AndroidReplicaOptionSheetViewController) {
        present(controller.wrappedInReaderBottomSheet(), animated: true)
    }

    private func displayName(for rule: ReplaceRule) -> String {
        rule.name.isEmpty ? rule.pattern : rule.name
    }
}
