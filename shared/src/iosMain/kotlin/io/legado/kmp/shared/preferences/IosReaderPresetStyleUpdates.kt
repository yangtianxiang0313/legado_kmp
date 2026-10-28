package io.legado.kmp.shared.preferences

internal fun ReaderPreset.withReaderStyle(
    style: ReaderStylePreferences,
    shareLayout: Boolean,
    variant: ReaderVisualVariant,
): ReaderPreset {
    val visual = withReaderVisual(style, variant)
    if (shareLayout) return visual
    return visual.withReaderLayout(style)
}

internal fun ReaderPreset.withReaderVisual(
    style: ReaderStylePreferences,
    variant: ReaderVisualVariant,
): ReaderPreset {
    val image = style.backgroundImagePath?.takeIf { it.isNotBlank() }
    val previousType = when (variant) {
        ReaderVisualVariant.DAY -> bgType
        ReaderVisualVariant.NIGHT -> bgTypeNight
        ReaderVisualVariant.E_INK -> bgTypeEInk
    }
    val type = when {
        image == null -> 0
        previousType == 1 && image == styleForVariant(variant).backgroundImagePath -> 1
        else -> 2
    }
    val background = image ?: style.backgroundColorHex
    return when (variant) {
        ReaderVisualVariant.DAY -> copy(
            bgStr = background,
            bgType = type,
            backgroundImagePath = image.takeIf { type == 2 },
            textColor = style.textColorHex,
            darkStatusIcon = style.darkStatusIcon,
        )
        ReaderVisualVariant.NIGHT -> copy(
            bgStrNight = background,
            bgTypeNight = type,
            textColorNight = style.textColorHex,
            darkStatusIconNight = style.darkStatusIcon,
        )
        ReaderVisualVariant.E_INK -> copy(
            bgStrEInk = background,
            bgTypeEInk = type,
            textColorEInk = style.textColorHex,
            darkStatusIconEInk = style.darkStatusIcon,
        )
    }
}

internal fun ReaderPreset.withReaderLayout(style: ReaderStylePreferences): ReaderPreset =
    copy(
        bgAlpha = style.backgroundAlpha,
        textSize = style.fontSizeSp.toInt(),
        lineSpacingExtra = (style.lineSpacingMultiplier * 10).toInt(),
        textFont = style.fontName,
        textBold = style.textBold,
        letterSpacing = style.letterSpacing,
        paragraphSpacing = style.paragraphSpacing,
        paragraphIndent = style.paragraphIndent,
        underline = style.underline,
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
