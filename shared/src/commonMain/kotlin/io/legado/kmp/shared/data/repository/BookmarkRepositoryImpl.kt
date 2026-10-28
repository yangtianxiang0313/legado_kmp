package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.BookmarkRepository
import io.legado.kmp.shared.model.Bookmark
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * SQLDelight implementation of BookmarkRepository
 * Uses the generated SQLDelight queries for database operations
 */
class BookmarkRepositoryImpl(
    private val database: LegadoDatabase
) : BookmarkRepository {

    override fun observeAllBookmarks(): Flow<List<Bookmark>> {
        return database.bookmarkQueries
            .selectAll()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list ->
                list.map { bookmark ->
                    Bookmark.from(
                        time = bookmark.time,
                        book_name = bookmark.book_name,
                        book_author = bookmark.book_author,
                        chapter_index = bookmark.chapter_index,
                        chapter_pos = bookmark.chapter_pos,
                        chapter_name = bookmark.chapter_name,
                        book_text = bookmark.book_text,
                        content = bookmark.content
                    )
                }
            }
    }

    override fun observeByBook(bookName: String, bookAuthor: String): Flow<List<Bookmark>> {
        return database.bookmarkQueries
            .selectByBook(bookName, bookAuthor)
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { list ->
                list.map { bookmark ->
                    Bookmark.from(
                        time = bookmark.time,
                        book_name = bookmark.book_name,
                        book_author = bookmark.book_author,
                        chapter_index = bookmark.chapter_index,
                        chapter_pos = bookmark.chapter_pos,
                        chapter_name = bookmark.chapter_name,
                        book_text = bookmark.book_text,
                        content = bookmark.content
                    )
                }
            }
    }

    override suspend fun getAllBookmarks(): List<Bookmark> {
        return database.bookmarkQueries
            .selectAll()
            .executeAsList()
            .map { bookmark ->
                Bookmark.from(
                    time = bookmark.time,
                    book_name = bookmark.book_name,
                    book_author = bookmark.book_author,
                    chapter_index = bookmark.chapter_index,
                    chapter_pos = bookmark.chapter_pos,
                    chapter_name = bookmark.chapter_name,
                    book_text = bookmark.book_text,
                    content = bookmark.content
                )
            }
    }

    override suspend fun getByBook(bookName: String, bookAuthor: String): List<Bookmark> {
        return database.bookmarkQueries
            .selectByBook(bookName, bookAuthor)
            .executeAsList()
            .map { bookmark ->
                Bookmark.from(
                    time = bookmark.time,
                    book_name = bookmark.book_name,
                    book_author = bookmark.book_author,
                    chapter_index = bookmark.chapter_index,
                    chapter_pos = bookmark.chapter_pos,
                    chapter_name = bookmark.chapter_name,
                    book_text = bookmark.book_text,
                    content = bookmark.content
                )
            }
    }

    override suspend fun getByTime(time: Long): Bookmark? {
        return database.bookmarkQueries
            .selectByTime(time)
            .executeAsOneOrNull()?.let { bookmark ->
                Bookmark.from(
                    time = bookmark.time,
                    book_name = bookmark.book_name,
                    book_author = bookmark.book_author,
                    chapter_index = bookmark.chapter_index,
                    chapter_pos = bookmark.chapter_pos,
                    chapter_name = bookmark.chapter_name,
                    book_text = bookmark.book_text,
                    content = bookmark.content
                )
            }
    }

    override suspend fun searchInBook(
        bookName: String,
        bookAuthor: String,
        key: String
    ): List<Bookmark> {
        val searchPattern = "%$key%"
        return database.bookmarkQueries
            .searchInBook(bookName, bookAuthor, searchPattern, searchPattern, searchPattern)
            .executeAsList()
            .map { bookmark ->
                Bookmark.from(
                    time = bookmark.time,
                    book_name = bookmark.book_name,
                    book_author = bookmark.book_author,
                    chapter_index = bookmark.chapter_index,
                    chapter_pos = bookmark.chapter_pos,
                    chapter_name = bookmark.chapter_name,
                    book_text = bookmark.book_text,
                    content = bookmark.content
                )
            }
    }

    override suspend fun insert(bookmark: Bookmark): Long {
        database.bookmarkQueries.insert(
            time = bookmark.time,
            book_name = bookmark.bookName,
            book_author = bookmark.bookAuthor,
            chapter_index = bookmark.chapterIndex.toLong(),
            chapter_pos = bookmark.chapterPos.toLong(),
            chapter_name = bookmark.chapterName,
            book_text = bookmark.bookText,
            content = bookmark.content
        )
        return bookmark.time
    }

    override suspend fun update(bookmark: Bookmark) {
        database.bookmarkQueries.update(
            book_name = bookmark.bookName,
            book_author = bookmark.bookAuthor,
            chapter_index = bookmark.chapterIndex.toLong(),
            chapter_pos = bookmark.chapterPos.toLong(),
            chapter_name = bookmark.chapterName,
            book_text = bookmark.bookText,
            content = bookmark.content,
            time = bookmark.time
        )
    }

    override suspend fun updateContent(time: Long, content: String) {
        database.bookmarkQueries.updateContent(content, time)
    }

    override suspend fun deleteByTime(time: Long) {
        database.bookmarkQueries.deleteByTime(time)
    }

    override suspend fun deleteByBook(bookName: String, bookAuthor: String) {
        database.bookmarkQueries.deleteByBook(bookName, bookAuthor)
    }

    override suspend fun deleteAll() {
        database.bookmarkQueries.deleteAll()
    }

    override suspend fun save(bookmark: Bookmark) {
        // Since we use INSERT OR REPLACE in the schema, we can use insert directly
        insert(bookmark)
    }

    override suspend fun countByBook(bookName: String, bookAuthor: String): Int {
        return getByBook(bookName, bookAuthor).size
    }
}
