package io.legado.kmp.shared.preferences

/** Platform-owned, durable encodings of the exact preference keys touched by one restore. */
data class PreparedBackupPreferencesRestore(val before: String, val after: String)

/** No method suspends: applying preferences must not release a thread-owned database transaction. */
interface BackupPreferencesTransactionStore {
    /** The entire callback and its database transaction stay on one thread. */
    @Throws(Exception::class)
    fun withBackupPreferencesRestoreLock(action: () -> Int): Int

    @Throws(Exception::class)
    fun prepareBackupPreferencesRestore(
        data: PreferencesBackupData,
        ignoredKeys: Set<String>,
    ): PreparedBackupPreferencesRestore

    @Throws(Exception::class)
    fun applyPreparedBackupPreferencesRestore(payload: String)

    /** Publish catalogs and flows only after the database outcome has been resolved. */
    @Throws(Exception::class)
    fun publishBackupPreferencesRestore()
}
