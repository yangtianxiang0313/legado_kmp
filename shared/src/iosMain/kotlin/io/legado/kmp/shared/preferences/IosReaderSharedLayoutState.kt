package io.legado.kmp.shared.preferences

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import platform.Foundation.NSUserDefaults

internal const val KEY_READER_SHARED_LAYOUT = "reader_shared_layout_snapshot"

private val readerLayoutJson = Json { ignoreUnknownKeys = true; encodeDefaults = true }

// Visuals belong to each preset, including in shared-layout mode.
@Serializable
internal data class IosReaderSharedLayoutState(
    val fontSizeSp: Float,
    val lineSpacingMultiplier: Float,
    val horizontalPaddingDp: Float,
    val fontName: String?,
    val textBold: Int,
    val letterSpacing: Float,
    val paragraphSpacing: Int,
    val paragraphIndent: Int,
    val underline: Boolean,
    val backgroundAlpha: Int,
    val titleMode: Int,
    val titleSize: Float,
    val titleTopSpacing: Int,
    val titleBottomSpacing: Int,
    val paddingTop: Int,
    val paddingBottom: Int,
    val paddingLeft: Int,
    val paddingRight: Int,
    val headerPaddingTop: Int,
    val headerPaddingBottom: Int,
    val headerPaddingLeft: Int,
    val headerPaddingRight: Int,
    val footerPaddingTop: Int,
    val footerPaddingBottom: Int,
    val footerPaddingLeft: Int,
    val footerPaddingRight: Int,
    val showHeaderLine: Boolean,
    val showFooterLine: Boolean,
    val tipHeaderLeft: Int,
    val tipHeaderMiddle: Int,
    val tipHeaderRight: Int,
    val tipFooterLeft: Int,
    val tipFooterMiddle: Int,
    val tipFooterRight: Int,
    val tipColorHex: String?,
    val tipDividerColorHex: String?,
    val headerMode: Int,
    val footerMode: Int,
) {
    fun toReaderStyle(): ReaderStylePreferences = ReaderStylePreferences(
        fontSizeSp = fontSizeSp,
        lineSpacingMultiplier = lineSpacingMultiplier,
        horizontalPaddingDp = horizontalPaddingDp,
        fontName = fontName,
        textBold = textBold,
        letterSpacing = letterSpacing,
        paragraphSpacing = paragraphSpacing,
        paragraphIndent = paragraphIndent,
        underline = underline,
        backgroundAlpha = backgroundAlpha,
        titleMode = titleMode,
        titleSize = titleSize,
        titleTopSpacing = titleTopSpacing,
        titleBottomSpacing = titleBottomSpacing,
        paddingTop = paddingTop,
        paddingBottom = paddingBottom,
        paddingLeft = paddingLeft,
        paddingRight = paddingRight,
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
    )

    companion object {
        fun from(style: ReaderStylePreferences): IosReaderSharedLayoutState = IosReaderSharedLayoutState(
            fontSizeSp = style.fontSizeSp,
            lineSpacingMultiplier = style.lineSpacingMultiplier,
            horizontalPaddingDp = style.horizontalPaddingDp,
            fontName = style.fontName,
            textBold = style.textBold,
            letterSpacing = style.letterSpacing,
            paragraphSpacing = style.paragraphSpacing,
            paragraphIndent = style.paragraphIndent,
            underline = style.underline,
            backgroundAlpha = style.backgroundAlpha,
            titleMode = style.titleMode,
            titleSize = style.titleSize,
            titleTopSpacing = style.titleTopSpacing,
            titleBottomSpacing = style.titleBottomSpacing,
            paddingTop = style.paddingTop,
            paddingBottom = style.paddingBottom,
            paddingLeft = style.paddingLeft,
            paddingRight = style.paddingRight,
            headerPaddingTop = style.headerPaddingTop,
            headerPaddingBottom = style.headerPaddingBottom,
            headerPaddingLeft = style.headerPaddingLeft,
            headerPaddingRight = style.headerPaddingRight,
            footerPaddingTop = style.footerPaddingTop,
            footerPaddingBottom = style.footerPaddingBottom,
            footerPaddingLeft = style.footerPaddingLeft,
            footerPaddingRight = style.footerPaddingRight,
            showHeaderLine = style.showHeaderLine,
            showFooterLine = style.showFooterLine,
            tipHeaderLeft = style.tipHeaderLeft,
            tipHeaderMiddle = style.tipHeaderMiddle,
            tipHeaderRight = style.tipHeaderRight,
            tipFooterLeft = style.tipFooterLeft,
            tipFooterMiddle = style.tipFooterMiddle,
            tipFooterRight = style.tipFooterRight,
            tipColorHex = style.tipColorHex,
            tipDividerColorHex = style.tipDividerColorHex,
            headerMode = style.headerMode,
            footerMode = style.footerMode,
        )
    }
}

