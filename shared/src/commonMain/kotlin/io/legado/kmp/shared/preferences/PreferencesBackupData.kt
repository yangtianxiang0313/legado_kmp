package io.legado.kmp.shared.preferences

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/** Preferences and Android-compatible appearance presets, independent of database records. */
@Serializable
data class PreferencesBackupData(
    val appConfig: JsonObject = JsonObject(emptyMap()),
    val readConfig: List<ReaderPreset> = emptyList(),
    val themeConfig: List<ThemePreset> = emptyList(),
)
