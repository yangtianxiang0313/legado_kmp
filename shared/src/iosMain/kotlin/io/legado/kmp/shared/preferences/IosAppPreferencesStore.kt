package io.legado.kmp.shared.preferences

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSUserDefaults
import platform.Foundation.NSUserDefaultsDidChangeNotification
import platform.UIKit.UIDevice

class IosAppPreferencesStore : AppPreferencesStore {
    private val defaults = NSUserDefaults.standardUserDefaults
    private val userAgentPreference = IosUserAgentPreference(defaults)
    private val readerPresetPersistence = IosReaderPresetPersistence(defaults)
    private val themePresetPersistence = IosThemePresetPersistence(defaults)
    override val themePresets: List<ThemePreset> get() = themePresetPersistence.presets
    override var readerPresets: List<ReaderPreset>
        get() = readerPresetPersistence.presets
        private set(value) { readerPresetPersistence.presets = value }

    private val uiState = MutableStateFlow(readPreferences())
    private val runtimeState = MutableStateFlow(readRuntimeConfig())

    override val preferences = uiState.asStateFlow()
    override val runtimeConfig = runtimeState.asStateFlow()

    override fun getBackupConfigJson(key: String): String? = IosPreferencesBackup.getConfig(defaults, key)

    override fun setBackupConfigJson(key: String, value: String?) {
        IosPreferencesBackup.setConfig(defaults, key, value)
    }

    override suspend fun exportBackupPreferences(): PreferencesBackupData =
        IosPreferencesBackup.export(defaults, readerPresets.mapIndexed { index, preset ->
            if (index == currentReaderPresetIndex()) defaults.readerPresetWithLegacyActiveValues(preset) else preset
        }, themePresets).withReaderSharedLayout(defaults)

    override suspend fun restoreBackupPreferences(data: PreferencesBackupData, ignoredKeys: Set<String>) {
        materializeLegacyReaderPresetValues()
        IosPreferencesBackup.restore(defaults, data, ignoredKeys)
        defaults.restoreReaderSharedLayout(data, ignoredKeys)
        readerPresetPersistence.reload()
        themePresetPersistence.reload()
        // Android presets contain the active layout; iOS snapshots already contain its exact defaults.
        if (BackupRestoreIgnoreKeys.READ_CONFIG !in ignoredKeys && data.readConfig.isNotEmpty() &&
            data.appConfig.keys.none { it in READER_STYLE_PREFERENCE_KEYS }) {
            val index = defaults.integerForKey(KEY_READ_STYLE_INDEX).toInt().coerceIn(0, readerPresets.lastIndex)
            val preset = readerPresets[index]
            val independent = IosPreferencesBackup.readerStyle(preset, defaults.stringForKey(KEY_THEME_MODE))
            val shared = defaults.readReaderSharedLayout().takeIf { defaults.boolForKey(KEY_SHARE_LAYOUT) }
            defaults.writeReaderStyle(preset.name, shared?.let(independent::withSharedLayoutFrom) ?: independent)
            defaults.setBool(true, KEY_READER_LINE_SPACING_ANDROID_SCALE_MIGRATED)
            defaults.synchronize()
        }
        refresh()
    }

    override suspend fun bootstrapDefaultsIfNeeded() {
        if (defaults.boolForKey(KEY_INITIALIZED)) return
        if (IosPreferencesBackup.hasStoredPreferences(defaults)) {
            materializeLegacyReaderPresetValues()
            themePresetPersistence.pinCatalogIfMissing()
            defaults.setBool(true, KEY_INITIALIZED)
            defaults.synchronize()
            refresh()
            return
        }
        val themePreset = themePresets.firstOrNull() ?: DefaultUiPresets.themePresets.first()
        val readerPreset = readerPresets.first()
        val readerStyle = readerPreset.toReaderStylePreferences()
        // Pin the fresh catalog before initialized would identify an old three-preset install.
        persistReaderPresets()
        themePresetPersistence.pinCatalogIfMissing()
        defaults.setBool(true, KEY_READER_LINE_SPACING_ANDROID_SCALE_MIGRATED)
        defaults.setBool(true, KEY_INITIALIZED)
        defaults.setObject(ThemeMode.SYSTEM.name, KEY_THEME_MODE)
        defaults.setInteger(BookshelfLayoutMode.LIST.legacyIndex.toLong(), KEY_BOOKSHELF_LAYOUT_INDEX)
        defaults.setObject(BookshelfLayoutMode.LIST.name, KEY_BOOKSHELF_LAYOUT)
        defaults.setInteger(0, KEY_BOOKSHELF_SORT)
        defaults.setInteger(0, KEY_BOOK_GROUP_STYLE)
        defaults.setBool(true, KEY_SHOW_UNREAD)
        defaults.setBool(false, KEY_SHOW_LAST_UPDATE_TIME)
        defaults.setBool(false, KEY_SHOW_WAIT_UP_COUNT)
        defaults.setBool(false, KEY_SHOW_BOOKSHELF_FAST_SCROLLER)
        defaults.setInteger(0, KEY_SAVE_TAB_POSITION)
        defaults.setObject(themePreset.themeName, KEY_THEME_PRESET)
        defaults.setObject(readerPreset.name, KEY_READER_PRESET)
        defaults.setFloat(readerStyle.fontSizeSp, KEY_READER_FONT_SIZE)
        defaults.setFloat(readerStyle.lineSpacingMultiplier, KEY_READER_LINE_SPACING)
        defaults.setFloat(readerStyle.horizontalPaddingDp, KEY_READER_HORIZONTAL_PADDING)
        defaults.setObject(readerStyle.backgroundMode.name, KEY_READER_BACKGROUND)
        defaults.setNullableString(KEY_READER_FONT_NAME, readerStyle.fontName)
        defaults.setNullableString(KEY_READER_BACKGROUND_HEX, readerStyle.backgroundColorHex)
        defaults.setNullableString(KEY_READER_TEXT_HEX, readerStyle.textColorHex)
        defaults.setInteger(readerStyle.textBold.toLong(), KEY_READER_TEXT_BOLD)
        defaults.setFloat(readerStyle.letterSpacing, KEY_READER_LETTER_SPACING)
        defaults.setInteger(readerStyle.paragraphSpacing.toLong(), KEY_READER_PARAGRAPH_SPACING)
        defaults.setInteger(readerStyle.paragraphIndent.toLong(), KEY_READER_PARAGRAPH_INDENT)
        defaults.setBool(readerStyle.underline, KEY_READER_UNDERLINE)
        defaults.setInteger(readerStyle.backgroundAlpha.toLong(), KEY_READER_BACKGROUND_ALPHA)
        defaults.setNullableString(KEY_READER_BACKGROUND_IMAGE_PATH, readerStyle.backgroundImagePath)
        defaults.setBool(readerStyle.darkStatusIcon, KEY_READER_DARK_STATUS_ICON)
        defaults.setInteger(readerStyle.titleMode.toLong(), KEY_READER_TITLE_MODE)
        defaults.setFloat(readerStyle.titleSize, KEY_READER_TITLE_SIZE)
        defaults.setInteger(readerStyle.titleTopSpacing.toLong(), KEY_READER_TITLE_TOP_SPACING)
        defaults.setInteger(readerStyle.titleBottomSpacing.toLong(), KEY_READER_TITLE_BOTTOM_SPACING)
        defaults.setInteger(readerStyle.paddingTop.toLong(), KEY_READER_PADDING_TOP)
        defaults.setInteger(readerStyle.paddingBottom.toLong(), KEY_READER_PADDING_BOTTOM)
        defaults.setInteger(readerStyle.paddingLeft.toLong(), KEY_READER_PADDING_LEFT)
        defaults.setInteger(readerStyle.paddingRight.toLong(), KEY_READER_PADDING_RIGHT)
        defaults.setInteger(readerStyle.headerPaddingTop.toLong(), KEY_READER_HEADER_PADDING_TOP)
        defaults.setInteger(readerStyle.headerPaddingBottom.toLong(), KEY_READER_HEADER_PADDING_BOTTOM)
        defaults.setInteger(readerStyle.headerPaddingLeft.toLong(), KEY_READER_HEADER_PADDING_LEFT)
        defaults.setInteger(readerStyle.headerPaddingRight.toLong(), KEY_READER_HEADER_PADDING_RIGHT)
        defaults.setInteger(readerStyle.footerPaddingTop.toLong(), KEY_READER_FOOTER_PADDING_TOP)
        defaults.setInteger(readerStyle.footerPaddingBottom.toLong(), KEY_READER_FOOTER_PADDING_BOTTOM)
        defaults.setInteger(readerStyle.footerPaddingLeft.toLong(), KEY_READER_FOOTER_PADDING_LEFT)
        defaults.setInteger(readerStyle.footerPaddingRight.toLong(), KEY_READER_FOOTER_PADDING_RIGHT)
        defaults.setBool(readerStyle.showHeaderLine, KEY_READER_SHOW_HEADER_LINE)
        defaults.setBool(readerStyle.showFooterLine, KEY_READER_SHOW_FOOTER_LINE)
        defaults.setInteger(readerStyle.tipHeaderLeft.toLong(), KEY_READER_TIP_HEADER_LEFT)
        defaults.setInteger(readerStyle.tipHeaderMiddle.toLong(), KEY_READER_TIP_HEADER_MIDDLE)
        defaults.setInteger(readerStyle.tipHeaderRight.toLong(), KEY_READER_TIP_HEADER_RIGHT)
        defaults.setInteger(readerStyle.tipFooterLeft.toLong(), KEY_READER_TIP_FOOTER_LEFT)
        defaults.setInteger(readerStyle.tipFooterMiddle.toLong(), KEY_READER_TIP_FOOTER_MIDDLE)
        defaults.setInteger(readerStyle.tipFooterRight.toLong(), KEY_READER_TIP_FOOTER_RIGHT)
        defaults.setNullableString(KEY_READER_TIP_COLOR_HEX, readerStyle.tipColorHex)
        defaults.setNullableString(KEY_READER_TIP_DIVIDER_COLOR_HEX, readerStyle.tipDividerColorHex)
        defaults.setInteger(readerStyle.headerMode.toLong(), KEY_READER_HEADER_MODE)
        defaults.setInteger(readerStyle.footerMode.toLong(), KEY_READER_FOOTER_MODE)
        defaults.setInteger(16, KEY_THREAD_COUNT)
        defaults.setBool(false, KEY_PRECISION_SEARCH)
        defaults.setBool(true, KEY_REPLACE_RULE_ENABLED_BY_DEFAULT)
        defaults.setBool(false, KEY_IGNORE_AUDIO_FOCUS)
        defaults.setInteger(0, KEY_REMOTE_SERVER_ID)
        defaults.setInteger(100, KEY_BRIGHTNESS_DAY)
        defaults.setInteger(100, KEY_BRIGHTNESS_NIGHT)
        defaults.setInteger(0, KEY_PAGE_ANIMATION)
        defaults.setBool(false, KEY_SHARE_LAYOUT)
        defaults.setInteger(0, KEY_READ_STYLE_INDEX)
        defaults.setInteger(0, KEY_COMIC_STYLE_INDEX)
        defaults.setInteger(10, KEY_AUTO_READ_SPEED)
        defaults.setBool(true, KEY_TTS_FOLLOW_SYSTEM_RATE)
        defaults.setInteger(5, KEY_TTS_SPEECH_RATE)
        defaults.setInteger(0, KEY_TTS_TIMER_MINUTES)
        defaults.setNullableString(KEY_TTS_VOICE_IDENTIFIER, null)
        defaults.setBool(true, KEY_TEXT_FULL_JUSTIFY)
        defaults.setBool(true, KEY_TEXT_BOTTOM_JUSTIFY)
        defaults.setBool(false, KEY_HIDE_STATUS_BAR)
        defaults.setBool(false, KEY_HIDE_NAVIGATION_BAR)
        defaults.setInteger(0, KEY_READER_CHINESE_MODE)
        defaults.setInteger(2, KEY_TAP_TOP_LEFT)
        defaults.setInteger(2, KEY_TAP_TOP_CENTER)
        defaults.setInteger(1, KEY_TAP_TOP_RIGHT)
        defaults.setInteger(2, KEY_TAP_MIDDLE_LEFT)
        defaults.setInteger(0, KEY_TAP_MIDDLE_CENTER)
        defaults.setInteger(1, KEY_TAP_MIDDLE_RIGHT)
        defaults.setInteger(2, KEY_TAP_BOTTOM_LEFT)
        defaults.setInteger(1, KEY_TAP_BOTTOM_CENTER)
        defaults.setInteger(1, KEY_TAP_BOTTOM_RIGHT)
        defaults.synchronize()
        refresh()
    }

