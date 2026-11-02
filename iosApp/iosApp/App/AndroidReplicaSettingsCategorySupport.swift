import UIKit
import shared

@MainActor
enum AndroidReplicaSettingsListRefresh {
    static func preservingScrollAnchor(in tableView: UITableView, updates: () -> Void) {
        let anchor = tableView.indexPathsForVisibleRows?.min()
        let distance = anchor.map { tableView.rectForRow(at: $0).minY - tableView.contentOffset.y }
        UIView.performWithoutAnimation {
            updates()
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
}

/// Row copy/state mapping is separate from the category controller's lifecycle and writes.
@MainActor
struct AndroidReplicaSettingsRowPresentation {
    typealias Row = AndroidReplicaSettingsCategoryViewController.Row

    let preferences: AppUiPreferences?
    let runtimeConfig: AppRuntimeConfig?

    func title(for row: Row) -> String {
        switch row {
        case .readerAppearance: return L10n.Settings.readerAppearanceTitle
        case .themePreset:
            return NSLocalizedString("settings.theme_list_title", value: "主题列表", comment: "Legado theme_list")
        case .themeBackground:
            return NSLocalizedString("settings.theme_background_title", value: "背景图片", comment: "Legado background_image")
        case .coverConfiguration:
            return NSLocalizedString("settings.cover_config_title", value: "封面配置", comment: "Legado cover_config")
        case .appLock: return L10n.Settings.appLockTitle
        case .automaticBackup:
            return NSLocalizedString("settings.automatic_backup_title", value: "自动备份", comment: "Automatic backup settings")
        case .themeMode: return L10n.Settings.themeModeTitle
        case .themeColor(let field, _): return field.title
        case .saveTheme:
            return NSLocalizedString("settings.save_theme_config_title", value: "保存主题配置", comment: "Legado save_theme_config")
        case .bookshelfLayout: return L10n.Settings.bookshelfLayoutTitle
        case .precisionSearch: return L10n.Settings.precisionSearchTitle
        case .threadCount: return L10n.Settings.threadCountTitle
        case .preDownloadNum: return AndroidReplicaPreDownloadPreference.title
        case .sourceCheck:
            return NSLocalizedString("settings.source_check_title", value: "校验设置", comment: "Legado check_source_config")
        case .replaceRuleEnabledByDefault: return L10n.Settings.replaceRuleTitle
        case .keepScreenOn: return L10n.Settings.keepScreenOnTitle
        case .showDiscovery: return L10n.Settings.showDiscoveryTitle
        case .showRss: return L10n.Settings.showRssTitle
        case .defaultHome: return L10n.Settings.defaultHomeTitle
        case .defaultToRead: return L10n.StartupReading.title
        case .clearCache: return L10n.Settings.clearCacheTitle
        case .backupPath: return L10n.Settings.backupPathTitle
        case .backupCapabilities:
            return NSLocalizedString("settings.backup_capabilities_title", value: "订阅与服务", comment: "Subscriptions and services settings")
        case .backupNow: return L10n.Settings.backupNowTitle
        case .restoreNow: return L10n.Settings.restoreNowTitle
        case .webDavUrl: return L10n.Settings.webDavUrlTitle
        case .webDavAccount: return L10n.Settings.webDavAccountTitle
        case .webDavPassword: return L10n.Settings.webDavPasswordTitle
        case .webDavDir: return L10n.Settings.webDavDirTitle
        case .webDavDeviceName: return L10n.Settings.webDavDeviceNameTitle
        case .syncBookProgress: return L10n.Settings.syncBookProgressTitle
        case .syncBookProgressPlus: return L10n.Settings.syncBookProgressPlusTitle
        case .restoreIgnore: return L10n.Settings.restoreIgnoreTitle
        case .onlyLatestBackup: return L10n.Settings.onlyLatestBackupTitle
        case .autoCheckNewBackup: return L10n.Settings.autoCheckNewBackupTitle
        case .hideStatusBar: return L10n.Settings.hideStatusBarTitle
        case .hideNavigationBar: return L10n.Settings.hideNavigationBarTitle
        case .textFullJustify: return L10n.Settings.textFullJustifyTitle
        case .textBottomJustify: return L10n.Settings.textBottomJustifyTitle
        case .autoRefreshOnStart: return L10n.Settings.autoRefreshOnStartTitle
        case .userAgent: return L10n.Settings.userAgentTitle
        case .autoChangeSource: return L10n.Settings.autoChangeSourceTitle
        case .showAddToShelfAlert:
            return NSLocalizedString(
                "settings.show_add_to_shelf_alert_title", value: "返回时提示放入书架", comment: "Legado show_add_to_shelf_alert_title")
        }
    }

    func detail(for row: Row) -> String? {
        switch row {
        case .readerAppearance:
            return preferences?.readerPresetName ?? L10n.Settings.readerPresetFallback
        case .themePreset:
            return NSLocalizedString(
                "settings.theme_list_detail", value: "使用、保存、导入或分享主题", comment: "Theme list actions")
        case .themeBackground(let night):
            return night
                ? NSLocalizedString("settings.theme_background_night_detail", value: "夜间背景", comment: "Night background summary")
                : NSLocalizedString("settings.theme_background_day_detail", value: "白天背景", comment: "Day background summary")
        case .coverConfiguration:
            return NSLocalizedString(
                "settings.cover_config_detail", value: "默认封面与封面加载规则", comment: "Default cover and loading rules")
        case .appLock:
            return NSLocalizedString(
                "settings.app_lock_management_detail", value: "设置、修改或关闭应用密码", comment: "App password management")
        case .automaticBackup:
            return NSLocalizedString(
                "settings.automatic_backup_detail", value: "备份目标、加密密码与执行状态", comment: "Automatic backup settings summary")
        case .themeMode:
            return themeModeText(preferences?.themeMode)
        case .themeColor(let field, let isNight):
            return field.summary(isNight: isNight)
        case .saveTheme(let isNight):
            return isNight
                ? NSLocalizedString(
                    "settings.save_night_theme_detail", value: "保存夜间主题配置以供调用和分享", comment: "Save night theme config")
                : NSLocalizedString(
                    "settings.save_day_theme_detail", value: "保存白天主题配置以供调用和分享", comment: "Save day theme config")
        case .bookshelfLayout:
            return bookshelfLayoutText(preferences?.bookshelfLayoutMode)
        case .precisionSearch:
            return boolText(runtimeConfig?.precisionSearch == true)
        case .threadCount:
            return "\(runtimeConfig?.threadCount ?? 16)"
        case .preDownloadNum:
            return String(
                format: NSLocalizedString(
                    "settings.pre_download_detail", value: "预先下载 %d 章正文", comment: "Int32 chapter count to download in advance"),
                runtimeConfig?.preDownloadNum ?? 10)
        case .sourceCheck:
            return SourceCheckSettingsStore().load().summary
        case .replaceRuleEnabledByDefault:
            return boolText(runtimeConfig?.replaceRuleEnabledByDefault ?? true)
        case .keepScreenOn:
            return boolText(RestoredAppPreferences.keepScreenOn)
        case .showDiscovery:
            return boolText(userDefaultBool(key: "showDiscovery", defaultValue: true))
        case .showRss:
            return boolText(userDefaultBool(key: "showRss", defaultValue: true))
        case .defaultHome:
            return defaultHomeText()
        case .defaultToRead:
            return L10n.StartupReading.detail
        case .clearCache:
            return L10n.Settings.clearCacheDetail
        case .backupPath:
            return runtimeConfig?.backupPath ?? L10n.Settings.notImplementedValue
        case .backupCapabilities:
            return NSLocalizedString(
                "settings.backup_capabilities_detail", value: "源订阅、服务器、朗读引擎、键盘辅助与直链上传",
                comment: "Subscription and service configuration categories")
        case .backupNow:
            return L10n.Settings.backupNowDetail
        case .restoreNow:
            return L10n.Settings.restoreNowDetail
        case .webDavUrl:
            return runtimeConfig?.webDavUrl ?? L10n.Settings.webDavUrlPlaceholder
        case .webDavAccount:
            return runtimeConfig?.webDavAccount ?? L10n.Settings.webDavAccountPlaceholder
        case .webDavPassword:
            return runtimeConfig?.webDavPassword != nil
                ? L10n.Settings.webDavPasswordMask : L10n.Settings.webDavPasswordPlaceholder
        case .webDavDir:
            return runtimeConfig?.webDavDir ?? "legado"
        case .webDavDeviceName:
            return runtimeConfig?.webDavDeviceName ?? L10n.Settings.notImplementedValue
        case .syncBookProgress:
            return boolText(runtimeConfig?.syncBookProgress ?? true)
        case .syncBookProgressPlus:
            return boolText(runtimeConfig?.syncBookProgressPlus ?? false)
        case .restoreIgnore:
            return backupIgnoreSummary(runtimeConfig?.backupRestoreIgnoredKeys)
        case .onlyLatestBackup:
            return boolText(runtimeConfig?.onlyLatestBackup ?? true)
        case .autoCheckNewBackup:
            return boolText(runtimeConfig?.autoCheckNewBackup ?? true)
        case .hideStatusBar:
            return boolText(runtimeConfig?.reader.hideStatusBar ?? false)
        case .hideNavigationBar:
            return boolText(runtimeConfig?.reader.hideNavigationBar ?? false)
        case .textFullJustify:
            return boolText(runtimeConfig?.reader.textFullJustify ?? true)
        case .textBottomJustify:
            return boolText(runtimeConfig?.reader.textBottomJustify ?? true)
        case .autoRefreshOnStart:
            return boolText(userDefaultBool(key: "autoRefreshOnStart", defaultValue: false))
        case .userAgent:
            let value = runtimeConfig?.userAgent
            return value?.nilIfEmpty ?? L10n.Settings.userAgentPlaceholder
        case .autoChangeSource:
            return boolText(ReaderAutoChangeSourcePreference.isEnabled())
        case .showAddToShelfAlert:
            return NSLocalizedString(
                "settings.show_add_to_shelf_alert_detail", value: "阅读未放入书架的书籍在返回时提示放入书架",
                comment: "Legado show_add_to_shelf_alert_summary")
        }
    }

    func isToggle(_ row: Row) -> Bool {
        switch row {
        case .precisionSearch, .replaceRuleEnabledByDefault, .keepScreenOn, .showDiscovery, .showRss, .syncBookProgress,
            .syncBookProgressPlus, .onlyLatestBackup, .autoCheckNewBackup, .hideStatusBar, .hideNavigationBar,
            .textFullJustify, .textBottomJustify, .autoRefreshOnStart, .defaultToRead, .autoChangeSource,
            .showAddToShelfAlert:
            return true
        default:
            return false
        }
    }

    func toggleValue(for row: Row) -> Bool {
        switch row {
        case .precisionSearch: return runtimeConfig?.precisionSearch == true
        case .replaceRuleEnabledByDefault: return runtimeConfig?.replaceRuleEnabledByDefault ?? true
        case .keepScreenOn: return RestoredAppPreferences.keepScreenOn
        case .showDiscovery: return userDefaultBool(key: "showDiscovery", defaultValue: true)
        case .showRss: return userDefaultBool(key: "showRss", defaultValue: true)
        case .syncBookProgress: return runtimeConfig?.syncBookProgress ?? true
        case .syncBookProgressPlus: return runtimeConfig?.syncBookProgressPlus ?? false
        case .onlyLatestBackup: return runtimeConfig?.onlyLatestBackup ?? true
        case .autoCheckNewBackup: return runtimeConfig?.autoCheckNewBackup ?? true
        case .hideStatusBar: return runtimeConfig?.reader.hideStatusBar ?? false
        case .hideNavigationBar: return runtimeConfig?.reader.hideNavigationBar ?? false
        case .textFullJustify: return runtimeConfig?.reader.textFullJustify ?? true
        case .textBottomJustify: return runtimeConfig?.reader.textBottomJustify ?? true
        case .autoRefreshOnStart: return userDefaultBool(key: "autoRefreshOnStart", defaultValue: false)
        case .defaultToRead: return StartupReadingPreferences.isEnabled
        case .autoChangeSource: return ReaderAutoChangeSourcePreference.isEnabled()
        case .showAddToShelfAlert: return ReaderExitPreferences().showsAddToShelfPrompt
        default: return false
        }
    }

    func userDefaultBool(key: String, defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    func defaultHomeText() -> String {
        switch UserDefaults.standard.integer(forKey: "defaultHomePage") {
        case 1: return L10n.Tabs.discovery
        case 2: return L10n.Tabs.rss
        case 3: return L10n.Tabs.settings
        default: return L10n.Tabs.bookshelf
        }
    }

    func themeModeText(_ mode: ThemeMode?) -> String {
        switch mode {
        case ThemeMode.light:
            return L10n.Settings.themeModeLight
        case ThemeMode.dark:
            return L10n.Settings.themeModeDark
        default:
            return L10n.Settings.themeModeSystem
        }
    }

    func bookshelfLayoutText(_ mode: BookshelfLayoutMode?) -> String {
        switch mode {
        case BookshelfLayoutMode.list: return L10n.Settings.layoutList
        case BookshelfLayoutMode.grid3: return L10n.Settings.layoutGrid3
        case BookshelfLayoutMode.grid4: return L10n.Settings.layoutGrid4
        case BookshelfLayoutMode.grid5: return L10n.Settings.layoutGrid5
        case BookshelfLayoutMode.grid6: return L10n.Settings.layoutGrid6
        default: return L10n.Settings.layoutGrid3
        }
    }

    func boolText(_ value: Bool) -> String {
        value ? L10n.Settings.enabled : L10n.Settings.disabled
    }

    func backupIgnoreSummary(_ keys: Any?) -> String {
        let keyStrings = backupIgnoreKeySet(from: keys)
        guard keyStrings.isEmpty == false else { return L10n.Settings.backupIgnoreNone }
        return backupIgnoreOptions.filter { keyStrings.contains($0.key) }.map(\.title).joined(separator: ", ")
    }

    func backupIgnoreKeySet() -> Set<String> {
        backupIgnoreKeySet(from: runtimeConfig?.backupRestoreIgnoredKeys)
    }

    func backupIgnoreKeySet(from keys: Any?) -> Set<String> {
        if let values = keys as? Set<String> { return values }
        if let values = keys as? Set<AnyHashable> { return Set(values.compactMap { $0 as? String }) }
        if let values = keys as? [String] { return Set(values) }
        return []
    }

    var backupIgnoreOptions: [(key: String, title: String)] {
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

}

@MainActor
enum AndroidReplicaPreDownloadPreference {
    static let title = NSLocalizedString("settings.pre_download_title", value: "预下载", comment: "Legado pre_download")

    static func showPicker(from owner: UIViewController, current: Int, onConfirm: @escaping (Int) -> Void) {
        guard owner.presentedViewController == nil else { return }
        let dialog = AndroidReaderNumberPickerDialogViewController(
            titleText: title, value: current, range: 0...9999,
            valueTitle: { "\($0)" }, completion: onConfirm)
        owner.present(dialog, animated: true)
    }

    static func set(_ value: Int) async throws {
        let facade = try SharedRuntime.settingsFacade().get()
        try await SharedAsync.void { completion in
            facade.setPreDownloadNum(num: Int32(value), completionHandler: completion)
        }
    }
}

extension AndroidReplicaSettingsCategoryViewController {
    func showSourceCheckConfiguration(isCurrent: @escaping () -> Bool, onChange: @escaping () -> Void) {
        guard presentedViewController == nil, isCurrent() else { return }
        let store = SourceCheckSettingsStore()
        let dialog = SourceCheckConfigurationViewController(settings: store.load()) { [weak self] settings in
            guard let self, isCurrent(), self.presentedViewController == nil else { return }
            store.save(settings)
            onChange()
        }
        dialog.canSave = { [weak self, weak dialog] in
            guard let self, let dialog, isCurrent() else { return false }
            return self.presentedViewController === dialog
                || (self.presentedViewController == nil && dialog.presentingViewController == nil)
        }
        dialog.onClose = { [weak self] in
            guard self != nil, isCurrent() else { return }
            onChange()
        }
        present(dialog, animated: true)
    }
}
