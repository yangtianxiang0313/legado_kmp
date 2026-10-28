package io.legado.kmp.shared.preferences

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

interface AppPreferencesStore {
    val preferences: Flow<AppUiPreferences>
    /** Lifecycle entry points need the current recording flag without suspending. */
    val runtimeConfig: StateFlow<AppRuntimeConfig>
    val themePresets: List<ThemePreset>
    val readerPresets: List<ReaderPreset>

    fun readerPresetForExport(name: String): ReaderPreset? = readerPresets.firstOrNull { it.name == name }

    fun getBackupConfigJson(key: String): String?

    fun setBackupConfigJson(key: String, value: String?)

    suspend fun exportBackupPreferences(): PreferencesBackupData

    suspend fun restoreBackupPreferences(data: PreferencesBackupData, ignoredKeys: Set<String>)

    suspend fun bootstrapDefaultsIfNeeded()

    suspend fun setThemeMode(mode: ThemeMode)

    suspend fun setBookshelfLayoutMode(mode: BookshelfLayoutMode)

    suspend fun setBookshelfSort(sort: Int)

    suspend fun setBookGroupStyle(style: Int)

    suspend fun setShowUnread(enabled: Boolean)

    suspend fun setShowLastUpdateTime(enabled: Boolean)

    suspend fun setShowWaitUpCount(enabled: Boolean)

    suspend fun setShowBookshelfFastScroller(enabled: Boolean)

    suspend fun setSaveTabPosition(position: Int)

    suspend fun setThemePreset(themeName: String)

    fun themePalette(isNightTheme: Boolean): ThemeColorPalette

    suspend fun setThemeColor(isNightTheme: Boolean, field: ThemeColorField, color: String)

    suspend fun saveThemePalette(themeName: String, isNightTheme: Boolean)

    suspend fun applyThemePreset(themeName: String)

    suspend fun importThemePreset(preset: ThemePreset)

    suspend fun deleteThemePreset(themeName: String)

    suspend fun setReaderPreset(name: String)

    suspend fun setReaderFontSize(fontSizeSp: Float)

    suspend fun setReaderFontSelection(
        fontName: String?,
        expectedName: String,
        expectedIndex: Int,
        expectedShareLayout: Boolean,
    )

    suspend fun setReaderLineSpacing(multiplier: Float)

    suspend fun setReaderQuickOption(
        option: ReaderAppearanceQuickOption,
        value: Int,
        expectedName: String,
        expectedIndex: Int,
        expectedShareLayout: Boolean,
    )

    suspend fun setReaderHorizontalPadding(paddingDp: Float)

    suspend fun setReaderBackgroundMode(mode: ReaderBackgroundMode)

    suspend fun setReaderStyle(style: ReaderStylePreferences)

    suspend fun setReaderLayout(style: ReaderStylePreferences)

    suspend fun setReaderStyleForVariant(
        style: ReaderStylePreferences,
        variant: ReaderVisualVariant,
        presetName: String? = null,
        expectedIndex: Int? = null,
    )

    suspend fun restoreReaderPreset(name: String, template: ReaderPreset, expectedIndex: Int? = null)

    suspend fun setThreadCount(count: Int)

    suspend fun setPrecisionSearch(enabled: Boolean)

    suspend fun setReplaceRuleEnabledByDefault(enabled: Boolean)

    suspend fun setIgnoreAudioFocus(enabled: Boolean)

    suspend fun setChangeSourceCheckAuthor(enabled: Boolean)

    suspend fun setChangeSourceLoadInfo(enabled: Boolean)

    suspend fun setChangeSourceLoadToc(enabled: Boolean)

    suspend fun setChangeSourceLoadWordCount(enabled: Boolean)

    suspend fun setAutoChangeSource(enabled: Boolean)

    suspend fun setWebDavUrl(url: String?)

    suspend fun setWebDavAccount(account: String?)

    suspend fun setWebDavPassword(password: String?)

    suspend fun setWebDavDir(dir: String)

    suspend fun setWebDavDeviceName(name: String?)

    suspend fun setSyncBookProgress(enabled: Boolean)

    suspend fun setSyncBookProgressPlus(enabled: Boolean)

    suspend fun setBackupPath(path: String?)

