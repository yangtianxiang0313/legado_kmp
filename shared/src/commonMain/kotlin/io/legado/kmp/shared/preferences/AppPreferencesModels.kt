package io.legado.kmp.shared.preferences

import kotlinx.serialization.Serializable

enum class ThemeMode {
    SYSTEM,
    LIGHT,
    DARK,
    E_INK,
}

enum class ReaderVisualVariant {
    DAY,
    NIGHT,
    E_INK,
}

enum class ReaderAppearanceQuickOption {
    FONT_WEIGHT,
    PARAGRAPH_INDENT,
    CHINESE_MODE,
}

enum class BookshelfLayoutMode(val legacyIndex: Int, val columnCount: Int) {
    LIST(0, 0),
    GRID_3(1, 3),
    GRID_4(2, 4),
    GRID_5(3, 5),
    GRID_6(4, 6);

    val isGrid: Boolean get() = this != LIST

    companion object {
        fun fromLegacyIndex(index: Int): BookshelfLayoutMode =
            entries.firstOrNull { it.legacyIndex == index } ?: LIST
    }
}

enum class ReaderBackgroundMode {
    PAPER,
    SEPIA,
    DARK,
}

fun ReaderBackgroundMode.defaultBackgroundColorHex(): String = when (this) {
    ReaderBackgroundMode.PAPER -> "#F6F0DD"
    ReaderBackgroundMode.SEPIA -> "#DDC090"
    ReaderBackgroundMode.DARK -> "#111111"
}

fun ReaderBackgroundMode.defaultTextColorHex(): String = when (this) {
    ReaderBackgroundMode.PAPER -> "#2D2418"
    ReaderBackgroundMode.SEPIA -> "#3F2F1D"
    ReaderBackgroundMode.DARK -> "#D0D0D0"
}

data class ReaderTapZoneActions(
    val topLeft: Int = 2,
    val topCenter: Int = 2,
    val topRight: Int = 1,
    val middleLeft: Int = 2,
    val middleCenter: Int = 0,
    val middleRight: Int = 1,
    val bottomLeft: Int = 2,
    val bottomCenter: Int = 1,
    val bottomRight: Int = 1,
) {
    val hasReachableMenuEntry: Boolean
        get() = listOf(
            topLeft,
            topCenter,
            topRight,
            middleLeft,
            middleCenter,
            middleRight,
            bottomLeft,
            bottomCenter,
            bottomRight,
        ).any { it == 0 }

    fun withReachableMenuEntry(): ReaderTapZoneActions {
        return if (hasReachableMenuEntry) this else copy(middleCenter = 0)
    }
}

data class ReaderRuntimeConfig(
    val brightnessDay: Int = 100,
    val brightnessNight: Int = 100,
    val pageAnimation: Int = 0,
    val shareLayout: Boolean = false,
    val readStyleIndex: Int = 0,
    val comicStyleIndex: Int = 0,
    val autoReadSpeed: Int = 10,
    val ttsFollowSystemRate: Boolean = true,
    val ttsSpeechRate: Int = 5,
    val ttsTimerMinutes: Int = 0,
    val ttsVoiceIdentifier: String? = null,
    val textFullJustify: Boolean = true,
    val textBottomJustify: Boolean = true,
    val hideStatusBar: Boolean = false,
    val hideNavigationBar: Boolean = false,
    val chineseMode: Int = 0,
    val tapZoneActions: ReaderTapZoneActions = ReaderTapZoneActions(),
    // R-05: Chinese layout mode
    val useZhLayout: Boolean = false,
    // Android display-cutout preference; it is not a text line-height mode.
    val readBodyToLh: Boolean = true,
    // R-06: Comic mode state
    val isComic: Boolean = false,
)

