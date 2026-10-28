package io.legado.kmp.shared.preferences

internal fun ThemeMode.readerVisualVariant(): ReaderVisualVariant = when (this) {
    ThemeMode.DARK -> ReaderVisualVariant.NIGHT
    ThemeMode.E_INK -> ReaderVisualVariant.E_INK
    ThemeMode.SYSTEM, ThemeMode.LIGHT -> ReaderVisualVariant.DAY
}

internal fun ReaderStylePreferences.withPresetVisual(
    preset: ReaderPreset,
    variant: ReaderVisualVariant,
): ReaderStylePreferences {
    val background = when (variant) {
        ReaderVisualVariant.DAY -> preset.bgStr
        ReaderVisualVariant.NIGHT -> preset.bgStrNight
        ReaderVisualVariant.E_INK -> preset.bgStrEInk
    }?.takeIf { it.isNotBlank() }
    val type = when (variant) {
        ReaderVisualVariant.DAY -> preset.bgType
        ReaderVisualVariant.NIGHT -> preset.bgTypeNight
        ReaderVisualVariant.E_INK -> preset.bgTypeEInk
    }
    val fallback = when (variant) {
        ReaderVisualVariant.DAY -> "#EEEEEE"
        ReaderVisualVariant.NIGHT -> "#000000"
        ReaderVisualVariant.E_INK -> "#FFFFFF"
    }
    val image = when (type) {
        1 -> background
        2 -> background?.takeUnless { it.startsWith("#") }
            ?: if (variant == ReaderVisualVariant.DAY) {
                preset.backgroundImagePath?.takeIf { it.isNotBlank() }
            } else null
        else -> null
    }
    return copy(
        backgroundMode = when {
            variant == ReaderVisualVariant.NIGHT -> ReaderBackgroundMode.DARK
            variant == ReaderVisualVariant.E_INK -> ReaderBackgroundMode.PAPER
            type == 0 && background.equals("#000000", ignoreCase = true) -> ReaderBackgroundMode.DARK
            type == 0 && (background.equals("#DDC090", ignoreCase = true) ||
                background.equals("#ffc0edc6", ignoreCase = true)) -> ReaderBackgroundMode.SEPIA
            else -> ReaderBackgroundMode.PAPER
        },
        backgroundColorHex = if (type == 0) background ?: fallback else fallback,
        backgroundImagePath = image,
        textColorHex = when (variant) {
            ReaderVisualVariant.DAY -> preset.textColor?.takeIf { it.isNotBlank() } ?: "#3E3D3B"
            ReaderVisualVariant.NIGHT -> preset.textColorNight?.takeIf { it.isNotBlank() } ?: "#ADADAD"
            ReaderVisualVariant.E_INK -> preset.textColorEInk?.takeIf { it.isNotBlank() } ?: "#000000"
        },
        darkStatusIcon = when (variant) {
            ReaderVisualVariant.DAY -> preset.darkStatusIcon
            ReaderVisualVariant.NIGHT -> preset.darkStatusIconNight
            ReaderVisualVariant.E_INK -> preset.darkStatusIconEInk
        },
    )
}
