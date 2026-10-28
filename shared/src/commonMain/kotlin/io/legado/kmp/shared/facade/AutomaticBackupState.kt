package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
internal data class AutomaticBackupWatermark(
    val lastSuccess: Long = 0,
    val failures: Int = 0,
    val retryAfter: Long = 0,
)

/** Schedule only. No account, URL, backup data, password or key material. */
internal class AutomaticBackupState(private val preferences: AppPreferencesStore) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    fun read(): Map<String, AutomaticBackupWatermark> {
        val stored = preferences.getBackupConfigJson(KEY) ?: return emptyMap()
        return try {
            require(stored.length <= 64 * 1024)
            json.decodeFromString<Map<String, AutomaticBackupWatermark>>(stored).also { values ->
                require(values.size <= 128)
                require(values.keys.all { it.length == 64 && it.all { char -> char in "0123456789abcdef" } })
                require(values.values.all { it.lastSuccess >= 0 && it.retryAfter >= 0 && it.failures in 0..16 })
            }
        } catch (_: Exception) {
            cloudBackupError("AUTOMATIC_BACKUP_INVALID_STATE", "自动备份记录无法读取，未清除记录或执行备份")
        }
    }

    fun success(identifier: String, now: Long) {
        val values = read()
        save(values + (identifier to AutomaticBackupWatermark(lastSuccess = maxOf(values[identifier]?.lastSuccess ?: 0, now))))
    }

    fun failure(identifier: String, now: Long): Long {
        val values = read()
        val prior = values[identifier] ?: AutomaticBackupWatermark()
        val count = (prior.failures + 1).coerceAtMost(16)
        val delay = (60_000L shl (count - 1).coerceAtMost(9)).coerceAtMost(MAX_RETRY_DELAY)
        val next = now.coerceAtMost(Long.MAX_VALUE - delay) + delay
        save(values + (identifier to prior.copy(failures = count, retryAfter = next)))
        return next
    }

    private fun save(values: Map<String, AutomaticBackupWatermark>) {
        val retained = values.entries.sortedByDescending { maxOf(it.value.lastSuccess, it.value.retryAfter) }
            .take(128).associate { it.key to it.value }
        preferences.setBackupConfigJson(KEY, json.encodeToString(retained))
    }

    companion object {
        const val DAY_MILLIS = 86_400_000L
        const val MAX_RETRY_DELAY = 6 * 60 * 60_000L
        private const val KEY = "legado.automaticBackup.state.v1"

        // Android Backup.shouldBackup uses lastBackup + DAYS(1) < now, not a calendar-day test.
        fun nextDue(lastSuccess: Long): Long =
            lastSuccess.coerceAtMost(Long.MAX_VALUE - DAY_MILLIS - 1) + DAY_MILLIS + 1
    }
}