internal fun NSUserDefaults.readReaderSharedLayout(): ReaderStylePreferences? {
    val stored = stringForKey(KEY_READER_SHARED_LAYOUT) ?: return null
    return runCatching {
        readerLayoutJson.decodeFromString<IosReaderSharedLayoutState>(stored).toReaderStyle()
    }.getOrNull()
}

internal fun NSUserDefaults.writeReaderSharedLayout(style: ReaderStylePreferences) {
    setObject(readerLayoutJson.encodeToString(IosReaderSharedLayoutState.from(style)), KEY_READER_SHARED_LAYOUT)
}

internal fun PreferencesBackupData.withReaderSharedLayout(defaults: NSUserDefaults): PreferencesBackupData {
    val values = appConfig.toMutableMap()
    val layout = defaults.readReaderSharedLayout()
    if (layout == null) {
        values.remove(KEY_READER_SHARED_LAYOUT)
    } else {
        values[KEY_READER_SHARED_LAYOUT] = readerLayoutJson.encodeToJsonElement(IosReaderSharedLayoutState.from(layout))
    }
    return copy(appConfig = JsonObject(values))
}

internal fun NSUserDefaults.restoreReaderSharedLayout(data: PreferencesBackupData, ignoredKeys: Set<String>) {
    if (BackupRestoreIgnoreKeys.READ_CONFIG in ignoredKeys) return
    val snapshot = data.appConfig[KEY_READER_SHARED_LAYOUT]
    if (snapshot != null) {
        val layout = runCatching {
            readerLayoutJson.decodeFromJsonElement<IosReaderSharedLayoutState>(snapshot).toReaderStyle()
        }.getOrNull()
        if (layout != null) {
            writeReaderSharedLayout(layout)
            return
        }
    }
    if (snapshot == null) {
        val nativeShared = data.appConfig["android.shareReadConfig"] as? JsonObject
        if (nativeShared != null) {
            writeReaderSharedLayout(AndroidBackupPreferences.sharedReaderStyle(nativeShared))
            return
        }
        if (data.appConfig["android.readConfig"] is JsonArray) {
            // Android initShareConfig falls back to preset 5, not the currently selected preset.
            writeReaderSharedLayout(data.readConfig.getOrNull(5)?.toReaderStylePreferences()
                ?: AndroidBackupPreferences.sharedReaderStyle(JsonObject(emptyMap())))
            return
        }
    }
    val readerKeys = setOf("share_layout", "shareLayout", "read_style_index", "readStyleSelect", "android.shareReadConfig")
    if (snapshot != null || data.readConfig.isNotEmpty() ||
        data.appConfig.keys.any { it in READER_STYLE_PREFERENCE_KEYS || it in readerKeys }) {
        // Old backups must use their restored active keys, not a pre-restore shared snapshot.
        removeObjectForKey(KEY_READER_SHARED_LAYOUT)
    }
}