    override suspend fun setThemeMode(mode: ThemeMode) = write {
        setObject(mode.name, KEY_THEME_MODE)
        readerPresetPersistence.writeActivePageAnimation()
    }

    override suspend fun setBookshelfLayoutMode(mode: BookshelfLayoutMode) = write {
        setInteger(mode.legacyIndex.toLong(), KEY_BOOKSHELF_LAYOUT_INDEX)
        setObject(mode.name, KEY_BOOKSHELF_LAYOUT)
    }

    override suspend fun setBookshelfSort(sort: Int) = write {
        setInteger(sort.coerceIn(0, 5).toLong(), KEY_BOOKSHELF_SORT)
    }

    override suspend fun setBookGroupStyle(style: Int) = write {
        setInteger(style.coerceAtLeast(0).toLong(), KEY_BOOK_GROUP_STYLE)
    }

    override suspend fun setShowUnread(enabled: Boolean) = write {
        setBool(enabled, KEY_SHOW_UNREAD)
    }

    override suspend fun setShowLastUpdateTime(enabled: Boolean) = write {
        setBool(enabled, KEY_SHOW_LAST_UPDATE_TIME)
    }

    override suspend fun setShowWaitUpCount(enabled: Boolean) = write {
        setBool(enabled, KEY_SHOW_WAIT_UP_COUNT)
    }

    override suspend fun setShowBookshelfFastScroller(enabled: Boolean) = write {
        setBool(enabled, KEY_SHOW_BOOKSHELF_FAST_SCROLLER)
    }

    override suspend fun setSaveTabPosition(position: Int) = write {
        setInteger(position.coerceAtLeast(0).toLong(), KEY_SAVE_TAB_POSITION)
    }

    override suspend fun setThemePreset(themeName: String) {
        themePresetPersistence.apply(themeName, switchMode = false)
        refreshThemePreferences()
    }

    override fun themePalette(isNightTheme: Boolean): ThemeColorPalette = themePresetPersistence.palette(isNightTheme)

    override suspend fun setThemeColor(isNightTheme: Boolean, field: ThemeColorField, color: String) {
        themePresetPersistence.setColor(isNightTheme, field, color)
        refreshThemePreferences()
    }

    override suspend fun saveThemePalette(themeName: String, isNightTheme: Boolean) {
        themePresetPersistence.savePalette(themeName, isNightTheme)
        refreshThemePreferences()
    }

    override suspend fun applyThemePreset(themeName: String) {
        themePresetPersistence.apply(themeName, switchMode = true)
        readerPresetPersistence.writeActivePageAnimation()
        refreshThemePreferences()
    }

    override suspend fun importThemePreset(preset: ThemePreset) {
        themePresetPersistence.import(preset)
        refreshThemePreferences()
    }

    override suspend fun deleteThemePreset(themeName: String) {
        themePresetPersistence.delete(themeName)
        refreshThemePreferences()
    }

    override suspend fun setReaderPreset(name: String) {
        val presetIndex = readerPresetPersistence.mutationIndex(name, null)
        if (presetIndex < 0) return
        setReadStyleIndex(presetIndex)
    }

    override suspend fun setReaderFontSize(fontSizeSp: Float) = write {
        setFloat(fontSizeSp.coerceIn(5f, 50f), KEY_READER_FONT_SIZE)
        persistCurrentReaderLayout(readPreferences().readerStyle.copy(fontSizeSp = floatForKey(KEY_READER_FONT_SIZE)))
    }

    override suspend fun setReaderFontSelection(
        fontName: String?,
        expectedName: String,
        expectedIndex: Int,
        expectedShareLayout: Boolean,
    ) {
        // Reject stale requests before write() can materialize any legacy state.
        readerPresetPersistence.selectedMutationIndex(expectedName, expectedIndex)
        check(defaults.boolForKey(KEY_SHARE_LAYOUT) == expectedShareLayout) {
            "Reader layout sharing changed: expected $expectedShareLayout"
        }
        write {
            setNullableString(KEY_READER_FONT_NAME, fontName)
            persistCurrentReaderLayout(readPreferences().readerStyle.copy(fontName = fontName))
        }
    }

    override suspend fun setReaderLineSpacing(multiplier: Float) = write {
        setFloat(multiplier.coerceIn(0f, 2f), KEY_READER_LINE_SPACING)
        persistCurrentReaderLayout(readPreferences().readerStyle.copy(lineSpacingMultiplier = floatForKey(KEY_READER_LINE_SPACING)))
    }

    override suspend fun setReaderQuickOption(
        option: ReaderAppearanceQuickOption,
        value: Int,
        expectedName: String,
        expectedIndex: Int,
        expectedShareLayout: Boolean,
    ) {
        val allowed = if (option == ReaderAppearanceQuickOption.PARAGRAPH_INDENT) 0..4 else 0..2
        require(value in allowed) { "Invalid reader quick option: $option=$value" }
        readerPresetPersistence.selectedMutationIndex(expectedName, expectedIndex)
        check(defaults.boolForKey(KEY_SHARE_LAYOUT) == expectedShareLayout) {
            "Reader layout sharing changed: expected $expectedShareLayout"
        }
        write {
            when (option) {
                ReaderAppearanceQuickOption.FONT_WEIGHT -> {
                    setInteger(value.toLong(), KEY_READER_TEXT_BOLD)
                    persistCurrentReaderLayout(readPreferences().readerStyle.copy(textBold = value))
                }
                ReaderAppearanceQuickOption.PARAGRAPH_INDENT -> {
                    setInteger(value.toLong(), KEY_READER_PARAGRAPH_INDENT)
                    persistCurrentReaderLayout(readPreferences().readerStyle.copy(paragraphIndent = value))
                }
                ReaderAppearanceQuickOption.CHINESE_MODE -> setInteger(value.toLong(), KEY_READER_CHINESE_MODE)
            }
        }
    }

    override suspend fun setReaderHorizontalPadding(paddingDp: Float) = write {
        val padding = paddingDp.coerceIn(12f, 36f)
        setFloat(padding, KEY_READER_HORIZONTAL_PADDING)
        setInteger(padding.toInt().toLong(), KEY_READER_PADDING_LEFT)
        setInteger(padding.toInt().toLong(), KEY_READER_PADDING_RIGHT)
        setInteger(padding.toInt().toLong(), KEY_READER_HEADER_PADDING_LEFT)
        setInteger(padding.toInt().toLong(), KEY_READER_HEADER_PADDING_RIGHT)
        setInteger(padding.toInt().toLong(), KEY_READER_FOOTER_PADDING_LEFT)
        setInteger(padding.toInt().toLong(), KEY_READER_FOOTER_PADDING_RIGHT)
        persistCurrentReaderLayout(readPreferences().readerStyle.copy(
            horizontalPaddingDp = padding,
            paddingLeft = padding.toInt(), paddingRight = padding.toInt(),
            headerPaddingLeft = padding.toInt(), headerPaddingRight = padding.toInt(),
            footerPaddingLeft = padding.toInt(), footerPaddingRight = padding.toInt(),
        ))
    }

    override suspend fun setReaderBackgroundMode(mode: ReaderBackgroundMode) {
        setReaderStyle(readPreferences().readerStyle.withBackgroundModeDefaults(mode).copy(backgroundImagePath = null))
    }

    override suspend fun setReaderStyle(style: ReaderStylePreferences) {
        setReaderStyleForVariant(style, defaults.readerVisualVariant(), null)
    }

    override suspend fun setReaderLayout(style: ReaderStylePreferences) = write {
        val effective = readPreferences().readerStyle.withSharedLayoutFrom(style)
        writeReaderStylePreferences(effective)
        persistCurrentReaderLayout(readReaderActiveStyle(effective))
    }

    override suspend fun setReaderStyleForVariant(
        style: ReaderStylePreferences,
        variant: ReaderVisualVariant,
        presetName: String?,
        expectedIndex: Int?,
    ) {
        val index = readerPresetPersistence.selectedMutationIndex(presetName, expectedIndex)
        require(index >= 0) { "Reader preset not found: $presetName" }
        write {
            writeReaderStylePreferences(style)
            val storedStyle = readReaderActiveStyle(style)
            if (boolForKey(KEY_SHARE_LAYOUT)) writeReaderSharedLayout(storedStyle)
            readerPresetPersistence.updateVisual(index, storedStyle, variant)
            writeReaderStyleSnapshot(readerPresets[index].name, readPreferences().readerStyle)
        }
    }

    override suspend fun restoreReaderPreset(name: String, template: ReaderPreset, expectedIndex: Int?) {
        val index = readerPresetPersistence.mutationIndex(name, expectedIndex)
        require(index >= 0) { "Reader preset not found: $name" }
        write {
            readerPresetPersistence.replace(index, template)
        }
    }

    override suspend fun setThreadCount(count: Int) = write {
        setInteger(count.coerceIn(1, 999).toLong(), KEY_THREAD_COUNT)
    }

    override suspend fun setPrecisionSearch(enabled: Boolean) = write {
        setBool(enabled, KEY_PRECISION_SEARCH)
    }

    override suspend fun setReplaceRuleEnabledByDefault(enabled: Boolean) = write {
        setBool(enabled, KEY_REPLACE_RULE_ENABLED_BY_DEFAULT)
    }

    override suspend fun setIgnoreAudioFocus(enabled: Boolean) = write {
        setBool(enabled, KEY_IGNORE_AUDIO_FOCUS)
    }

    override suspend fun setChangeSourceCheckAuthor(enabled: Boolean) = write {
        setBool(enabled, KEY_CHANGE_SOURCE_CHECK_AUTHOR)
    }

    override suspend fun setChangeSourceLoadInfo(enabled: Boolean) = write {
        setBool(enabled, KEY_CHANGE_SOURCE_LOAD_INFO)
    }

    override suspend fun setChangeSourceLoadToc(enabled: Boolean) = write {
        setBool(enabled, KEY_CHANGE_SOURCE_LOAD_TOC)
    }

    override suspend fun setChangeSourceLoadWordCount(enabled: Boolean) = write {
        setBool(enabled, KEY_CHANGE_SOURCE_LOAD_WORD_COUNT)
    }

    override suspend fun setAutoChangeSource(enabled: Boolean) = write {
        setBool(enabled, KEY_AUTO_CHANGE_SOURCE)
    }

    override suspend fun setWebDavUrl(url: String?) = write {
        setNullableString(KEY_WEB_DAV_URL, url?.trim()?.ifEmpty { null })
    }

    override suspend fun setWebDavAccount(account: String?) = write {
        setNullableString(KEY_WEB_DAV_ACCOUNT, account?.ifEmpty { null })
    }

    override suspend fun setWebDavPassword(password: String?) = write {
        setNullableString(KEY_WEB_DAV_PASSWORD, password?.ifEmpty { null })
    }

    override suspend fun setWebDavDir(dir: String) = write {
        setNullableString(KEY_WEB_DAV_DIR, dir.trim().ifEmpty { "legado" })
    }

    override suspend fun setWebDavDeviceName(name: String?) = write {
        setNullableString(KEY_WEB_DAV_DEVICE_NAME, name?.trim()?.ifEmpty { null })
    }

