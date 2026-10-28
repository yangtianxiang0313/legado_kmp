import Foundation
import shared

extension SettingsFacade {
    func bootstrapDefaultsIfNeededAsync() async throws {
        try await SharedAsync.void { completion in
            bootstrapDefaultsIfNeeded(completionHandler: completion)
        }
    }

    func loadTxtTocRulesAsync() async throws -> [TxtTocRule] {
        try await SharedAsync.value { completion in
            loadTxtTocRules(completionHandler: completion)
        }
    }

    func saveTxtTocRuleAsync(rule: TxtTocRule) async throws -> TxtTocRule {
        try await SharedAsync.value { completion in
            saveTxtTocRule(rule: rule, completionHandler: completion)
        }
    }

    func setTxtTocRuleEnabledAsync(id: Int64, enabled: Bool) async throws -> TxtTocRule {
        try await SharedAsync.value { completion in
            setTxtTocRuleEnabled(id: id, enabled: enabled, completionHandler: completion)
        }
    }

    func deleteTxtTocRuleAsync(id: Int64) async throws {
        try await SharedAsync.void { completion in
            deleteTxtTocRule(id: id, completionHandler: completion)
        }
    }

    func setThemeModeAsync(mode: ThemeMode) async throws {
        try await SharedAsync.void { completion in
            setThemeMode(mode: mode, completionHandler: completion)
        }
    }

    func setBookshelfLayoutModeAsync(mode: BookshelfLayoutMode) async throws {
        try await SharedAsync.void { completion in
            setBookshelfLayoutMode(mode: mode, completionHandler: completion)
        }
    }

    func setBookshelfSortAsync(sort: Int32) async throws {
        try await SharedAsync.void { completion in
            setBookshelfSort(sort: sort, completionHandler: completion)
        }
    }

    func setBookGroupStyleAsync(style: Int32) async throws {
        try await SharedAsync.void { completion in
            setBookGroupStyle(style: style, completionHandler: completion)
        }
    }

