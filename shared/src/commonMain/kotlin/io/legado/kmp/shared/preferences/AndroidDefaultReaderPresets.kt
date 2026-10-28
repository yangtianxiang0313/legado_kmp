package io.legado.kmp.shared.preferences

// legado 5f5d314, assets/defaultData/readConfig.json; omitted fields use Config defaults.
internal object AndroidDefaultReaderPresets {
    val presets: List<ReaderPreset> = listOf(
        config("微信读书", "#ffc0edc6", "#000000", "#ff0b0b0b", "#ADADAD").copy(
            textSize = 24,
            letterSpacing = 0f,
            lineSpacingExtra = 10,
            paragraphSpacing = 6,
            paragraphIndent = "\u3000\u3000".length,
            titleSize = 4f,
            paddingTop = 5,
            paddingBottom = 4,
            paddingLeft = 22,
            paddingRight = 22,
            headerPaddingTop = 10,
            headerPaddingLeft = 19,
            footerPaddingTop = 0,
            footerPaddingBottom = 10,
            footerPaddingLeft = 13,
            footerPaddingRight = 17,
            showHeaderLine = true,
            tipColorHex = "#" + (-10461088).toUInt().toString(16).padStart(8, '0'),
            tipHeaderLeft = 1,
            tipHeaderRight = 2,
            tipFooterLeft = 7,
        ),
        config("预设1", "#FFFFFF", "#000000", "#000000", "#FFFFFF"),
        config("预设2", "#DDC090", "#3C3F43", "#3E3422", "#DCDFE1"),
        config("预设3", "#C2D8AA", "#3C3F43", "#596C44", "#88C16F", false),
        config("预设4", "#DBB8E2", "#3C3F43", "#68516C", "#F6AEAE", false),
        config("预设5", "#ABCEE0", "#3C3F43", "#3D4C54", "#90BFF5", false),
    )

    private fun config(
        name: String,
        background: String,
        nightBackground: String,
        text: String,
        nightText: String,
        darkStatusIcon: Boolean = true,
    ): ReaderPreset = ReaderPreset(
        name = name,
        bgStr = background,
        bgStrNight = nightBackground,
        textColor = text,
        textColorNight = nightText,
        darkStatusIcon = darkStatusIcon,
        textSize = 20,
        lineSpacingExtra = 12,
        paddingLeft = 16,
        paddingRight = 16,
    )
}
