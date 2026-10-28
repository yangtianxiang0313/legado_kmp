import UIKit
import shared

final class AndroidReplicaMyViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Action {
        case open(() -> UIViewController?)
        case themeMode
    }

    private struct Row {
        let title: String
        let summary: String?
        let iconName: String
        let identifier: String
        let action: Action
    }

    private struct Section {
        let title: String?
        let rows: [Row]
    }

    private let titleBar = AndroidReplicaMyTitleBar(title: L10n.Tabs.settings)
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let screen = SettingsScreenAdapter()
    private lazy var sections = makeSections()
    private var headers: [Int: AndroidReplicaSettingsSectionHeader] = [:]
    private var themeMode: ThemeMode?
    private var themeLoadError: String?
    private var themeTask: Task<Void, Never>?
    private weak var themeDialog: ReaderPreferenceChoiceDialogViewController?
    private var isPageVisible = false
    private var interactionGeneration: UInt64 = 0
    private var selectionGeneration: UInt64?
    private var themeValueNeedsRefresh = false

    override var preferredStatusBarStyle: UIStatusBarStyle {
        BookshelfRootView.statusBarStyle(for: traitCollection)
    }

    private var themeChoices: [(String, ThemeMode)] {
        [
            (L10n.Settings.themeModeSystem, .system),
            (Self.androidText("theme_mode_light", "亮色主题"), .light),
            (Self.androidText("theme_mode_dark", "暗色主题"), .dark),
            (NSLocalizedString("settings.theme_mode_e_ink", value: "E-Ink(墨水屏)", comment: "theme_mode[3]"), .eInk),
        ]
    }

    private static func androidText(_ key: String, _ value: String) -> String {
        NSLocalizedString("settings.my_android.\(key)", value: value, comment: "Legado 5f5d314 pref_main.xml")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        bindPreferences()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
        center.addObserver(
            self, selector: #selector(deactivated(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(deactivated(_:)), name: UIScene.willDeactivateNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPageVisible = true
        refreshThemeValueIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isPageVisible = false
        invalidateInteraction()
        super.viewWillDisappear(animated)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        refreshPalette()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            themeValueNeedsRefresh = true
            DispatchQueue.main.async { [weak self] in self?.refreshThemeValueIfNeeded() }
        }
    }

    deinit {
        themeTask?.cancel()
        screen.unbind()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.background
        titleBar.accessibilityIdentifier = UIIdentifiers.Settings.titleBar
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.estimatedSectionHeaderHeight = 50
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
        tableView.tableFooterView = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: CGFloat.leastNormalMagnitude))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = UIIdentifiers.Settings.table
        tableView.register(
            AndroidReplicaMyPreferenceCell.self,
            forCellReuseIdentifier: AndroidReplicaMyPreferenceCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleBar)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }

    private func makeSections() -> [Section] {
        // Preserve pref_main.xml ordering; Web service is foreground-only on iOS.
        [
            Section(
                title: nil,
                rows: [
                    Row(
                        title: L10n.Settings.sourceManagementTitle,
                        summary: Self.androidText("book_source_manage_desc", "新建、导入、编辑或管理书源"),
                        iconName: "MyAndroidSource", identifier: UIIdentifiers.Settings.sourceManagementRow,
                        action: .open { AndroidReplicaSourceManagementViewController() }),
                    Row(
                        title: Self.androidText("txt_toc_rule", "TXT 目录规则"),
                        summary: Self.androidText("config_txt_toc_rule", "配置 TXT 目录规则"),
                        iconName: "MyAndroidSource", identifier: UIIdentifiers.Settings.txtTocRuleRow,
                        action: .open { AndroidReplicaTxtTocRuleViewController().configuredForDrillDownPresentation() }),
                    Row(
                        title: L10n.Settings.replaceRuleTitle,
                        summary: Self.androidText("replace_purify_desc", "配置替换净化规则"),
                        iconName: "MyAndroidReplace", identifier: UIIdentifiers.Settings.replaceRuleRow,
                        action: .open { ReplaceRuleViewController().configuredForDrillDownPresentation() }),
                    Row(
                        title: L10n.Settings.dictRuleTitle, summary: Self.androidText("config_dict_rule", "配置字典规则"),
                        iconName: "MyAndroidTranslate", identifier: UIIdentifiers.Settings.dictRuleRow,
                        action: .open { DictRuleViewController().configuredForDrillDownPresentation() }),
                    Row(
                        title: "Web 服务", summary: "前台服务",
                        iconName: "MyAndroidFolder", identifier: "settings.webService.row",
                        action: .open { ForegroundWebViewController().configuredForDrillDownPresentation() }),
                    Row(
                        title: L10n.Settings.themeModeTitle, summary: L10n.Settings.themeModeRootDetail,
                        iconName: "MyAndroidTheme", identifier: UIIdentifiers.Settings.themeModeRootRow,
                        action: .themeMode),
                ]),
            Section(
                title: L10n.Settings.configTitle,
                rows: [
                    Row(
                        title: Self.androidText("backup_restore", "备份与恢复"),
                        summary: Self.androidText("web_dav_set_import_old", "WebDav 设置/导入旧版本数据"),
                        iconName: "MyAndroidBackup", identifier: UIIdentifiers.Settings.backupRow,
                        action: .open {
                            AndroidReplicaSettingsCategoryViewController(category: .backup)
                                .configuredForDrillDownPresentation()
                        }),
                    Row(
                        title: L10n.Settings.themeSettingRootTitle,
                        summary: Self.androidText("theme_setting_s", "与界面/颜色相关的一些设置"),
                        iconName: "MyAndroidTheme", identifier: UIIdentifiers.Settings.themeSettingRow,
                        action: .open {
                            AndroidReplicaSettingsCategoryViewController(category: .theme)
                                .configuredForDrillDownPresentation()
                        }),
                    Row(
                        title: L10n.Settings.appConfigEntryTitle, summary: L10n.Settings.appConfigEntryDetail,
                        iconName: "MyAndroidOther", identifier: UIIdentifiers.Settings.appConfigRow,
                        action: .open {
                            AndroidReplicaSettingsCategoryViewController(category: .other)
                                .configuredForDrillDownPresentation()
                        }),
                ]),
            Section(
                title: L10n.Settings.otherSectionTitle,
                rows: [
                    Row(
                        title: L10n.Settings.bookmarkTitle, summary: Self.androidText("all_bookmark", "所有书签"),
                        iconName: "MyAndroidBookmark", identifier: UIIdentifiers.Settings.bookmarkRow,
                        action: .open { AllBookmarkViewController().configuredForDrillDownPresentation() }),
                    Row(
                        title: L10n.Settings.readRecordTitle, summary: Self.androidText("read_record_summary", "阅读时间记录"),
                        iconName: "BookshelfAndroidHistory", identifier: UIIdentifiers.Settings.readRecordRow,
                        action: .open { ReadRecordViewController().configuredForDrillDownPresentation() }),
                    Row(
                        title: L10n.Settings.fileManageTitle, summary: "本地文件 / 远程书籍",
                        iconName: "MyAndroidFolder", identifier: UIIdentifiers.Settings.fileManageRow,
                        action: .open { SandboxFilesViewController() }),
                    Row(
                        title: L10n.Settings.aboutTitle, summary: nil,
                        iconName: "MyAndroidAbout", identifier: UIIdentifiers.Settings.aboutRow,
                        action: .open { AboutViewController().configuredForDrillDownPresentation() }),
                ]),
        ]
    }

    private func bindPreferences() {
        screen.onPreferencesChange = { [weak self] preferences in
            guard let self else { return }
            if let previous = self.themeMode, previous != preferences.themeMode {
                self.themeDialog?.dismiss(animated: false)
                self.themeDialog = nil
            }
            self.themeMode = preferences.themeMode
            self.themeValueNeedsRefresh = true
            self.refreshThemeValueIfNeeded()
        }
        if case .failure(let error) = screen.bootstrap() { themeLoadError = error.message }
    }

    private var allowsInteraction: Bool {
        isPageVisible && themeTask == nil && canPerformNavigationAction
            && !tableView.isDragging && !tableView.isDecelerating
    }

    private func isCurrentSession(_ generation: UInt64, scene: UIWindowScene) -> Bool {
        generation == interactionGeneration && isPageVisible && isVisibleInNavigationStack
            && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.isKeyWindow == true
            && viewIfLoaded?.window?.windowScene === scene && scene.activationState == .foregroundActive
            && !isMovingFromParent && !isBeingDismissed
    }

    private func invalidateInteraction() {
        interactionGeneration &+= 1
        selectionGeneration = nil
        themeTask?.cancel()
        themeTask = nil
        themeDialog?.dismiss(animated: false)
        themeDialog = nil
        // Cancel a touch begun before leaving the page/scene without rebuilding the list.
        tableView.isUserInteractionEnabled = false
        tableView.isUserInteractionEnabled = true
        for cell in tableView.visibleCells { cell.setHighlighted(false, animated: false) }
    }

    @objc private func deactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        invalidateInteraction()
    }

    private func showThemeModePicker() {
        guard allowsInteraction, let scene = view.window?.windowScene else { return }
        guard let current = themeMode else {
            showTransientMessage(themeLoadError ?? L10n.Settings.loading)
            return
        }
        let generation = interactionGeneration
        let choices = themeChoices
        let dialog = ReaderPreferenceChoiceDialogViewController(
            title: L10n.Settings.themeModePicker, items: choices.map(\.0),
            selectedIndex: choices.firstIndex { $0.1 == current } ?? -1,
            identifier: "settings.theme.mode"
        ) { [weak self, weak scene] index in
            guard let self, let scene, self.isCurrentSession(generation, scene: scene),
                self.allowsInteraction, self.themeMode == current, choices.indices.contains(index)
            else { return }
            self.themeDialog = nil
            self.setThemeMode(choices[index].1, generation: generation, scene: scene)
        }
        dialog.canSelect = { [weak self, weak scene] in
            guard let self, let scene else { return false }
            return self.isCurrentSession(generation, scene: scene) && self.themeMode == current
        }
        selectionGeneration = nil
        themeDialog = dialog
        present(dialog, animated: true)
    }

    private func setThemeMode(_ mode: ThemeMode, generation: UInt64, scene: UIWindowScene) {
        guard mode != themeMode else { return }
        themeTask = Task { @MainActor [weak self, weak scene] in
            guard let self, let scene else { return }
            defer {
                if self.interactionGeneration == generation { self.themeTask = nil }
            }
            do {
                try Task.checkCancellation()
                guard self.isCurrentSession(generation, scene: scene), self.canPerformNavigationAction else { return }
                try await self.screen.setThemeMode(mode: mode)
            } catch {
                guard !(error is CancellationError), self.isCurrentSession(generation, scene: scene),
                    self.canPerformNavigationAction
                else { return }
                self.presentError(error)
            }
        }
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        view.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        titleBar.applyPalette()
        for header in headers.values { header.applyPalette() }
        for case let cell as AndroidReplicaMyPreferenceCell in tableView.visibleCells { cell.applyPalette() }
        setNeedsStatusBarAppearanceUpdate()
        parent?.setNeedsStatusBarAppearanceUpdate()
    }

    private func refreshThemeValueIfNeeded() {
        guard themeValueNeedsRefresh, isPageVisible, !tableView.isTracking,
            !tableView.isDragging, !tableView.isDecelerating,
            !tableView.visibleCells.contains(where: \.isHighlighted)
        else { return }
        themeValueNeedsRefresh = false
        let anchor = tableView.indexPathsForVisibleRows?.min()
        let distance = anchor.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        for case let cell as AndroidReplicaMyPreferenceCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell),
                case .themeMode = sections[indexPath.section].rows[indexPath.row].action
            else { continue }
            cell.setValue(themeChoices.first { $0.1 == themeMode }?.0)
        }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
            tableView.layoutIfNeeded()
            if let anchor, let distance {
                let minimum = -tableView.adjustedContentInset.top
                let maximum = max(
                    minimum,
                    tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom)
                let offset = min(maximum, max(minimum, tableView.rectForRow(at: anchor).minY - distance))
                tableView.setContentOffset(CGPoint(x: tableView.contentOffset.x, y: offset), animated: false)
            }
        }
    }

    func numberOfSections(in _: UITableView) -> Int { sections.count }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title == nil ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat { .leastNormalMagnitude }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = sections[section].title else { return nil }
        if let header = headers[section] { return header }
        let header = AndroidReplicaSettingsSectionHeader(title: title)
        headers[section] = header
        return header
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: AndroidReplicaMyPreferenceCell.reuseIdentifier, for: indexPath)
            as! AndroidReplicaMyPreferenceCell
        let value: String?
        if case .themeMode = row.action { value = themeChoices.first { $0.1 == themeMode }?.0 } else { value = nil }
        cell.configure(title: row.title, summary: row.summary, iconName: row.iconName, value: value)
        cell.accessibilityIdentifier = row.identifier
        return cell
    }

    func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        guard allowsInteraction else { return false }
        selectionGeneration = interactionGeneration
        return true
    }

    func tableView(_: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard allowsInteraction else { return nil }
        if selectionGeneration == nil { selectionGeneration = interactionGeneration }
        return selectionGeneration == interactionGeneration ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        defer { selectionGeneration = nil }
        guard allowsInteraction, selectionGeneration == interactionGeneration,
            sections.indices.contains(indexPath.section),
            sections[indexPath.section].rows.indices.contains(indexPath.row)
        else { return }
        switch sections[indexPath.section].rows[indexPath.row].action {
        case .themeMode:
            showThemeModePicker()
        case .open(let destination):
            guard let controller = destination(), allowsInteraction else { return }
            invalidateInteraction()
            navigationController?.pushViewController(controller, animated: true)
        }
    }

    func tableView(_: UITableView, didUnhighlightRowAt _: IndexPath) {
        DispatchQueue.main.async { [weak self] in self?.refreshThemeValueIfNeeded() }
    }

    func scrollViewWillBeginDragging(_: UIScrollView) { selectionGeneration = nil }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { refreshThemeValueIfNeeded() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { refreshThemeValueIfNeeded() }
}

// Keep this page's typography scoped here rather than changing every shared settings surface.
private final class AndroidReplicaMyTitleBar: NavigationToolbarView {
    private let label = ReaderTocSingleLineLabel()

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .header
        label.text = title
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = false
        label.isAccessibilityElement = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let preferredHeight = heightAnchor.constraint(equalToConstant: 56)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            preferredHeight,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
        updateTypography()
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyPalette() {
        label.textColor = AndroidReplicaTheme.toolbarText
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateTypography()
        }
        applyPalette()
    }

    private func updateTypography() {
        // ToolbarTitle -> TextAppearance.Material.Widget.ActionBar.Title: 20sp sans-serif-medium.
        label.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
    }
}
