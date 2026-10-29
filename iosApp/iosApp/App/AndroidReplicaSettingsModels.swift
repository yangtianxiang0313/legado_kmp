extension AndroidReplicaSettingsCategoryViewController {
    enum Category {
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

        var sections: [Section] {
            switch self {
            case .theme:
                return [
                    Section(title: nil, rows: [.themePreset, .coverConfiguration]),
                    Section(
                        title: "白天",
                        rows: ThemeColorSetting.allCases.map { .themeColor($0, false) } + [
                            .themeBackground(false), .saveTheme(false),
                        ]),
                    Section(
                        title: "夜间",
                        rows: ThemeColorSetting.allCases.map { .themeColor($0, true) } + [
                            .themeBackground(true), .saveTheme(true),
                        ]
                    ),
                ]
            case .other:
                return [
                    Section(
                        title: L10n.Settings.readingSettingsSectionTitle,
                        rows: [
                            .readerAppearance, .hideStatusBar, .hideNavigationBar, .textFullJustify, .textBottomJustify,
                            .autoChangeSource,
                        ]),
                    Section(
                        title: nil,
                        rows: [
                            .bookshelfLayout, .precisionSearch, .threadCount, .preDownloadNum, .replaceRuleEnabledByDefault,
                            .keepScreenOn, .showDiscovery, .showRss, .defaultHome, .autoRefreshOnStart, .defaultToRead,
                            .userAgent,
                            .sourceCheck, .showAddToShelfAlert, .appLock, .clearCache,
                        ]),
                ]
            case .backup:
                return [
                    Section(title: nil, rows: [.backupNow, .restoreNow, .automaticBackup, .backupCapabilities]),
                    Section(
                        title: "WebDAV",
                        rows: [.webDavUrl, .webDavAccount, .webDavPassword, .webDavDir, .webDavDeviceName]),
                    Section(
                        title: L10n.Settings.backupTitle,
                        rows: [.backupPath, .restoreIgnore, .onlyLatestBackup, .autoCheckNewBackup]),
                    Section(
                        title: L10n.Settings.syncBookProgressTitle, rows: [.syncBookProgress, .syncBookProgressPlus]),
                ]
            }
        }
    }

    struct Section {
        let title: String?
        let rows: [Row]
    }

    enum Row: Equatable {
        case readerAppearance
        case themePreset
        case themeMode
        case themeColor(ThemeColorSetting, Bool)
        case themeBackground(Bool)
        case coverConfiguration
        case appLock
        case automaticBackup
        case saveTheme(Bool)
        case bookshelfLayout
        case precisionSearch
        case threadCount
        case preDownloadNum
        case replaceRuleEnabledByDefault
        case keepScreenOn
        case showDiscovery
        case showRss
        case defaultHome
        case defaultToRead
        case clearCache
        case sourceCheck
        case backupPath
        case backupNow
        case backupCapabilities
        case restoreNow
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
        case hideStatusBar
        case hideNavigationBar
        case textFullJustify
        case textBottomJustify
        case autoRefreshOnStart
        case userAgent
        case autoChangeSource
        case showAddToShelfAlert
    }
}
