package io.legado.kmp.shared.preferences

import platform.Foundation.NSUserDefaults

internal fun NSUserDefaults.readReaderStylePreferences(): ReaderStylePreferences {
    val fallback = DefaultUiPresets.readerPresets.first().toReaderStylePreferences()
    return ReaderStylePreferences(
        fontSizeSp = floatForKey(KEY_READER_FONT_SIZE).takeIf { objectForKey(KEY_READER_FONT_SIZE) != null }
            ?: fallback.fontSizeSp,
        lineSpacingMultiplier = floatForKey(KEY_READER_LINE_SPACING)
            .takeIf { objectForKey(KEY_READER_LINE_SPACING) != null } ?: fallback.lineSpacingMultiplier,
        horizontalPaddingDp = floatForKey(KEY_READER_HORIZONTAL_PADDING)
            .takeIf { objectForKey(KEY_READER_HORIZONTAL_PADDING) != null } ?: fallback.horizontalPaddingDp,
        backgroundMode = ReaderBackgroundMode.entries.firstOrNull { it.name == stringForKey(KEY_READER_BACKGROUND) }
            ?: fallback.backgroundMode,
        fontName = stringForKey(KEY_READER_FONT_NAME) ?: fallback.fontName,
        backgroundColorHex = stringForKey(KEY_READER_BACKGROUND_HEX) ?: fallback.backgroundColorHex,
        textColorHex = stringForKey(KEY_READER_TEXT_HEX) ?: fallback.textColorHex,
        textBold = integerForKey(KEY_READER_TEXT_BOLD).takeIf { objectForKey(KEY_READER_TEXT_BOLD) != null }?.toInt() ?: fallback.textBold,
        letterSpacing = floatForKey(KEY_READER_LETTER_SPACING).takeIf { objectForKey(KEY_READER_LETTER_SPACING) != null } ?: fallback.letterSpacing,
        paragraphSpacing = integerForKey(KEY_READER_PARAGRAPH_SPACING).takeIf { objectForKey(KEY_READER_PARAGRAPH_SPACING) != null }?.toInt() ?: fallback.paragraphSpacing,
        paragraphIndent = integerForKey(KEY_READER_PARAGRAPH_INDENT).takeIf { objectForKey(KEY_READER_PARAGRAPH_INDENT) != null }?.toInt() ?: fallback.paragraphIndent,
        underline = objectForKey(KEY_READER_UNDERLINE)?.let { boolForKey(KEY_READER_UNDERLINE) } ?: fallback.underline,
        backgroundAlpha = integerForKey(KEY_READER_BACKGROUND_ALPHA).takeIf { objectForKey(KEY_READER_BACKGROUND_ALPHA) != null }?.toInt() ?: fallback.backgroundAlpha,
        backgroundImagePath = stringForKey(KEY_READER_BACKGROUND_IMAGE_PATH) ?: fallback.backgroundImagePath,
        darkStatusIcon = objectForKey(KEY_READER_DARK_STATUS_ICON)?.let { boolForKey(KEY_READER_DARK_STATUS_ICON) } ?: fallback.darkStatusIcon,
        titleMode = integerForKey(KEY_READER_TITLE_MODE).takeIf { objectForKey(KEY_READER_TITLE_MODE) != null }?.toInt() ?: fallback.titleMode,
        titleSize = floatForKey(KEY_READER_TITLE_SIZE).takeIf { objectForKey(KEY_READER_TITLE_SIZE) != null } ?: fallback.titleSize,
        titleTopSpacing = integerForKey(KEY_READER_TITLE_TOP_SPACING).takeIf { objectForKey(KEY_READER_TITLE_TOP_SPACING) != null }?.toInt() ?: fallback.titleTopSpacing,
        titleBottomSpacing = integerForKey(KEY_READER_TITLE_BOTTOM_SPACING).takeIf { objectForKey(KEY_READER_TITLE_BOTTOM_SPACING) != null }?.toInt() ?: fallback.titleBottomSpacing,
        paddingTop = integerForKey(KEY_READER_PADDING_TOP).takeIf { objectForKey(KEY_READER_PADDING_TOP) != null }?.toInt() ?: fallback.paddingTop,
        paddingBottom = integerForKey(KEY_READER_PADDING_BOTTOM).takeIf { objectForKey(KEY_READER_PADDING_BOTTOM) != null }?.toInt() ?: fallback.paddingBottom,
        paddingLeft = integerForKey(KEY_READER_PADDING_LEFT).takeIf { objectForKey(KEY_READER_PADDING_LEFT) != null }?.toInt() ?: fallback.paddingLeft,
        paddingRight = integerForKey(KEY_READER_PADDING_RIGHT).takeIf { objectForKey(KEY_READER_PADDING_RIGHT) != null }?.toInt() ?: fallback.paddingRight,
        headerPaddingTop = integerForKey(KEY_READER_HEADER_PADDING_TOP).takeIf { objectForKey(KEY_READER_HEADER_PADDING_TOP) != null }?.toInt() ?: fallback.headerPaddingTop,
        headerPaddingBottom = integerForKey(KEY_READER_HEADER_PADDING_BOTTOM).takeIf { objectForKey(KEY_READER_HEADER_PADDING_BOTTOM) != null }?.toInt() ?: fallback.headerPaddingBottom,
        headerPaddingLeft = integerForKey(KEY_READER_HEADER_PADDING_LEFT).takeIf { objectForKey(KEY_READER_HEADER_PADDING_LEFT) != null }?.toInt() ?: fallback.headerPaddingLeft,
        headerPaddingRight = integerForKey(KEY_READER_HEADER_PADDING_RIGHT).takeIf { objectForKey(KEY_READER_HEADER_PADDING_RIGHT) != null }?.toInt() ?: fallback.headerPaddingRight,
        footerPaddingTop = integerForKey(KEY_READER_FOOTER_PADDING_TOP).takeIf { objectForKey(KEY_READER_FOOTER_PADDING_TOP) != null }?.toInt() ?: fallback.footerPaddingTop,
        footerPaddingBottom = integerForKey(KEY_READER_FOOTER_PADDING_BOTTOM).takeIf { objectForKey(KEY_READER_FOOTER_PADDING_BOTTOM) != null }?.toInt() ?: fallback.footerPaddingBottom,
        footerPaddingLeft = integerForKey(KEY_READER_FOOTER_PADDING_LEFT).takeIf { objectForKey(KEY_READER_FOOTER_PADDING_LEFT) != null }?.toInt() ?: fallback.footerPaddingLeft,
        footerPaddingRight = integerForKey(KEY_READER_FOOTER_PADDING_RIGHT).takeIf { objectForKey(KEY_READER_FOOTER_PADDING_RIGHT) != null }?.toInt() ?: fallback.footerPaddingRight,
        showHeaderLine = objectForKey(KEY_READER_SHOW_HEADER_LINE)?.let { boolForKey(KEY_READER_SHOW_HEADER_LINE) } ?: fallback.showHeaderLine,
        showFooterLine = objectForKey(KEY_READER_SHOW_FOOTER_LINE)?.let { boolForKey(KEY_READER_SHOW_FOOTER_LINE) } ?: fallback.showFooterLine,
        tipHeaderLeft = integerForKey(KEY_READER_TIP_HEADER_LEFT).takeIf { objectForKey(KEY_READER_TIP_HEADER_LEFT) != null }?.toInt() ?: fallback.tipHeaderLeft,
        tipHeaderMiddle = integerForKey(KEY_READER_TIP_HEADER_MIDDLE).takeIf { objectForKey(KEY_READER_TIP_HEADER_MIDDLE) != null }?.toInt() ?: fallback.tipHeaderMiddle,
        tipHeaderRight = integerForKey(KEY_READER_TIP_HEADER_RIGHT).takeIf { objectForKey(KEY_READER_TIP_HEADER_RIGHT) != null }?.toInt() ?: fallback.tipHeaderRight,
        tipFooterLeft = integerForKey(KEY_READER_TIP_FOOTER_LEFT).takeIf { objectForKey(KEY_READER_TIP_FOOTER_LEFT) != null }?.toInt() ?: fallback.tipFooterLeft,
        tipFooterMiddle = integerForKey(KEY_READER_TIP_FOOTER_MIDDLE).takeIf { objectForKey(KEY_READER_TIP_FOOTER_MIDDLE) != null }?.toInt() ?: fallback.tipFooterMiddle,
        tipFooterRight = integerForKey(KEY_READER_TIP_FOOTER_RIGHT).takeIf { objectForKey(KEY_READER_TIP_FOOTER_RIGHT) != null }?.toInt() ?: fallback.tipFooterRight,
        tipColorHex = stringForKey(KEY_READER_TIP_COLOR_HEX) ?: fallback.tipColorHex,
        tipDividerColorHex = stringForKey(KEY_READER_TIP_DIVIDER_COLOR_HEX) ?: fallback.tipDividerColorHex,
        headerMode = integerForKey(KEY_READER_HEADER_MODE).takeIf { objectForKey(KEY_READER_HEADER_MODE) != null }?.toInt() ?: fallback.headerMode,
        footerMode = integerForKey(KEY_READER_FOOTER_MODE).takeIf { objectForKey(KEY_READER_FOOTER_MODE) != null }?.toInt() ?: fallback.footerMode,
    )
}