    override suspend fun setSyncBookProgress(enabled: Boolean) = write {
        setBool(enabled, KEY_SYNC_BOOK_PROGRESS)
    }

    override suspend fun setSyncBookProgressPlus(enabled: Boolean) = write {
        setBool(enabled, KEY_SYNC_BOOK_PROGRESS_PLUS)
    }

    override suspend fun setBackupPath(path: String?) = write {
        setNullableString(KEY_BACKUP_PATH, path)
    }

    override suspend fun setBackupRestoreIgnoredKeys(keys: Set<String>) = write {
        setNullableString(KEY_BACKUP_RESTORE_IGNORED_KEYS, keys.sorted().joinToString(",").ifEmpty { null })
    }

    override suspend fun setOnlyLatestBackup(enabled: Boolean) = write {
        setBool(enabled, KEY_ONLY_LATEST_BACKUP)
    }

    override suspend fun setAutoCheckNewBackup(enabled: Boolean) = write {
        setBool(enabled, KEY_AUTO_CHECK_NEW_BACKUP)
    }

    override suspend fun setRemoteServerId(id: Long) = write {
        setInteger(id.coerceAtLeast(0L), KEY_REMOTE_SERVER_ID)
    }

    override suspend fun setBrightnessDay(value: Int) = write {
        setInteger(value.coerceIn(1, 100).toLong(), KEY_BRIGHTNESS_DAY)
    }

    override suspend fun setBrightnessNight(value: Int) = write {
        setInteger(value.coerceIn(1, 100).toLong(), KEY_BRIGHTNESS_NIGHT)
    }

    override suspend fun setPageAnimation(value: Int) = write {
        readerPresetPersistence.setCurrentPageAnimation(value)
    }

    override suspend fun setShareLayout(enabled: Boolean) = write {
        if (enabled == boolForKey(KEY_SHARE_LAYOUT)) return@write
        changeReaderSelection(currentReaderPresetIndex(), enabled, keepVisual = true)
    }

    override suspend fun setReadStyleIndex(index: Int) = write {
        changeReaderSelection(index, boolForKey(KEY_SHARE_LAYOUT))
    }

    override suspend fun setComicStyleIndex(index: Int) = write {
        setInteger(index.coerceAtLeast(0).toLong(), KEY_COMIC_STYLE_INDEX)
    }

    override suspend fun setAutoReadSpeed(value: Int) = write {
        setInteger(value.coerceIn(1, 300).toLong(), KEY_AUTO_READ_SPEED)
    }

    override suspend fun setTextFullJustify(enabled: Boolean) = write {
        setBool(enabled, KEY_TEXT_FULL_JUSTIFY)
    }

    override suspend fun setTextBottomJustify(enabled: Boolean) = write {
        setBool(enabled, KEY_TEXT_BOTTOM_JUSTIFY)
    }

    override suspend fun setHideStatusBar(enabled: Boolean) = write {
        setBool(enabled, KEY_HIDE_STATUS_BAR)
    }

    override suspend fun setHideNavigationBar(enabled: Boolean) = write {
        setBool(enabled, KEY_HIDE_NAVIGATION_BAR)
    }

    override suspend fun setReaderRuntimeConfig(config: ReaderRuntimeConfig) = write {
        val previousIndex = currentReaderPresetIndex()
        val readerIndex = config.readStyleIndex.coerceIn(0, (readerPresets.size - 1).coerceAtLeast(0))
        if (config.shareLayout != boolForKey(KEY_SHARE_LAYOUT) || readerIndex != currentReaderPresetIndex()) {
            changeReaderSelection(readerIndex, config.shareLayout, keepVisual = readerIndex == currentReaderPresetIndex())
        }
        setInteger(config.brightnessDay.coerceIn(1, 100).toLong(), KEY_BRIGHTNESS_DAY)
        setInteger(config.brightnessNight.coerceIn(1, 100).toLong(), KEY_BRIGHTNESS_NIGHT)
        // A selection change takes the target preset's animation, not the outgoing runtime snapshot.
        if (readerIndex == previousIndex) readerPresetPersistence.setCurrentPageAnimation(config.pageAnimation)
        setBool(config.shareLayout, KEY_SHARE_LAYOUT)
        setInteger(readerIndex.toLong(), KEY_READ_STYLE_INDEX)
        setInteger(config.comicStyleIndex.coerceAtLeast(0).toLong(), KEY_COMIC_STYLE_INDEX)
        setInteger(config.autoReadSpeed.coerceIn(1, 300).toLong(), KEY_AUTO_READ_SPEED)
        setBool(config.ttsFollowSystemRate, KEY_TTS_FOLLOW_SYSTEM_RATE)
        setInteger(config.ttsSpeechRate.coerceIn(0, 100).toLong(), KEY_TTS_SPEECH_RATE)
        setInteger(config.ttsTimerMinutes.coerceIn(0, 180).toLong(), KEY_TTS_TIMER_MINUTES)
        setNullableString(KEY_TTS_VOICE_IDENTIFIER, config.ttsVoiceIdentifier?.takeIf { it.isNotBlank() })
        setBool(config.textFullJustify, KEY_TEXT_FULL_JUSTIFY)
        setBool(config.textBottomJustify, KEY_TEXT_BOTTOM_JUSTIFY)
        setBool(config.hideStatusBar, KEY_HIDE_STATUS_BAR)
        setBool(config.hideNavigationBar, KEY_HIDE_NAVIGATION_BAR)
        setInteger(config.chineseMode.coerceIn(0, 2).toLong(), KEY_READER_CHINESE_MODE)
        setBool(config.useZhLayout, KEY_USE_ZH_LAYOUT)
        setBool(config.readBodyToLh, KEY_READ_BODY_TO_LH)
        setInteger(config.tapZoneActions.topLeft.toLong(), KEY_TAP_TOP_LEFT)
        setInteger(config.tapZoneActions.topCenter.toLong(), KEY_TAP_TOP_CENTER)
        setInteger(config.tapZoneActions.topRight.toLong(), KEY_TAP_TOP_RIGHT)
        setInteger(config.tapZoneActions.middleLeft.toLong(), KEY_TAP_MIDDLE_LEFT)
        setInteger(config.tapZoneActions.middleCenter.toLong(), KEY_TAP_MIDDLE_CENTER)
        setInteger(config.tapZoneActions.middleRight.toLong(), KEY_TAP_MIDDLE_RIGHT)
        setInteger(config.tapZoneActions.bottomLeft.toLong(), KEY_TAP_BOTTOM_LEFT)
        setInteger(config.tapZoneActions.bottomCenter.toLong(), KEY_TAP_BOTTOM_CENTER)
        setInteger(config.tapZoneActions.bottomRight.toLong(), KEY_TAP_BOTTOM_RIGHT)
    }

    override suspend fun renameReaderPreset(oldName: String, newName: String, expectedIndex: Int?) {
        val index = readerPresetPersistence.mutationIndex(oldName, expectedIndex)
        if (index < 0 || readerPresets[index].name == newName) return
        write {
            readerPresetPersistence.rename(index, newName)
        }
    }

    override suspend fun deleteReaderPreset(name: String, expectedIndex: Int?) {
        val removedIndex = readerPresetPersistence.mutationIndex(name, expectedIndex)
        if (readerPresets.size <= 5) return
        if (removedIndex < 0) return
        write {
            readerPresetPersistence.delete(removedIndex, preserveCurrentReaderLayout())
        }
    }

    override suspend fun importReaderPreset(preset: ReaderPreset) {
        preserveCurrentReaderLayout()
        readerPresets = readerPresets + preset
        persistReaderPresets()
        write {
            val index = (readerPresets.size - 1).coerceAtLeast(0)
            setInteger(index.toLong(), KEY_READ_STYLE_INDEX)
            val importedStyle = preset.styleForVariant(readerVisualVariant())
            // Android's durConfig setter also replaces shareConfig when sharing is enabled.
            if (boolForKey(KEY_SHARE_LAYOUT)) writeReaderSharedLayout(importedStyle)
            writeReaderStyle(preset.name, importedStyle)
            readerPresetPersistence.writeActivePageAnimation()
        }
    }

    override suspend fun replaceReaderPreset(expectedName: String, preset: ReaderPreset, expectedIndex: Int?): ReaderPreset {
        // Validation precedes write's legacy materialization. There is no suspension before replacement.
        val index = readerPresetPersistence.selectedMutationIndex(expectedName, expectedIndex)
        require(index >= 0) { "Reader preset not found: $expectedName" }
        write {
            readerPresetPersistence.replace(index, preset)
        }
        return preset
    }

    override suspend fun upsertReaderPresetWithoutSelecting(preset: ReaderPreset): ReaderPreset {
        // Existing reader-menu imports still append and select. System imports keep both indices.
        readerPresetPersistence.materializeLegacyValues()
        readerPresetPersistence.upsertWithoutSelecting(preset)
        refresh()
        return preset
    }

    override fun readerPresetForExport(name: String): ReaderPreset? =
        readerPresetPersistence.presetForExport(name, readPreferences().readerStyle)

    override suspend fun setTapZoneActions(actions: ReaderTapZoneActions) = write {
        setInteger(actions.topLeft.toLong(), KEY_TAP_TOP_LEFT)
        setInteger(actions.topCenter.toLong(), KEY_TAP_TOP_CENTER)
        setInteger(actions.topRight.toLong(), KEY_TAP_TOP_RIGHT)
        setInteger(actions.middleLeft.toLong(), KEY_TAP_MIDDLE_LEFT)
        setInteger(actions.middleCenter.toLong(), KEY_TAP_MIDDLE_CENTER)
        setInteger(actions.middleRight.toLong(), KEY_TAP_MIDDLE_RIGHT)
        setInteger(actions.bottomLeft.toLong(), KEY_TAP_BOTTOM_LEFT)
        setInteger(actions.bottomCenter.toLong(), KEY_TAP_BOTTOM_CENTER)
        setInteger(actions.bottomRight.toLong(), KEY_TAP_BOTTOM_RIGHT)
    }