    suspend fun setBackupRestoreIgnoredKeys(keys: Set<String>)

    suspend fun setOnlyLatestBackup(enabled: Boolean)

    suspend fun setAutoCheckNewBackup(enabled: Boolean)

    suspend fun setRemoteServerId(id: Long)

    suspend fun setBrightnessDay(value: Int)

    suspend fun setBrightnessNight(value: Int)

    suspend fun setPageAnimation(value: Int)

    suspend fun setShareLayout(enabled: Boolean)

    suspend fun setReadStyleIndex(index: Int)

    suspend fun setComicStyleIndex(index: Int)

    suspend fun setAutoReadSpeed(value: Int)

    suspend fun setTextFullJustify(enabled: Boolean)

    suspend fun setTextBottomJustify(enabled: Boolean)

    suspend fun setHideStatusBar(enabled: Boolean)

    suspend fun setHideNavigationBar(enabled: Boolean)

    suspend fun setReaderRuntimeConfig(config: ReaderRuntimeConfig)

    suspend fun setTapZoneActions(actions: ReaderTapZoneActions)

    suspend fun renameReaderPreset(oldName: String, newName: String, expectedIndex: Int? = null)

    suspend fun deleteReaderPreset(name: String, expectedIndex: Int? = null)

    suspend fun importReaderPreset(preset: ReaderPreset)

    /** Exact-name catalog upsert; never selects a new slot, renames, or clears unrelated entries. */
    suspend fun upsertReaderPresetWithoutSelecting(preset: ReaderPreset): ReaderPreset

    /** Replaces one slot verbatim; a supplied index must still be selected with the expected name before any writes. */
    suspend fun replaceReaderPreset(expectedName: String, preset: ReaderPreset, expectedIndex: Int? = null): ReaderPreset

