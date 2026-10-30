import Kingfisher
import shared
import SnapKit
import StoreKit
import UIKit
import UniformTypeIdentifiers
final class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let screen = SettingsScreenAdapter()
    private lazy var backupCoordinator = SettingsBackupCoordinator(
        owner: self, screen: screen,
        onError: { [weak self] error in self?.presentError(error) },
        onRestored: { [weak self] in self?.tableView.reloadData() }
    )
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let category: SettingsCategory
    private var preferences: AppUiPreferences?
    private var runtimeConfig: AppRuntimeConfig?
    fileprivate init(category: SettingsCategory = .other) {
        self.category = category
        super.init(nibName: nil, bundle: nil)
    }
    static func makeThemeConfig() -> SettingsViewController {
        SettingsViewController(category: .theme)
    }
    static func makeOtherConfig() -> SettingsViewController {
        SettingsViewController(category: .other)
    }
    static func makeBackupConfig() -> SettingsViewController {
        SettingsViewController(category: .backup)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = category.title
        scaffoldView.titleBarView.setTitle(category.title)
        scaffoldView.titleBarView.accessibilityIdentifier = UIIdentifiers.Settings.titleBar
        let backButton = makeLegacyBarButton(
            imageSystemName: "chevron.left",
            target: self,
            action: #selector(handleBackTapped)
        )
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        scaffoldView.titleBarView.setLeftViews([backButton])
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        tableView.accessibilityIdentifier = UIIdentifiers.Settings.table
        tableView.dataSource = self
        tableView.delegate = self
        scaffoldView.contentView.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        scaffoldView.contentView.addSubview(stateView)
        stateView.setTestingIdentifier(UIIdentifiers.Settings.state)
        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        bootstrapDependencies()
    }

    deinit {
        screen.unbind()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    func numberOfSections(in _: UITableView) -> Int {
        category.sections.count
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        category.sections[section].rows.count
    }

    func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        category.sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "cell"
        let style: UITableViewCell.CellStyle = category == .backup ? .subtitle : .value1
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: style, reuseIdentifier: identifier)
        let row = category.sections[indexPath.section].rows[indexPath.row]
        let preferences = preferences
        let runtimeConfig = runtimeConfig
        cell.accessoryType = .disclosureIndicator
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = category == .backup ? 2 : 1

        switch row {
        case .readerAppearance:
            cell.textLabel?.text = L10n.Settings.readerAppearanceTitle
            cell.detailTextLabel?.text = preferences?.readerPresetName ?? L10n.Settings.readerPresetFallback
            cell.accessibilityIdentifier = UIIdentifiers.Settings.readerAppearanceRow
        case .themePreset:
            cell.textLabel?.text = L10n.Settings.themePresetTitle
            cell.detailTextLabel?.text = preferences?.themePresetName ?? L10n.Settings.themePresetFallback
            cell.accessibilityIdentifier = UIIdentifiers.Settings.themePresetRow
        case .themeMode:
            cell.textLabel?.text = L10n.Settings.themeModeTitle
            cell.detailTextLabel?.text = themeModeText(preferences?.themeMode)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.themeModeRow
        case .bookshelfLayout:
            cell.textLabel?.text = L10n.Settings.bookshelfLayoutTitle
            cell.detailTextLabel?.text = bookshelfLayoutText(preferences?.bookshelfLayoutMode)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.bookshelfLayoutRow
        case .precisionSearch:
            cell.textLabel?.text = L10n.Settings.precisionSearchTitle
            cell.detailTextLabel?.text = runtimeConfig?.precisionSearch == true ? L10n.Settings.precisionSearchOn : L10n.Settings.precisionSearchOff
            cell.accessibilityIdentifier = UIIdentifiers.Settings.precisionSearchRow
        case .threadCount:
            cell.textLabel?.text = L10n.Settings.threadCountTitle
            cell.detailTextLabel?.text = "\(runtimeConfig?.threadCount ?? 16)"
            cell.accessibilityIdentifier = UIIdentifiers.Settings.threadCountRow
        case .replaceRuleEnabledByDefault:
            cell.textLabel?.text = L10n.Settings.replaceRuleTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.replaceRuleEnabledByDefault ?? true)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.replaceRuleDefaultRow
        case .keepScreenOn:
            cell.textLabel?.text = L10n.Settings.keepScreenOnTitle
            cell.detailTextLabel?.text = boolText(RestoredAppPreferences.keepScreenOn)
            cell.accessoryType = .none
        case .showDiscovery:
            cell.textLabel?.text = L10n.Settings.showDiscoveryTitle
            cell.detailTextLabel?.text = boolText(UserDefaults.standard.object(forKey: "showDiscovery") as? Bool ?? true)
            cell.accessoryType = .none
        case .showRss:
            cell.textLabel?.text = L10n.Settings.showRssTitle
            cell.detailTextLabel?.text = boolText(UserDefaults.standard.object(forKey: "showRss") as? Bool ?? true)
            cell.accessoryType = .none
        case .defaultHome:
            cell.textLabel?.text = L10n.Settings.defaultHomeTitle
            cell.detailTextLabel?.text = defaultHomeText()
            cell.accessoryType = .disclosureIndicator
        case .clearCache:
            cell.textLabel?.text = L10n.Settings.clearCacheTitle
            cell.detailTextLabel?.text = L10n.Settings.clearCacheDetail
            cell.accessoryType = .none
        case .backupPath:
            cell.textLabel?.text = L10n.Settings.backupPathTitle
            cell.detailTextLabel?.text = runtimeConfig?.backupPath ?? L10n.Settings.notImplementedValue
            cell.accessibilityIdentifier = UIIdentifiers.Settings.backupPathRow
        case .backupCapabilities:
            cell.textLabel?.text = "订阅与服务"
            cell.detailTextLabel?.text = "源订阅、服务器、朗读引擎与键盘辅助"
        case .backupNow:
            cell.textLabel?.text = L10n.Settings.backupNowTitle
            cell.detailTextLabel?.text = L10n.Settings.backupNowDetail
            cell.accessibilityIdentifier = UIIdentifiers.Settings.backupNowRow
        case .restoreNow:
            cell.textLabel?.text = L10n.Settings.restoreNowTitle
            cell.detailTextLabel?.text = L10n.Settings.restoreNowDetail
            cell.accessibilityIdentifier = UIIdentifiers.Settings.restoreNowRow
        case .webDav:
            cell.textLabel?.text = L10n.Settings.webDavTitle
            cell.detailTextLabel?.text = L10n.Settings.webDavCheckDetail
            cell.accessibilityIdentifier = UIIdentifiers.Settings.webDavRow
        case .webDavUrl:
            cell.textLabel?.text = L10n.Settings.webDavUrlTitle
            cell.detailTextLabel?.text = runtimeConfig?.webDavUrl ?? L10n.Settings.webDavUrlPlaceholder
            cell.accessibilityIdentifier = UIIdentifiers.Settings.webDavUrlRow
        case .webDavAccount:
            cell.textLabel?.text = L10n.Settings.webDavAccountTitle
            cell.detailTextLabel?.text = runtimeConfig?.webDavAccount ?? L10n.Settings.webDavAccountPlaceholder
            cell.accessibilityIdentifier = UIIdentifiers.Settings.webDavAccountRow
        case .webDavPassword:
            cell.textLabel?.text = L10n.Settings.webDavPasswordTitle
            cell.detailTextLabel?.text = runtimeConfig?.webDavPassword != nil ? L10n.Settings.webDavPasswordMask : L10n.Settings.webDavPasswordPlaceholder
            cell.accessibilityIdentifier = UIIdentifiers.Settings.webDavPasswordRow
        case .webDavDir:
            cell.textLabel?.text = L10n.Settings.webDavDirTitle
            cell.detailTextLabel?.text = runtimeConfig?.webDavDir ?? "legado"
            cell.accessibilityIdentifier = UIIdentifiers.Settings.webDavDirRow
        case .webDavDeviceName:
            cell.textLabel?.text = L10n.Settings.webDavDeviceNameTitle
            cell.detailTextLabel?.text = runtimeConfig?.webDavDeviceName ?? L10n.Settings.notImplementedValue
            cell.accessibilityIdentifier = UIIdentifiers.Settings.webDavDeviceNameRow
        case .syncBookProgress:
            cell.textLabel?.text = L10n.Settings.syncBookProgressTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.syncBookProgress ?? true)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.syncBookProgressRow
        case .syncBookProgressPlus:
            cell.textLabel?.text = L10n.Settings.syncBookProgressPlusTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.syncBookProgressPlus ?? false)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.syncBookProgressPlusRow
        case .restoreIgnore:
            cell.textLabel?.text = L10n.Settings.restoreIgnoreTitle
            cell.detailTextLabel?.text = backupIgnoreSummary(runtimeConfig?.backupRestoreIgnoredKeys)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.restoreIgnoreRow
        case .onlyLatestBackup:
            cell.textLabel?.text = L10n.Settings.onlyLatestBackupTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.onlyLatestBackup ?? true)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.onlyLatestBackupRow
        case .autoCheckNewBackup:
            cell.textLabel?.text = L10n.Settings.autoCheckNewBackupTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.autoCheckNewBackup ?? true)
            cell.accessibilityIdentifier = UIIdentifiers.Settings.autoCheckNewBackupRow
        // F67: 隐藏状态栏
        case .hideStatusBar:
            cell.textLabel?.text = L10n.Settings.hideStatusBarTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.reader.hideStatusBar ?? false)
            cell.accessoryType = .none
        // F68: 隐藏导航栏
        case .hideNavigationBar:
            cell.textLabel?.text = L10n.Settings.hideNavigationBarTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.reader.hideNavigationBar ?? false)
            cell.accessoryType = .none
        // F74: 两端对齐
        case .textFullJustify:
            cell.textLabel?.text = L10n.Settings.textFullJustifyTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.reader.textFullJustify ?? true)
            cell.accessoryType = .none
        // F75: 底部对齐
        case .textBottomJustify:
            cell.textLabel?.text = L10n.Settings.textBottomJustifyTitle
            cell.detailTextLabel?.text = boolText(runtimeConfig?.reader.textBottomJustify ?? true)
            cell.accessoryType = .none
        // F103: 启动自动刷新
        case .autoRefreshOnStart:
            cell.textLabel?.text = L10n.Settings.autoRefreshOnStartTitle
            cell.detailTextLabel?.text = boolText(UserDefaults.standard.object(forKey: "autoRefreshOnStart") as? Bool ?? false)
            cell.accessoryType = .none
        // F109: 自定义 User-Agent
        case .userAgent:
            cell.textLabel?.text = L10n.Settings.userAgentTitle
            let ua = runtimeConfig?.userAgent
            cell.detailTextLabel?.text = ua?.isEmpty == false ? ua : L10n.Settings.userAgentPlaceholder
            cell.accessoryType = .disclosureIndicator
        // F81: 自动换源
        case .autoChangeSource:
            cell.textLabel?.text = L10n.Settings.autoChangeSourceTitle
            cell.detailTextLabel?.text = boolText(ReaderAutoChangeSourcePreference.isEnabled())
            cell.accessoryType = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let row = category.sections[indexPath.section].rows[indexPath.row]
        switch row {
        case .readerAppearance:
            let controller = AndroidReaderStyleSheetViewController().configuredForDrillDownPresentation()
            navigationController?.pushViewController(controller, animated: true)
        case .themePreset:
            showThemePresetPicker()
        case .themeMode:
            showThemeModePicker()
        case .bookshelfLayout:
            showBookshelfLayoutPicker()
        case .precisionSearch:
            togglePrecisionSearch()
        case .threadCount:
            showThreadCountPicker()
        case .replaceRuleEnabledByDefault:
            toggleReplaceRuleEnabledByDefault()
        case .keepScreenOn:
            RestoredAppPreferences.setKeepScreenOn(!RestoredAppPreferences.keepScreenOn)
            tableView.reloadData()
        case .showDiscovery:
            toggleUserDefault(key: "showDiscovery", defaultValue: true)
        case .showRss:
            toggleUserDefault(key: "showRss", defaultValue: true)
        case .defaultHome:
            showDefaultHomePicker()
        case .clearCache:
            clearCache()
        case .backupPath:
            showTextValueEditor(
                title: L10n.Settings.backupPathTitle,
                value: runtimeConfig?.backupPath,
                placeholder: "content://backup/Legado"
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setBackupPath(path: value)
            }
        case .backupCapabilities:
            navigationController?.pushViewController(BackupCapabilitiesViewController(style: .insetGrouped), animated: true)
        case .backupNow:
            backupCoordinator.executeBackup()
        case .restoreNow:
            backupCoordinator.showRestoreFilePicker()
        case .webDav:
            backupCoordinator.checkWebDavConnection()
        case .webDavUrl:
            showTextValueEditor(
                title: L10n.Settings.webDavUrlTitle,
                value: runtimeConfig?.webDavUrl,
                placeholder: L10n.Settings.webDavUrlPlaceholder
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setWebDavUrl(url: value)
            }
        case .webDavAccount:
            showTextValueEditor(
                title: L10n.Settings.webDavAccountTitle,
                value: runtimeConfig?.webDavAccount,
                placeholder: L10n.Settings.webDavAccountPlaceholder
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setWebDavAccount(account: value)
            }
        case .webDavPassword:
            showSecureTextValueEditor(
                title: L10n.Settings.webDavPasswordTitle,
                value: runtimeConfig?.webDavPassword,
                placeholder: L10n.Settings.webDavPasswordPlaceholder
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setWebDavPassword(password: value)
            }
        case .webDavDir:
            showTextValueEditor(
                title: L10n.Settings.webDavDirTitle,
                value: runtimeConfig?.webDavDir,
                placeholder: "legado"
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setWebDavDir(dir: value ?? "legado")
            }
        case .webDavDeviceName:
            showTextValueEditor(
                title: L10n.Settings.webDavDeviceNameTitle,
                value: runtimeConfig?.webDavDeviceName,
                placeholder: UIDevice.current.name
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setWebDavDeviceName(name: value)
            }
        case .syncBookProgress:
            toggleSyncBookProgress()
        case .syncBookProgressPlus:
            toggleSyncBookProgressPlus()
        case .restoreIgnore:
            showBackupIgnorePicker()
        case .onlyLatestBackup:
            toggleOnlyLatestBackup()
        case .autoCheckNewBackup:
            toggleAutoCheckNewBackup()
        // F67: 隐藏状态栏切换
        case .hideStatusBar:
            toggleHideStatusBar()
        // F68: 隐藏导航栏切换
        case .hideNavigationBar:
            toggleHideNavigationBar()
        // F74: 两端对齐切换
        case .textFullJustify:
            toggleTextFullJustify()
        // F75: 底部对齐切换
        case .textBottomJustify:
            toggleTextBottomJustify()
        // F103: 启动自动刷新切换
        case .autoRefreshOnStart:
            toggleUserDefault(key: "autoRefreshOnStart", defaultValue: false)
        // F109: 自定义 User-Agent 编辑
        case .userAgent:
            showTextValueEditor(
                title: L10n.Settings.userAgentTitle,
                value: runtimeConfig?.userAgent,
                placeholder: L10n.Settings.userAgentPlaceholder
            ) { [weak self] value in
                guard let self else { return }
                try await self.screen.setUserAgent(ua: value ?? "")
            }
        // F81: 自动换源切换
        case .autoChangeSource:
            ReaderAutoChangeSourcePreference.setEnabled(!ReaderAutoChangeSourcePreference.isEnabled())
            tableView.reloadData()
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }

    private func bootstrapDependencies() {
        stateView.showLoading(message: L10n.Settings.loading)
        screen.onPreferencesChange = { [weak self] preferences in
            guard let self else { return }
            self.preferences = preferences
            self.stateView.hide()
            self.tableView.reloadData()
        }
        screen.onRuntimeConfigChange = { [weak self] runtimeConfig in
            guard let self else { return }
            self.runtimeConfig = runtimeConfig
            self.stateView.hide()
            self.tableView.reloadData()
        }

        switch screen.bootstrap() {
        case .success:
            Task { [weak self] in
                do {
                    guard let self else { return }
                    try await self.screen.bootstrapDefaultsIfNeeded()
                    await MainActor.run {
                        self.stateView.hide()
                    }
                } catch {
                    await MainActor.run {
                        self?.stateView.showMessage(
                            title: L10n.Settings.failed,
                            message: error.userFacingMessage,
                            actionTitle: L10n.Common.retry
                        ) { [weak self] in
                            self?.bootstrapDependencies()
                        }
                    }
                }
            }
        case let .failure(error):
            stateView.showMessage(
                title: L10n.Settings.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    private func showThemePresetPicker() {
        let alert = UIAlertController(title: L10n.Settings.themePresetPicker, message: nil, preferredStyle: .actionSheet)
        for preset in screen.themePresets {
            alert.addAction(UIAlertAction(title: preset.themeName, style: .default) { [weak self] _ in
                self?.runSettingTask {
                    guard let self else { return }
                    try await self.screen.setThemePreset(themeName: preset.themeName)
                }
            })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func showThemeModePicker() {
        let alert = UIAlertController(title: L10n.Settings.themeModePicker, message: nil, preferredStyle: .actionSheet)
        let modes: [(String, ThemeMode)] = [
            (L10n.Settings.themeModeSystem, .system),
            (L10n.Settings.themeModeLight, .light),
            (L10n.Settings.themeModeDark, .dark),
        ]
        for item in modes {
            alert.addAction(UIAlertAction(title: item.0, style: .default) { [weak self] _ in
                self?.runSettingTask {
                    guard let self else { return }
                    try await self.screen.setThemeMode(mode: item.1)
                }
            })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func showBookshelfLayoutPicker() {
        let alert = UIAlertController(title: L10n.Settings.bookshelfLayoutPicker, message: nil, preferredStyle: .actionSheet)
        let layouts: [(String, BookshelfLayoutMode)] = [
            (L10n.Settings.layoutList, .list),
            (L10n.Settings.layoutGrid3, .grid3),
            (L10n.Settings.layoutGrid4, .grid4),
            (L10n.Settings.layoutGrid5, .grid5),
            (L10n.Settings.layoutGrid6, .grid6),
        ]
        for item in layouts {
            alert.addAction(UIAlertAction(title: item.0, style: .default) { [weak self] _ in
                self?.runSettingTask {
                    guard let self else { return }
                    try await self.screen.setBookshelfLayoutMode(mode: item.1)
                }
            })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func togglePrecisionSearch() {
        let enabled = !(runtimeConfig?.precisionSearch == true)
        runSettingTask {
            try await self.screen.setPrecisionSearch(enabled: enabled)
        }
    }

    private func showThreadCountPicker() {
        let alert = UIAlertController(title: L10n.Settings.threadCountPicker, message: nil, preferredStyle: .actionSheet)
        for count in [4, 8, 16, 24, 32] {
            alert.addAction(UIAlertAction(title: "\(count)", style: .default) { [weak self] _ in
                self?.runSettingTask {
                    guard let self else { return }
                    try await self.screen.setThreadCount(count: count)
                }
            })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func toggleReplaceRuleEnabledByDefault() {
        let enabled = !(runtimeConfig?.replaceRuleEnabledByDefault == true)
        runSettingTask {
            try await self.screen.setReplaceRuleEnabledByDefault(enabled: enabled)
        }
    }

    private func toggleSyncBookProgress() {
        let enabled = !(runtimeConfig?.syncBookProgress == true)
        runSettingTask {
            try await self.screen.setSyncBookProgress(enabled: enabled)
        }
    }

    private func toggleSyncBookProgressPlus() {
        let enabled = !(runtimeConfig?.syncBookProgressPlus == true)
        runSettingTask {
            try await self.screen.setSyncBookProgressPlus(enabled: enabled)
        }
    }

    private func toggleOnlyLatestBackup() {
        let enabled = !(runtimeConfig?.onlyLatestBackup == true)
        runSettingTask {
            try await self.screen.setOnlyLatestBackup(enabled: enabled)
        }
    }

    private func toggleAutoCheckNewBackup() {
        let enabled = !(runtimeConfig?.autoCheckNewBackup == true)
        runSettingTask {
            try await self.screen.setAutoCheckNewBackup(enabled: enabled)
        }
    }

    // F67: 隐藏状态栏切换
    private func toggleHideStatusBar() {
        let enabled = !(runtimeConfig?.reader.hideStatusBar ?? false)
        runSettingTask {
            try await self.screen.setHideStatusBar(enabled: enabled)
        }
    }

    // F68: 隐藏导航栏切换
    private func toggleHideNavigationBar() {
        let enabled = !(runtimeConfig?.reader.hideNavigationBar ?? false)
        runSettingTask {
            try await self.screen.setHideNavigationBar(enabled: enabled)
        }
    }

    // F74: 两端对齐切换
    private func toggleTextFullJustify() {
        let enabled = !(runtimeConfig?.reader.textFullJustify ?? true)
        runSettingTask {
            try await self.screen.setTextFullJustify(enabled: enabled)
        }
    }

    // F75: 底部对齐切换
    private func toggleTextBottomJustify() {
        let enabled = !(runtimeConfig?.reader.textBottomJustify ?? true)
        runSettingTask {
            try await self.screen.setTextBottomJustify(enabled: enabled)
        }
    }

    private func showTextValueEditor(
        title: String,
        value: String?,
        placeholder: String,
        save: @escaping (String?) async throws -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = value
            textField.placeholder = placeholder
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.save, style: .default) { [weak self, weak alert] _ in
            let rawValue = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = rawValue?.isEmpty == true ? nil : rawValue
            self?.runSettingTask {
                try await save(normalized)
            }
        })
        present(alert, animated: true)
    }

    private func showSecureTextValueEditor(
        title: String,
        value: String?,
        placeholder: String,
        save: @escaping (String?) async throws -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { textField in
            textField.text = value
            textField.placeholder = placeholder
            textField.isSecureTextEntry = true
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.Common.save, style: .default) { [weak self, weak alert] _ in
            let rawValue = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = rawValue?.isEmpty == true ? nil : rawValue
            self?.runSettingTask {
                try await save(normalized)
            }
        })
        present(alert, animated: true)
    }

    private func showBackupIgnorePicker() {
        let alert = UIAlertController(
            title: L10n.Settings.restoreIgnoreTitle,
            message: L10n.Settings.backupIgnoreDialog,
            preferredStyle: .actionSheet
        )
        let selected = backupIgnoreKeySet()
        for option in backupIgnoreOptions {
            let suffix = selected.contains(option.key) ? " ✓" : ""
            alert.addAction(UIAlertAction(title: "\(option.title)\(suffix)", style: .default) { [weak self] _ in
                self?.updateBackupIgnoreSet(toggling: option.key)
            })
        }
        alert.addAction(UIAlertAction(title: L10n.Settings.backupIgnoreNone, style: .destructive) { [weak self] _ in
            self?.runSettingTask { [weak self] in
                guard let self else { return }
                try await self.screen.setBackupRestoreIgnoredKeys(keys: [])
            }
        })
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds
        }
        present(alert, animated: true)
    }

    private func updateBackupIgnoreSet(toggling key: String) {
        var keys = backupIgnoreKeySet()
        if keys.contains(key) {
            keys.remove(key)
        } else {
            keys.insert(key)
        }
        runSettingTask {
            try await self.screen.setBackupRestoreIgnoredKeys(keys: Array(keys).sorted())
        }
    }

    private func runSettingTask(_ operation: @escaping () async throws -> Void) {
        Task { [weak self] in
            do {
                try await operation()
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    private func toggleUserDefault(key: String, defaultValue: Bool) {
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
        RestoredAppPreferences.set(!current, forKey: key)
        tableView.reloadData()
    }

    private func defaultHomeText() -> String {
        switch UserDefaults.standard.integer(forKey: "defaultHomePage") {
        case 1: return L10n.Tabs.discovery
        case 2: return L10n.Tabs.rss
        case 3: return L10n.Tabs.settings
        default: return L10n.Tabs.bookshelf
        }
    }

    private func showDefaultHomePicker() {
        let alert = UIAlertController(title: L10n.Settings.defaultHomePicker, message: nil, preferredStyle: .actionSheet)
        let options: [(String, Int)] = [
            (L10n.Tabs.bookshelf, 0),
            (L10n.Tabs.discovery, 1),
            (L10n.Tabs.rss, 2),
            (L10n.Tabs.settings, 3),
        ]
        for option in options {
            alert.addAction(UIAlertAction(title: option.0, style: .default) { [weak self] _ in
                RestoredAppPreferences.set(option.1, forKey: "defaultHomePage")
                self?.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        present(alert, animated: true)
    }

    private func clearCache() {
        KingfisherManager.shared.cache.clearMemoryCache()
        KingfisherManager.shared.cache.clearDiskCache { [weak self] in
            DispatchQueue.global(qos: .utility).async { [weak self] in
                URLCache.shared.removeAllCachedResponses()
                MediaAudioDiskCache.shared.removeAll()
                DispatchQueue.main.async {
                    let alert = UIAlertController(title: L10n.Settings.clearCacheSuccess, message: nil, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                    self?.present(alert, animated: true)
                }
            }
        }
    }

    private func presentSimpleAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .default))
        present(alert, animated: true)
    }

    private func themeModeText(_ mode: ThemeMode?) -> String {
        switch mode {
        case ThemeMode.light:
            return L10n.Settings.themeModeLight
        case ThemeMode.dark:
            return L10n.Settings.themeModeDark
        default:
            return L10n.Settings.themeModeSystem
        }
    }

    private func bookshelfLayoutText(_ mode: BookshelfLayoutMode?) -> String {
        switch mode {
        case BookshelfLayoutMode.list: return L10n.Settings.layoutList
        case BookshelfLayoutMode.grid3: return L10n.Settings.layoutGrid3
        case BookshelfLayoutMode.grid4: return L10n.Settings.layoutGrid4
        case BookshelfLayoutMode.grid5: return L10n.Settings.layoutGrid5
        case BookshelfLayoutMode.grid6: return L10n.Settings.layoutGrid6
        default: return L10n.Settings.layoutGrid3
        }
    }

    private func boolText(_ value: Bool) -> String {
        value ? L10n.Settings.enabled : L10n.Settings.disabled
    }

    private func backupIgnoreSummary(_ keys: Any?) -> String {
        let keyStrings = backupIgnoreKeySet(from: keys)
        guard keyStrings.isEmpty == false else {
            return L10n.Settings.backupIgnoreNone
        }
        return backupIgnoreOptions
            .filter { keyStrings.contains($0.key) }
            .map(\.title)
            .joined(separator: "、")
    }

    private func backupIgnoreKeySet() -> Set<String> {
        backupIgnoreKeySet(from: runtimeConfig?.backupRestoreIgnoredKeys)
    }

    private func backupIgnoreKeySet(from keys: Any?) -> Set<String> {
        if let values = keys as? Set<String> {
            return values
        }
        if let values = keys as? Set<AnyHashable> {
            return Set(values.compactMap { $0 as? String })
        }
        if let values = keys as? [String] {
            return Set(values)
        }
        return []
    }

    private var backupIgnoreOptions: [(key: String, title: String)] {
        [
            ("readConfig", L10n.Settings.readerAppearanceTitle),
            ("themeMode", L10n.Settings.themeModeTitle),
            ("themeConfig", L10n.Settings.themeSettingRootTitle),
            ("coverConfig", L10n.Settings.themePresetTitle),
            ("bookshelfLayout", L10n.Settings.bookshelfLayoutTitle),
            ("showRss", "RSS"),
            ("threadCount", L10n.Settings.threadCountTitle),
            ("localBook", L10n.Settings.fileManageTitle),
        ]
    }

    @objc private func handleBackTapped() {
        navigationController?.popViewController(animated: true)
    }
}
