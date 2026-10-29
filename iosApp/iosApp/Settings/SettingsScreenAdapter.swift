import SnapKit
import StoreKit
import UIKit
import shared

final class SettingsScreenAdapter {
    private let bindings = ScreenBindingController(owner: "SettingsScreen")
    private var bindingGeneration: UInt64 = 0
    private var facade: SettingsFacade?
    private var lastPreferencesSignature: String?
    private var lastRuntimeSignature: String?
    private var lastTxtTocRulesSignature: String?
    private var lastDictRulesSignature: String?
    private(set) var latestRuntimeConfig: AppRuntimeConfig?

    var onPreferencesChange: ((AppUiPreferences) -> Void)?
    var onRuntimeConfigChange: ((AppRuntimeConfig) -> Void)?
    var onTxtTocRulesChange: (([TxtTocRule]) -> Void)?
    var onDictRulesChange: (([DictRule]) -> Void)?

    var themePresets: [ThemePreset] {
        facade?.themeSettings.presets ?? []
    }

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        bindingGeneration &+= 1
        let generation = bindingGeneration
        bindings.cancelAll()
        facade = nil
        lastPreferencesSignature = nil
        lastRuntimeSignature = nil
        latestRuntimeConfig = nil
        lastTxtTocRulesSignature = nil
        lastDictRulesSignature = nil

