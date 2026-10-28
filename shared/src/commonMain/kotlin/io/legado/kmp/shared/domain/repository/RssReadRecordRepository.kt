package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.RssReadRecord

interface RssReadRecordRepository {
    suspend fun insertRecord(vararg rssReadRecord: RssReadRecord)
    suspend fun getRecords(): List<RssReadRecord>
    suspend fun countRecords(): Int
    suspend fun deleteAllRecord()
}