    override suspend fun setUserAgent(ua: String) = write { userAgentPreference.write(ua) }
    override suspend fun setTextSelectAble(enabled: Boolean) = write { setBool(enabled, KEY_TEXT_SELECT_ABLE) }
    override suspend fun setScreenOrientation(orientation: String?) = write { setNullableString(KEY_SCREEN_ORIENTATION, orientation) }
    override suspend fun setBookExportFileName(template: String?) = write { setNullableString(KEY_BOOK_EXPORT_FILE_NAME, template) }
    override suspend fun setEpisodeExportFileName(template: String?) = write { setNullableString(KEY_EPISODE_EXPORT_FILE_NAME, template) }
    override suspend fun setDefaultBookTreeUri(uri: String?) = write { setNullableString(KEY_DEFAULT_BOOK_TREE_URI, uri) }
    override suspend fun setShowDiscovery(enabled: Boolean) = write { IosPreferencesBackup.writeBoolean(this, KEY_SHOW_DISCOVERY, enabled) }
    override suspend fun setShowRSS(enabled: Boolean) = write { IosPreferencesBackup.writeBoolean(this, KEY_SHOW_RSS, enabled) }
    override suspend fun setAutoRefreshBook(enabled: Boolean) = write { IosPreferencesBackup.writeBoolean(this, KEY_AUTO_REFRESH_BOOK, enabled) }
    override suspend fun setExportCharset(charset: String) = write { setObject(charset.ifBlank { "UTF-8" }, KEY_EXPORT_CHARSET) }
    override suspend fun setExportUseReplace(enabled: Boolean) = write { setBool(enabled, KEY_EXPORT_USE_REPLACE) }
    override suspend fun setExportToWebDav(enabled: Boolean) = write { setBool(enabled, KEY_EXPORT_TO_WEBDAV) }
    override suspend fun setExportNoChapterName(enabled: Boolean) = write { setBool(enabled, KEY_EXPORT_NO_CHAPTER_NAME) }
    override suspend fun setEnableCustomExport(enabled: Boolean) = write { setBool(enabled, KEY_ENABLE_CUSTOM_EXPORT) }
    override suspend fun setExportType(type: Int) = write { setInteger(type.toLong(), KEY_EXPORT_TYPE) }
    override suspend fun setExportPictureFile(enabled: Boolean) = write { setBool(enabled, KEY_EXPORT_PICTURE_FILE) }
    override suspend fun setParallelExportBook(enabled: Boolean) = write { setBool(enabled, KEY_PARALLEL_EXPORT_BOOK) }
    override suspend fun setTtsEngine(engine: String?) = write { setNullableString(KEY_TTS_ENGINE, engine) }
    override suspend fun setTocUiUseReplace(enabled: Boolean) = write { setBool(enabled, KEY_TOC_UI_USE_REPLACE) }
    override suspend fun setTocCountWords(enabled: Boolean) = write { setBool(enabled, KEY_TOC_COUNT_WORDS) }
    override suspend fun setEnableReadRecord(enabled: Boolean) = write { setBool(enabled, KEY_ENABLE_READ_RECORD) }
    override suspend fun setImportKeepName(enabled: Boolean) = write { setBool(enabled, KEY_IMPORT_KEEP_NAME) }
    override suspend fun setImportKeepGroup(enabled: Boolean) = write { setBool(enabled, KEY_IMPORT_KEEP_GROUP) }
    override suspend fun setImportKeepEnable(enabled: Boolean) = write { setBool(enabled, KEY_IMPORT_KEEP_ENABLE) }
    override suspend fun setPreDownloadNum(num: Int) = write { setInteger(num.coerceIn(0, 9999).toLong(), KEY_PRE_DOWNLOAD_NUM) }
    override suspend fun setMediaButtonOnExit(enabled: Boolean) = write { setBool(enabled, KEY_MEDIA_BUTTON_ON_EXIT) }
    override suspend fun setReadAloudByMediaButton(enabled: Boolean) = write { setBool(enabled, KEY_READ_ALOUD_BY_MEDIA_BUTTON) }
    override suspend fun setPauseReadAloudWhilePhoneCalls(enabled: Boolean) = write { setBool(enabled, KEY_PAUSE_READ_ALOUD_WHILE_PHONE_CALLS) }
    override suspend fun setStreamReadAloudAudio(enabled: Boolean) = write { setBool(enabled, KEY_STREAM_READ_ALOUD_AUDIO) }
    override suspend fun setDoublePageHorizontal(value: String?) = write { setNullableString(KEY_DOUBLE_PAGE_HORIZONTAL, value) }
    override suspend fun setKeyPageOnLongPress(enabled: Boolean) = write { setBool(enabled, KEY_KEY_PAGE_ON_LONG_PRESS) }
    override suspend fun setVolumeKeyPage(enabled: Boolean) = write { setBool(enabled, KEY_VOLUME_KEY_PAGE) }
    override suspend fun setVolumeKeyPageOnPlay(enabled: Boolean) = write { setBool(enabled, KEY_VOLUME_KEY_PAGE_ON_PLAY) }
    override suspend fun setMouseWheelPage(enabled: Boolean) = write { setBool(enabled, KEY_MOUSE_WHEEL_PAGE) }
    override suspend fun setSearchScope(scope: String) = write { setObject(scope, KEY_SEARCH_SCOPE) }
    override suspend fun setSearchGroup(group: String) = write { setObject(group, KEY_SEARCH_GROUP) }
    override suspend fun setShowMangaUi(enabled: Boolean) = write { setBool(enabled, KEY_SHOW_MANGA_UI) }
    override suspend fun setDisableMangaScale(enabled: Boolean) = write { setBool(enabled, KEY_DISABLE_MANGA_SCALE) }
    override suspend fun setDisableMangaPageAnim(enabled: Boolean) = write { setBool(enabled, KEY_DISABLE_MANGA_PAGE_ANIM) }
    override suspend fun setMangaPreDownloadNum(num: Int) = write { setInteger(num.coerceIn(0, 100).toLong(), KEY_MANGA_PRE_DOWNLOAD_NUM) }
    override suspend fun setDisableClickScroll(enabled: Boolean) = write { setBool(enabled, KEY_DISABLE_CLICK_SCROLL) }
    override suspend fun setMangaAutoPageSpeed(speed: Int) = write { setInteger(speed.coerceIn(1, 100).toLong(), KEY_MANGA_AUTO_PAGE_SPEED) }
    override suspend fun setMangaFooterConfig(config: String) = write { setObject(config, KEY_MANGA_FOOTER_CONFIG) }
    override suspend fun setEnableMangaHorizontalScroll(enabled: Boolean) = write { setBool(enabled, KEY_ENABLE_MANGA_HORIZONTAL_SCROLL) }
    override suspend fun setMangaColorFilter(filter: String) = write { setObject(filter, KEY_MANGA_COLOR_FILTER) }
    override suspend fun setHideMangaTitle(enabled: Boolean) = write { setBool(enabled, KEY_HIDE_MANGA_TITLE) }
    override suspend fun setEnableMangaEInk(enabled: Boolean) = write { setBool(enabled, KEY_ENABLE_MANGA_EINK) }
    override suspend fun setMangaEInkThreshold(threshold: Int) = write { setInteger(threshold.coerceIn(0, 255).toLong(), KEY_MANGA_EINK_THRESHOLD) }
    override suspend fun setDisableHorizontalPageSnap(enabled: Boolean) = write { setBool(enabled, KEY_DISABLE_HORIZONTAL_PAGE_SNAP) }
    override suspend fun setEnableMangaGray(enabled: Boolean) = write { setBool(enabled, KEY_ENABLE_MANGA_GRAY) }
    override suspend fun setUseZhLayout(enabled: Boolean) = write { setBool(enabled, KEY_USE_ZH_LAYOUT) }
    override suspend fun setReadBodyToLh(enabled: Boolean) = write { setBool(enabled, KEY_READ_BODY_TO_LH) }
    override suspend fun setIsComic(enabled: Boolean) = write { setBool(enabled, KEY_IS_COMIC) }
    override suspend fun setIsCronet(enabled: Boolean) = write { setBool(enabled, KEY_IS_CRONET) }
    override suspend fun setUseAntiAlias(enabled: Boolean) = write { setBool(enabled, KEY_USE_ANTI_ALIAS) }
    override suspend fun setUseDefaultCover(enabled: Boolean) = write { setBool(enabled, KEY_USE_DEFAULT_COVER) }
    override suspend fun setOptimizeRender(enabled: Boolean) = write { setBool(enabled, KEY_OPTIMIZE_RENDER) }
    override suspend fun setRecordLog(enabled: Boolean) = write { setBool(enabled, KEY_RECORD_LOG) }
    override suspend fun setIsTransparentStatusBar(enabled: Boolean) = write { setBool(enabled, KEY_IS_TRANSPARENT_STATUS_BAR) }
    override suspend fun setImmNavigationBar(enabled: Boolean) = write { setBool(enabled, KEY_IMM_NAVIGATION_BAR) }
    override suspend fun setBookImportFileName(template: String?) = write { setNullableString(KEY_BOOK_IMPORT_FILE_NAME, template) }
    override suspend fun setEnableReview(enabled: Boolean) = write { setBool(enabled, KEY_ENABLE_REVIEW) }
    override suspend fun setImportBookPath(path: String?) = write { setNullableString(KEY_IMPORT_BOOK_PATH, path) }
    override suspend fun setNoAnimScrollPage(enabled: Boolean) = write { setBool(enabled, KEY_NO_ANIM_SCROLL_PAGE) }
    override suspend fun setWebPort(port: Int) = write { setInteger(port.coerceIn(1, 65535).toLong(), KEY_WEB_PORT) }
    override suspend fun setOpenBookInfoByClickTitle(enabled: Boolean) = write { setBool(enabled, KEY_OPEN_BOOK_INFO_BY_CLICK_TITLE) }
    override suspend fun setContentSelectSpeakMod(mod: Int) = write { setInteger(mod.toLong(), KEY_CONTENT_SELECT_SPEAK_MOD) }
    override suspend fun setBatchChangeSourceDelay(delay: Int) = write { setInteger(delay.coerceAtLeast(0).toLong(), KEY_BATCH_CHANGE_SOURCE_DELAY) }
    override suspend fun setPreviewImageByClick(enabled: Boolean) = write {
        setBool(enabled, KEY_PREVIEW_IMAGE_BY_CLICK)
        setBool(enabled, KEY_LEGACY_PREVIEW_IMAGE_BY_CLICK)
    }
    override suspend fun setProgressBarBehavior(behavior: String) = write { setObject(behavior.ifBlank { "page" }, KEY_PROGRESS_BAR_BEHAVIOR) }
    override suspend fun setPaddingDisplayCutouts(enabled: Boolean) = write { setBool(enabled, KEY_PADDING_DISPLAY_CUTOUTS) }
    override suspend fun setPageTouchSlop(slop: Int) = write {
        val safeSlop = slop.coerceAtLeast(0).toLong()
        setInteger(safeSlop, KEY_PAGE_TOUCH_SLOP)
        setInteger(safeSlop, KEY_LEGACY_PAGE_TOUCH_SLOP)
    }
    override suspend fun setBitmapCacheSize(size: Int) = write { setInteger(size.coerceIn(1, 500).toLong(), KEY_BITMAP_CACHE_SIZE) }
    override suspend fun setImageRetainNum(num: Int) = write { setInteger(num.coerceAtLeast(0).toLong(), KEY_IMAGE_RETAIN_NUM) }
    override suspend fun setShowReadTitleBarAddition(enabled: Boolean) = write { setBool(enabled, KEY_SHOW_READ_TITLE_BAR_ADDITION) }
    override suspend fun setReadBarStyleFollowPage(enabled: Boolean) = write { setBool(enabled, KEY_READ_BAR_STYLE_FOLLOW_PAGE) }
    override suspend fun setSourceEditMaxLine(maxLine: Int) = write { setInteger(maxLine.coerceAtLeast(10).toLong(), KEY_SOURCE_EDIT_MAX_LINE) }
    override suspend fun setAudioPlayUseWakeLock(enabled: Boolean) = write { setBool(enabled, KEY_AUDIO_PLAY_USE_WAKE_LOCK) }
    override suspend fun setAudioPlayMode(mode: Int) = write { setInteger(mode.coerceIn(0, 3).toLong(), KEY_AUDIO_PLAY_MODE) }
    override suspend fun setBrightnessVwPos(enabled: Boolean) = write { setBool(enabled, KEY_BRIGHTNESS_VW_POS) }
    override suspend fun setWelcomeImage(path: String?) = write { setNullableString(KEY_WELCOME_IMAGE, path) }
    override suspend fun setWelcomeShowText(enabled: Boolean) = write { setBool(enabled, KEY_WELCOME_SHOW_TEXT) }
    override suspend fun setWelcomeShowIcon(enabled: Boolean) = write { setBool(enabled, KEY_WELCOME_SHOW_ICON) }
    override suspend fun setWelcomeImageDark(path: String?) = write { setNullableString(KEY_WELCOME_IMAGE_DARK, path) }
    override suspend fun setWelcomeShowTextDark(enabled: Boolean) = write { setBool(enabled, KEY_WELCOME_SHOW_TEXT_DARK) }
    override suspend fun setWelcomeShowIconDark(enabled: Boolean) = write { setBool(enabled, KEY_WELCOME_SHOW_ICON_DARK) }
    override suspend fun setDefaultHomePage(page: String) = write { setObject(page.ifBlank { "bookshelf" }, KEY_DEFAULT_HOME_PAGE) }
    override suspend fun setUpdateToVariant(variant: String) = write { setObject(variant.ifBlank { "default_version" }, KEY_UPDATE_TO_VARIANT) }
    override suspend fun setLoadCoverOnlyWifi(enabled: Boolean) = write { setBool(enabled, KEY_LOAD_COVER_ONLY_WIFI) }
    override suspend fun setShowAddToShelfAlert(enabled: Boolean) = write { IosPreferencesBackup.writeBoolean(this, KEY_SHOW_ADD_TO_SHELF_ALERT, enabled) }
    override suspend fun setBookInfoDeleteAlert(enabled: Boolean) = write { setBool(enabled, KEY_BOOK_INFO_DELETE_ALERT) }
    override suspend fun setRecordHeapDump(enabled: Boolean) = write { setBool(enabled, KEY_RECORD_HEAP_DUMP) }