        switch SharedRuntime.settingsFacade() {
        case .success(let facade):
            self.facade = facade
            bindings.bind(
                facade.watchPreferences { [weak self] preferences in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handlePreferences(preferences)
                    }
                })
            bindings.bind(
                facade.watchRuntimeConfig { [weak self] runtimeConfig in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handleRuntimeConfig(runtimeConfig)
                    }
                })
            bindings.bind(
                facade.watchTxtTocRules { [weak self] rules in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handleTxtTocRules(rules)
                    }
                })
            bindings.bind(
                facade.watchDictRules { [weak self] rules in
                    DispatchQueue.main.async {
                        guard let self, self.bindingGeneration == generation else { return }
                        self.handleDictRules(rules)
                    }
                })
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func unbind() {
        bindingGeneration &+= 1
        bindings.cancelAll()
        facade = nil
    }

    func bootstrapDefaultsIfNeeded() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.bootstrapDefaultsIfNeededAsync()
    }

    func setThemePreset(themeName: String) async throws {
        try await applyThemePreset(themeName: themeName)
    }

    func applyThemePreset(themeName: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void { completion in
            facade.themeSettings.applyPreset(themeName: themeName, completionHandler: completion)
        }
    }

    func deleteThemePreset(themeName: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void { completion in
            facade.themeSettings.deletePreset(themeName: themeName, completionHandler: completion)
        }
    }

    func importThemePreset(json: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void { completion in
            facade.themeSettings.importPreset(json: json, completionHandler: completion)
        }
    }

    func setThemeMode(mode: ThemeMode) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setThemeModeAsync(mode: mode)
    }

    func themePalette(isNight: Bool) throws -> ThemeColorPalette {
        guard let facade else { throw runtimeNotReadyError() }
        return facade.themeSettings.palette(isNightTheme: isNight)
    }

    func setThemeColor(isNight: Bool, field: ThemeColorField, color: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void {
            facade.themeSettings.setColor(isNightTheme: isNight, field: field, color: color, completionHandler: $0)
        }
    }

    func saveThemePalette(name: String, isNight: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void {
            facade.themeSettings.savePalette(themeName: name, isNightTheme: isNight, completionHandler: $0)
        }
    }

    func setBookshelfLayoutMode(mode: BookshelfLayoutMode) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setBookshelfLayoutModeAsync(mode: mode)
    }

    func setPrecisionSearch(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setPrecisionSearchAsync(enabled: enabled)
    }

    func setThreadCount(count: Int) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setThreadCountAsync(count: Int32(count))
    }

    func setReplaceRuleEnabledByDefault(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setReplaceRuleEnabledByDefaultAsync(enabled: enabled)
    }

    func setUserAgent(ua: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await SharedAsync.void { completion in
            facade.setUserAgent(ua: ua, completionHandler: completion)
        }
    }

    func setWebDavUrl(url: String?) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setWebDavUrlAsync(url: url)
    }

    func setWebDavAccount(account: String?) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setWebDavAccountAsync(account: account)
    }

    func setWebDavPassword(password: String?) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setWebDavPasswordAsync(password: password)
    }

    func setWebDavDir(dir: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setWebDavDirAsync(dir: dir)
    }

    func setWebDavDeviceName(name: String?) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setWebDavDeviceNameAsync(name: name)
    }

    func checkWebDavConnection() async throws -> Bool {
        guard let facade else { throw runtimeNotReadyError() }
        return await facade.checkWebDavConnectionAsync()
    }

    func initWebDavDirs() async throws -> Bool {
        guard let facade else { throw runtimeNotReadyError() }
        return await facade.initWebDavDirsAsync()
    }

    func setSyncBookProgress(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setSyncBookProgressAsync(enabled: enabled)
    }

    func setSyncBookProgressPlus(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setSyncBookProgressPlusAsync(enabled: enabled)
    }

    func setBackupPath(path: String?) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setBackupPathAsync(path: path)
    }

    func setBackupRestoreIgnoredKeys(keys: [String]) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setBackupRestoreIgnoredKeysAsync(keys: Set(keys))
    }

    func setOnlyLatestBackup(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setOnlyLatestBackupAsync(enabled: enabled)
    }

    func setAutoCheckNewBackup(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setAutoCheckNewBackupAsync(enabled: enabled)
    }

    // F67: 隐藏状态栏
    func setHideStatusBar(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setHideStatusBarAsync(enabled: enabled)
    }

    // F68: 隐藏导航栏
    func setHideNavigationBar(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setHideNavigationBarAsync(enabled: enabled)
    }

    // F74: 两端对齐
    func setTextFullJustify(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setTextFullJustifyAsync(enabled: enabled)
    }

    // F75: 底部对齐
    func setTextBottomJustify(enabled: Bool) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.setTextBottomJustifyAsync(enabled: enabled)
    }

    func loadTxtTocRules() async throws -> [TxtTocRule] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadTxtTocRulesAsync()
    }

    func saveTxtTocRule(_ rule: TxtTocRule) async throws -> TxtTocRule {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.saveTxtTocRuleAsync(rule: rule)
    }

    func setTxtTocRuleEnabled(id: Int64, enabled: Bool) async throws -> TxtTocRule {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.setTxtTocRuleEnabledAsync(id: id, enabled: enabled)
    }

    func deleteTxtTocRule(id: Int64) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.deleteTxtTocRuleAsync(id: id)
    }

    func loadReadRecords() async throws -> [ReadRecordShow] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadReadRecordsAsync()
    }

    func clearReadRecords() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.clearReadRecordsAsync()
    }

    func vacuumDatabase() async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.vacuumDatabaseAsync()
    }

    // MARK: - Backup & Restore

    func createBackup(password: String? = nil) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.createBackupAsync(password: password)
    }

    func createAndroidBackupArchive(password: String) async throws -> AndroidBackupExport {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.value { facade.createAndroidBackupArchive(password: password, completionHandler: $0) }
    }

    func restoreFromBackup(payload: String, password: String? = nil) async throws -> BackupRestoreResult {
        guard let facade else { throw runtimeNotReadyError() }
        let request = BackupRestoreTerminalRequest()
        let client = BackupRestoreFacade(settings: facade)
        // Cancellation cannot release the restore UI before Kotlin reports its actual terminal state.
        return try await withTaskCancellationHandler {
            try await SharedAsync.value { completion in
                request.install(
                    client.restore(payload: payload, password: password) { response in
                        request.finish()
                        if response.isCancelled {
                            completion(nil, CancellationError())
                        } else if let result = response.result {
                            completion(result, nil)
                        } else {
                            completion(
                                nil,
                                NSError(
                                    domain: "io.legado.backup", code: 1,
                                    userInfo: [
                                        NSLocalizedDescriptionKey: response.errorMessage ?? "备份恢复失败",
                                        "errorCode": response.errorCode ?? "BACKUP_RESTORE_FAILED",
                                    ]))
                        }
                    })
            }
        } onCancel: {
            request.cancel()
        }
    }

    // MARK: - DictRule management

    func loadDictRules() async throws -> [DictRule] {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.loadDictRulesAsync()
    }

    func saveDictRule(_ rule: DictRule) async throws -> DictRule {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.saveDictRuleAsync(rule: rule)
    }

    func deleteDictRule(name: String) async throws {
        guard let facade else { throw runtimeNotReadyError() }
        try await facade.deleteDictRuleAsync(name: name)
    }

    func setDictRuleEnabled(name: String, enabled: Bool) async throws -> DictRule {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.setDictRuleEnabledAsync(name: name, enabled: enabled)
    }

    func importDictRules(payload: String) async throws -> Int32 {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.importDictRulesAsync(payload: payload)
    }

    func exportDictRules(names: [String]) async throws -> String {
        guard let facade else { throw runtimeNotReadyError() }
        return try await facade.exportDictRulesAsync(names: names)
    }

    private func handlePreferences(_ preferences: AppUiPreferences) {
        let signature = [
            preferences.themePresetName,
            preferences.readerPresetName,
            preferences.themeMode.name,
            preferences.bookshelfLayoutMode.name,
            "\(preferences.readerStyle.fontSizeSp)",
            "\(preferences.readerStyle.lineSpacingMultiplier)",
            "\(preferences.readerStyle.horizontalPaddingDp)",
            preferences.readerStyle.backgroundMode.name,
        ].joined(separator: "|")
        guard signature != lastPreferencesSignature else { return }
        lastPreferencesSignature = signature
        onPreferencesChange?(preferences)
    }

    private func handleRuntimeConfig(_ runtimeConfig: AppRuntimeConfig) {
        latestRuntimeConfig = runtimeConfig
        let signature = [
            "\(runtimeConfig.threadCount)",
            "\(runtimeConfig.precisionSearch)",
            "\(runtimeConfig.replaceRuleEnabledByDefault)",
            runtimeConfig.userAgent,
            runtimeConfig.webDavUrl ?? "",
            runtimeConfig.webDavAccount ?? "",
            runtimeConfig.webDavPassword != nil ? "set" : "",
            runtimeConfig.webDavDir,
            runtimeConfig.webDavDeviceName ?? "",
            "\(runtimeConfig.syncBookProgress)",
            "\(runtimeConfig.syncBookProgressPlus)",
            runtimeConfig.backupPath ?? "",
            runtimeConfig.backupRestoreIgnoredKeys.sorted().joined(separator: ","),
            "\(runtimeConfig.onlyLatestBackup)",
            "\(runtimeConfig.autoCheckNewBackup)",
            "\(runtimeConfig.remoteServerId)",
            // 阅读相关设置签名，确保 reader 变化也触发更新
            "\(runtimeConfig.reader.textFullJustify)",
            "\(runtimeConfig.reader.textBottomJustify)",
            "\(runtimeConfig.reader.hideStatusBar)",
            "\(runtimeConfig.reader.hideNavigationBar)",
        ].joined(separator: "|")
        guard signature != lastRuntimeSignature else { return }
        lastRuntimeSignature = signature
        onRuntimeConfigChange?(runtimeConfig)
    }

    private func handleTxtTocRules(_ rules: [TxtTocRule]) {
        let signature = rules.map {
            "\($0.id)#\($0.name)#\($0.rule)#\($0.example ?? "")#\($0.serialNumber)#\($0.enable)"
        }.joined(separator: "|")
        guard signature != lastTxtTocRulesSignature else { return }
        lastTxtTocRulesSignature = signature
        onTxtTocRulesChange?(rules)
    }

    private func handleDictRules(_ rules: [DictRule]) {
        let signature = rules.map {
            "\($0.name)#\($0.urlRule)#\($0.showRule)#\($0.enabled)#\($0.sortNumber)"
        }.joined(separator: "|")
        guard signature != lastDictRulesSignature else { return }
        lastDictRulesSignature = signature
        onDictRulesChange?(rules)
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.Settings.unavailable]
        )
    }
}
