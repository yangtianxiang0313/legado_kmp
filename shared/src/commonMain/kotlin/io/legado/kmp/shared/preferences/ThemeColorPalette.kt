package io.legado.kmp.shared.preferences

import kotlin.math.pow

enum class ThemeColorField { PRIMARY, ACCENT, BACKGROUND, BOTTOM_BACKGROUND }

/** Effective colors for one editable day/night channel, independent of the active theme mode. */
data class ThemeColorPalette(
    val isNightTheme: Boolean,
    val primaryColor: String,
    val accentColor: String,
    val backgroundColor: String,
    val bottomBackground: String,
)

internal object ThemePaletteColors {
    fun opaque(color: Int): Int = color or 0xff000000u.toInt()

    fun hex(color: Int): String = "#" + opaque(color).toUInt().toString(16).padStart(8, '0').uppercase()

    fun editableColor(isNightTheme: Boolean, field: ThemeColorField, color: String): Int {
        val value = opaque(ThemePresetCodec.colorInt(color))
        if (field == ThemeColorField.BACKGROUND) {
            require(isLight(value) != isNightTheme) {
                if (isNightTheme) "夜间背景不能太亮" else "白天背景不能太暗"
            }
        }
        return value
    }

    fun defaultColor(isNightTheme: Boolean, field: ThemeColorField): Int = when (field) {
        ThemeColorField.PRIMARY -> if (isNightTheme) 0xff546e7au else 0xff795548u
        ThemeColorField.ACCENT -> if (isNightTheme) 0xffd84315u else 0xffe53935u
        ThemeColorField.BACKGROUND -> if (isNightTheme) 0xff212121u else 0xfff5f5f5u
        ThemeColorField.BOTTOM_BACKGROUND -> if (isNightTheme) 0xff303030u else 0xffeeeeeeu
    }.toInt()

    fun isLight(color: Int): Boolean {
        fun linear(shift: Int): Double {
            val channel = ((color ushr shift) and 255) / 255.0
            return if (channel <= 0.04045) channel / 12.92 else ((channel + 0.055) / 1.055).pow(2.4)
        }
        return linear(16) * 0.2126 + linear(8) * 0.7152 + linear(0) * 0.0722 >= 0.5
    }
}