// Selection and legacy migrations preserve stored values; interactive edits use the bounded writer.
internal fun NSUserDefaults.writeReaderStyleSnapshot(presetName: String, style: ReaderStylePreferences) {
    setObject(presetName, "reader_preset_name")
    setFloat(style.fontSizeSp, KEY_READER_FONT_SIZE)
    setFloat(style.lineSpacingMultiplier, KEY_READER_LINE_SPACING)
    setFloat(style.horizontalPaddingDp, KEY_READER_HORIZONTAL_PADDING)
    setObject(style.backgroundMode.name, KEY_READER_BACKGROUND)
    setNullableString(KEY_READER_BACKGROUND_HEX, style.backgroundColorHex)
    setNullableString(KEY_READER_TEXT_HEX, style.textColorHex)
    setNullableString(KEY_READER_FONT_NAME, style.fontName)
    setInteger(style.textBold.toLong(), KEY_READER_TEXT_BOLD)
    setFloat(style.letterSpacing, KEY_READER_LETTER_SPACING)
    setInteger(style.paragraphSpacing.toLong(), KEY_READER_PARAGRAPH_SPACING)
    setInteger(style.paragraphIndent.toLong(), KEY_READER_PARAGRAPH_INDENT)
    setBool(style.underline, KEY_READER_UNDERLINE)
    setInteger(style.backgroundAlpha.toLong(), KEY_READER_BACKGROUND_ALPHA)
    setNullableString(KEY_READER_BACKGROUND_IMAGE_PATH, style.backgroundImagePath)
    setBool(style.darkStatusIcon, KEY_READER_DARK_STATUS_ICON)
    setInteger(style.titleMode.toLong(), KEY_READER_TITLE_MODE)
    setFloat(style.titleSize, KEY_READER_TITLE_SIZE)
    setInteger(style.titleTopSpacing.toLong(), KEY_READER_TITLE_TOP_SPACING)
    setInteger(style.titleBottomSpacing.toLong(), KEY_READER_TITLE_BOTTOM_SPACING)
    setInteger(style.paddingTop.toLong(), KEY_READER_PADDING_TOP)
    setInteger(style.paddingBottom.toLong(), KEY_READER_PADDING_BOTTOM)
    setInteger(style.paddingLeft.toLong(), KEY_READER_PADDING_LEFT)
    setInteger(style.paddingRight.toLong(), KEY_READER_PADDING_RIGHT)
    setInteger(style.headerPaddingTop.toLong(), KEY_READER_HEADER_PADDING_TOP)
    setInteger(style.headerPaddingBottom.toLong(), KEY_READER_HEADER_PADDING_BOTTOM)
    setInteger(style.headerPaddingLeft.toLong(), KEY_READER_HEADER_PADDING_LEFT)
    setInteger(style.headerPaddingRight.toLong(), KEY_READER_HEADER_PADDING_RIGHT)
    setInteger(style.footerPaddingTop.toLong(), KEY_READER_FOOTER_PADDING_TOP)
    setInteger(style.footerPaddingBottom.toLong(), KEY_READER_FOOTER_PADDING_BOTTOM)
    setInteger(style.footerPaddingLeft.toLong(), KEY_READER_FOOTER_PADDING_LEFT)
    setInteger(style.footerPaddingRight.toLong(), KEY_READER_FOOTER_PADDING_RIGHT)
    setBool(style.showHeaderLine, KEY_READER_SHOW_HEADER_LINE)
    setBool(style.showFooterLine, KEY_READER_SHOW_FOOTER_LINE)
    setInteger(style.tipHeaderLeft.toLong(), KEY_READER_TIP_HEADER_LEFT)
    setInteger(style.tipHeaderMiddle.toLong(), KEY_READER_TIP_HEADER_MIDDLE)
    setInteger(style.tipHeaderRight.toLong(), KEY_READER_TIP_HEADER_RIGHT)
    setInteger(style.tipFooterLeft.toLong(), KEY_READER_TIP_FOOTER_LEFT)
    setInteger(style.tipFooterMiddle.toLong(), KEY_READER_TIP_FOOTER_MIDDLE)
    setInteger(style.tipFooterRight.toLong(), KEY_READER_TIP_FOOTER_RIGHT)
    setNullableString(KEY_READER_TIP_COLOR_HEX, style.tipColorHex)
    setNullableString(KEY_READER_TIP_DIVIDER_COLOR_HEX, style.tipDividerColorHex)
    setInteger(style.headerMode.toLong(), KEY_READER_HEADER_MODE)
    setInteger(style.footerMode.toLong(), KEY_READER_FOOTER_MODE)
}

private fun NSUserDefaults.setNullableString(key: String, value: String?) {
    if (value == null) removeObjectForKey(key) else setObject(value, key)
}
