package io.legado.kmp.shared.preferences

import platform.Foundation.NSUserDefaults

internal fun NSUserDefaults.writeReaderStylePreferences(style: ReaderStylePreferences) {
    setFloat(style.fontSizeSp.coerceIn(5f, 50f), KEY_READER_FONT_SIZE)
    setFloat(style.lineSpacingMultiplier.coerceIn(0f, 2f), KEY_READER_LINE_SPACING)
    setFloat(style.horizontalPaddingDp.coerceIn(0f, 48f), KEY_READER_HORIZONTAL_PADDING)
    setObject(style.backgroundMode.name, KEY_READER_BACKGROUND)
    setNullableString(KEY_READER_BACKGROUND_HEX, style.backgroundColorHex)
    setNullableString(KEY_READER_TEXT_HEX, style.textColorHex)
    setNullableString(KEY_READER_FONT_NAME, style.fontName)
    setInteger(style.textBold.coerceIn(0, 2).toLong(), KEY_READER_TEXT_BOLD)
    setFloat(style.letterSpacing.coerceIn(-0.5f, 0.5f), KEY_READER_LETTER_SPACING)
    setInteger(style.paragraphSpacing.coerceIn(0, 20).toLong(), KEY_READER_PARAGRAPH_SPACING)
    setInteger(style.paragraphIndent.coerceIn(0, 6).toLong(), KEY_READER_PARAGRAPH_INDENT)
    setBool(style.underline, KEY_READER_UNDERLINE)
    setInteger(style.backgroundAlpha.coerceIn(0, 100).toLong(), KEY_READER_BACKGROUND_ALPHA)
    setNullableString(KEY_READER_BACKGROUND_IMAGE_PATH, style.backgroundImagePath)
    setBool(style.darkStatusIcon, KEY_READER_DARK_STATUS_ICON)
    setInteger(style.titleMode.coerceIn(0, 2).toLong(), KEY_READER_TITLE_MODE)
    setFloat(style.titleSize.coerceIn(0f, 20f), KEY_READER_TITLE_SIZE)
    setInteger(style.titleTopSpacing.coerceIn(0, 100).toLong(), KEY_READER_TITLE_TOP_SPACING)
    setInteger(style.titleBottomSpacing.coerceIn(0, 100).toLong(), KEY_READER_TITLE_BOTTOM_SPACING)
    setInteger(style.paddingTop.coerceIn(0, 200).toLong(), KEY_READER_PADDING_TOP)
    setInteger(style.paddingBottom.coerceIn(0, 100).toLong(), KEY_READER_PADDING_BOTTOM)
    setInteger(style.paddingLeft.coerceIn(0, 100).toLong(), KEY_READER_PADDING_LEFT)
    setInteger(style.paddingRight.coerceIn(0, 100).toLong(), KEY_READER_PADDING_RIGHT)
    setInteger(style.headerPaddingTop.coerceIn(0, 100).toLong(), KEY_READER_HEADER_PADDING_TOP)
    setInteger(style.headerPaddingBottom.coerceIn(0, 100).toLong(), KEY_READER_HEADER_PADDING_BOTTOM)
    setInteger(style.headerPaddingLeft.coerceIn(0, 100).toLong(), KEY_READER_HEADER_PADDING_LEFT)
    setInteger(style.headerPaddingRight.coerceIn(0, 100).toLong(), KEY_READER_HEADER_PADDING_RIGHT)
    setInteger(style.footerPaddingTop.coerceIn(0, 100).toLong(), KEY_READER_FOOTER_PADDING_TOP)
    setInteger(style.footerPaddingBottom.coerceIn(0, 100).toLong(), KEY_READER_FOOTER_PADDING_BOTTOM)
    setInteger(style.footerPaddingLeft.coerceIn(0, 100).toLong(), KEY_READER_FOOTER_PADDING_LEFT)
    setInteger(style.footerPaddingRight.coerceIn(0, 100).toLong(), KEY_READER_FOOTER_PADDING_RIGHT)
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
    if (value == null) {
        removeObjectForKey(key)
    } else {
        setObject(value, key)
    }
}

