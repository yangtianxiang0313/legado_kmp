package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.model.BackupData
import io.legado.kmp.shared.model.ReadRecord

/**
 * Restores core rows synchronously inside the caller's SQL transaction.
 * The caller filters ignored books and coordinates preferences with the enclosing transaction.
 * Returns the number of read-record rows written, including newer duplicates in this batch.
 */
internal fun restoreBackupCoreTables(
    database: LegadoDatabase,
    data: BackupData,
    checkActive: () -> Unit,
): Int {
    checkActive()
    val books = BookRepositoryImpl(database)
    data.bookshelf.forEach { book ->
        checkActive()
        books.restoreFromBackup(book)
    }

    val bookSources = BookSourceRepositoryImpl(database)
    data.bookSource.forEach { bookSource ->
        checkActive()
        bookSources.restoreFromBackup(bookSource)
    }

    data.bookGroup.forEach { group ->
        checkActive()
        val existing = database.bookGroupQueries.selectById(group.groupId).executeAsOneOrNull()
        if (existing != null) {
            database.bookGroupQueries.update(
                group_name = group.groupName,
                cover = group.cover,
                order = group.order.toLong(),
                enable_refresh = if (group.enableRefresh) 1L else 0L,
                show = if (group.show) 1L else 0L,
                book_sort = group.bookSort.toLong(),
                group_id = group.groupId,
            )
        } else {
            database.bookGroupQueries.insert(
                group_id = group.groupId,
                group_name = group.groupName,
                cover = group.cover,
                order = group.order.toLong(),
                enable_refresh = if (group.enableRefresh) 1L else 0L,
                show = if (group.show) 1L else 0L,
                book_sort = group.bookSort.toLong(),
            )
        }
    }

    data.bookmark.forEach { bookmark ->
        checkActive()
        database.bookmarkQueries.insert(
            time = bookmark.time,
            book_name = bookmark.bookName,
            book_author = bookmark.bookAuthor,
            chapter_index = bookmark.chapterIndex.toLong(),
            chapter_pos = bookmark.chapterPos.toLong(),
            chapter_name = bookmark.chapterName,
            book_text = bookmark.bookText,
            content = bookmark.content,
        )
    }

    val restoredReadRecords = restoreBackupReadRecords(database, data.readRecord, checkActive)
    checkActive()
    return restoredReadRecords
}

private fun restoreBackupReadRecords(
    database: LegadoDatabase,
    records: List<ReadRecord>,
    checkActive: () -> Unit,
): Int {
    if (records.isEmpty()) return 0
    checkActive()
    val existingRecords = mutableMapOf<Pair<String, String>, ReadRecord>()
    database.readRecordQueries.selectAll { deviceId, bookName, readTime, lastRead ->
        checkActive()
        ReadRecord.from(deviceId, bookName, readTime, lastRead)
    }.executeAsList().forEach { record ->
        checkActive()
        existingRecords[record.deviceId to record.bookName] = record
    }

    var restored = 0
    records.forEach { record ->
        checkActive()
        val key = record.deviceId to record.bookName
        val existing = existingRecords[key]
        if (existing == null || record.readTime > existing.readTime ||
            (record.readTime == existing.readTime && record.lastRead > existing.lastRead)) {
            val merged = record.copy(lastRead = maxOf(record.lastRead, existing?.lastRead ?: 0L))
            database.readRecordQueries.insert(
                device_id = merged.deviceId,
                book_name = merged.bookName,
                read_time = merged.readTime,
                last_read = merged.lastRead,
            )
            existingRecords[key] = merged
            restored++
        }
    }
    return restored
}
