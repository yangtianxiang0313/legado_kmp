package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.ReadRecord
import io.legado.kmp.shared.model.ReadRecordShow
import io.legado.kmp.shared.model.ReadRecordSnapshot

interface ReadRecordRepository {
    /** Filtered records and unfiltered total in one transaction, using exact Long sums that saturate on overflow. */
    suspend fun loadSnapshot(query: String, enabled: Boolean): ReadRecordSnapshot

    /** Atomically add a nonnegative delta to deviceId="" only; zero is a no-op and overflow saturates. */
    suspend fun addReadTime(bookName: String, elapsedMillis: Long, lastRead: Long): Unit

    /** Initialize the local row without overwriting any existing record. */
    suspend fun ensureLocalRecord(bookName: String, lastRead: Long): Unit
    suspend fun getAll(): List<ReadRecord>
    suspend fun getAllShow(): List<ReadRecordShow>
    suspend fun getAllTime(): Long
    suspend fun search(searchKey: String): List<ReadRecordShow>
    suspend fun getReadTime(bookName: String): Long?
    suspend fun getReadTime(deviceId: String, bookName: String): Long?
    suspend fun insert(record: ReadRecord)
    suspend fun update(record: ReadRecord)
    suspend fun delete(record: ReadRecord)
    suspend fun clear()
    suspend fun deleteByName(bookName: String)
}
