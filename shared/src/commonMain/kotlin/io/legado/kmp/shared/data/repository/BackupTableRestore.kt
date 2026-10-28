package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.model.BackupData

/** Every DAO uses this driver's transaction; no suspension may release its thread-owned connection. */
internal fun restoreBackupTables(database: LegadoDatabase, data: BackupData, checkActive: () -> Unit): Int =
    database.bookQueries.transactionWithResult {
        checkActive()
        val readRecords = restoreBackupCoreTables(database, data, checkActive)
        restoreBackupAuxiliaryTables(database, data, checkActive)
        checkActive()
        readRecords
    }
