package io.legado.kmp.shared.preferences

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import platform.Foundation.NSNumber
import platform.Foundation.NSUserDefaults

/** Catalog mutations and active day/night colors are independent, as in ThemeConfig. */
internal class IosThemePresetPersistence(private val defaults: NSUserDefaults) {
    // New snapshots use Android's six fields; only legacy paired presets carry the optional seventh.
    private val json = Json { encodeDefaults = true; explicitNulls = false }
    var presets: List<ThemePreset> = IosPreferencesBackup.loadThemes(defaults)
        private set

    fun reload() { presets = IosPreferencesBackup.loadThemes(defaults) }

    fun pinCatalogIfMissing() {
        if (defaults.objectForKey(CATALOG) == null) persist(presets)
    }

    fun palette(isNightTheme: Boolean): ThemeColorPalette {
        val catalog = IosPreferencesBackup.loadThemes(defaults)
        val name = defaults.stringForKey("theme_preset_name") ?: ""
        val selected = catalog.firstOrNull { it.themeName == name }
            ?: DefaultUiPresets.legacyThemePresets.firstOrNull { it.themeName == name }
        val preset = if (selected?.isNightTheme == isNightTheme) selected else {
            selected?.pairedThemeName?.let { pairedName ->
                catalog.firstOrNull {
                    it.themeName == pairedName && it.pairedThemeName == name && it.isNightTheme == isNightTheme
                }
            }
        }
        fun color(field: ThemeColorField): String {
            val fallback = ThemePaletteColors.defaultColor(isNightTheme, field)
            var value = rawColor(key(field, isNightTheme))
                ?: preset?.color(field)?.let(::parsedColor) ?: fallback
            if (field == ThemeColorField.BACKGROUND && ThemePaletteColors.isLight(value) == isNightTheme) {
                value = fallback
            }
            return ThemePaletteColors.hex(value)
        }
        return ThemeColorPalette(
            isNightTheme, color(ThemeColorField.PRIMARY), color(ThemeColorField.ACCENT),
            color(ThemeColorField.BACKGROUND), color(ThemeColorField.BOTTOM_BACKGROUND),
        )
    }

    fun setColor(isNightTheme: Boolean, field: ThemeColorField, color: String) {
        val value = ThemePaletteColors.editableColor(isNightTheme, field, color)
        defaults.setInteger(value.toLong(), key(field, isNightTheme))
        defaults.synchronize()
    }

    fun savePalette(themeName: String, isNightTheme: Boolean) {
        require(themeName.length <= 4096) { "主题名称过长" }
        val colors = palette(isNightTheme)
        import(ThemePreset(
            themeName, isNightTheme, colors.primaryColor, colors.accentColor,
            colors.backgroundColor, colors.bottomBackground,
        ))
    }

    fun apply(name: String, switchMode: Boolean) {
        val source = presets.firstOrNull { it.themeName == name }
            ?: DefaultUiPresets.legacyThemePresets.firstOrNull { it.themeName == name }
            ?: throw IllegalArgumentException("主题已不存在")
        val preset = ThemePresetCodec.validated(source)
        // Validate every value before publishing any preference change.
        val pair = preset.pairedThemeName?.let { pairedName ->
            presets.firstOrNull {
                it.themeName == pairedName && it.pairedThemeName == name && it.isNightTheme != preset.isNightTheme
            }?.let(ThemePresetCodec::validated)
        }
        preserveActiveIfNeeded()
        pinCatalogIfMissing()
        writeColors(preset)
        pair?.let { writeColors(it) }
        defaults.setObject(name, "theme_preset_name")
        if (switchMode) defaults.setObject(if (preset.isNightTheme) ThemeMode.DARK.name else ThemeMode.LIGHT.name, "theme_mode")
        defaults.synchronize()
    }

    fun import(preset: ThemePreset) {
        val validated = ThemePresetCodec.validated(preset)
        val updated = presets.toMutableList()
        val index = updated.indexOfFirst { it.themeName == validated.themeName }
        if (index < 0) updated.add(validated) else updated[index] = validated
        preserveActiveIfNeeded()
        persist(updated)
    }

    fun delete(name: String) {
        require(presets.any { it.themeName == name }) { "主题已不存在" }
        preserveActiveIfNeeded()
        persist(presets.filterNot { it.themeName == name })
    }

    private fun persist(values: List<ThemePreset>) {
        defaults.setObject(json.encodeToString(values), CATALOG)
        defaults.synchronize()
        presets = values
    }

    private fun preserveActiveIfNeeded() {
        // Freeze both effective channels before a catalog replacement can change a legacy fallback.
        val palettes = listOf(palette(false), palette(true))
        palettes.forEach { palette ->
            ThemeColorField.entries.forEach { field ->
                val key = key(field, palette.isNightTheme)
                if (rawColor(key) == null) {
                    val raw = when (field) {
                        ThemeColorField.PRIMARY -> palette.primaryColor
                        ThemeColorField.ACCENT -> palette.accentColor
                        ThemeColorField.BACKGROUND -> palette.backgroundColor
                        ThemeColorField.BOTTOM_BACKGROUND -> palette.bottomBackground
                    }
                    defaults.setInteger(ThemePresetCodec.colorInt(raw).toLong(), key)
                }
            }
        }
    }

    private fun writeColors(preset: ThemePreset) {
        ThemeColorField.entries.forEach { field ->
            var value = ThemePresetCodec.colorInt(preset.color(field))
            if (field == ThemeColorField.BACKGROUND && ThemePaletteColors.isLight(value) == preset.isNightTheme) {
                value = ThemePaletteColors.defaultColor(preset.isNightTheme, field)
            }
            defaults.setInteger(value.toLong(), key(field, preset.isNightTheme))
        }
    }

    private fun rawColor(key: String): Int? = when (val value = defaults.objectForKey(key)) {
        is NSNumber -> value.longLongValue.toInt()
        is Number -> value.toLong().toInt()
        is String -> parsedColor(value)
        else -> null
    }

    private fun parsedColor(raw: String): Int? = runCatching {
        // The existing iOS palette also accepts old backup hex strings without '#'.
        val value = if (!raw.startsWith('#') && (raw.length == 6 || raw.length == 8) && raw.toUIntOrNull(16) != null) {
            "#$raw"
        } else raw
        ThemePresetCodec.colorInt(value)
    }.getOrNull()

    private fun key(field: ThemeColorField, isNightTheme: Boolean): String = when (field) {
        ThemeColorField.PRIMARY -> "colorPrimary"
        ThemeColorField.ACCENT -> "colorAccent"
        ThemeColorField.BACKGROUND -> "colorBackground"
        ThemeColorField.BOTTOM_BACKGROUND -> "colorBottomBackground"
    } + if (isNightTheme) "Night" else ""

    private fun ThemePreset.color(field: ThemeColorField): String = when (field) {
        ThemeColorField.PRIMARY -> primaryColor
        ThemeColorField.ACCENT -> accentColor
        ThemeColorField.BACKGROUND -> backgroundColor
        ThemeColorField.BOTTOM_BACKGROUND -> bottomBackground
    }

    private companion object { const val CATALOG = "backup_theme_presets" }
}