    private fun persistReaderPresets() = readerPresetPersistence.persist()

    private fun currentReaderPresetIndex(): Int = readerPresetPersistence.currentIndex()

    private fun materializeLegacyReaderPresetValues() {
        migrateReaderLineSpacingToAndroidScale()
        readerPresetPersistence.materializeLegacyValues()
    }

    private fun persistCurrentReaderLayout(style: ReaderStylePreferences) = readerPresetPersistence.persistCurrentLayout(style)

    private fun preserveCurrentReaderLayout(): ReaderStylePreferences {
        materializeLegacyReaderPresetValues()
        val style = readPreferences().readerStyle
        // Persist legacy active-key edits only at a mutation boundary, never during reads.
        persistCurrentReaderLayout(style)
        return style
    }

    private fun changeReaderSelection(index: Int, shareLayout: Boolean, keepVisual: Boolean = false) {
        val previousStyle = preserveCurrentReaderLayout()
        defaults.setBool(shareLayout, KEY_SHARE_LAYOUT)
        activateReaderPreset(index, previousStyle, keepVisual)
    }

    private fun activateReaderPreset(index: Int, previousStyle: ReaderStylePreferences, keepVisual: Boolean = false) {
        readerPresetPersistence.activate(index, previousStyle, keepVisual)
    }

    private inline fun write(block: NSUserDefaults.() -> Unit) {
        materializeLegacyReaderPresetValues()
        defaults.block()
        defaults.synchronize()
        refresh()
    }

    private fun refresh() {
        uiState.value = readPreferences()
        runtimeState.value = readRuntimeConfig()
    }

    private fun refreshThemePreferences() {
        refresh()
        // Raw palette/catalog changes need a notification even when AppUiPreferences remains equal.
        NSNotificationCenter.defaultCenter.postNotificationName(NSUserDefaultsDidChangeNotification, defaults)
    }

    private fun readPreferences(): AppUiPreferences {
        val themePresetName = defaults.stringForKey(KEY_THEME_PRESET)
            ?: themePresets.firstOrNull()?.themeName ?: DefaultUiPresets.themePresets.first().themeName
        val readStyleIndex = currentReaderPresetIndex()
        val selectedReaderPreset = readerPresets.getOrNull(readStyleIndex)?.let {
            defaults.readerPresetWithLegacyActiveValues(it)
        }
        val readerPresetName = selectedReaderPreset?.name ?: defaults.stringForKey(KEY_READER_PRESET) ?: readerPresets.first().name
        val bookshelfLayoutIndex = defaults.integerForKey(KEY_BOOKSHELF_LAYOUT_INDEX).takeIf { defaults.objectForKey(KEY_BOOKSHELF_LAYOUT_INDEX) != null }
            ?.toInt()?.coerceAtLeast(0) ?: 1
        val activeReaderStyle = defaults.readReaderActiveStyle(
            selectedReaderPreset?.toReaderStylePreferences() ?: readerPresets.first().toReaderStylePreferences())
        val visualPresetStyle = selectedReaderPreset?.let {
            IosPreferencesBackup.readerStyle(it, defaults.stringForKey(KEY_THEME_MODE))
        } ?: activeReaderStyle
        val layout = if (defaults.boolForKey(KEY_SHARE_LAYOUT)) {
            defaults.readReaderSharedLayout() ?: activeReaderStyle
        } else activeReaderStyle
        val effectiveReaderStyle = visualPresetStyle.withSharedLayoutFrom(layout)
        return AppUiPreferences(
            themeMode = defaults.stringForKey(KEY_THEME_MODE).safeEnumValueOf<ThemeMode>() ?: ThemeMode.SYSTEM,
            bookshelfLayoutMode = defaults.stringForKey(KEY_BOOKSHELF_LAYOUT).safeEnumValueOf<BookshelfLayoutMode>()
                ?: BookshelfLayoutMode.fromLegacyIndex(bookshelfLayoutIndex),
            bookshelfSort = defaults.integerForKey(KEY_BOOKSHELF_SORT).takeIf { defaults.objectForKey(KEY_BOOKSHELF_SORT) != null }
                ?.toInt()?.coerceIn(0, 5) ?: 0,
            bookGroupStyle = defaults.integerForKey(KEY_BOOK_GROUP_STYLE).takeIf { defaults.objectForKey(KEY_BOOK_GROUP_STYLE) != null }
                ?.toInt()?.coerceAtLeast(0) ?: 0,
            showUnread = defaults.objectForKey(KEY_SHOW_UNREAD)?.let { defaults.boolForKey(KEY_SHOW_UNREAD) } ?: true,
            showLastUpdateTime = defaults.boolForKey(KEY_SHOW_LAST_UPDATE_TIME),
            showWaitUpCount = defaults.boolForKey(KEY_SHOW_WAIT_UP_COUNT),
            showBookshelfFastScroller = defaults.boolForKey(KEY_SHOW_BOOKSHELF_FAST_SCROLLER),
            saveTabPosition = defaults.integerForKey(KEY_SAVE_TAB_POSITION).takeIf { defaults.objectForKey(KEY_SAVE_TAB_POSITION) != null }
                ?.toInt()?.coerceAtLeast(0) ?: 0,
            themePresetName = themePresetName,
            readerPresetName = readerPresetName,
            readerStyle = effectiveReaderStyle,
            readerPreset = selectedReaderPreset,
            readerPresetIndex = readStyleIndex,
        )
    }

    private fun NSUserDefaults.writeReaderStyle(presetName: String, style: ReaderStylePreferences) {
        writeReaderStyleSnapshot(presetName, style)
    }

    private fun migrateReaderLineSpacingToAndroidScale() {
        if (defaults.boolForKey(KEY_READER_LINE_SPACING_ANDROID_SCALE_MIGRATED)) return
        defaults.setBool(true, KEY_READER_LINE_SPACING_ANDROID_SCALE_MIGRATED)
        if (defaults.objectForKey(KEY_READER_LINE_SPACING) == null) return
        val oldMultiplier = defaults.floatForKey(KEY_READER_LINE_SPACING)
        if (oldMultiplier < 1f) return
        defaults.setFloat((oldMultiplier - 1f).coerceIn(0f, 2f), KEY_READER_LINE_SPACING)
    }

