package io.legado.kmp.shared.preferences

import platform.Foundation.NSUserDefaults

internal fun NSUserDefaults.readerPresetDefaults(): List<ReaderPreset> =
    if (boolForKey("initialized") || READER_STYLE_PREFERENCE_KEYS.any { objectForKey(it) != null }) {
        DefaultUiPresets.legacyReaderPresets
    } else {
        DefaultUiPresets.readerPresets
    }

internal fun NSUserDefaults.readerVisualVariant(): ReaderVisualVariant =
    (ThemeMode.entries.firstOrNull { it.name == stringForKey("theme_mode") } ?: ThemeMode.SYSTEM)
        .readerVisualVariant()

internal fun NSUserDefaults.readerPresetWithLegacyActiveValues(preset: ReaderPreset): ReaderPreset {
    if (stringForKey("custom_reader_presets") != null ||
        READER_STYLE_PREFERENCE_KEYS.none { objectForKey(it) != null }) return preset
    // Old flat keys describe the day visual, even if a theme change preceded this migration.
    val active = readReaderActiveStyle(preset.toReaderStylePreferences())
    return preset.withReaderStyle(active, boolForKey("share_layout"), ReaderVisualVariant.DAY)
}

internal fun NSUserDefaults.readReaderActiveStyle(fallback: ReaderStylePreferences): ReaderStylePreferences {
    val active = readReaderStylePreferences()
    fun <T> field(key: String, value: T, default: T): T = if (objectForKey(key) != null) value else default
    val lineSpacing = field(KEY_READER_LINE_SPACING, active.lineSpacingMultiplier, fallback.lineSpacingMultiplier)
    val effectiveSpacing = if (objectForKey(KEY_READER_LINE_SPACING) != null &&
        !boolForKey("reader_line_spacing_android_scale_migrated") && lineSpacing >= 1f) {
        (lineSpacing - 1f).coerceIn(0f, 2f)
    } else lineSpacing
    return active.copy(
        fontSizeSp = field(KEY_READER_FONT_SIZE, active.fontSizeSp, fallback.fontSizeSp),
        lineSpacingMultiplier = effectiveSpacing,
        horizontalPaddingDp = field(KEY_READER_HORIZONTAL_PADDING, active.horizontalPaddingDp, fallback.horizontalPaddingDp),
        backgroundMode = field(KEY_READER_BACKGROUND, active.backgroundMode, fallback.backgroundMode),
        backgroundColorHex = field(KEY_READER_BACKGROUND_HEX, active.backgroundColorHex, fallback.backgroundColorHex),
        textColorHex = field(KEY_READER_TEXT_HEX, active.textColorHex, fallback.textColorHex),
        fontName = field(KEY_READER_FONT_NAME, active.fontName, fallback.fontName),
        textBold = field(KEY_READER_TEXT_BOLD, active.textBold, fallback.textBold),
        letterSpacing = field(KEY_READER_LETTER_SPACING, active.letterSpacing, fallback.letterSpacing),
        paragraphSpacing = field(KEY_READER_PARAGRAPH_SPACING, active.paragraphSpacing, fallback.paragraphSpacing),
        paragraphIndent = field(KEY_READER_PARAGRAPH_INDENT, active.paragraphIndent, fallback.paragraphIndent),
        underline = field(KEY_READER_UNDERLINE, active.underline, fallback.underline),
        backgroundAlpha = field(KEY_READER_BACKGROUND_ALPHA, active.backgroundAlpha, fallback.backgroundAlpha),
        backgroundImagePath = field(KEY_READER_BACKGROUND_IMAGE_PATH, active.backgroundImagePath, fallback.backgroundImagePath),
        darkStatusIcon = field(KEY_READER_DARK_STATUS_ICON, active.darkStatusIcon, fallback.darkStatusIcon),
        titleMode = field(KEY_READER_TITLE_MODE, active.titleMode, fallback.titleMode),
        titleSize = field(KEY_READER_TITLE_SIZE, active.titleSize, fallback.titleSize),
        titleTopSpacing = field(KEY_READER_TITLE_TOP_SPACING, active.titleTopSpacing, fallback.titleTopSpacing),
        titleBottomSpacing = field(KEY_READER_TITLE_BOTTOM_SPACING, active.titleBottomSpacing, fallback.titleBottomSpacing),
        paddingTop = field(KEY_READER_PADDING_TOP, active.paddingTop, fallback.paddingTop),
        paddingBottom = field(KEY_READER_PADDING_BOTTOM, active.paddingBottom, fallback.paddingBottom),
        paddingLeft = field(KEY_READER_PADDING_LEFT, active.paddingLeft, fallback.paddingLeft),
        paddingRight = field(KEY_READER_PADDING_RIGHT, active.paddingRight, fallback.paddingRight),
        headerPaddingTop = field(KEY_READER_HEADER_PADDING_TOP, active.headerPaddingTop, fallback.headerPaddingTop),
        headerPaddingBottom = field(KEY_READER_HEADER_PADDING_BOTTOM, active.headerPaddingBottom, fallback.headerPaddingBottom),
        headerPaddingLeft = field(KEY_READER_HEADER_PADDING_LEFT, active.headerPaddingLeft, fallback.headerPaddingLeft),
        headerPaddingRight = field(KEY_READER_HEADER_PADDING_RIGHT, active.headerPaddingRight, fallback.headerPaddingRight),
        footerPaddingTop = field(KEY_READER_FOOTER_PADDING_TOP, active.footerPaddingTop, fallback.footerPaddingTop),
        footerPaddingBottom = field(KEY_READER_FOOTER_PADDING_BOTTOM, active.footerPaddingBottom, fallback.footerPaddingBottom),
        footerPaddingLeft = field(KEY_READER_FOOTER_PADDING_LEFT, active.footerPaddingLeft, fallback.footerPaddingLeft),
        footerPaddingRight = field(KEY_READER_FOOTER_PADDING_RIGHT, active.footerPaddingRight, fallback.footerPaddingRight),
        showHeaderLine = field(KEY_READER_SHOW_HEADER_LINE, active.showHeaderLine, fallback.showHeaderLine),
        showFooterLine = field(KEY_READER_SHOW_FOOTER_LINE, active.showFooterLine, fallback.showFooterLine),
        tipHeaderLeft = field(KEY_READER_TIP_HEADER_LEFT, active.tipHeaderLeft, fallback.tipHeaderLeft),
        tipHeaderMiddle = field(KEY_READER_TIP_HEADER_MIDDLE, active.tipHeaderMiddle, fallback.tipHeaderMiddle),
        tipHeaderRight = field(KEY_READER_TIP_HEADER_RIGHT, active.tipHeaderRight, fallback.tipHeaderRight),
        tipFooterLeft = field(KEY_READER_TIP_FOOTER_LEFT, active.tipFooterLeft, fallback.tipFooterLeft),
        tipFooterMiddle = field(KEY_READER_TIP_FOOTER_MIDDLE, active.tipFooterMiddle, fallback.tipFooterMiddle),
        tipFooterRight = field(KEY_READER_TIP_FOOTER_RIGHT, active.tipFooterRight, fallback.tipFooterRight),
        tipColorHex = field(KEY_READER_TIP_COLOR_HEX, active.tipColorHex, fallback.tipColorHex),
        tipDividerColorHex = field(KEY_READER_TIP_DIVIDER_COLOR_HEX, active.tipDividerColorHex, fallback.tipDividerColorHex),
        headerMode = field(KEY_READER_HEADER_MODE, active.headerMode, fallback.headerMode),
        footerMode = field(KEY_READER_FOOTER_MODE, active.footerMode, fallback.footerMode),
    )
}
