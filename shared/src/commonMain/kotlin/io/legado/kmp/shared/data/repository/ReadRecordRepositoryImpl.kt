package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.model.ReadRecord
import io.legado.kmp.shared.model.ReadRecordShow
import io.legado.kmp.shared.model.ReadRecordSnapshot

class ReadRecordRepositoryImpl(
    private val database: LegadoDatabase
) : ReadRecordRepository {

    override suspend fun loadSnapshot(query: String, enabled: Boolean): ReadRecordSnapshot {
        return database.readRecordQueries.transactionWithResult {
            val all = allAggregationRows()
            ReadRecordSnapshot(
                records = aggregate(if (query.isEmpty()) all else searchAggregationRows(query)),
                totalReadTime = sumTime(all),
                enabled = enabled
            )
        }
    }

    override suspend fun addReadTime(bookName: String, elapsedMillis: Long, lastRead: Long): Unit {
        require(elapsedMillis >= 0L) { "elapsedMillis must not be negative" }
        if (elapsedMillis == 0L) return

        val timestamp = lastRead.coerceAtLeast(0L)
        database.readRecordQueries.transaction {
            database.readRecordQueries.ensureLocalRecord(book_name = bookName, last_read = timestamp)
            database.readRecordQueries.addLocalReadTime(
                elapsedMillis = elapsedMillis,
                lastRead = timestamp,
                book_name = bookName
            )
        }
    }

    override suspend fun ensureLocalRecord(bookName: String, lastRead: Long): Unit {
        database.readRecordQueries.ensureLocalRecord(book_name = bookName, last_read = lastRead.coerceAtLeast(0L))
    }

    override suspend fun getAll(): List<ReadRecord> {
        return database.readRecordQueries.selectAll(
            mapper = ReadRecord::from
        ).executeAsList()
    }

    override suspend fun getAllShow(): List<ReadRecordShow> {
        return database.readRecordQueries.transactionWithResult { aggregate(allAggregationRows()) }
    }

    override suspend fun getAllTime(): Long {
        return database.readRecordQueries.transactionWithResult { sumTime(allAggregationRows()) }
    }

    override suspend fun search(searchKey: String): List<ReadRecordShow> {
        return database.readRecordQueries.transactionWithResult { aggregate(searchAggregationRows(searchKey)) }
    }

    override suspend fun getReadTime(bookName: String): Long? {
        return database.readRecordQueries.transactionWithResult {
            val rows = database.readRecordQueries.selectByBookName(bookName, mapper = ReadRecord::from).executeAsList()
            if (rows.isEmpty()) null else sumTime(rows)
        }
    }

    override suspend fun getReadTime(deviceId: String, bookName: String): Long? {
        return database.readRecordQueries.selectReadTimeByDeviceAndBook(deviceId, bookName).executeAsOneOrNull()
    }

    override suspend fun insert(record: ReadRecord) {
        database.readRecordQueries.insert(
            device_id = record.deviceId,
            book_name = record.bookName,
            read_time = record.readTime,
            last_read = record.lastRead
        )
    }

    override suspend fun update(record: ReadRecord) {
        database.readRecordQueries.update(
            read_time = record.readTime,
            last_read = record.lastRead,
            device_id = record.deviceId,
            book_name = record.bookName
        )
    }

    override suspend fun delete(record: ReadRecord) {
        database.readRecordQueries.deleteByPrimaryKey(
            device_id = record.deviceId,
            book_name = record.bookName
        )
    }

    override suspend fun clear() {
        database.readRecordQueries.clear()
    }

    override suspend fun deleteByName(bookName: String) {
        database.readRecordQueries.deleteByBookName(bookName)
    }

    private fun allAggregationRows(): List<ReadRecord> = database.readRecordQueries
        .selectAllForAggregation(mapper = ReadRecord::from).executeAsList()

    private fun searchAggregationRows(query: String): List<ReadRecord> = database.readRecordQueries
        .searchForAggregation(query, mapper = ReadRecord::from).executeAsList()

    private fun aggregate(rows: List<ReadRecord>): List<ReadRecordShow> {
        val records = linkedMapOf<String, ReadRecordShow>()
        for (row in rows) {
            val previous = records[row.bookName]
            records[row.bookName] = ReadRecordShow(
                bookName = row.bookName,
                readTime = addTime(previous?.readTime ?: 0L, row.readTime),
                lastRead = maxOf(previous?.lastRead ?: 0L, row.lastRead),
            )
        }
        return records.values.toList()
    }

    private fun sumTime(rows: List<ReadRecord>): Long = rows.fold(0L) { total, row -> addTime(total, row.readTime) }

    // Keep ordinary totals exact; imported negative values contribute zero and overflow saturates.
    private fun addTime(total: Long, value: Long): Long {
        val increment = value.coerceAtLeast(0L)
        return if (total > Long.MAX_VALUE - increment) Long.MAX_VALUE else total + increment
    }
}
