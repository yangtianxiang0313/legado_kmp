package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookGroupRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.domain.repository.BookmarkRepository
import io.legado.kmp.shared.domain.repository.DictRuleRepository
import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.domain.repository.ReplaceRuleRepository
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.repository.SearchKeywordRepository
import io.legado.kmp.shared.domain.repository.TxtTocRuleRepository
import io.legado.kmp.shared.model.DictRule
import io.legado.kmp.shared.model.ReadRecordShow
import io.legado.kmp.shared.model.TxtTocRule
import kotlinx.coroutines.flow.first
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import io.legado.kmp.shared.preferences.AppUiPreferences
import io.legado.kmp.shared.preferences.BookshelfLayoutMode
import io.legado.kmp.shared.preferences.ReaderTapZoneActions
import io.legado.kmp.shared.preferences.ReaderBackgroundMode
import io.legado.kmp.shared.preferences.ReaderAppearanceQuickOption
import io.legado.kmp.shared.preferences.ReaderPreset
import io.legado.kmp.shared.preferences.ReaderRuntimeConfig
import io.legado.kmp.shared.preferences.ReaderStylePreferences
import io.legado.kmp.shared.preferences.ReaderVisualVariant
import io.legado.kmp.shared.preferences.ThemeMode
import io.legado.kmp.shared.preferences.ThemePreset
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class SettingsFacade(
    private val preferencesStore: AppPreferencesStore,
    private val txtTocRuleRepository: TxtTocRuleRepository,
    private val database: io.legado.kmp.shared.data.database.LegadoDatabase? = null,
    private val dictRuleRepository: DictRuleRepository? = null,
    private val bookRepository: BookRepository? = null,
    private val bookSourceRepository: BookSourceRepository? = null,
    private val rssSourceRepository: RssSourceRepository? = null,
    private val replaceRuleRepository: ReplaceRuleRepository? = null,
    private val bookGroupRepository: BookGroupRepository? = null,
    private val bookmarkRepository: BookmarkRepository? = null,
    private val searchKeywordRepository: SearchKeywordRepository? = null,
    private val readRecordRepository: ReadRecordRepository? = null,
    private val rssStarRepository: io.legado.kmp.shared.domain.repository.RssStarRepository? = null,
    private val ruleSubRepository: io.legado.kmp.shared.domain.repository.RuleSubRepository? = null,
    private val httpTTSRepository: io.legado.kmp.shared.domain.repository.HttpTTSRepository? = null,
    private val keyboardAssistRepository: io.legado.kmp.shared.domain.repository.KeyboardAssistRepository? = null,
    private val serverRepository: io.legado.kmp.shared.domain.repository.ServerRepository? = null,
) : SettingsWebDavSupport(preferencesStore, bookRepository, serverRepository) {
    val themeSettings = ThemeSettingsFacade(preferencesStore)

    val themePresets: List<ThemePreset>
        get() = preferencesStore.themePresets

    val readerPresets: List<ReaderPreset>
        get() = preferencesStore.readerPresets

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun bootstrapDefaultsIfNeeded() {
        runRecoverable("SettingsFacade.bootstrapDefaultsIfNeeded") {
            preferencesStore.bootstrapDefaultsIfNeeded()
        }
    }

    fun watchPreferences(onUpdate: (AppUiPreferences) -> Unit): FlowSubscription {
        return watchFlow(preferencesStore.preferences, onUpdate, label = "SettingsFacade.preferences")
    }

    fun watchRuntimeConfig(onUpdate: (AppRuntimeConfig) -> Unit): FlowSubscription {
        return watchFlow(preferencesStore.runtimeConfig, onUpdate, label = "SettingsFacade.runtimeConfig")
    }

    fun watchTxtTocRules(onUpdate: (List<TxtTocRule>) -> Unit): FlowSubscription {
        return watchFlow(txtTocRuleRepository.observeAll(), onUpdate, label = "SettingsFacade.txtTocRules")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadTxtTocRules(): List<TxtTocRule> {
        return runRecoverable("SettingsFacade.loadTxtTocRules") {
            txtTocRuleRepository.getAll()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveTxtTocRule(rule: TxtTocRule): TxtTocRule {
        return runRecoverable("SettingsFacade.saveTxtTocRule") {
            val existing = txtTocRuleRepository.get(rule.id)
            val normalized = if (existing == null && rule.serialNumber < 0) {
                rule.copy(serialNumber = txtTocRuleRepository.getMaxOrder() + 1)
            } else {
                rule
            }
            if (existing == null) {
                txtTocRuleRepository.insert(normalized)
            } else {
                txtTocRuleRepository.update(normalized)
            }
            normalized
        }
    }

    /** Imported Android rules retain their identity, enable flag, and even negative serial numbers. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importTxtTocRule(rule: TxtTocRule): TxtTocRule = runRecoverable("SettingsFacade.importTxtTocRule") {
        if (txtTocRuleRepository.get(rule.id) == null) txtTocRuleRepository.insert(rule)
        else txtTocRuleRepository.update(rule)
        rule
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTxtTocRuleEnabled(id: Long, enabled: Boolean): TxtTocRule {
        return runRecoverable("SettingsFacade.setTxtTocRuleEnabled") {
            val current = txtTocRuleRepository.get(id) ?: error("TxtTocRule not found: $id")
            val updated = current.copy(enable = enabled)
            txtTocRuleRepository.update(updated)
            updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteTxtTocRule(id: Long) {
        runRecoverable("SettingsFacade.deleteTxtTocRule") {
            txtTocRuleRepository.delete(id)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadReadRecords(): List<ReadRecordShow> {
        return runRecoverable("SettingsFacade.loadReadRecords") {
            val repo = readRecordRepository ?: error("ReadRecordRepository not available")
            repo.getAllShow()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearReadRecords() {
        runRecoverable("SettingsFacade.clearReadRecords") {
            val repo = readRecordRepository ?: error("ReadRecordRepository not available")
            repo.clear()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setThemeMode(mode: ThemeMode) {
        runRecoverable("SettingsFacade.setThemeMode") {
            preferencesStore.setThemeMode(mode)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBookshelfLayoutMode(mode: BookshelfLayoutMode) {
        runRecoverable("SettingsFacade.setBookshelfLayoutMode") {
            preferencesStore.setBookshelfLayoutMode(mode)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBookshelfSort(sort: Int) {
        runRecoverable("SettingsFacade.setBookshelfSort") {
            preferencesStore.setBookshelfSort(sort)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBookGroupStyle(style: Int) {
        runRecoverable("SettingsFacade.setBookGroupStyle") {
            preferencesStore.setBookGroupStyle(style)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowUnread(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowUnread") {
            preferencesStore.setShowUnread(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowLastUpdateTime(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowLastUpdateTime") {
            preferencesStore.setShowLastUpdateTime(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowWaitUpCount(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowWaitUpCount") {
            preferencesStore.setShowWaitUpCount(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowBookshelfFastScroller(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowBookshelfFastScroller") {
            preferencesStore.setShowBookshelfFastScroller(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setOpenBookInfoByClickTitle(enabled: Boolean) {
        runRecoverable("SettingsFacade.setOpenBookInfoByClickTitle") {
            preferencesStore.setOpenBookInfoByClickTitle(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBookInfoDeleteAlert(enabled: Boolean) {
        runRecoverable("SettingsFacade.setBookInfoDeleteAlert") {
            preferencesStore.setBookInfoDeleteAlert(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBatchChangeSourceDelay(delay: Int) {
        runRecoverable("SettingsFacade.setBatchChangeSourceDelay") {
            preferencesStore.setBatchChangeSourceDelay(delay.coerceAtLeast(0))
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSaveTabPosition(position: Int) {
        runRecoverable("SettingsFacade.setSaveTabPosition") {
            preferencesStore.setSaveTabPosition(position)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setThemePreset(themeName: String) {
        runRecoverable("SettingsFacade.setThemePreset") {
            preferencesStore.setThemePreset(themeName)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderPreset(name: String) {
        runRecoverable("SettingsFacade.setReaderPreset") {
            preferencesStore.setReaderPreset(name)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderFontSize(fontSizeSp: Float) {
        runRecoverable("SettingsFacade.setReaderFontSize") {
            preferencesStore.setReaderFontSize(fontSizeSp)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderFontSelection(
        fontName: String?,
        expectedName: String,
        expectedIndex: Int,
        expectedShareLayout: Boolean,
    ) {
        runRecoverable("SettingsFacade.setReaderFontSelection") {
            preferencesStore.setReaderFontSelection(fontName, expectedName, expectedIndex, expectedShareLayout)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderLineSpacing(multiplier: Float) {
        runRecoverable("SettingsFacade.setReaderLineSpacing") {
            preferencesStore.setReaderLineSpacing(multiplier)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderQuickOption(
        option: ReaderAppearanceQuickOption, value: Int,
        expectedName: String, expectedIndex: Int, expectedShareLayout: Boolean,
    ) {
        runRecoverable("SettingsFacade.setReaderQuickOption") {
            preferencesStore.setReaderQuickOption(option, value, expectedName, expectedIndex, expectedShareLayout)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderHorizontalPadding(paddingDp: Float) {
        runRecoverable("SettingsFacade.setReaderHorizontalPadding") {
            preferencesStore.setReaderHorizontalPadding(paddingDp)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderBackgroundMode(mode: ReaderBackgroundMode) {
        runRecoverable("SettingsFacade.setReaderBackgroundMode") {
            preferencesStore.setReaderBackgroundMode(mode)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderStyle(style: ReaderStylePreferences) {
        runRecoverable("SettingsFacade.setReaderStyle") {
            preferencesStore.setReaderStyle(style)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderLayout(style: ReaderStylePreferences) {
        runRecoverable("SettingsFacade.setReaderLayout") {
            preferencesStore.setReaderLayout(style)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderStyleForVariant(
        style: ReaderStylePreferences,
        variant: ReaderVisualVariant,
        presetName: String? = null,
        expectedIndex: Int? = null,
    ) {
        runRecoverable("SettingsFacade.setReaderStyleForVariant") {
            preferencesStore.setReaderStyleForVariant(style, variant, presetName, expectedIndex)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun restoreReaderPreset(name: String, template: ReaderPreset, expectedIndex: Int? = null) {
        runRecoverable("SettingsFacade.restoreReaderPreset") {
            preferencesStore.restoreReaderPreset(name, template, expectedIndex)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setThreadCount(count: Int) {
        runRecoverable("SettingsFacade.setThreadCount") {
            preferencesStore.setThreadCount(count)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setPrecisionSearch(enabled: Boolean) {
        runRecoverable("SettingsFacade.setPrecisionSearch") {
            preferencesStore.setPrecisionSearch(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReplaceRuleEnabledByDefault(enabled: Boolean) {
        runRecoverable("SettingsFacade.setReplaceRuleEnabledByDefault") {
            preferencesStore.setReplaceRuleEnabledByDefault(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setIgnoreAudioFocus(enabled: Boolean) {
        runRecoverable("SettingsFacade.setIgnoreAudioFocus") {
            preferencesStore.setIgnoreAudioFocus(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setChangeSourceCheckAuthor(enabled: Boolean) {
        runRecoverable("SettingsFacade.setChangeSourceCheckAuthor") {
            preferencesStore.setChangeSourceCheckAuthor(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setChangeSourceLoadInfo(enabled: Boolean) {
        runRecoverable("SettingsFacade.setChangeSourceLoadInfo") {
            preferencesStore.setChangeSourceLoadInfo(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setChangeSourceLoadToc(enabled: Boolean) {
        runRecoverable("SettingsFacade.setChangeSourceLoadToc") {
            preferencesStore.setChangeSourceLoadToc(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setChangeSourceLoadWordCount(enabled: Boolean) {
        runRecoverable("SettingsFacade.setChangeSourceLoadWordCount") {
            preferencesStore.setChangeSourceLoadWordCount(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setAutoChangeSource(enabled: Boolean) {
        runRecoverable("SettingsFacade.setAutoChangeSource") {
            preferencesStore.setAutoChangeSource(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setWebDavUrl(url: String?) {
        runRecoverable("SettingsFacade.setWebDavUrl") {
            preferencesStore.setWebDavUrl(url)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setWebDavAccount(account: String?) {
        runRecoverable("SettingsFacade.setWebDavAccount") {
            preferencesStore.setWebDavAccount(account)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setWebDavPassword(password: String?) {
        runRecoverable("SettingsFacade.setWebDavPassword") {
            preferencesStore.setWebDavPassword(password)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setWebDavDir(dir: String) {
        runRecoverable("SettingsFacade.setWebDavDir") {
            preferencesStore.setWebDavDir(dir)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setWebDavDeviceName(name: String?) {
        runRecoverable("SettingsFacade.setWebDavDeviceName") {
            preferencesStore.setWebDavDeviceName(name)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSyncBookProgress(enabled: Boolean) {
        runRecoverable("SettingsFacade.setSyncBookProgress") {
            preferencesStore.setSyncBookProgress(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSyncBookProgressPlus(enabled: Boolean) {
        runRecoverable("SettingsFacade.setSyncBookProgressPlus") {
            preferencesStore.setSyncBookProgressPlus(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBackupPath(path: String?) {
        runRecoverable("SettingsFacade.setBackupPath") {
            preferencesStore.setBackupPath(path)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBackupRestoreIgnoredKeys(keys: Set<String>) {
        runRecoverable("SettingsFacade.setBackupRestoreIgnoredKeys") {
            preferencesStore.setBackupRestoreIgnoredKeys(keys)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setOnlyLatestBackup(enabled: Boolean) {
        runRecoverable("SettingsFacade.setOnlyLatestBackup") {
            preferencesStore.setOnlyLatestBackup(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setAutoCheckNewBackup(enabled: Boolean) {
        runRecoverable("SettingsFacade.setAutoCheckNewBackup") {
            preferencesStore.setAutoCheckNewBackup(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setRemoteServerId(id: Long) {
        runRecoverable("SettingsFacade.setRemoteServerId") {
            preferencesStore.setRemoteServerId(id)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBrightnessDay(value: Int) {
        runRecoverable("SettingsFacade.setBrightnessDay") {
            preferencesStore.setBrightnessDay(value)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBrightnessNight(value: Int) {
        runRecoverable("SettingsFacade.setBrightnessNight") {
            preferencesStore.setBrightnessNight(value)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setPageAnimation(value: Int) {
        runRecoverable("SettingsFacade.setPageAnimation") {
            preferencesStore.setPageAnimation(value)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShareLayout(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShareLayout") {
            preferencesStore.setShareLayout(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReadStyleIndex(index: Int) {
        runRecoverable("SettingsFacade.setReadStyleIndex") {
            preferencesStore.setReadStyleIndex(index)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setComicStyleIndex(index: Int) {
        runRecoverable("SettingsFacade.setComicStyleIndex") {
            preferencesStore.setComicStyleIndex(index)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setAutoReadSpeed(value: Int) {
        runRecoverable("SettingsFacade.setAutoReadSpeed") {
            preferencesStore.setAutoReadSpeed(value)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTextFullJustify(enabled: Boolean) {
        runRecoverable("SettingsFacade.setTextFullJustify") {
            preferencesStore.setTextFullJustify(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTextBottomJustify(enabled: Boolean) {
        runRecoverable("SettingsFacade.setTextBottomJustify") {
            preferencesStore.setTextBottomJustify(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setHideStatusBar(enabled: Boolean) {
        runRecoverable("SettingsFacade.setHideStatusBar") {
            preferencesStore.setHideStatusBar(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setHideNavigationBar(enabled: Boolean) {
        runRecoverable("SettingsFacade.setHideNavigationBar") {
            preferencesStore.setHideNavigationBar(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReaderRuntimeConfig(config: ReaderRuntimeConfig) {
        runRecoverable("SettingsFacade.setReaderRuntimeConfig") {
            preferencesStore.setReaderRuntimeConfig(
                config.copy(tapZoneActions = config.tapZoneActions.withReachableMenuEntry())
            )
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReadBarStyleFollowPage(enabled: Boolean) {
        runRecoverable("SettingsFacade.setReadBarStyleFollowPage") {
            preferencesStore.setReadBarStyleFollowPage(enabled)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTapZoneActions(actions: ReaderTapZoneActions) {
        runRecoverable("SettingsFacade.setTapZoneActions") {
            preferencesStore.setTapZoneActions(actions.withReachableMenuEntry())
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun renameReaderPreset(oldName: String, newName: String, expectedIndex: Int? = null) {
        runRecoverable("SettingsFacade.renameReaderPreset") {
            preferencesStore.renameReaderPreset(oldName, newName, expectedIndex)
        }
    }

    /**
     * R-10: Delete a reader preset with minimum count protection (>= 5).
     * Mirrors legado ReadBookConfig behavior where a minimum number of presets
     * must be maintained to avoid empty configuration.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteReaderPreset(name: String, expectedIndex: Int? = null) {
        runRecoverable("SettingsFacade.deleteReaderPreset") {
            val currentCount = preferencesStore.readerPresets.size
            if (currentCount <= 5) {
                throw RecoverableSharedException(
                    "MIN_PRESET_COUNT",
                    "Cannot delete preset: minimum 5 presets required (current: $currentCount)"
                )
            }
            preferencesStore.deleteReaderPreset(name, expectedIndex)
        }
    }

    // MARK: - M-51: getBookSortByGroupId

    /**
     * Get the book sort mode for a specific group.
     * Mirrors legado AppConfig.getBookSortByGroupId():
     * Returns the group's bookSort if >= 0, otherwise falls back to global bookshelfSort.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getBookSortByGroupId(groupId: Long): Int {
        return runRecoverable("SettingsFacade.getBookSortByGroupId") {
            val group = bookGroupRepository?.getBookGroupById(groupId)
            val defaultSort = preferencesStore.preferences.first().bookshelfSort
            group?.getRealBookSort(defaultSort) ?: defaultSort
        }
    }

    /**
     * Set the book sort mode for a specific group.
     * Updates the group's bookSort field in the database.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBookSortByGroupId(groupId: Long, sort: Int) {
        runRecoverable("SettingsFacade.setBookSortByGroupId") {
            val repo = bookGroupRepository ?: error("BookGroupRepository not available")
            val group = repo.getBookGroupById(groupId)
                ?: error("BookGroup not found: $groupId")
            repo.update(group.copy(bookSort = sort))
        }
    }

    // MARK: - P1 Config Items

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setUserAgent(ua: String) {
        runRecoverable("SettingsFacade.setUserAgent") { preferencesStore.setUserAgent(ua) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTextSelectAble(enabled: Boolean) {
        runRecoverable("SettingsFacade.setTextSelectAble") { preferencesStore.setTextSelectAble(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setScreenOrientation(orientation: String?) {
        runRecoverable("SettingsFacade.setScreenOrientation") { preferencesStore.setScreenOrientation(orientation) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setBookExportFileName(template: String?) {
        runRecoverable("SettingsFacade.setBookExportFileName") { preferencesStore.setBookExportFileName(template) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEpisodeExportFileName(template: String?) {
        runRecoverable("SettingsFacade.setEpisodeExportFileName") { preferencesStore.setEpisodeExportFileName(template) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDefaultBookTreeUri(uri: String?) {
        runRecoverable("SettingsFacade.setDefaultBookTreeUri") { preferencesStore.setDefaultBookTreeUri(uri) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowDiscovery(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowDiscovery") { preferencesStore.setShowDiscovery(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowRSS(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowRSS") { preferencesStore.setShowRSS(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setAutoRefreshBook(enabled: Boolean) {
        runRecoverable("SettingsFacade.setAutoRefreshBook") { preferencesStore.setAutoRefreshBook(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setExportCharset(charset: String) {
        runRecoverable("SettingsFacade.setExportCharset") { preferencesStore.setExportCharset(charset) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setExportUseReplace(enabled: Boolean) {
        runRecoverable("SettingsFacade.setExportUseReplace") { preferencesStore.setExportUseReplace(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setExportToWebDav(enabled: Boolean) {
        runRecoverable("SettingsFacade.setExportToWebDav") { preferencesStore.setExportToWebDav(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setExportNoChapterName(enabled: Boolean) {
        runRecoverable("SettingsFacade.setExportNoChapterName") { preferencesStore.setExportNoChapterName(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnableCustomExport(enabled: Boolean) {
        runRecoverable("SettingsFacade.setEnableCustomExport") { preferencesStore.setEnableCustomExport(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setExportType(type: Int) {
        runRecoverable("SettingsFacade.setExportType") { preferencesStore.setExportType(type) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setExportPictureFile(enabled: Boolean) {
        runRecoverable("SettingsFacade.setExportPictureFile") { preferencesStore.setExportPictureFile(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setParallelExportBook(enabled: Boolean) {
        runRecoverable("SettingsFacade.setParallelExportBook") { preferencesStore.setParallelExportBook(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTtsEngine(engine: String?) {
        runRecoverable("SettingsFacade.setTtsEngine") { preferencesStore.setTtsEngine(engine) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTocUiUseReplace(enabled: Boolean) {
        runRecoverable("SettingsFacade.setTocUiUseReplace") { preferencesStore.setTocUiUseReplace(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setTocCountWords(enabled: Boolean) {
        runRecoverable("SettingsFacade.setTocCountWords") { preferencesStore.setTocCountWords(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnableReadRecord(enabled: Boolean) {
        runRecoverable("SettingsFacade.setEnableReadRecord") { preferencesStore.setEnableReadRecord(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setImportKeepName(enabled: Boolean) {
        runRecoverable("SettingsFacade.setImportKeepName") { preferencesStore.setImportKeepName(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setImportKeepGroup(enabled: Boolean) {
        runRecoverable("SettingsFacade.setImportKeepGroup") { preferencesStore.setImportKeepGroup(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setImportKeepEnable(enabled: Boolean) {
        runRecoverable("SettingsFacade.setImportKeepEnable") { preferencesStore.setImportKeepEnable(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setPreDownloadNum(num: Int) {
        runRecoverable("SettingsFacade.setPreDownloadNum") { preferencesStore.setPreDownloadNum(num) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMediaButtonOnExit(enabled: Boolean) {
        runRecoverable("SettingsFacade.setMediaButtonOnExit") { preferencesStore.setMediaButtonOnExit(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setReadAloudByMediaButton(enabled: Boolean) {
        runRecoverable("SettingsFacade.setReadAloudByMediaButton") { preferencesStore.setReadAloudByMediaButton(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setPauseReadAloudWhilePhoneCalls(enabled: Boolean) {
        runRecoverable("SettingsFacade.setPauseReadAloudWhilePhoneCalls") { preferencesStore.setPauseReadAloudWhilePhoneCalls(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setStreamReadAloudAudio(enabled: Boolean) {
        runRecoverable("SettingsFacade.setStreamReadAloudAudio") { preferencesStore.setStreamReadAloudAudio(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDoublePageHorizontal(value: String?) {
        runRecoverable("SettingsFacade.setDoublePageHorizontal") { preferencesStore.setDoublePageHorizontal(value) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setKeyPageOnLongPress(enabled: Boolean) {
        runRecoverable("SettingsFacade.setKeyPageOnLongPress") { preferencesStore.setKeyPageOnLongPress(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setVolumeKeyPage(enabled: Boolean) {
        runRecoverable("SettingsFacade.setVolumeKeyPage") { preferencesStore.setVolumeKeyPage(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setVolumeKeyPageOnPlay(enabled: Boolean) {
        runRecoverable("SettingsFacade.setVolumeKeyPageOnPlay") { preferencesStore.setVolumeKeyPageOnPlay(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMouseWheelPage(enabled: Boolean) {
        runRecoverable("SettingsFacade.setMouseWheelPage") { preferencesStore.setMouseWheelPage(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSearchScope(scope: String) {
        runRecoverable("SettingsFacade.setSearchScope") { preferencesStore.setSearchScope(scope) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setSearchGroup(group: String) {
        runRecoverable("SettingsFacade.setSearchGroup") { preferencesStore.setSearchGroup(group) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setShowMangaUi(enabled: Boolean) {
        runRecoverable("SettingsFacade.setShowMangaUi") { preferencesStore.setShowMangaUi(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDisableMangaScale(enabled: Boolean) {
        runRecoverable("SettingsFacade.setDisableMangaScale") { preferencesStore.setDisableMangaScale(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDisableMangaPageAnim(enabled: Boolean) {
        runRecoverable("SettingsFacade.setDisableMangaPageAnim") { preferencesStore.setDisableMangaPageAnim(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMangaPreDownloadNum(num: Int) {
        runRecoverable("SettingsFacade.setMangaPreDownloadNum") { preferencesStore.setMangaPreDownloadNum(num) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDisableClickScroll(enabled: Boolean) {
        runRecoverable("SettingsFacade.setDisableClickScroll") { preferencesStore.setDisableClickScroll(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMangaAutoPageSpeed(speed: Int) {
        runRecoverable("SettingsFacade.setMangaAutoPageSpeed") { preferencesStore.setMangaAutoPageSpeed(speed) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMangaFooterConfig(config: String) {
        runRecoverable("SettingsFacade.setMangaFooterConfig") { preferencesStore.setMangaFooterConfig(config) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnableMangaHorizontalScroll(enabled: Boolean) {
        runRecoverable("SettingsFacade.setEnableMangaHorizontalScroll") { preferencesStore.setEnableMangaHorizontalScroll(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMangaColorFilter(filter: String) {
        runRecoverable("SettingsFacade.setMangaColorFilter") { preferencesStore.setMangaColorFilter(filter) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setHideMangaTitle(enabled: Boolean) {
        runRecoverable("SettingsFacade.setHideMangaTitle") { preferencesStore.setHideMangaTitle(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnableMangaEInk(enabled: Boolean) {
        runRecoverable("SettingsFacade.setEnableMangaEInk") { preferencesStore.setEnableMangaEInk(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setMangaEInkThreshold(threshold: Int) {
        runRecoverable("SettingsFacade.setMangaEInkThreshold") { preferencesStore.setMangaEInkThreshold(threshold) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDisableHorizontalPageSnap(enabled: Boolean) {
        runRecoverable("SettingsFacade.setDisableHorizontalPageSnap") { preferencesStore.setDisableHorizontalPageSnap(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setEnableMangaGray(enabled: Boolean) {
        runRecoverable("SettingsFacade.setEnableMangaGray") { preferencesStore.setEnableMangaGray(enabled) }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setUseZhLayout(enabled: Boolean) {
        runRecoverable("SettingsFacade.setUseZhLayout") { preferencesStore.setUseZhLayout(enabled) }
    }

    // MARK: - DictRule management

    private val dictJson = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }

    fun watchDictRules(onUpdate: (List<DictRule>) -> Unit): FlowSubscription {
        val repo = dictRuleRepository ?: run {
            CrashCollector.record("SettingsFacade", "watchDictRules",
                error = IllegalStateException("DictRuleRepository not available"))
            return watchFlow(kotlinx.coroutines.flow.flowOf(emptyList()), onUpdate, label = "SettingsFacade.dictRules.fallback")
        }
        return watchFlow(repo.observeAll(), onUpdate, label = "SettingsFacade.dictRules")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadDictRules(): List<DictRule> {
        return runRecoverable("SettingsFacade.loadDictRules") {
            val repo = dictRuleRepository ?: error("DictRuleRepository not available")
            repo.getAll()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveDictRule(rule: DictRule): DictRule {
        return runRecoverable("SettingsFacade.saveDictRule") {
            val repo = dictRuleRepository ?: error("DictRuleRepository not available")
            repo.save(rule)
            rule
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteDictRule(name: String) {
        runRecoverable("SettingsFacade.deleteDictRule") {
            val repo = dictRuleRepository ?: error("DictRuleRepository not available")
            repo.delete(name)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setDictRuleEnabled(name: String, enabled: Boolean): DictRule {
        return runRecoverable("SettingsFacade.setDictRuleEnabled") {
            val repo = dictRuleRepository ?: error("DictRuleRepository not available")
            val current = repo.get(name) ?: error("DictRule not found: $name")
            val updated = current.copy(enabled = enabled)
            repo.save(updated)
            updated
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importDictRules(payload: String): Int {
        return runRecoverable("SettingsFacade.importDictRules") {
            val repo = dictRuleRepository ?: error("DictRuleRepository not available")
            val rules = try {
                dictJson.decodeFromString<List<DictRule>>(payload)
            } catch (e: Exception) {
                throw RecoverableSharedException("INVALID_DICT_RULE_JSON", "Invalid dict rule JSON: ${e.message}")
            }
            repo.saveAll(rules)
            rules.size
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun exportDictRules(names: List<String>): String {
        return runRecoverable("SettingsFacade.exportDictRules") {
            val repo = dictRuleRepository ?: error("DictRuleRepository not available")
            val allRules = repo.getAll()
            val filtered = if (names.isEmpty()) allRules else allRules.filter { it.name in names }
            dictJson.encodeToString(filtered)
        }
    }

    private val readerPresetSupport = SettingsReaderPresetSupport(preferencesStore)

    @Throws(RecoverableSharedException::class)
    fun decodeReaderPresets(jsonString: String): List<ReaderPreset> {
        return readerPresetSupport.decode(jsonString)
    }

    fun exportReaderPresetJson(name: String): String? {
        return readerPresetSupport.export(name)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importReaderPresetJson(jsonString: String) {
        readerPresetSupport.importLegacy(jsonString)
    }

    // MARK: - R-03: configList theme management (add/remove/reorder presets as list)

    /**
     * Add a new reader preset to the list.
     * Mirrors legado ReadBookConfig.configList.add().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addReaderPreset(preset: ReaderPreset) {
        runRecoverable("SettingsFacade.addReaderPreset") {
            preferencesStore.importReaderPreset(preset)
        }
    }

    /**
     * Reorder reader presets by providing the desired name order.
     * Names not in the list are appended at the end.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun reorderReaderPresets(orderedNames: List<String>) {
        readerPresetSupport.reorder(orderedNames)
    }

    // MARK: - R-07: save/initConfigs JSON

    /**
     * Export all reader presets as a JSON array string.
     * Mirrors legado ReadBookConfig.save() which serializes configList to JSON.
     */
    fun exportAllReaderPresetsJson(): String {
        return readerPresetSupport.exportAll()
    }

    /**
     * Import reader presets from a JSON array string, replacing existing presets.
     * Mirrors legado ReadBookConfig.initConfigs() which loads configList from JSON.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importAllReaderPresetsJson(jsonString: String) {
        readerPresetSupport.importAll(jsonString)
    }

    // MARK: - R-08: import ZIP themes

    /**
     * Import a reader theme from ZIP data.
     * Mirrors legado ReadBookConfig.Config.import(byteArray):
     * - Extracts readConfig.json from the ZIP
     * - Parses it as a ReaderPreset
     * - Font and background image files are noted but handled by platform layer
     *
     * @param zipEntries Map of file name to file content bytes extracted from the ZIP
     * @return The imported ReaderPreset
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importReaderPresetFromZip(zipEntries: Map<String, ByteArray>): ReaderPreset {
        return ReaderPresetTransferSupport(preferencesStore).importLegacyEntries(zipEntries)
    }

    @Throws(RecoverableSharedException::class)
    fun exportAndroidReaderPresetJson(name: String): String? =
        ReaderPresetTransferSupport(preferencesStore).export(name)

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun replaceAndroidReaderPreset(expectedName: String, jsonString: String, expectedIndex: Int? = null): ReaderPreset =
        ReaderPresetTransferSupport(preferencesStore).replace(expectedName, jsonString, expectedIndex)

    /** Upserts one named Android configuration without selecting another slot. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun importAndroidReaderPreset(jsonString: String): ReaderPreset =
        ReaderPresetTransferSupport(preferencesStore).importAndroid(jsonString)

    // MARK: - R-09: Background image management

    /**
     * R-09: Get all background image paths/identifiers from reader presets.
     * Mirrors legado ReadBookConfig.getAllPicBgStr() which collects
     * all bg/bgNight image strings from config list.
     */
    fun getAllBackgroundImages(): List<String> {
        val images = mutableListOf<String>()
        for (preset in preferencesStore.readerPresets) {
            preset.bgStr?.takeIf { it.isNotBlank() }?.let { images.add(it) }
            preset.bgStrNight?.takeIf { it.isNotBlank() }?.let { images.add(it) }
        }
        return images.distinct()
    }

    /**
     * R-09: Clear background image references from all presets.
     * Mirrors legado ReadBookConfig.clearBg() which nullifies bg fields.
     * Note: actual file deletion is handled by the platform layer.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearBackgroundCache() {
        runRecoverable("SettingsFacade.clearBackgroundCache") {
            val presets = preferencesStore.readerPresets
            for (preset in presets) {
                if (preset.bgStr != null || preset.bgStrNight != null) {
                    val cleared = preset.copy(bgStr = null, bgStrNight = null)
                    preferencesStore.deleteReaderPreset(preset.name)
                    preferencesStore.importReaderPreset(cleared)
                }
            }
        }
    }

    // MARK: - R-11: Export reader config for sharing

    /**
     * R-11: Export current reader configuration (active preset + style settings) as JSON
     * for sharing with other users. Mirrors legado ReadBookConfig.getExportConfig().
     */
    fun getExportReaderConfig(): String {
        return readerPresetSupport.exportAll()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun vacuumDatabase() {
        runRecoverable("SettingsFacade.vacuumDatabase") {
            database?.vacuum() ?: error("Database not available for VACUUM")
        }
    }

    // MARK: - Crash Reports

    /**
     * Get the number of recorded crash reports.
     */
    fun getCrashReportCount(): Int = CrashCollector.reportCount

    /**
     * Export all crash reports as Markdown for debugging.
     */
    fun exportCrashReports(): String = CrashCollector.exportMarkdown()

    /**
     * Clear all recorded crash reports.
     */
    fun clearCrashReports() = CrashCollector.clear()

    /**
     * Watch crash reports in real-time.
     */
    fun watchCrashReports(onCrash: (CrashReport) -> Unit): FlowSubscription {
        return watchFlow(CrashCollector.crashFlow, onCrash, "crashReports")
    }

    // MARK: - Backup & Restore

    private val backupSupport by lazy {
        SettingsBackupSupport(
            preferencesStore, txtTocRuleRepository, dictRuleRepository, bookRepository,
            bookSourceRepository, rssSourceRepository, replaceRuleRepository, bookGroupRepository,
            bookmarkRepository, searchKeywordRepository, readRecordRepository, rssStarRepository,
            ruleSubRepository, httpTTSRepository, keyboardAssistRepository, serverRepository,
            database,
        )
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun createBackup(password: String? = null): String = runRecoverable("SettingsFacade.createBackup") {
        backupSupport.createBackup(password)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun createAndroidBackupArchive(password: String? = null): AndroidBackupExport =
        runRecoverable("SettingsFacade.createAndroidBackupArchive") { backupSupport.createArchive(password) }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun restoreFromBackup(payload: String, password: String? = null): BackupRestoreResult =
        runRecoverable("SettingsFacade.restoreFromBackup") { backupSupport.restore(payload, password) }

    companion object {
        const val DEFAULT_WEBDAV_URL = SettingsWebDavSupport.DEFAULT_WEBDAV_URL
    }
}