    func setShowUnreadAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setShowUnread(enabled: enabled, completionHandler: completion)
        }
    }

    func setShowLastUpdateTimeAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setShowLastUpdateTime(enabled: enabled, completionHandler: completion)
        }
    }

    func setShowWaitUpCountAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setShowWaitUpCount(enabled: enabled, completionHandler: completion)
        }
    }

    func setShowBookshelfFastScrollerAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setShowBookshelfFastScroller(enabled: enabled, completionHandler: completion)
        }
    }

    func setOpenBookInfoByClickTitleAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setOpenBookInfoByClickTitle(enabled: enabled, completionHandler: completion)
        }
    }

    func setBatchChangeSourceDelayAsync(delay: Int32) async throws {
        try await SharedAsync.void { completion in
            setBatchChangeSourceDelay(delay: delay, completionHandler: completion)
        }
    }

    func setSaveTabPositionAsync(position: Int32) async throws {
        try await SharedAsync.void { completion in
            setSaveTabPosition(position: position, completionHandler: completion)
        }
    }

    func setThemePresetAsync(themeName: String) async throws {
        try await SharedAsync.void { completion in
            setThemePreset(themeName: themeName, completionHandler: completion)
        }
    }

    func setReaderPresetAsync(name: String) async throws {
        try await SharedAsync.void { completion in
            setReaderPreset(name: name, completionHandler: completion)
        }
    }

    func setReaderFontSizeAsync(fontSizeSp: Float) async throws {
        try await SharedAsync.void { completion in
            setReaderFontSize(fontSizeSp: fontSizeSp, completionHandler: completion)
        }
    }

    func setReaderLineSpacingAsync(multiplier: Float) async throws {
        try await SharedAsync.void { completion in
            setReaderLineSpacing(multiplier: multiplier, completionHandler: completion)
        }
    }

    func setReaderHorizontalPaddingAsync(paddingDp: Float) async throws {
        try await SharedAsync.void { completion in
            setReaderHorizontalPadding(paddingDp: paddingDp, completionHandler: completion)
        }
    }

    func setReaderBackgroundModeAsync(mode: ReaderBackgroundMode) async throws {
        try await SharedAsync.void { completion in
            setReaderBackgroundMode(mode: mode, completionHandler: completion)
        }
    }

    func setReaderStyleAsync(style: ReaderStylePreferences) async throws {
        try await SharedAsync.void { completion in
            setReaderStyle(style: style, completionHandler: completion)
        }
    }

    func setThreadCountAsync(count: Int32) async throws {
        try await SharedAsync.void { completion in
            setThreadCount(count: count, completionHandler: completion)
        }
    }

    func setPrecisionSearchAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setPrecisionSearch(enabled: enabled, completionHandler: completion)
        }
    }

    func setReplaceRuleEnabledByDefaultAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setReplaceRuleEnabledByDefault(enabled: enabled, completionHandler: completion)
        }
    }

    func setWebDavUrlAsync(url: String?) async throws {
        try await SharedAsync.void { completion in
            setWebDavUrl(url: url, completionHandler: completion)
        }
    }

    func setWebDavAccountAsync(account: String?) async throws {
        try await SharedAsync.void { completion in
            setWebDavAccount(account: account, completionHandler: completion)
        }
    }

    func setWebDavPasswordAsync(password: String?) async throws {
        try await SharedAsync.void { completion in
            setWebDavPassword(password: password, completionHandler: completion)
        }
    }

    func setWebDavDirAsync(dir: String) async throws {
        try await SharedAsync.void { completion in
            setWebDavDir(dir: dir, completionHandler: completion)
        }
    }

    func setWebDavDeviceNameAsync(name: String?) async throws {
        try await SharedAsync.void { completion in
            setWebDavDeviceName(name: name, completionHandler: completion)
        }
    }

    func setSyncBookProgressAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setSyncBookProgress(enabled: enabled, completionHandler: completion)
        }
    }

    func setSyncBookProgressPlusAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setSyncBookProgressPlus(enabled: enabled, completionHandler: completion)
        }
    }

    func setBackupPathAsync(path: String?) async throws {
        try await SharedAsync.void { completion in
            setBackupPath(path: path, completionHandler: completion)
        }
    }

    func setBackupRestoreIgnoredKeysAsync(keys: Set<String>) async throws {
        try await SharedAsync.void { completion in
            setBackupRestoreIgnoredKeys(keys: keys, completionHandler: completion)
        }
    }

    func setOnlyLatestBackupAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setOnlyLatestBackup(enabled: enabled, completionHandler: completion)
        }
    }

    func setAutoCheckNewBackupAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setAutoCheckNewBackup(enabled: enabled, completionHandler: completion)
        }
    }

    func setRemoteServerIdAsync(id: Int64) async throws {
        try await SharedAsync.void { completion in
            setRemoteServerId(id: id, completionHandler: completion)
        }
    }

    func setBrightnessDayAsync(value: Int32) async throws {
        try await SharedAsync.void { completion in
            setBrightnessDay(value: value, completionHandler: completion)
        }
    }

    func setBrightnessNightAsync(value: Int32) async throws {
        try await SharedAsync.void { completion in
            setBrightnessNight(value: value, completionHandler: completion)
        }
    }

    func setPageAnimationAsync(value: Int32) async throws {
        try await SharedAsync.void { completion in
            setPageAnimation(value: value, completionHandler: completion)
        }
    }

    func setShareLayoutAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setShareLayout(enabled: enabled, completionHandler: completion)
        }
    }

    func setReadStyleIndexAsync(index: Int32) async throws {
        try await SharedAsync.void { completion in
            setReadStyleIndex(index: index, completionHandler: completion)
        }
    }

    func setComicStyleIndexAsync(index: Int32) async throws {
        try await SharedAsync.void { completion in
            setComicStyleIndex(index: index, completionHandler: completion)
        }
    }

    func setAutoReadSpeedAsync(value: Int32) async throws {
        try await SharedAsync.void { completion in
            setAutoReadSpeed(value: value, completionHandler: completion)
        }
    }

    func setTextFullJustifyAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setTextFullJustify(enabled: enabled, completionHandler: completion)
        }
    }

    func setTextBottomJustifyAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setTextBottomJustify(enabled: enabled, completionHandler: completion)
        }
    }

    func setHideStatusBarAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setHideStatusBar(enabled: enabled, completionHandler: completion)
        }
    }

    func setHideNavigationBarAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setHideNavigationBar(enabled: enabled, completionHandler: completion)
        }
    }

    func setReadBarStyleFollowPageAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setReadBarStyleFollowPage(enabled: enabled, completionHandler: completion)
        }
    }

    func setBookInfoDeleteAlertAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setBookInfoDeleteAlert(enabled: enabled, completionHandler: completion)
        }
    }

    func setReaderRuntimeConfigAsync(config: ReaderRuntimeConfig) async throws {
        try await SharedAsync.void { completion in
            setReaderRuntimeConfig(config: config, completionHandler: completion)
        }
    }

    func setTapZoneActionsAsync(actions: ReaderTapZoneActions) async throws {
        try await SharedAsync.void { completion in
            setTapZoneActions(actions: actions, completionHandler: completion)
        }
    }

    func vacuumDatabaseAsync() async throws {
        try await SharedAsync.void { completion in
            vacuumDatabase(completionHandler: completion)
        }
    }

    func renameReaderPresetAsync(oldName: String, newName: String, expectedIndex: Int32? = nil) async throws {
        try await SharedAsync.void { completion in
            renameReaderPreset(oldName: oldName, newName: newName, expectedIndex: expectedIndex.map { KotlinInt(value: $0) }, completionHandler: completion)
        }
    }

    func deleteReaderPresetAsync(name: String, expectedIndex: Int32? = nil) async throws {
        try await SharedAsync.void { completion in
            deleteReaderPreset(name: name, expectedIndex: expectedIndex.map { KotlinInt(value: $0) }, completionHandler: completion)
        }
    }

    func importReaderPresetJsonAsync(jsonString: String) async throws {
        try await SharedAsync.void { completion in
            importReaderPresetJson(jsonString: jsonString, completionHandler: completion)
        }
    }

    // MARK: - DictRule management

    func loadDictRulesAsync() async throws -> [DictRule] {
        try await SharedAsync.value { completion in
            loadDictRules(completionHandler: completion)
        }
    }

    func saveDictRuleAsync(rule: DictRule) async throws -> DictRule {
        try await SharedAsync.value { completion in
            saveDictRule(rule: rule, completionHandler: completion)
        }
    }

    func deleteDictRuleAsync(name: String) async throws {
        try await SharedAsync.void { completion in
            deleteDictRule(name: name, completionHandler: completion)
        }
    }

    func setDictRuleEnabledAsync(name: String, enabled: Bool) async throws -> DictRule {
        try await SharedAsync.value { completion in
            setDictRuleEnabled(name: name, enabled: enabled, completionHandler: completion)
        }
    }

    func importDictRulesAsync(payload: String) async throws -> Int32 {
        let result: KotlinInt = try await SharedAsync.value { completion in
            importDictRules(payload: payload, completionHandler: completion)
        }
        return result.int32Value
    }

    func exportDictRulesAsync(names: [String]) async throws -> String {
        try await SharedAsync.value { completion in
            exportDictRules(names: names, completionHandler: completion)
        }
    }

    // MARK: - Backup & Restore

    func createBackupAsync(password: String? = nil) async throws -> String {
        try await SharedAsync.value { completion in
            createBackup(password: password, completionHandler: completion)
        }
    }

    func restoreFromBackupAsync(payload: String, password: String? = nil) async throws -> BackupRestoreResult {
        try await SharedAsync.value { completion in
            restoreFromBackup(payload: payload, password: password, completionHandler: completion)
        }
    }

    func loadReadRecordsAsync() async throws -> [ReadRecordShow] {
        try await SharedAsync.value { completion in
            loadReadRecords(completionHandler: completion)
        }
    }

    func clearReadRecordsAsync() async throws {
        try await SharedAsync.void { completion in
            clearReadRecords(completionHandler: completion)
        }
    }

    // MARK: - WebDAV Operations

    func isWebDavConfiguredAsync() async -> Bool {
        do {
            let result: KotlinBoolean = try await SharedAsync.value { completion in
                isWebDavConfigured(completionHandler: completion)
            }
            return result.boolValue
        } catch {
            return false
        }
    }

    func checkWebDavConnectionAsync() async -> Bool {
        do {
            let result: KotlinBoolean = try await SharedAsync.value { completion in
                checkWebDavConnection(completionHandler: completion)
            }
            return result.boolValue
        } catch {
            return false
        }
    }

    func initWebDavDirsAsync() async -> Bool {
        do {
            let result: KotlinBoolean = try await SharedAsync.value { completion in
                doInitWebDavDirs(completionHandler: completion)
            }
            return result.boolValue
        } catch {
            return false
        }
    }

    func uploadBookProgressAsync(book: Book) async throws {
        try await SharedAsync.void { completion in
            uploadBookProgress(book: book, completionHandler: completion)
        }
    }

    func getBookProgressAsync(bookName: String, bookAuthor: String) async -> BookProgress? {
        do {
            return try await SharedAsync.optionalValue { completion in
                getBookProgress(bookName: bookName, bookAuthor: bookAuthor, completionHandler: completion)
            }
        } catch {
            return nil
        }
    }

    func uploadBookToWebDavAsync(book: Book, fileBytes: KotlinByteArray) async throws {
        try await SharedAsync.void { completion in
            uploadBookToWebDav(book: book, fileBytes: fileBytes, completionHandler: completion)
        }
    }

    func backupToWebDavAsync(backupJson: String) async throws {
        try await SharedAsync.void { completion in
            backupToWebDav(backupJson: backupJson, completionHandler: completion)
        }
    }

    func getWebDavBackupNamesAsync() async -> [String] {
        do {
            return try await SharedAsync.value { completion in
                getWebDavBackupNames(completionHandler: completion)
            }
        } catch {
            return []
        }
    }

    func restoreFromWebDavAsync(name: String) async -> String? {
        do {
            return try await SharedAsync.optionalValue { completion in
                restoreFromWebDav(name: name, completionHandler: completion)
            }
        } catch {
            return nil
        }
    }
}
