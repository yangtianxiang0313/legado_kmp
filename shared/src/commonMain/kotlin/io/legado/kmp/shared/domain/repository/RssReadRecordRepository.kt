package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.RssReadRecord
import kotlinx.coroutines.flow.Flow

interface RssReadRecordRepository {
    suspend fun insertRecord(vararg rssReadRecord: RssReadRecord)
    suspend fun getRecords(): List<RssReadRecord>
    fun observeRecords(): Flow<List<RssReadRecord>>
    suspend fun countRecords(): Int
    suspend fun deleteAllRecord()
}