data class AppRuntimeConfig(
    val threadCount: Int = 16,
    val precisionSearch: Boolean = false,
    val replaceRuleEnabledByDefault: Boolean = true,
    val ignoreAudioFocus: Boolean = false,
    val changeSourceCheckAuthor: Boolean = false,
    val changeSourceLoadInfo: Boolean = false,
    val changeSourceLoadToc: Boolean = false,
    val changeSourceLoadWordCount: Boolean = false,
    val autoChangeSource: Boolean = true,
    val webDavUrl: String? = null,
    val webDavAccount: String? = null,
    val webDavPassword: String? = null,
    val webDavDir: String = "legado",
    val webDavDeviceName: String? = null,
    val syncBookProgress: Boolean = true,
    val syncBookProgressPlus: Boolean = false,
    val backupPath: String? = null,
    val backupRestoreIgnoredKeys: Set<String> = emptySet(),
    val onlyLatestBackup: Boolean = true,
    val autoCheckNewBackup: Boolean = true,
    val remoteServerId: Long = 0L,
    val reader: ReaderRuntimeConfig = ReaderRuntimeConfig(),
    // M-03: Custom UserAgent
    val userAgent: String = DEFAULT_USER_AGENT,
    // M-07: Text selectable in reader
    val textSelectAble: Boolean = true,
    // M-10: Screen orientation lock (null = follow system)
    val screenOrientation: String? = null,
    // M-11: Export file name templates
    val bookExportFileName: String? = null,
    val episodeExportFileName: String? = null,
    // M-13: Default book save location
    val defaultBookTreeUri: String? = null,
    // M-14: Discovery/RSS tab visibility
    val showDiscovery: Boolean = true,
    val showRSS: Boolean = true,
    // M-15: Auto refresh book
    val autoRefreshBook: Boolean = false,
    // M-19: Export subsystem
    val exportCharset: String = "UTF-8",
    val exportUseReplace: Boolean = true,
    val exportToWebDav: Boolean = false,
    val exportNoChapterName: Boolean = false,
    val enableCustomExport: Boolean = false,
    val exportType: Int = 0,
    val exportPictureFile: Boolean = false,
    val parallelExportBook: Boolean = false,
    // M-21: TTS engine selection
    val ttsEngine: String? = null,
    // M-23: TOC UI options
    val tocUiUseReplace: Boolean = false,
    val tocCountWords: Boolean = true,
    // M-24: Reading record toggle
    val enableReadRecord: Boolean = true,
    // M-28: Import keep settings
    val importKeepName: Boolean = false,
    val importKeepGroup: Boolean = false,
    val importKeepEnable: Boolean = false,
    // M-30: Pre-download chapter count
    val preDownloadNum: Int = 10,
    // M-31: Media button / read aloud
    val mediaButtonOnExit: Boolean = true,
    val readAloudByMediaButton: Boolean = false,
    val pauseReadAloudWhilePhoneCalls: Boolean = false,
    val streamReadAloudAudio: Boolean = false,
    // M-32: Double page mode
    val doublePageHorizontal: String? = null,
    // M-34: Key page controls
    val keyPageOnLongPress: Boolean = false,
    val volumeKeyPage: Boolean = true,
    val volumeKeyPageOnPlay: Boolean = true,
    val mouseWheelPage: Boolean = true,
    // M-36: Search scope
    val searchScope: String = "",
    val searchGroup: String = "",
    // M-44: Manga subsystem
    val showMangaUi: Boolean = true,
    val disableMangaScale: Boolean = true,
    val disableMangaPageAnim: Boolean = false,
    val mangaPreDownloadNum: Int = 10,
    val disableClickScroll: Boolean = false,
    val mangaAutoPageSpeed: Int = 3,
    val mangaFooterConfig: String = "",
    val enableMangaHorizontalScroll: Boolean = false,
    val mangaColorFilter: String = "",
    val hideMangaTitle: Boolean = false,
    val enableMangaEInk: Boolean = false,
    val mangaEInkThreshold: Int = 150,
    val disableHorizontalPageSnap: Boolean = false,
    val enableMangaGray: Boolean = false,
    // M-01: Cronet network engine (Android-specific)
    val isCronet: Boolean = false,
    // M-02: Anti-alias
    val useAntiAlias: Boolean = false,
    // M-04: Use default cover
    val useDefaultCover: Boolean = false,
    // M-05: Optimize render with CanvasRecorder (Android-specific)
    val optimizeRender: Boolean = false,
    // M-06: Record log
    val recordLog: Boolean = false,
    // M-08: Transparent status bar (Android-specific)
    val isTransparentStatusBar: Boolean = true,
    // M-09: Immersive navigation bar (Android-specific)
    val immNavigationBar: Boolean = true,
    // M-12: Import file name template
    val bookImportFileName: String? = null,
    // M-16: Review feature toggle (debug-only in legado)
    val enableReview: Boolean = false,
    // M-17: Local import path
    val importBookPath: String? = null,
    // M-18: No animation scroll page
    val noAnimScrollPage: Boolean = false,
    // M-22: Web service port
    val webPort: Int = 1122,
    // M-25: Open book info by clicking title
    val openBookInfoByClickTitle: Boolean = true,
    // M-26: Selected text speak mode
    val contentSelectSpeakMod: Int = 0,
    // M-27: Batch change source delay
    val batchChangeSourceDelay: Int = 0,
    // M-29: Preview image by click
    val previewImageByClick: Boolean = false,
    // M-33: Progress bar behavior
    val progressBarBehavior: String = "page",
    // M-35: Padding display cutouts (Android-specific)
    val paddingDisplayCutouts: Boolean = false,
    // M-37: Page touch slop
    val pageTouchSlop: Int = 0,
    // M-38: Bitmap cache configuration
    val bitmapCacheSize: Int = 50,
    val imageRetainNum: Int = 0,
    // M-39: Read bar style
    val showReadTitleBarAddition: Boolean = true,
    val readBarStyleFollowPage: Boolean = false,
    // M-40: Source edit max line
    val sourceEditMaxLine: Int = Int.MAX_VALUE,
    // M-41: Audio play wake lock
    val audioPlayUseWakeLock: Boolean = false,
    // A02: Audio play mode (0=list_end_stop, 1=single_loop, 2=random, 3=list_loop)
    val audioPlayMode: Int = 0,
    // M-42: Brightness view position
    val brightnessVwPos: Boolean = false,
    // M-45: Welcome image customization
    val welcomeImage: String? = null,
    val welcomeShowText: Boolean = true,
    val welcomeShowIcon: Boolean = true,
    val welcomeImageDark: String? = null,
    val welcomeShowTextDark: Boolean = true,
    val welcomeShowIconDark: Boolean = true,
    // M-46: Default home page
    val defaultHomePage: String = "bookshelf",
    // M-47: Update to variant (Android-specific)
    val updateToVariant: String = "default_version",
    // M-48: Load cover only on WiFi
    val loadCoverOnlyWifi: Boolean = false,
    // M-49: Show add to shelf alert
    val showAddToShelfAlert: Boolean = true,
    // B-01: Confirm before removing a book from its detail page
    val bookInfoDeleteAlert: Boolean = true,
    // M-50: Record heap dump (Android-specific)
    val recordHeapDump: Boolean = false,
) {
    /**
     * P-02: Get the active brightness based on current theme mode.
     * When in night/dark theme, returns brightnessNight; otherwise brightnessDay.
     */
    fun readBrightness(isNightTheme: Boolean): Int {
        return if (isNightTheme) reader.brightnessNight else reader.brightnessDay
    }

    companion object {
        const val DEFAULT_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
    }

    /**
     * M-43: Detect click area and auto-fix the primary menu zone.
     * Reading must always keep middle-center as a reachable main-menu tap target.
     */
    fun detectClickArea(): AppRuntimeConfig {
        val actions = reader.tapZoneActions
        val safeActions = actions.withReachableMenuEntry()
        if (safeActions != actions) {
            return copy(
                reader = reader.copy(
                    tapZoneActions = safeActions
                )
            )
        }
        return this
    }
}