internal const val KEY_READER_FONT_SIZE = "reader_font_size_sp"
internal const val KEY_READER_LINE_SPACING = "reader_line_spacing"
internal const val KEY_READER_HORIZONTAL_PADDING = "reader_horizontal_padding"
internal const val KEY_READER_BACKGROUND = "reader_background"
internal const val KEY_READER_FONT_NAME = "reader_font_name"
internal const val KEY_READER_BACKGROUND_HEX = "reader_background_hex"
internal const val KEY_READER_TEXT_HEX = "reader_text_hex"
internal const val KEY_READER_TEXT_BOLD = "reader_text_bold"
internal const val KEY_READER_LETTER_SPACING = "reader_letter_spacing"
internal const val KEY_READER_PARAGRAPH_SPACING = "reader_paragraph_spacing"
internal const val KEY_READER_PARAGRAPH_INDENT = "reader_paragraph_indent"
internal const val KEY_READER_UNDERLINE = "reader_underline"
internal const val KEY_READER_BACKGROUND_ALPHA = "reader_background_alpha"
internal const val KEY_READER_BACKGROUND_IMAGE_PATH = "reader_background_image_path"
internal const val KEY_READER_DARK_STATUS_ICON = "reader_dark_status_icon"
internal const val KEY_READER_TITLE_MODE = "reader_title_mode"
internal const val KEY_READER_TITLE_SIZE = "reader_title_size"
internal const val KEY_READER_TITLE_TOP_SPACING = "reader_title_top_spacing"
internal const val KEY_READER_TITLE_BOTTOM_SPACING = "reader_title_bottom_spacing"
internal const val KEY_READER_PADDING_TOP = "reader_padding_top"
internal const val KEY_READER_PADDING_BOTTOM = "reader_padding_bottom"
internal const val KEY_READER_PADDING_LEFT = "reader_padding_left"
internal const val KEY_READER_PADDING_RIGHT = "reader_padding_right"
internal const val KEY_READER_HEADER_PADDING_TOP = "reader_header_padding_top"
internal const val KEY_READER_HEADER_PADDING_BOTTOM = "reader_header_padding_bottom"
internal const val KEY_READER_HEADER_PADDING_LEFT = "reader_header_padding_left"
internal const val KEY_READER_HEADER_PADDING_RIGHT = "reader_header_padding_right"
internal const val KEY_READER_FOOTER_PADDING_TOP = "reader_footer_padding_top"
internal const val KEY_READER_FOOTER_PADDING_BOTTOM = "reader_footer_padding_bottom"
internal const val KEY_READER_FOOTER_PADDING_LEFT = "reader_footer_padding_left"
internal const val KEY_READER_FOOTER_PADDING_RIGHT = "reader_footer_padding_right"
internal const val KEY_READER_SHOW_HEADER_LINE = "reader_show_header_line"
internal const val KEY_READER_SHOW_FOOTER_LINE = "reader_show_footer_line"
internal const val KEY_READER_TIP_HEADER_LEFT = "reader_tip_header_left"
internal const val KEY_READER_TIP_HEADER_MIDDLE = "reader_tip_header_middle"
internal const val KEY_READER_TIP_HEADER_RIGHT = "reader_tip_header_right"
internal const val KEY_READER_TIP_FOOTER_LEFT = "reader_tip_footer_left"
internal const val KEY_READER_TIP_FOOTER_MIDDLE = "reader_tip_footer_middle"
internal const val KEY_READER_TIP_FOOTER_RIGHT = "reader_tip_footer_right"
internal const val KEY_READER_TIP_COLOR_HEX = "reader_tip_color_hex"
internal const val KEY_READER_TIP_DIVIDER_COLOR_HEX = "reader_tip_divider_color_hex"
internal const val KEY_READER_HEADER_MODE = "reader_header_mode"
internal const val KEY_READER_FOOTER_MODE = "reader_footer_mode"

/** Exact style keys shared by the writer and backup codec. */
internal val READER_STYLE_PREFERENCE_KEYS: Set<String> = setOf(
    KEY_READER_FONT_SIZE,
    KEY_READER_LINE_SPACING,
    KEY_READER_HORIZONTAL_PADDING,
    KEY_READER_BACKGROUND,
    KEY_READER_FONT_NAME,
    KEY_READER_BACKGROUND_HEX,
    KEY_READER_TEXT_HEX,
    KEY_READER_TEXT_BOLD,
    KEY_READER_LETTER_SPACING,
    KEY_READER_PARAGRAPH_SPACING,
    KEY_READER_PARAGRAPH_INDENT,
    KEY_READER_UNDERLINE,
    KEY_READER_BACKGROUND_ALPHA,
    KEY_READER_BACKGROUND_IMAGE_PATH,
    KEY_READER_DARK_STATUS_ICON,
    KEY_READER_TITLE_MODE,
    KEY_READER_TITLE_SIZE,
    KEY_READER_TITLE_TOP_SPACING,
    KEY_READER_TITLE_BOTTOM_SPACING,
    KEY_READER_PADDING_TOP,
    KEY_READER_PADDING_BOTTOM,
    KEY_READER_PADDING_LEFT,
    KEY_READER_PADDING_RIGHT,
    KEY_READER_HEADER_PADDING_TOP,
    KEY_READER_HEADER_PADDING_BOTTOM,
    KEY_READER_HEADER_PADDING_LEFT,
    KEY_READER_HEADER_PADDING_RIGHT,
    KEY_READER_FOOTER_PADDING_TOP,
    KEY_READER_FOOTER_PADDING_BOTTOM,
    KEY_READER_FOOTER_PADDING_LEFT,
    KEY_READER_FOOTER_PADDING_RIGHT,
    KEY_READER_SHOW_HEADER_LINE,
    KEY_READER_SHOW_FOOTER_LINE,
    KEY_READER_TIP_HEADER_LEFT,
    KEY_READER_TIP_HEADER_MIDDLE,
    KEY_READER_TIP_HEADER_RIGHT,
    KEY_READER_TIP_FOOTER_LEFT,
    KEY_READER_TIP_FOOTER_MIDDLE,
    KEY_READER_TIP_FOOTER_RIGHT,
    KEY_READER_TIP_COLOR_HEX,
    KEY_READER_TIP_DIVIDER_COLOR_HEX,
    KEY_READER_HEADER_MODE,
    KEY_READER_FOOTER_MODE,
)
