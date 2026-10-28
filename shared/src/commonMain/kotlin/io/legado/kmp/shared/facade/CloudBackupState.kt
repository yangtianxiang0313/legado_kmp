package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class CloudBackupWatermark(
    val localBackupTime: Long = 0,
    val restoredTime: Long = 0,
    val uploadedTime: Long = 0,
    val seenModified: Long = 0,
    val seenName: String? = null,
) {
    val threshold: Long get() = maxOf(localBackupTime, restoredTime, uploadedTime, seenModified)
}

/** Reading never writes, removes, acknowledges or advances a watermark. */
internal class CloudBackupState(private val preferences: AppPreferencesStore) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun read(): Map<String, CloudBackupWatermark> {
        val stored = preferences.getBackupConfigJson(KEY) ?: return emptyMap()
        return try {
            json.decodeFromString<Map<String, CloudBackupWatermark>>(stored).also { scopes ->
                require(scopes.keys.all { it.length == 64 && it.all { char -> char in "0123456789abcdef" } })
                require(scopes.values.all {
                    it.localBackupTime >= 0 && it.restoredTime >= 0 && it.uploadedTime >= 0 && it.seenModified >= 0
                })
            }
        } catch (_: Exception) {
            cloudBackupError("CLOUD_BACKUP_INVALID_STATE", "云备份提示记录无法读取；未清除记录或自动恢复")
        }
    }

    fun save(scopes: Map<String, CloudBackupWatermark>) {
        preferences.setBackupConfigJson(KEY, json.encodeToString(scopes))
    }

    companion object {
        private const val KEY = "legado.cloudBackup.state.v1"
    }
}
