package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.RssReadRecordRepository
import io.legado.kmp.shared.model.RssReadRecord

class RssReadRecordRepositoryImpl(
    private val database: LegadoDatabase
) : RssReadRecordRepository {

    override suspend fun insertRecord(vararg rssReadRecord: RssReadRecord) {
        rssReadRecord.forEach {
            database.rssReadRecordQueries.insertIgnoreRssReadRecord(
                record = it.record,
                title = it.title,
                read_time = it.readTime,
                read = if (it.read) 1L else 0L
            )
        }
    }

    override suspend fun getRecords(): List<RssReadRecord> {
        return database.rssReadRecordQueries.selectAllRssReadRecords(mapper = ::mapRecord).executeAsList()
    }

    override suspend fun countRecords(): Int = database.rssReadRecordQueries.countAllRssReadRecords().executeAsOne().toInt()

    override suspend fun deleteAllRecord() {
        database.rssReadRecordQueries.deleteAllRssReadRecords()
    }

    private fun mapRecord(
        record: String,
        title: String?,
        read_time: Long?,
        read: Long
    ): RssReadRecord {
        return RssReadRecord(
            record = record,
            title = title,
            readTime = read_time,
            read = read == 1L
        )
    }
}
