import Foundation

enum SettingsCategory: Equatable {
    case theme
    case other
    case backup

    var title: String {
        switch self {
        case .theme:
            return L10n.Settings.themeSettingRootTitle
        case .other:
            return L10n.Settings.appConfigEntryTitle
        case .backup:
            return L10n.Settings.backupTitle
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .theme:
            return [
                SettingsSection(title: nil, rows: [.themePreset, .themeMode]),
            ]
        case .other:
            return [
                // 阅读设置分组
                SettingsSection(title: L10n.Settings.readingSettingsSectionTitle, rows: [.readerAppearance, .hideStatusBar, .hideNavigationBar, .textFullJustify, .textBottomJustify, .autoChangeSource]),
                // 通用设置分组
                SettingsSection(title: nil, rows: [.bookshelfLayout, .precisionSearch, .threadCount, .replaceRuleEnabledByDefault, .keepScreenOn, .showDiscovery, .showRss, .defaultHome, .autoRefreshOnStart, .userAgent, .clearCache]),
            ]
        case .backup:
            return [
                SettingsSection(title: nil, rows: [.backupNow, .restoreNow, .backupCapabilities]),
                SettingsSection(title: "WebDAV", rows: [.webDavUrl, .webDavAccount, .webDavPassword, .webDavDir, .webDavDeviceName]),
                SettingsSection(title: L10n.Settings.backupTitle, rows: [.backupPath, .restoreIgnore, .onlyLatestBackup, .autoCheckNewBackup]),
                SettingsSection(title: L10n.Settings.syncBookProgressTitle, rows: [.syncBookProgress, .syncBookProgressPlus]),
            ]
        }
    }
}

struct SettingsSection {
    let title: String?
    let rows: [SettingsRow]
}

enum SettingsRow {
    case readerAppearance
    case themePreset
    case themeMode
    case bookshelfLayout
    case precisionSearch
    case threadCount
    case replaceRuleEnabledByDefault
    case keepScreenOn
    case showDiscovery
    case showRss
    case defaultHome
    case clearCache
    case backupPath
    case backupNow
    case backupCapabilities
    case restoreNow
    case webDav
    case webDavUrl
    case webDavAccount
    case webDavPassword
    case webDavDir
    case webDavDeviceName
    case syncBookProgress
    case syncBookProgressPlus
    case restoreIgnore
    case onlyLatestBackup
    case autoCheckNewBackup
    // F67: 隐藏状态栏
    case hideStatusBar
    // F68: 隐藏导航栏
    case hideNavigationBar
    // F74: 两端对齐
    case textFullJustify
    // F75: 底部对齐
    case textBottomJustify
    // F103: 启动自动刷新
    case autoRefreshOnStart
    // F109: 自定义 User-Agent
    case userAgent
    // F81: 自动换源
    case autoChangeSource
}