object BackupRestoreIgnoreKeys {
    const val READ_CONFIG = "readConfig"
    const val THEME_MODE = "themeMode"
    const val THEME_CONFIG = "themeConfig"
    const val COVER_CONFIG = "coverConfig"
    const val BOOKSHELF_LAYOUT = "bookshelfLayout"
    const val SHOW_RSS = "showRss"
    const val THREAD_COUNT = "threadCount"
    const val LOCAL_BOOK = "localBook"

    val all: Set<String> = setOf(
        READ_CONFIG,
        THEME_MODE,
        THEME_CONFIG,
        COVER_CONFIG,
        BOOKSHELF_LAYOUT,
        SHOW_RSS,
        THREAD_COUNT,
        LOCAL_BOOK,
    )
}

data class ReaderStylePreferences(
    val fontSizeSp: Float = 20f,
    val lineSpacingMultiplier: Float = 1.2f,
    val horizontalPaddingDp: Float = 16f,
    val backgroundMode: ReaderBackgroundMode = ReaderBackgroundMode.PAPER,
    val backgroundColorHex: String? = "#EEEEEE",
    val textColorHex: String? = "#3E3D3B",
    val fontName: String? = null,
    val textBold: Int = 0,
    val letterSpacing: Float = 0.1f,
    val paragraphSpacing: Int = 2,
    val paragraphIndent: Int = 2,
    val underline: Boolean = false,
    val backgroundAlpha: Int = 100,
    val backgroundImagePath: String? = null,
    val darkStatusIcon: Boolean = true,
    val titleMode: Int = 0,
    val titleSize: Float = 0f,
    val titleTopSpacing: Int = 0,
    val titleBottomSpacing: Int = 0,
    val paddingTop: Int = 6,
    val paddingBottom: Int = 6,
    val paddingLeft: Int = 16,
    val paddingRight: Int = 16,
    val headerPaddingTop: Int = 0,
    val headerPaddingBottom: Int = 0,
    val headerPaddingLeft: Int = 16,
    val headerPaddingRight: Int = 16,
    val footerPaddingTop: Int = 6,
    val footerPaddingBottom: Int = 6,
    val footerPaddingLeft: Int = 16,
    val footerPaddingRight: Int = 16,
    val showHeaderLine: Boolean = false,
    val showFooterLine: Boolean = true,
    val tipHeaderLeft: Int = 2,
    val tipHeaderMiddle: Int = 0,
    val tipHeaderRight: Int = 3,
    val tipFooterLeft: Int = 1,
    val tipFooterMiddle: Int = 0,
    val tipFooterRight: Int = 6,
    val tipColorHex: String? = null,
    val tipDividerColorHex: String? = null,
    val headerMode: Int = 0,
    val footerMode: Int = 0,
) {
    fun withBackgroundModeDefaults(mode: ReaderBackgroundMode): ReaderStylePreferences = copy(
        backgroundMode = mode,
        backgroundColorHex = mode.defaultBackgroundColorHex(),
        textColorHex = mode.defaultTextColorHex(),
    )

    fun withSharedLayoutFrom(shared: ReaderStylePreferences): ReaderStylePreferences = copy(
        fontSizeSp = shared.fontSizeSp,
        lineSpacingMultiplier = shared.lineSpacingMultiplier,
        horizontalPaddingDp = shared.horizontalPaddingDp,
        fontName = shared.fontName,
        textBold = shared.textBold,
        letterSpacing = shared.letterSpacing,
        paragraphSpacing = shared.paragraphSpacing,
        paragraphIndent = shared.paragraphIndent,
        underline = shared.underline,
        backgroundAlpha = shared.backgroundAlpha,
        titleMode = shared.titleMode,
        titleSize = shared.titleSize,
        titleTopSpacing = shared.titleTopSpacing,
        titleBottomSpacing = shared.titleBottomSpacing,
        paddingTop = shared.paddingTop,
        paddingBottom = shared.paddingBottom,
        paddingLeft = shared.paddingLeft,
        paddingRight = shared.paddingRight,
        headerPaddingTop = shared.headerPaddingTop,
        headerPaddingBottom = shared.headerPaddingBottom,
        headerPaddingLeft = shared.headerPaddingLeft,
        headerPaddingRight = shared.headerPaddingRight,
        footerPaddingTop = shared.footerPaddingTop,
        footerPaddingBottom = shared.footerPaddingBottom,
        footerPaddingLeft = shared.footerPaddingLeft,
        footerPaddingRight = shared.footerPaddingRight,
        showHeaderLine = shared.showHeaderLine,
        showFooterLine = shared.showFooterLine,
        tipHeaderLeft = shared.tipHeaderLeft,
        tipHeaderMiddle = shared.tipHeaderMiddle,
        tipHeaderRight = shared.tipHeaderRight,
        tipFooterLeft = shared.tipFooterLeft,
        tipFooterMiddle = shared.tipFooterMiddle,
        tipFooterRight = shared.tipFooterRight,
        tipColorHex = shared.tipColorHex,
        tipDividerColorHex = shared.tipDividerColorHex,
        headerMode = shared.headerMode,
        footerMode = shared.footerMode,
    )
}

