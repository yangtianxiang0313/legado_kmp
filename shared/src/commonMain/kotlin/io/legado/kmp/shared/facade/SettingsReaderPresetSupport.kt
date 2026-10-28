package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.ReaderPreset
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Legacy list-management semantics stay separate from Android single-config upserts. */
internal class SettingsReaderPresetSupport(private val store: AppPreferencesStore) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; prettyPrint = true }

    fun decode(payload: String): List<ReaderPreset> = try {
        json.decodeFromString<List<ReaderPreset>>(payload)
    } catch (error: Exception) {
        throw error.asRecoverableSharedException("SettingsFacade.decodeReaderPresets")
    }

    fun export(name: String): String? = store.readerPresetForExport(name)?.let { json.encodeToString(it) }

    fun exportAll(): String = json.encodeToString(store.readerPresets)

    suspend fun importLegacy(payload: String) = runRecoverable("SettingsFacade.importReaderPresetJson") {
        val preset = try {
            json.decodeFromString<ReaderPreset>(payload)
        } catch (error: Exception) {
            throw RecoverableSharedException("INVALID_PRESET_JSON", "Invalid reader preset JSON: ${error.message}")
        }
        if (preset.name.isBlank()) {
            throw RecoverableSharedException("EMPTY_PRESET_NAME", "Reader preset name cannot be empty")
        }
        val names = store.readerPresets.map { it.name }.toSet()
        var name = preset.name
        var counter = 1
        while (name in names) {
            counter++
            name = "${preset.name} ($counter)"
        }
        store.importReaderPreset(preset.copy(name = name))
    }

    suspend fun reorder(names: List<String>) = runRecoverable("SettingsFacade.reorderReaderPresets") {
        val current = store.readerPresets
        val ordered = mutableListOf<ReaderPreset>()
        val remaining = current.toMutableList()
        for (name in names) {
            val found = remaining.firstOrNull { it.name == name }
            if (found != null) {
                ordered.add(found)
                remaining.remove(found)
            }
        }
        ordered.addAll(remaining)
        for (preset in current) store.deleteReaderPreset(preset.name)
        for (preset in ordered) store.importReaderPreset(preset)
    }

    suspend fun importAll(payload: String) = runRecoverable("SettingsFacade.importAllReaderPresetsJson") {
        val presets = try {
            json.decodeFromString<List<ReaderPreset>>(payload)
        } catch (error: Exception) {
            throw RecoverableSharedException("INVALID_PRESET_JSON", "Invalid reader presets JSON: ${error.message}")
        }
        if (presets.isEmpty()) {
            throw RecoverableSharedException("EMPTY_PRESET_LIST", "Reader presets list cannot be empty")
        }
        for (existing in store.readerPresets) store.deleteReaderPreset(existing.name)
        for (preset in presets) store.importReaderPreset(preset)
    }
}
