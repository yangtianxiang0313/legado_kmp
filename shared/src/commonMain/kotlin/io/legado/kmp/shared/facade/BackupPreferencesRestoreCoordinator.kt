package io.legado.kmp.shared.facade

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.BackupPreferencesTransactionStore
import io.legado.kmp.shared.preferences.PreparedBackupPreferencesRestore
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.random.Random

/** The committed journal phase, not an interrupted caller's last instruction, selects recovery. */
internal object BackupPreferencesRestoreCoordinator {
    private val mutex = Mutex()

    suspend fun <T> serialized(
        database: LegadoDatabase?,
        preferences: AppPreferencesStore,
        block: suspend () -> T,
    ): T = mutex.withLock {
        recoverLocked(database, preferences)
        block()
    }

    fun recoverAtStartup(database: LegadoDatabase, preferences: AppPreferencesStore) = runBlocking {
        mutex.withLock { recoverLocked(database, preferences) }
        Unit
    }

    fun begin(database: LegadoDatabase, prepared: PreparedBackupPreferencesRestore): String {
        require(prepared.before.length <= MAX_PAYLOAD_LENGTH && prepared.after.length <= MAX_PAYLOAD_LENGTH) {
            "Prepared backup preferences exceed the recovery journal limit"
        }
        val id = Random.nextLong().toULong().toString(16) + Random.nextLong().toULong().toString(16)
        database.backupRestoreJournalQueries.insertPending(id, prepared.before, prepared.after)
        return id
    }

    fun markCommitted(database: LegadoDatabase, id: String) {
        database.backupRestoreJournalQueries.markCommitted(id)
        val row = database.backupRestoreJournalQueries.readPending().executeAsOneOrNull()
        check(row?.transactionId == id && row.state == "COMMITTED") { "Backup recovery journal ownership changed" }
    }

    fun acknowledge(database: LegadoDatabase, id: String) {
        database.backupRestoreJournalQueries.deletePending(id)
        check(database.backupRestoreJournalQueries.readPending().executeAsOneOrNull() == null) {
            "Backup recovery journal could not be cleared"
        }
    }

    /** Caller holds [mutex]. PREPARED survived outside the rolled-back data transaction. */
    fun recoverLocked(database: LegadoDatabase?, preferences: AppPreferencesStore): String? {
        val db = database ?: return null
        val row = db.backupRestoreJournalQueries.readPending().executeAsOneOrNull() ?: return null
        try {
            val platform = preferences as? BackupPreferencesTransactionStore
                ?: error("Transactional backup preferences unavailable")
            val payload = when (row.state) {
                "PREPARED" -> row.beforePayload
                "COMMITTED" -> row.afterPayload
                else -> error("Invalid backup recovery journal phase")
            }
            require(payload.length <= MAX_PAYLOAD_LENGTH)
            platform.applyPreparedBackupPreferencesRestore(payload)
            platform.publishBackupPreferencesRestore()
            acknowledge(db, row.transactionId)
            return row.state
        } catch (_: Exception) {
            // Keep the only durable before/after images; never expose their contents in errors or logs.
            throw RecoverableSharedException(
                "BACKUP_PREFERENCES_RECOVERY_REQUIRED",
                "上次备份恢复尚未完成，设置补偿失败；请重试或重新启动，恢复日志已保留",
            )
        }
    }

    private const val MAX_PAYLOAD_LENGTH = 12 * 1024 * 1024
}