data class AppUiPreferences(
    val themeMode: ThemeMode = ThemeMode.SYSTEM,
    val bookshelfLayoutMode: BookshelfLayoutMode = BookshelfLayoutMode.LIST,
    val bookshelfSort: Int = 0,
    val bookGroupStyle: Int = 0,
    val showUnread: Boolean = true,
    val showLastUpdateTime: Boolean = false,
    val showWaitUpCount: Boolean = false,
    val showBookshelfFastScroller: Boolean = false,
    val saveTabPosition: Int = 0,
    val themePresetName: String = "Default",
    val readerPresetName: String = "Legado 默认",
    val readerStyle: ReaderStylePreferences = ReaderStylePreferences(),
    val readerPreset: ReaderPreset? = null,
    val readerPresetIndex: Int = 0,
)

@Serializable
data class ThemePreset(
    val themeName: String,
    val isNightTheme: Boolean = false,
    val primaryColor: String,
    val accentColor: String,
    val backgroundColor: String,
    val bottomBackground: String,
    val pairedThemeName: String? = null,
)

@Serializable
data class ReaderPreset(
    val name: String,
    val bgStr: String? = null,
    val bgStrNight: String? = null,
    val textColor: String? = null,
    val textColorNight: String? = null,
    val bgAlpha: Int = 100,
    val bgType: Int = 0,
    // R-02: Night background type (0=color, 1=assets, 2=custom image)
    val bgTypeNight: Int = 0,
    // R-01: E-Ink background type
    val bgTypeEInk: Int = 0,
    val backgroundImagePath: String? = null,
    val darkStatusIcon: Boolean = true,
    // R-02: Night dark status icon
    val darkStatusIconNight: Boolean = false,
    // R-01: E-Ink specific fields
    val bgStrEInk: String? = "#FFFFFF",
    val textColorEInk: String? = "#000000",
    val darkStatusIconEInk: Boolean = true,
    val pageAnimEInk: Int = 4,
    val pageAnim: Int = 0,
    val textFont: String? = null,
    val textBold: Int = 0,
    val textSize: Int? = null,
    val letterSpacing: Float = 0.1f,
    val lineSpacingExtra: Int? = null,
    val paragraphSpacing: Int = 2,
    val paragraphIndent: Int = 2,
    val underline: Boolean = false,
    val titleMode: Int = 0,
    val titleSize: Float = 0f,
    val titleTopSpacing: Int = 0,
    val titleBottomSpacing: Int = 0,
    val paddingTop: Int = 6,
    val paddingBottom: Int = 6,
    val paddingLeft: Int? = null,
    val paddingRight: Int? = null,
    val headerPaddingTop: Int = 0,
    val headerPaddingBottom: Int = 0,
    val headerPaddingLeft: Int = 16,
    val headerPaddingRight: Int = 16,
    val footerPaddingTop: Int = 6,
    val footerPaddingBottom: Int = 6,
    val footerPaddingLeft: Int = 16,
    val footerPaddingRight: Int = 16,
    val showHeaderLine: Boolean = false,
    val showFooterLine: Boolean = true,
    val tipHeaderLeft: Int = 2,
    val tipHeaderMiddle: Int = 0,
    val tipHeaderRight: Int = 3,
    val tipFooterLeft: Int = 1,
    val tipFooterMiddle: Int = 0,
    val tipFooterRight: Int = 6,
    val tipColorHex: String? = null,
    val tipDividerColorHex: String? = null,
    val headerMode: Int = 0,
    val footerMode: Int = 0,
) {
    fun toReaderStylePreferences(): ReaderStylePreferences = styleForVariant(ReaderVisualVariant.DAY)

    fun styleForVariant(variant: ReaderVisualVariant): ReaderStylePreferences {
        return ReaderStylePreferences(
            fontSizeSp = (textSize ?: 24).toFloat(),
            lineSpacingMultiplier = ((lineSpacingExtra ?: 12) / 10f).coerceIn(0f, 2f),
            horizontalPaddingDp = (((paddingLeft ?: 16) + (paddingRight ?: 16)) / 2f).coerceIn(12f, 36f),
            fontName = textFont,
            textBold = textBold,
            letterSpacing = letterSpacing,
            paragraphSpacing = paragraphSpacing,
            paragraphIndent = paragraphIndent,
            underline = underline,
            backgroundAlpha = bgAlpha,
            titleMode = titleMode,
            titleSize = titleSize,
            titleTopSpacing = titleTopSpacing,
            titleBottomSpacing = titleBottomSpacing,
            paddingTop = paddingTop,
            paddingBottom = paddingBottom,
            paddingLeft = paddingLeft ?: 16,
            paddingRight = paddingRight ?: 16,
            headerPaddingTop = headerPaddingTop,
            headerPaddingBottom = headerPaddingBottom,
            headerPaddingLeft = headerPaddingLeft,
            headerPaddingRight = headerPaddingRight,
            footerPaddingTop = footerPaddingTop,
            footerPaddingBottom = footerPaddingBottom,
            footerPaddingLeft = footerPaddingLeft,
            footerPaddingRight = footerPaddingRight,
            showHeaderLine = showHeaderLine,
            showFooterLine = showFooterLine,
            tipHeaderLeft = tipHeaderLeft,
            tipHeaderMiddle = tipHeaderMiddle,
            tipHeaderRight = tipHeaderRight,
            tipFooterLeft = tipFooterLeft,
            tipFooterMiddle = tipFooterMiddle,
            tipFooterRight = tipFooterRight,
            tipColorHex = tipColorHex,
            tipDividerColorHex = tipDividerColorHex,
            headerMode = headerMode,
            footerMode = footerMode,
        ).withPresetVisual(this, variant)
    }
}

