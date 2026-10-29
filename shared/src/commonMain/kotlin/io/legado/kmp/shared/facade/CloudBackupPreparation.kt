package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Facade-issued, single-use confirmation. No payload, password or account is exposed to native UI.
 * Summary counts describe eligible input rows, not inserts: restoration merges existing records.
 * preferencesRestored means a preferences section participates, subject to the captured ignore keys.
 */
class PreparedCloudBackup private constructor(
    preparation: CloudBackupPreparation,
    val summary: BackupRestoreResult,
    warnings: List<String>,
) {
    // A display-only copy must not retain CloudBackupFile.origin after discard/consumption.
    val file: CloudBackupFile = preparation.file.copy()
    private val warningSnapshot = warnings.toList()
    val warnings: List<String> get() = warningSnapshot.toList()
    private val pending = MutableStateFlow<CloudBackupPreparation?>(preparation)

    /** Idempotent and thread-safe. A commit already claimed by the facade is not interrupted. */
    fun discard() {
        pending.value = null
    }

    internal fun configuration(owner: Any, current: AppRuntimeConfig): CloudBackupConfiguration =
        currentPreparation(owner, current).config

    internal fun claim(owner: Any, current: AppRuntimeConfig): CloudBackupPreparation {
        val preparation = currentPreparation(owner, current)
        if (!pending.compareAndSet(preparation, null)) unavailable()
        return preparation
    }

    private fun currentPreparation(owner: Any, current: AppRuntimeConfig): CloudBackupPreparation {
        val preparation = pending.value ?: unavailable()
        if (preparation.owner !== owner) unavailable()
        if (!preparation.config.matches(current)) {
            pending.compareAndSet(preparation, null)
            cloudBackupError(
                "CLOUD_BACKUP_PREPARATION_EXPIRED",
                "WebDAV 配置或恢复忽略项已变化，请重新预检备份后确认恢复",
            )
        }
        return preparation
    }

    override fun toString(): String = "PreparedCloudBackup(redacted)"

    internal companion object {
        fun create(
            owner: Any,
            config: CloudBackupConfiguration,
            file: CloudBackupFile,
            payload: CloudBackupPayload,
        ): PreparedCloudBackup = PreparedCloudBackup(
            CloudBackupPreparation(owner, config, file.copy(), payload), payload.summary, payload.warnings,
        )

        private fun unavailable(): Nothing = cloudBackupError(
            "CLOUD_BACKUP_PREPARATION_UNAVAILABLE",
            "备份预检已丢弃、已使用或不属于当前操作，请重新预检后确认恢复",
        )
    }
}

/** Not a data class: generated copy/component/toString must never expose credentials or payload. */
internal class CloudBackupPreparation(
    val owner: Any,
    val config: CloudBackupConfiguration,
    val file: CloudBackupFile,
    val payload: CloudBackupPayload,
)