    private fun readRuntimeConfig(): AppRuntimeConfig {
        return AppRuntimeConfig(
            threadCount = defaults.integerForKey(KEY_THREAD_COUNT).takeIf { defaults.objectForKey(KEY_THREAD_COUNT) != null }
                ?.toInt()?.coerceIn(1, 999) ?: 16,
            precisionSearch = defaults.boolForKey(KEY_PRECISION_SEARCH),
            replaceRuleEnabledByDefault = defaults.objectForKey(KEY_REPLACE_RULE_ENABLED_BY_DEFAULT)?.let {
                defaults.boolForKey(KEY_REPLACE_RULE_ENABLED_BY_DEFAULT)
            } ?: true,
            ignoreAudioFocus = defaults.objectForKey(KEY_IGNORE_AUDIO_FOCUS)?.let {
                defaults.boolForKey(KEY_IGNORE_AUDIO_FOCUS)
            } ?: false,
            changeSourceCheckAuthor = defaults.objectForKey(KEY_CHANGE_SOURCE_CHECK_AUTHOR)?.let {
                defaults.boolForKey(KEY_CHANGE_SOURCE_CHECK_AUTHOR)
            } ?: false,
            changeSourceLoadInfo = defaults.objectForKey(KEY_CHANGE_SOURCE_LOAD_INFO)?.let {
                defaults.boolForKey(KEY_CHANGE_SOURCE_LOAD_INFO)
            } ?: false,
            changeSourceLoadToc = defaults.objectForKey(KEY_CHANGE_SOURCE_LOAD_TOC)?.let {
                defaults.boolForKey(KEY_CHANGE_SOURCE_LOAD_TOC)
            } ?: false,
            changeSourceLoadWordCount = defaults.objectForKey(KEY_CHANGE_SOURCE_LOAD_WORD_COUNT)?.let {
                defaults.boolForKey(KEY_CHANGE_SOURCE_LOAD_WORD_COUNT)
            } ?: false,
            autoChangeSource = defaults.objectForKey(KEY_AUTO_CHANGE_SOURCE)?.let {
                defaults.boolForKey(KEY_AUTO_CHANGE_SOURCE)
            } ?: true,
            webDavUrl = defaults.stringForKey(KEY_WEB_DAV_URL)?.takeIf { it.isNotBlank() },
            webDavAccount = defaults.stringForKey(KEY_WEB_DAV_ACCOUNT)?.takeIf { it.isNotBlank() },
            webDavPassword = defaults.stringForKey(KEY_WEB_DAV_PASSWORD)?.takeIf { it.isNotBlank() },
            webDavDir = defaults.stringForKey(KEY_WEB_DAV_DIR)?.takeIf { it.isNotBlank() } ?: "legado",
            webDavDeviceName = defaults.stringForKey(KEY_WEB_DAV_DEVICE_NAME)?.takeIf { it.isNotBlank() }
                ?: UIDevice.currentDevice.name,
            syncBookProgress = defaults.objectForKey(KEY_SYNC_BOOK_PROGRESS)?.let {
                defaults.boolForKey(KEY_SYNC_BOOK_PROGRESS)
            } ?: true,
            syncBookProgressPlus = defaults.objectForKey(KEY_SYNC_BOOK_PROGRESS_PLUS)?.let {
                defaults.boolForKey(KEY_SYNC_BOOK_PROGRESS_PLUS)
            } ?: false,
            backupPath = defaults.stringForKey(KEY_BACKUP_PATH),
            backupRestoreIgnoredKeys = defaults.stringForKey(KEY_BACKUP_RESTORE_IGNORED_KEYS)
                ?.split(',')
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?.toSet()
                ?: emptySet(),
            onlyLatestBackup = defaults.objectForKey(KEY_ONLY_LATEST_BACKUP)?.let {
                defaults.boolForKey(KEY_ONLY_LATEST_BACKUP)
            } ?: true,
            autoCheckNewBackup = defaults.objectForKey(KEY_AUTO_CHECK_NEW_BACKUP)?.let {
                defaults.boolForKey(KEY_AUTO_CHECK_NEW_BACKUP)
            } ?: true,
            remoteServerId = defaults.integerForKey(KEY_REMOTE_SERVER_ID),
            reader = ReaderRuntimeConfig(
                brightnessDay = defaults.integerForKey(KEY_BRIGHTNESS_DAY).takeIf { defaults.objectForKey(KEY_BRIGHTNESS_DAY) != null }
                    ?.toInt()?.coerceIn(1, 100) ?: 100,
                brightnessNight = defaults.integerForKey(KEY_BRIGHTNESS_NIGHT).takeIf { defaults.objectForKey(KEY_BRIGHTNESS_NIGHT) != null }
                    ?.toInt()?.coerceIn(1, 100) ?: 100,
                pageAnimation = readerPresetPersistence.currentPageAnimation(),
                shareLayout = defaults.boolForKey(KEY_SHARE_LAYOUT),
                readStyleIndex = defaults.integerForKey(KEY_READ_STYLE_INDEX).toInt().coerceAtLeast(0),
                comicStyleIndex = defaults.integerForKey(KEY_COMIC_STYLE_INDEX).toInt().coerceAtLeast(0),
                autoReadSpeed = defaults.integerForKey(KEY_AUTO_READ_SPEED).takeIf { defaults.objectForKey(KEY_AUTO_READ_SPEED) != null }
                    ?.toInt()?.coerceIn(1, 300) ?: 10,
                ttsFollowSystemRate = defaults.objectForKey(KEY_TTS_FOLLOW_SYSTEM_RATE)?.let {
                    defaults.boolForKey(KEY_TTS_FOLLOW_SYSTEM_RATE)
                } ?: true,
                ttsSpeechRate = defaults.integerForKey(KEY_TTS_SPEECH_RATE).takeIf { defaults.objectForKey(KEY_TTS_SPEECH_RATE) != null }
                    ?.toInt()?.coerceIn(0, 100) ?: 5,
                ttsTimerMinutes = defaults.integerForKey(KEY_TTS_TIMER_MINUTES).takeIf { defaults.objectForKey(KEY_TTS_TIMER_MINUTES) != null }
                    ?.toInt()?.coerceIn(0, 180) ?: 0,
                ttsVoiceIdentifier = defaults.stringForKey(KEY_TTS_VOICE_IDENTIFIER)?.takeIf { it.isNotBlank() },
                textFullJustify = defaults.objectForKey(KEY_TEXT_FULL_JUSTIFY)?.let { defaults.boolForKey(KEY_TEXT_FULL_JUSTIFY) } ?: true,
                textBottomJustify = defaults.objectForKey(KEY_TEXT_BOTTOM_JUSTIFY)?.let { defaults.boolForKey(KEY_TEXT_BOTTOM_JUSTIFY) } ?: true,
                hideStatusBar = defaults.boolForKey(KEY_HIDE_STATUS_BAR),
                hideNavigationBar = defaults.boolForKey(KEY_HIDE_NAVIGATION_BAR),
                chineseMode = defaults.integerForKey(KEY_READER_CHINESE_MODE).takeIf { defaults.objectForKey(KEY_READER_CHINESE_MODE) != null }?.toInt() ?: 0,
                tapZoneActions = ReaderTapZoneActions(
                    topLeft = defaults.integerForKey(KEY_TAP_TOP_LEFT).takeIf { defaults.objectForKey(KEY_TAP_TOP_LEFT) != null }?.toInt() ?: 2,
                    topCenter = defaults.integerForKey(KEY_TAP_TOP_CENTER).takeIf { defaults.objectForKey(KEY_TAP_TOP_CENTER) != null }?.toInt() ?: 2,
                    topRight = defaults.integerForKey(KEY_TAP_TOP_RIGHT).takeIf { defaults.objectForKey(KEY_TAP_TOP_RIGHT) != null }?.toInt() ?: 1,
                    middleLeft = defaults.integerForKey(KEY_TAP_MIDDLE_LEFT).takeIf { defaults.objectForKey(KEY_TAP_MIDDLE_LEFT) != null }?.toInt() ?: 2,
                    middleCenter = defaults.integerForKey(KEY_TAP_MIDDLE_CENTER).takeIf { defaults.objectForKey(KEY_TAP_MIDDLE_CENTER) != null }?.toInt() ?: 0,
                    middleRight = defaults.integerForKey(KEY_TAP_MIDDLE_RIGHT).takeIf { defaults.objectForKey(KEY_TAP_MIDDLE_RIGHT) != null }?.toInt() ?: 1,
                    bottomLeft = defaults.integerForKey(KEY_TAP_BOTTOM_LEFT).takeIf { defaults.objectForKey(KEY_TAP_BOTTOM_LEFT) != null }?.toInt() ?: 2,
                    bottomCenter = defaults.integerForKey(KEY_TAP_BOTTOM_CENTER).takeIf { defaults.objectForKey(KEY_TAP_BOTTOM_CENTER) != null }?.toInt() ?: 1,
                    bottomRight = defaults.integerForKey(KEY_TAP_BOTTOM_RIGHT).takeIf { defaults.objectForKey(KEY_TAP_BOTTOM_RIGHT) != null }?.toInt() ?: 1,
                ),
                useZhLayout = defaults.objectForKey(KEY_USE_ZH_LAYOUT)?.let { defaults.boolForKey(KEY_USE_ZH_LAYOUT) } ?: false,
                readBodyToLh = defaults.objectForKey(KEY_READ_BODY_TO_LH)?.let { defaults.boolForKey(KEY_READ_BODY_TO_LH) } ?: true,
                isComic = defaults.objectForKey(KEY_IS_COMIC)?.let { defaults.boolForKey(KEY_IS_COMIC) } ?: false,
            ),
            userAgent = userAgentPreference.read(),
            textSelectAble = defaults.objectForKey(KEY_TEXT_SELECT_ABLE)?.let { defaults.boolForKey(KEY_TEXT_SELECT_ABLE) } ?: true,
            screenOrientation = defaults.stringForKey(KEY_SCREEN_ORIENTATION),
            bookExportFileName = defaults.stringForKey(KEY_BOOK_EXPORT_FILE_NAME),
            episodeExportFileName = defaults.stringForKey(KEY_EPISODE_EXPORT_FILE_NAME),
            defaultBookTreeUri = defaults.stringForKey(KEY_DEFAULT_BOOK_TREE_URI),
            showDiscovery = defaults.objectForKey(KEY_SHOW_DISCOVERY)?.let { defaults.boolForKey(KEY_SHOW_DISCOVERY) } ?: true,
            showRSS = defaults.objectForKey(KEY_SHOW_RSS)?.let { defaults.boolForKey(KEY_SHOW_RSS) } ?: true,
            autoRefreshBook = defaults.objectForKey(KEY_AUTO_REFRESH_BOOK)?.let { defaults.boolForKey(KEY_AUTO_REFRESH_BOOK) } ?: false,
            exportCharset = defaults.stringForKey(KEY_EXPORT_CHARSET)?.takeIf { it.isNotBlank() } ?: "UTF-8",
            exportUseReplace = defaults.objectForKey(KEY_EXPORT_USE_REPLACE)?.let { defaults.boolForKey(KEY_EXPORT_USE_REPLACE) } ?: true,
            exportToWebDav = defaults.objectForKey(KEY_EXPORT_TO_WEBDAV)?.let { defaults.boolForKey(KEY_EXPORT_TO_WEBDAV) } ?: false,
            exportNoChapterName = defaults.objectForKey(KEY_EXPORT_NO_CHAPTER_NAME)?.let { defaults.boolForKey(KEY_EXPORT_NO_CHAPTER_NAME) } ?: false,
            enableCustomExport = defaults.objectForKey(KEY_ENABLE_CUSTOM_EXPORT)?.let { defaults.boolForKey(KEY_ENABLE_CUSTOM_EXPORT) } ?: false,
            exportType = defaults.integerForKey(KEY_EXPORT_TYPE).takeIf { defaults.objectForKey(KEY_EXPORT_TYPE) != null }?.toInt() ?: 0,
            exportPictureFile = defaults.objectForKey(KEY_EXPORT_PICTURE_FILE)?.let { defaults.boolForKey(KEY_EXPORT_PICTURE_FILE) } ?: false,
            parallelExportBook = defaults.objectForKey(KEY_PARALLEL_EXPORT_BOOK)?.let { defaults.boolForKey(KEY_PARALLEL_EXPORT_BOOK) } ?: false,
            ttsEngine = defaults.stringForKey(KEY_TTS_ENGINE),
            tocUiUseReplace = defaults.objectForKey(KEY_TOC_UI_USE_REPLACE)?.let { defaults.boolForKey(KEY_TOC_UI_USE_REPLACE) } ?: false,
            tocCountWords = defaults.objectForKey(KEY_TOC_COUNT_WORDS)?.let { defaults.boolForKey(KEY_TOC_COUNT_WORDS) } ?: true,
            enableReadRecord = defaults.objectForKey(KEY_ENABLE_READ_RECORD)?.let { defaults.boolForKey(KEY_ENABLE_READ_RECORD) } ?: true,
            importKeepName = defaults.objectForKey(KEY_IMPORT_KEEP_NAME)?.let { defaults.boolForKey(KEY_IMPORT_KEEP_NAME) } ?: false,
            importKeepGroup = defaults.objectForKey(KEY_IMPORT_KEEP_GROUP)?.let { defaults.boolForKey(KEY_IMPORT_KEEP_GROUP) } ?: false,
            importKeepEnable = defaults.objectForKey(KEY_IMPORT_KEEP_ENABLE)?.let { defaults.boolForKey(KEY_IMPORT_KEEP_ENABLE) } ?: false,
            preDownloadNum = defaults.integerForKey(KEY_PRE_DOWNLOAD_NUM).takeIf { defaults.objectForKey(KEY_PRE_DOWNLOAD_NUM) != null }?.toInt()?.coerceIn(0, 9999) ?: 10,
            mediaButtonOnExit = defaults.objectForKey(KEY_MEDIA_BUTTON_ON_EXIT)?.let { defaults.boolForKey(KEY_MEDIA_BUTTON_ON_EXIT) } ?: true,
            readAloudByMediaButton = defaults.objectForKey(KEY_READ_ALOUD_BY_MEDIA_BUTTON)?.let { defaults.boolForKey(KEY_READ_ALOUD_BY_MEDIA_BUTTON) } ?: false,
            pauseReadAloudWhilePhoneCalls = defaults.objectForKey(KEY_PAUSE_READ_ALOUD_WHILE_PHONE_CALLS)?.let { defaults.boolForKey(KEY_PAUSE_READ_ALOUD_WHILE_PHONE_CALLS) } ?: false,
            streamReadAloudAudio = defaults.objectForKey(KEY_STREAM_READ_ALOUD_AUDIO)?.let { defaults.boolForKey(KEY_STREAM_READ_ALOUD_AUDIO) } ?: false,
            doublePageHorizontal = defaults.stringForKey(KEY_DOUBLE_PAGE_HORIZONTAL),
            keyPageOnLongPress = defaults.objectForKey(KEY_KEY_PAGE_ON_LONG_PRESS)?.let { defaults.boolForKey(KEY_KEY_PAGE_ON_LONG_PRESS) } ?: false,
            volumeKeyPage = defaults.objectForKey(KEY_VOLUME_KEY_PAGE)?.let { defaults.boolForKey(KEY_VOLUME_KEY_PAGE) } ?: true,
            volumeKeyPageOnPlay = defaults.objectForKey(KEY_VOLUME_KEY_PAGE_ON_PLAY)?.let { defaults.boolForKey(KEY_VOLUME_KEY_PAGE_ON_PLAY) } ?: true,
            mouseWheelPage = defaults.objectForKey(KEY_MOUSE_WHEEL_PAGE)?.let { defaults.boolForKey(KEY_MOUSE_WHEEL_PAGE) } ?: true,
            searchScope = defaults.stringForKey(KEY_SEARCH_SCOPE) ?: "",
            searchGroup = defaults.stringForKey(KEY_SEARCH_GROUP) ?: "",
            showMangaUi = defaults.objectForKey(KEY_SHOW_MANGA_UI)?.let { defaults.boolForKey(KEY_SHOW_MANGA_UI) } ?: true,
            disableMangaScale = defaults.objectForKey(KEY_DISABLE_MANGA_SCALE)?.let { defaults.boolForKey(KEY_DISABLE_MANGA_SCALE) } ?: true,
            disableMangaPageAnim = defaults.objectForKey(KEY_DISABLE_MANGA_PAGE_ANIM)?.let { defaults.boolForKey(KEY_DISABLE_MANGA_PAGE_ANIM) } ?: false,
            mangaPreDownloadNum = defaults.integerForKey(KEY_MANGA_PRE_DOWNLOAD_NUM).takeIf { defaults.objectForKey(KEY_MANGA_PRE_DOWNLOAD_NUM) != null }?.toInt()?.coerceIn(0, 100) ?: 10,
            disableClickScroll = defaults.objectForKey(KEY_DISABLE_CLICK_SCROLL)?.let { defaults.boolForKey(KEY_DISABLE_CLICK_SCROLL) } ?: false,
            mangaAutoPageSpeed = defaults.integerForKey(KEY_MANGA_AUTO_PAGE_SPEED).takeIf { defaults.objectForKey(KEY_MANGA_AUTO_PAGE_SPEED) != null }?.toInt()?.coerceIn(1, 100) ?: 3,
            mangaFooterConfig = defaults.stringForKey(KEY_MANGA_FOOTER_CONFIG) ?: "",
            enableMangaHorizontalScroll = defaults.objectForKey(KEY_ENABLE_MANGA_HORIZONTAL_SCROLL)?.let { defaults.boolForKey(KEY_ENABLE_MANGA_HORIZONTAL_SCROLL) } ?: false,
            mangaColorFilter = defaults.stringForKey(KEY_MANGA_COLOR_FILTER) ?: "",
            hideMangaTitle = defaults.objectForKey(KEY_HIDE_MANGA_TITLE)?.let { defaults.boolForKey(KEY_HIDE_MANGA_TITLE) } ?: false,
            enableMangaEInk = defaults.objectForKey(KEY_ENABLE_MANGA_EINK)?.let { defaults.boolForKey(KEY_ENABLE_MANGA_EINK) } ?: false,
            mangaEInkThreshold = defaults.integerForKey(KEY_MANGA_EINK_THRESHOLD).takeIf { defaults.objectForKey(KEY_MANGA_EINK_THRESHOLD) != null }?.toInt()?.coerceIn(0, 255) ?: 150,
            disableHorizontalPageSnap = defaults.objectForKey(KEY_DISABLE_HORIZONTAL_PAGE_SNAP)?.let { defaults.boolForKey(KEY_DISABLE_HORIZONTAL_PAGE_SNAP) } ?: false,
            enableMangaGray = defaults.objectForKey(KEY_ENABLE_MANGA_GRAY)?.let { defaults.boolForKey(KEY_ENABLE_MANGA_GRAY) } ?: false,
            isCronet = defaults.objectForKey(KEY_IS_CRONET)?.let { defaults.boolForKey(KEY_IS_CRONET) } ?: false,
            useAntiAlias = defaults.objectForKey(KEY_USE_ANTI_ALIAS)?.let { defaults.boolForKey(KEY_USE_ANTI_ALIAS) } ?: false,
            useDefaultCover = defaults.objectForKey(KEY_USE_DEFAULT_COVER)?.let { defaults.boolForKey(KEY_USE_DEFAULT_COVER) } ?: false,
            optimizeRender = defaults.objectForKey(KEY_OPTIMIZE_RENDER)?.let { defaults.boolForKey(KEY_OPTIMIZE_RENDER) } ?: false,
            recordLog = defaults.objectForKey(KEY_RECORD_LOG)?.let { defaults.boolForKey(KEY_RECORD_LOG) } ?: false,
            isTransparentStatusBar = defaults.objectForKey(KEY_IS_TRANSPARENT_STATUS_BAR)?.let { defaults.boolForKey(KEY_IS_TRANSPARENT_STATUS_BAR) } ?: true,
            immNavigationBar = defaults.objectForKey(KEY_IMM_NAVIGATION_BAR)?.let { defaults.boolForKey(KEY_IMM_NAVIGATION_BAR) } ?: true,
            bookImportFileName = defaults.stringForKey(KEY_BOOK_IMPORT_FILE_NAME),
            enableReview = defaults.objectForKey(KEY_ENABLE_REVIEW)?.let { defaults.boolForKey(KEY_ENABLE_REVIEW) } ?: false,
            importBookPath = defaults.stringForKey(KEY_IMPORT_BOOK_PATH),
            noAnimScrollPage = defaults.objectForKey(KEY_NO_ANIM_SCROLL_PAGE)?.let { defaults.boolForKey(KEY_NO_ANIM_SCROLL_PAGE) } ?: false,
            webPort = defaults.integerForKey(KEY_WEB_PORT).takeIf { defaults.objectForKey(KEY_WEB_PORT) != null }?.toInt()?.coerceIn(1, 65535) ?: 1122,
            openBookInfoByClickTitle = defaults.objectForKey(KEY_OPEN_BOOK_INFO_BY_CLICK_TITLE)?.let { defaults.boolForKey(KEY_OPEN_BOOK_INFO_BY_CLICK_TITLE) } ?: true,
            contentSelectSpeakMod = defaults.integerForKey(KEY_CONTENT_SELECT_SPEAK_MOD).takeIf { defaults.objectForKey(KEY_CONTENT_SELECT_SPEAK_MOD) != null }?.toInt() ?: 0,
            batchChangeSourceDelay = defaults.integerForKey(KEY_BATCH_CHANGE_SOURCE_DELAY).takeIf { defaults.objectForKey(KEY_BATCH_CHANGE_SOURCE_DELAY) != null }?.toInt()?.coerceAtLeast(0) ?: 0,
            previewImageByClick = defaults.objectForKey(KEY_PREVIEW_IMAGE_BY_CLICK)?.let { defaults.boolForKey(KEY_PREVIEW_IMAGE_BY_CLICK) }
                ?: defaults.objectForKey(KEY_LEGACY_PREVIEW_IMAGE_BY_CLICK)?.let { defaults.boolForKey(KEY_LEGACY_PREVIEW_IMAGE_BY_CLICK) }
                ?: false,
            progressBarBehavior = defaults.stringForKey(KEY_PROGRESS_BAR_BEHAVIOR)?.takeIf { it.isNotBlank() } ?: "page",
            paddingDisplayCutouts = defaults.objectForKey(KEY_PADDING_DISPLAY_CUTOUTS)?.let { defaults.boolForKey(KEY_PADDING_DISPLAY_CUTOUTS) } ?: false,
            pageTouchSlop = (
                defaults.integerForKey(KEY_PAGE_TOUCH_SLOP).takeIf { defaults.objectForKey(KEY_PAGE_TOUCH_SLOP) != null }
                    ?: defaults.integerForKey(KEY_LEGACY_PAGE_TOUCH_SLOP).takeIf { defaults.objectForKey(KEY_LEGACY_PAGE_TOUCH_SLOP) != null }
                    ?: 0
                ).toInt().coerceAtLeast(0),
            bitmapCacheSize = defaults.integerForKey(KEY_BITMAP_CACHE_SIZE).takeIf { defaults.objectForKey(KEY_BITMAP_CACHE_SIZE) != null }?.toInt()?.coerceIn(1, 500) ?: 50,
            imageRetainNum = defaults.integerForKey(KEY_IMAGE_RETAIN_NUM).takeIf { defaults.objectForKey(KEY_IMAGE_RETAIN_NUM) != null }?.toInt()?.coerceAtLeast(0) ?: 0,
            showReadTitleBarAddition = defaults.objectForKey(KEY_SHOW_READ_TITLE_BAR_ADDITION)?.let { defaults.boolForKey(KEY_SHOW_READ_TITLE_BAR_ADDITION) } ?: true,
            readBarStyleFollowPage = defaults.objectForKey(KEY_READ_BAR_STYLE_FOLLOW_PAGE)?.let { defaults.boolForKey(KEY_READ_BAR_STYLE_FOLLOW_PAGE) } ?: false,
            sourceEditMaxLine = (defaults.integerForKey(KEY_SOURCE_EDIT_MAX_LINE).takeIf { defaults.objectForKey(KEY_SOURCE_EDIT_MAX_LINE) != null }?.toInt() ?: Int.MAX_VALUE).let { if (it < 10) Int.MAX_VALUE else it },
            audioPlayUseWakeLock = defaults.objectForKey(KEY_AUDIO_PLAY_USE_WAKE_LOCK)?.let { defaults.boolForKey(KEY_AUDIO_PLAY_USE_WAKE_LOCK) } ?: false,
            audioPlayMode = defaults.objectForKey(KEY_AUDIO_PLAY_MODE)?.let { defaults.integerForKey(KEY_AUDIO_PLAY_MODE).toInt().coerceIn(0, 3) } ?: 0,
            brightnessVwPos = defaults.objectForKey(KEY_BRIGHTNESS_VW_POS)?.let { defaults.boolForKey(KEY_BRIGHTNESS_VW_POS) } ?: false,
            welcomeImage = defaults.stringForKey(KEY_WELCOME_IMAGE),
            welcomeShowText = defaults.objectForKey(KEY_WELCOME_SHOW_TEXT)?.let { defaults.boolForKey(KEY_WELCOME_SHOW_TEXT) } ?: true,
            welcomeShowIcon = defaults.objectForKey(KEY_WELCOME_SHOW_ICON)?.let { defaults.boolForKey(KEY_WELCOME_SHOW_ICON) } ?: true,
            welcomeImageDark = defaults.stringForKey(KEY_WELCOME_IMAGE_DARK),
            welcomeShowTextDark = defaults.objectForKey(KEY_WELCOME_SHOW_TEXT_DARK)?.let { defaults.boolForKey(KEY_WELCOME_SHOW_TEXT_DARK) } ?: true,
            welcomeShowIconDark = defaults.objectForKey(KEY_WELCOME_SHOW_ICON_DARK)?.let { defaults.boolForKey(KEY_WELCOME_SHOW_ICON_DARK) } ?: true,
            defaultHomePage = defaults.stringForKey(KEY_DEFAULT_HOME_PAGE)?.takeIf { it.isNotBlank() } ?: "bookshelf",
            updateToVariant = defaults.stringForKey(KEY_UPDATE_TO_VARIANT)?.takeIf { it.isNotBlank() } ?: "default_version",
            loadCoverOnlyWifi = defaults.objectForKey(KEY_LOAD_COVER_ONLY_WIFI)?.let { defaults.boolForKey(KEY_LOAD_COVER_ONLY_WIFI) } ?: false,
            showAddToShelfAlert = defaults.objectForKey(KEY_SHOW_ADD_TO_SHELF_ALERT)?.let { defaults.boolForKey(KEY_SHOW_ADD_TO_SHELF_ALERT) } ?: true,
            bookInfoDeleteAlert = defaults.objectForKey(KEY_BOOK_INFO_DELETE_ALERT)?.let { defaults.boolForKey(KEY_BOOK_INFO_DELETE_ALERT) } ?: true,
            recordHeapDump = defaults.objectForKey(KEY_RECORD_HEAP_DUMP)?.let { defaults.boolForKey(KEY_RECORD_HEAP_DUMP) } ?: false,
        )
    }

