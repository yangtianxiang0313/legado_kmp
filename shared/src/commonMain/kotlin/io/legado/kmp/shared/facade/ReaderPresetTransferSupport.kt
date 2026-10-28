package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.ReaderPreset
import kotlinx.serialization.json.Json

/** Keeps portable single-scheme transfer separate from legacy preset-list imports. */
internal class ReaderPresetTransferSupport(private val store: AppPreferencesStore) {
    fun export(name: String): String? = try {
        store.readerPresetForExport(name)?.let { ReaderPresetTransferCodec().encode(it) }
    } catch (error: Exception) {
        throw error.asRecoverableSharedException("SettingsFacade.exportAndroidReaderPresetJson")
    }

    suspend fun replace(expectedName: String, jsonString: String, expectedIndex: Int? = null): ReaderPreset =
        runRecoverable("SettingsFacade.replaceAndroidReaderPreset") {
            val preset = ReaderPresetTransferCodec().decode(jsonString)
            store.replaceReaderPreset(expectedName, preset, expectedIndex)
        }

    suspend fun importAndroid(jsonString: String): ReaderPreset =
        runRecoverable("SettingsFacade.importAndroidReaderPreset") {
            val preset = ReaderPresetTransferCodec().decode(jsonString)
            store.upsertReaderPresetWithoutSelecting(preset)
        }

    suspend fun importLegacyEntries(entries: Map<String, ByteArray>): ReaderPreset =
        runRecoverable("SettingsFacade.importReaderPresetFromZip") {
            val bytes = entries["readConfig.json"]
                ?: throw RecoverableSharedException("MISSING_CONFIG", "ZIP does not contain readConfig.json")
            val preset = try {
                Json { ignoreUnknownKeys = true }.decodeFromString<ReaderPreset>(bytes.decodeToString())
            } catch (error: Exception) {
                throw RecoverableSharedException("INVALID_PRESET_JSON", "Invalid reader preset in ZIP: ${error.message}")
            }
            val names = store.readerPresets.map { it.name }.toSet()
            var name = preset.name
            var counter = 1
            while (name in names) {
                counter++
                name = "${preset.name} ($counter)"
            }
            preset.copy(name = name).also { store.importReaderPreset(it) }
        }
}