    // M-03
    suspend fun setUserAgent(ua: String)
    // M-07
    suspend fun setTextSelectAble(enabled: Boolean)
    // M-10
    suspend fun setScreenOrientation(orientation: String?)
    // M-11
    suspend fun setBookExportFileName(template: String?)
    suspend fun setEpisodeExportFileName(template: String?)
    // M-13
    suspend fun setDefaultBookTreeUri(uri: String?)
    // M-14
    suspend fun setShowDiscovery(enabled: Boolean)
    suspend fun setShowRSS(enabled: Boolean)
    // M-15
    suspend fun setAutoRefreshBook(enabled: Boolean)
    // M-19
    suspend fun setExportCharset(charset: String)
    suspend fun setExportUseReplace(enabled: Boolean)
    suspend fun setExportToWebDav(enabled: Boolean)
    suspend fun setExportNoChapterName(enabled: Boolean)
    suspend fun setEnableCustomExport(enabled: Boolean)
    suspend fun setExportType(type: Int)
    suspend fun setExportPictureFile(enabled: Boolean)
    suspend fun setParallelExportBook(enabled: Boolean)
    // M-21
    suspend fun setTtsEngine(engine: String?)
    // M-23
    suspend fun setTocUiUseReplace(enabled: Boolean)
    suspend fun setTocCountWords(enabled: Boolean)
    // M-24
    suspend fun setEnableReadRecord(enabled: Boolean)
    // M-28
    suspend fun setImportKeepName(enabled: Boolean)
    suspend fun setImportKeepGroup(enabled: Boolean)
    suspend fun setImportKeepEnable(enabled: Boolean)
    // M-30
    suspend fun setPreDownloadNum(num: Int)
    // M-31
    suspend fun setMediaButtonOnExit(enabled: Boolean)
    suspend fun setReadAloudByMediaButton(enabled: Boolean)
    suspend fun setPauseReadAloudWhilePhoneCalls(enabled: Boolean)
    suspend fun setStreamReadAloudAudio(enabled: Boolean)
    // M-32
    suspend fun setDoublePageHorizontal(value: String?)
    // M-34
    suspend fun setKeyPageOnLongPress(enabled: Boolean)
    suspend fun setVolumeKeyPage(enabled: Boolean)
    suspend fun setVolumeKeyPageOnPlay(enabled: Boolean)
    suspend fun setMouseWheelPage(enabled: Boolean)
    // M-36
    suspend fun setSearchScope(scope: String)
    suspend fun setSearchGroup(group: String)
    // M-44
    suspend fun setShowMangaUi(enabled: Boolean)
    suspend fun setDisableMangaScale(enabled: Boolean)
    suspend fun setDisableMangaPageAnim(enabled: Boolean)
    suspend fun setMangaPreDownloadNum(num: Int)
    suspend fun setDisableClickScroll(enabled: Boolean)
    suspend fun setMangaAutoPageSpeed(speed: Int)
    suspend fun setMangaFooterConfig(config: String)
    suspend fun setEnableMangaHorizontalScroll(enabled: Boolean)
    suspend fun setMangaColorFilter(filter: String)
    suspend fun setHideMangaTitle(enabled: Boolean)
    suspend fun setEnableMangaEInk(enabled: Boolean)
    suspend fun setMangaEInkThreshold(threshold: Int)
    suspend fun setDisableHorizontalPageSnap(enabled: Boolean)
    suspend fun setEnableMangaGray(enabled: Boolean)
    // R-05
    suspend fun setUseZhLayout(enabled: Boolean)
    // R-04
    suspend fun setReadBodyToLh(enabled: Boolean)
    // R-06
    suspend fun setIsComic(enabled: Boolean)
    // M-01
    suspend fun setIsCronet(enabled: Boolean)
    // M-02
    suspend fun setUseAntiAlias(enabled: Boolean)
    // M-04
    suspend fun setUseDefaultCover(enabled: Boolean)
    // M-05
    suspend fun setOptimizeRender(enabled: Boolean)
    // M-06
    suspend fun setRecordLog(enabled: Boolean)
    // M-08
    suspend fun setIsTransparentStatusBar(enabled: Boolean)
    // M-09
    suspend fun setImmNavigationBar(enabled: Boolean)
    // M-12
    suspend fun setBookImportFileName(template: String?)
    // M-16
    suspend fun setEnableReview(enabled: Boolean)
    // M-17
    suspend fun setImportBookPath(path: String?)
    // M-18
    suspend fun setNoAnimScrollPage(enabled: Boolean)
    // M-22
    suspend fun setWebPort(port: Int)
    // M-25
    suspend fun setOpenBookInfoByClickTitle(enabled: Boolean)
    // M-26
    suspend fun setContentSelectSpeakMod(mod: Int)
    // M-27
    suspend fun setBatchChangeSourceDelay(delay: Int)
    // M-29
    suspend fun setPreviewImageByClick(enabled: Boolean)
    // M-33
    suspend fun setProgressBarBehavior(behavior: String)
    // M-35
    suspend fun setPaddingDisplayCutouts(enabled: Boolean)
    // M-37
    suspend fun setPageTouchSlop(slop: Int)
    // M-38
    suspend fun setBitmapCacheSize(size: Int)
    suspend fun setImageRetainNum(num: Int)
    // M-39
    suspend fun setShowReadTitleBarAddition(enabled: Boolean)
    suspend fun setReadBarStyleFollowPage(enabled: Boolean)
    // M-40
    suspend fun setSourceEditMaxLine(maxLine: Int)
    // M-41
    suspend fun setAudioPlayUseWakeLock(enabled: Boolean)
    // A02: Audio play mode persistence
    suspend fun setAudioPlayMode(mode: Int)
    // M-42
    suspend fun setBrightnessVwPos(enabled: Boolean)
    // M-45
    suspend fun setWelcomeImage(path: String?)
    suspend fun setWelcomeShowText(enabled: Boolean)
    suspend fun setWelcomeShowIcon(enabled: Boolean)
    suspend fun setWelcomeImageDark(path: String?)
    suspend fun setWelcomeShowTextDark(enabled: Boolean)
    suspend fun setWelcomeShowIconDark(enabled: Boolean)
    // M-46
    suspend fun setDefaultHomePage(page: String)
    // M-47
    suspend fun setUpdateToVariant(variant: String)
    // M-48
    suspend fun setLoadCoverOnlyWifi(enabled: Boolean)
    // M-49
    suspend fun setShowAddToShelfAlert(enabled: Boolean)
    // B-01
    suspend fun setBookInfoDeleteAlert(enabled: Boolean)
    // M-50
    suspend fun setRecordHeapDump(enabled: Boolean)
}