    private fun NSUserDefaults.setNullableString(key: String, value: String?) {
        if (value == null) {
            removeObjectForKey(key)
        } else {
            setObject(value, key)
        }
    }

    private inline fun <reified T : Enum<T>> String?.safeEnumValueOf(): T? {
        val candidate = this ?: return null
        return enumValues<T>().firstOrNull { it.name == candidate }
    }

    private companion object {
        private const val KEY_INITIALIZED = "initialized"
        private const val KEY_THEME_MODE = "theme_mode"
        private const val KEY_BOOKSHELF_LAYOUT_INDEX = "bookshelf_layout"
        private const val KEY_BOOKSHELF_LAYOUT = "bookshelf_layout_mode"
        private const val KEY_BOOKSHELF_SORT = "bookshelf_sort"
        private const val KEY_BOOK_GROUP_STYLE = "book_group_style"
        private const val KEY_SHOW_UNREAD = "show_unread"
        private const val KEY_SHOW_LAST_UPDATE_TIME = "show_last_update_time"
        private const val KEY_SHOW_WAIT_UP_COUNT = "show_wait_up_count"
        private const val KEY_SHOW_BOOKSHELF_FAST_SCROLLER = "show_bookshelf_fast_scroller"
        private const val KEY_SAVE_TAB_POSITION = "save_tab_position"
        private const val KEY_THEME_PRESET = "theme_preset_name"
        private const val KEY_READER_PRESET = "reader_preset_name"
        private const val KEY_READER_LINE_SPACING_ANDROID_SCALE_MIGRATED = "reader_line_spacing_android_scale_migrated"
        private const val KEY_THREAD_COUNT = "thread_count"
        private const val KEY_PRECISION_SEARCH = "precision_search"
        private const val KEY_REPLACE_RULE_ENABLED_BY_DEFAULT = "replace_rule_enabled_by_default"
        private const val KEY_IGNORE_AUDIO_FOCUS = "ignore_audio_focus"
        private const val KEY_CHANGE_SOURCE_CHECK_AUTHOR = "change_source_check_author"
        private const val KEY_CHANGE_SOURCE_LOAD_INFO = "change_source_load_info"
        private const val KEY_CHANGE_SOURCE_LOAD_TOC = "change_source_load_toc"
        private const val KEY_CHANGE_SOURCE_LOAD_WORD_COUNT = "change_source_load_word_count"
        private const val KEY_AUTO_CHANGE_SOURCE = "auto_change_source"
        private const val KEY_WEB_DAV_URL = "web_dav_url"
        private const val KEY_WEB_DAV_ACCOUNT = "web_dav_account"
        private const val KEY_WEB_DAV_PASSWORD = "web_dav_password"
        private const val KEY_WEB_DAV_DIR = "webDavDir"
        private const val KEY_WEB_DAV_DEVICE_NAME = "webDavDeviceName"
        private const val KEY_SYNC_BOOK_PROGRESS = "syncBookProgress"
        private const val KEY_SYNC_BOOK_PROGRESS_PLUS = "syncBookProgressPlus"
        private const val KEY_BACKUP_PATH = "backup_path"
        private const val KEY_BACKUP_RESTORE_IGNORED_KEYS = "backup_restore_ignored_keys"
        private const val KEY_ONLY_LATEST_BACKUP = "only_latest_backup"
        private const val KEY_AUTO_CHECK_NEW_BACKUP = "auto_check_new_backup"
        private const val KEY_REMOTE_SERVER_ID = "remote_server_id"
        private const val KEY_BRIGHTNESS_DAY = "brightness_day"
        private const val KEY_BRIGHTNESS_NIGHT = "brightness_night"
        private const val KEY_PAGE_ANIMATION = "page_animation"
        private const val KEY_SHARE_LAYOUT = "share_layout"
        private const val KEY_READ_STYLE_INDEX = "read_style_index"
        private const val KEY_COMIC_STYLE_INDEX = "comic_style_index"
        private const val KEY_AUTO_READ_SPEED = "auto_read_speed"
        private const val KEY_TTS_FOLLOW_SYSTEM_RATE = "tts_follow_system_rate"
        private const val KEY_TTS_SPEECH_RATE = "tts_speech_rate"
        private const val KEY_TTS_TIMER_MINUTES = "tts_timer_minutes"
        private const val KEY_TTS_VOICE_IDENTIFIER = "tts_voice_identifier"
        private const val KEY_TEXT_FULL_JUSTIFY = "text_full_justify"
        private const val KEY_TEXT_BOTTOM_JUSTIFY = "text_bottom_justify"
        private const val KEY_HIDE_STATUS_BAR = "hide_status_bar"
        private const val KEY_HIDE_NAVIGATION_BAR = "hide_navigation_bar"
        private const val KEY_READER_CHINESE_MODE = "reader_chinese_mode"
        private const val KEY_TAP_TOP_LEFT = "tap_top_left"
        private const val KEY_TAP_TOP_CENTER = "tap_top_center"
        private const val KEY_TAP_TOP_RIGHT = "tap_top_right"
        private const val KEY_TAP_MIDDLE_LEFT = "tap_middle_left"
        private const val KEY_TAP_MIDDLE_CENTER = "tap_middle_center"
        private const val KEY_TAP_MIDDLE_RIGHT = "tap_middle_right"
        private const val KEY_TAP_BOTTOM_LEFT = "tap_bottom_left"
        private const val KEY_TAP_BOTTOM_CENTER = "tap_bottom_center"
        private const val KEY_TAP_BOTTOM_RIGHT = "tap_bottom_right"
        private const val KEY_TEXT_SELECT_ABLE = "text_select_able"
        private const val KEY_SCREEN_ORIENTATION = "screen_orientation"
        private const val KEY_BOOK_EXPORT_FILE_NAME = "book_export_file_name"
        private const val KEY_EPISODE_EXPORT_FILE_NAME = "episode_export_file_name"
        private const val KEY_DEFAULT_BOOK_TREE_URI = "default_book_tree_uri"
        private const val KEY_SHOW_DISCOVERY = "show_discovery"
        private const val KEY_SHOW_RSS = "show_rss"
        private const val KEY_AUTO_REFRESH_BOOK = "auto_refresh_book"
        private const val KEY_EXPORT_CHARSET = "export_charset"
        private const val KEY_EXPORT_USE_REPLACE = "export_use_replace"
        private const val KEY_EXPORT_TO_WEBDAV = "export_to_webdav"
        private const val KEY_EXPORT_NO_CHAPTER_NAME = "export_no_chapter_name"
        private const val KEY_ENABLE_CUSTOM_EXPORT = "enable_custom_export"
        private const val KEY_EXPORT_TYPE = "export_type"
        private const val KEY_EXPORT_PICTURE_FILE = "export_picture_file"
        private const val KEY_PARALLEL_EXPORT_BOOK = "parallel_export_book"
        private const val KEY_TTS_ENGINE = "tts_engine"
        private const val KEY_TOC_UI_USE_REPLACE = "toc_ui_use_replace"
        private const val KEY_TOC_COUNT_WORDS = "toc_count_words"
        private const val KEY_ENABLE_READ_RECORD = "enable_read_record"
        private const val KEY_IMPORT_KEEP_NAME = "import_keep_name"
        private const val KEY_IMPORT_KEEP_GROUP = "import_keep_group"
        private const val KEY_IMPORT_KEEP_ENABLE = "import_keep_enable"
        private const val KEY_PRE_DOWNLOAD_NUM = "pre_download_num"
        private const val KEY_MEDIA_BUTTON_ON_EXIT = "media_button_on_exit"
        private const val KEY_READ_ALOUD_BY_MEDIA_BUTTON = "read_aloud_by_media_button"
        private const val KEY_PAUSE_READ_ALOUD_WHILE_PHONE_CALLS = "pause_read_aloud_while_phone_calls"
        private const val KEY_STREAM_READ_ALOUD_AUDIO = "stream_read_aloud_audio"
        private const val KEY_DOUBLE_PAGE_HORIZONTAL = "double_page_horizontal"
        private const val KEY_KEY_PAGE_ON_LONG_PRESS = "key_page_on_long_press"
        private const val KEY_VOLUME_KEY_PAGE = "volume_key_page"
        private const val KEY_VOLUME_KEY_PAGE_ON_PLAY = "volume_key_page_on_play"
        private const val KEY_MOUSE_WHEEL_PAGE = "mouse_wheel_page"
        private const val KEY_SEARCH_SCOPE = "search_scope"
        private const val KEY_SEARCH_GROUP = "search_group"
        private const val KEY_SHOW_MANGA_UI = "show_manga_ui"
        private const val KEY_DISABLE_MANGA_SCALE = "disable_manga_scale"
        private const val KEY_DISABLE_MANGA_PAGE_ANIM = "disable_manga_page_anim"
        private const val KEY_MANGA_PRE_DOWNLOAD_NUM = "manga_pre_download_num"
        private const val KEY_DISABLE_CLICK_SCROLL = "disable_click_scroll"
        private const val KEY_MANGA_AUTO_PAGE_SPEED = "manga_auto_page_speed"
        private const val KEY_MANGA_FOOTER_CONFIG = "manga_footer_config"
        private const val KEY_ENABLE_MANGA_HORIZONTAL_SCROLL = "enable_manga_horizontal_scroll"
        private const val KEY_MANGA_COLOR_FILTER = "manga_color_filter"
        private const val KEY_HIDE_MANGA_TITLE = "hide_manga_title"
        private const val KEY_ENABLE_MANGA_EINK = "enable_manga_eink"
        private const val KEY_MANGA_EINK_THRESHOLD = "manga_eink_threshold"
        private const val KEY_DISABLE_HORIZONTAL_PAGE_SNAP = "disable_horizontal_page_snap"
        private const val KEY_ENABLE_MANGA_GRAY = "enable_manga_gray"
        private const val KEY_USE_ZH_LAYOUT = "use_zh_layout"
        private const val KEY_READ_BODY_TO_LH = "read_body_to_lh"
        private const val KEY_IS_COMIC = "is_comic"
        private const val KEY_IS_CRONET = "is_cronet"
        private const val KEY_USE_ANTI_ALIAS = "use_anti_alias"
        private const val KEY_USE_DEFAULT_COVER = "use_default_cover"
        private const val KEY_OPTIMIZE_RENDER = "optimize_render"
        private const val KEY_RECORD_LOG = "record_log"
        private const val KEY_IS_TRANSPARENT_STATUS_BAR = "is_transparent_status_bar"
        private const val KEY_IMM_NAVIGATION_BAR = "imm_navigation_bar"
        private const val KEY_BOOK_IMPORT_FILE_NAME = "book_import_file_name"
        private const val KEY_ENABLE_REVIEW = "enable_review"
        private const val KEY_IMPORT_BOOK_PATH = "import_book_path"
        private const val KEY_NO_ANIM_SCROLL_PAGE = "no_anim_scroll_page"
        private const val KEY_WEB_PORT = "web_port"
        private const val KEY_OPEN_BOOK_INFO_BY_CLICK_TITLE = "open_book_info_by_click_title"
        private const val KEY_CONTENT_SELECT_SPEAK_MOD = "content_select_speak_mod"
        private const val KEY_BATCH_CHANGE_SOURCE_DELAY = "batch_change_source_delay"
        private const val KEY_PREVIEW_IMAGE_BY_CLICK = "previewImageByClick"
        private const val KEY_LEGACY_PREVIEW_IMAGE_BY_CLICK = "preview_image_by_click"
        private const val KEY_PROGRESS_BAR_BEHAVIOR = "progress_bar_behavior"
        private const val KEY_PADDING_DISPLAY_CUTOUTS = "padding_display_cutouts"
        private const val KEY_PAGE_TOUCH_SLOP = "pageTouchSlop"
        private const val KEY_LEGACY_PAGE_TOUCH_SLOP = "page_touch_slop"
        private const val KEY_BITMAP_CACHE_SIZE = "bitmap_cache_size"
        private const val KEY_IMAGE_RETAIN_NUM = "image_retain_num"
        private const val KEY_SHOW_READ_TITLE_BAR_ADDITION = "show_read_title_bar_addition"
        private const val KEY_READ_BAR_STYLE_FOLLOW_PAGE = "read_bar_style_follow_page"
        private const val KEY_SOURCE_EDIT_MAX_LINE = "source_edit_max_line"
        private const val KEY_AUDIO_PLAY_USE_WAKE_LOCK = "audio_play_use_wake_lock"
        private const val KEY_AUDIO_PLAY_MODE = "audio_play_mode"
        private const val KEY_BRIGHTNESS_VW_POS = "brightness_vw_pos"
        private const val KEY_WELCOME_IMAGE = "welcome_image"
        private const val KEY_WELCOME_SHOW_TEXT = "welcome_show_text"
        private const val KEY_WELCOME_SHOW_ICON = "welcome_show_icon"
        private const val KEY_WELCOME_IMAGE_DARK = "welcome_image_dark"
        private const val KEY_WELCOME_SHOW_TEXT_DARK = "welcome_show_text_dark"
        private const val KEY_WELCOME_SHOW_ICON_DARK = "welcome_show_icon_dark"
        private const val KEY_DEFAULT_HOME_PAGE = "default_home_page"
        private const val KEY_UPDATE_TO_VARIANT = "update_to_variant"
        private const val KEY_LOAD_COVER_ONLY_WIFI = "load_cover_only_wifi"
        private const val KEY_SHOW_ADD_TO_SHELF_ALERT = "show_add_to_shelf_alert"
        private const val KEY_BOOK_INFO_DELETE_ALERT = "bookInfoDeleteAlert"
        private const val KEY_RECORD_HEAP_DUMP = "record_heap_dump"

    }
}