/**
 * T-02/T-03/T-04: ReadTipConfig UI option lists.
 * Tip type values matching legado ReadTipConfig constants.
 */
object ReadTipConfig {
    const val none = 0
    const val chapterTitle = 1
    const val time = 2
    const val battery = 3
    const val batteryPercentage = 10
    const val page = 4
    const val totalProgress = 5
    const val pageAndTotal = 6
    const val bookName = 7
    const val timeBattery = 8
    const val timeBatteryPercentage = 9
    const val totalProgress1 = 11

    /** T-02: tip type values for UI selectors */
    val tipValues: List<Int> = listOf(
        none, bookName, chapterTitle, time, battery, batteryPercentage,
        page, totalProgress, totalProgress1, pageAndTotal,
        timeBattery, timeBatteryPercentage,
    )

    /** T-02: tip type display names (localization keys) */
    val tipNames: List<String> = listOf(
        "none", "bookName", "chapterTitle", "time", "battery", "batteryPercentage",
        "page", "totalProgress", "totalProgress1", "pageAndTotal",
        "timeBattery", "timeBatteryPercentage",
    )

    /** T-03: tip color option names */
    val tipColorNames: List<String> = listOf("default", "follow_main_text")

    /** T-03: tip divider color option names */
    val tipDividerColorNames: List<String> = listOf("default", "follow_main_text", "transparent")

