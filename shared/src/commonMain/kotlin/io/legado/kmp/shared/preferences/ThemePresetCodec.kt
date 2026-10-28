package io.legado.kmp.shared.preferences

import kotlinx.serialization.json.Json

/** ThemeConfig.Config and android.graphics.Color.parseColor, not CSS color names. */
internal object ThemePresetCodec {
    private val json = Json { ignoreUnknownKeys = true }
    private val hex = Regex("#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?")
    private val names = mapOf(
        "black" to 0xff000000u, "darkgray" to 0xff444444u, "gray" to 0xff888888u,
        "lightgray" to 0xffccccccu, "white" to 0xffffffffu, "red" to 0xffff0000u,
        "green" to 0xff00ff00u, "blue" to 0xff0000ffu, "yellow" to 0xffffff00u,
        "cyan" to 0xff00ffffu, "magenta" to 0xffff00ffu, "aqua" to 0xff00ffffu,
        "fuchsia" to 0xffff00ffu, "darkgrey" to 0xff444444u, "grey" to 0xff888888u,
        "lightgrey" to 0xffccccccu, "lime" to 0xff00ff00u, "maroon" to 0xff800000u,
        "navy" to 0xff000080u, "olive" to 0xff808000u, "purple" to 0xff800080u,
        "silver" to 0xffc0c0c0u, "teal" to 0xff008080u,
    )

    fun decode(raw: String): ThemePreset {
        require(raw.length <= 1024 * 1024) { "主题配置过大" }
        return validated(json.decodeFromString<ThemePreset>(raw.trim()).copy(pairedThemeName = null))
    }

    fun validated(preset: ThemePreset): ThemePreset {
        require(preset.themeName.length <= 4096) { "主题名称过长" }
        // Android permits an empty theme name; do not invent a different rename policy.
        return preset.copy(
            primaryColor = normalized(preset.primaryColor), accentColor = normalized(preset.accentColor),
            backgroundColor = normalized(preset.backgroundColor), bottomBackground = normalized(preset.bottomBackground),
        )
    }

    fun colorInt(raw: String): Int {
        if (hex.matches(raw)) {
            val value = raw.substring(1).toUInt(16)
            return (if (raw.length == 7) value or 0xff000000u else value).toInt()
        }
        return names[raw.lowercase()]?.toInt() ?: throw IllegalArgumentException("无效主题颜色: $raw")
    }

    private fun normalized(raw: String): String = "#" + colorInt(raw).toUInt().toString(16).padStart(8, '0').uppercase()
}