    /** T-04: header mode options (0=follow status bar, 1=show, 2=hide) */
    fun getHeaderModes(): List<Int> = listOf(0, 1, 2)

    /** T-04: footer mode options (0=show, 1=hide) */
    fun getFooterModes(): List<Int> = listOf(0, 1)
}

object DefaultUiPresets {
    val themePresets: List<ThemePreset> = listOf(
        ThemePreset("默认", false, "#795548", "#E53935", "#F5F5F5", "#EEEEEE"),
        ThemePreset("典雅蓝", false, "#03A9F4", "#AD1457", "#F5F5F5", "#EEEEEE"),
        ThemePreset("黑白", true, "#303030", "#E0E0E0", "#424242", "#424242"),
        ThemePreset("A屏黑", true, "#000000", "#FFFFFF", "#000000", "#000000"),
    )

    /** Compatibility lookup only; new installs use Android's themeConfig.json catalog. */
    val legacyThemePresets: List<ThemePreset> = listOf(
        ThemePreset(
            themeName = "Default",
            primaryColor = "#3F51B5",
            accentColor = "#FF7043",
            backgroundColor = "#F7F7F7",
            bottomBackground = "#FFFFFF",
        ),
        ThemePreset(
            themeName = "Paper",
            primaryColor = "#795548",
            accentColor = "#5D4037",
            backgroundColor = "#F5ECD9",
            bottomBackground = "#FFF8EA",
        ),
        ThemePreset(
            themeName = "Night",
            isNightTheme = true,
            primaryColor = "#121212",
            accentColor = "#90CAF9",
            backgroundColor = "#101010",
            bottomBackground = "#1A1A1A",
        ),
    )

    val readerPresets: List<ReaderPreset> = AndroidDefaultReaderPresets.presets

    internal val legacyReaderPresets: List<ReaderPreset> = listOf(
        ReaderPreset(
            name = "Legado 默认",
            bgStr = "#EEEEEE",
            textColor = "#3E3D3B",
            textSize = 20,
        ),
        ReaderPreset(
            name = "Compact",
            bgStr = "#FFFFFF",
            textColor = "#222222",
            textSize = 20,
            lineSpacingExtra = 6,
            paddingTop = 6,
            paddingBottom = 6,
            paddingLeft = 18,
            paddingRight = 18,
        ),
        ReaderPreset(
            name = "Night",
            bgStr = "#000000",
            bgStrNight = "#000000",
            textColor = "#D0D0D0",
            textColorNight = "#D0D0D0",
            textSize = 22,
            lineSpacingExtra = 8,
            paddingTop = 6,
            paddingBottom = 6,
            paddingLeft = 20,
            paddingRight = 20,
        ),
    )
}
