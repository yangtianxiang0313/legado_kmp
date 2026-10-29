package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import app.cash.sqldelight.coroutines.mapToOneOrNull
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.model.BookChapter
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow

class BookChapterRepositoryImpl(
    private val database: LegadoDatabase
) : BookChapterRepository {

    override fun observeChaptersByBookUrl(bookUrl: String): Flow<List<BookChapter>> =
        database.bookChapterQueries.selectByBookUrl(bookUrl, ::mapChapter)
            .asFlow().mapToList(Dispatchers.Default)

    override fun observeChapterByBookUrlAndIndex(bookUrl: String, index: Int): Flow<BookChapter?> =
        database.bookChapterQueries.selectByBookUrlAndIndex(bookUrl, index.toLong(), ::mapChapter)
            .asFlow().mapToOneOrNull(Dispatchers.Default)

    override suspend fun getChaptersByBookUrl(bookUrl: String): List<BookChapter> {
        return database.bookChapterQueries.selectByBookUrl(bookUrl, ::mapChapter).executeAsList()
    }

    override suspend fun getChapter(bookUrl: String, index: Int): BookChapter? {
        return database.bookChapterQueries
            .selectByBookUrlAndIndex(
                book_url = bookUrl,
                chapter_index = index.toLong(),
                mapper = ::mapChapter
            )
            .executeAsOneOrNull()
    }

    override suspend fun getChapter(bookUrl: String, title: String): BookChapter? {
        return database.bookChapterQueries
            .selectByBookUrlAndTitle(
                book_url = bookUrl,
                title = title,
                mapper = ::mapChapter
            )
            .executeAsOneOrNull()
    }

    override suspend fun search(
        bookUrl: String,
        keyword: String,
        start: Int?,
        end: Int?
    ): List<BookChapter> {
        return if (start != null && end != null) {
            database.bookChapterQueries.searchByBookUrlRange(
                book_url = bookUrl,
                chapter_index = start.toLong(),
                chapter_index_ = end.toLong(),
                value = keyword,
                mapper = ::mapChapter
            ).executeAsList()
        } else {
            database.bookChapterQueries.searchByBookUrl(
                book_url = bookUrl,
                value = keyword,
                mapper = ::mapChapter
            ).executeAsList()
        }
    }

    override suspend fun insert(chapter: BookChapter) {
        database.insertBookChapter(chapter)
    }

    override suspend fun insertAll(chapters: List<BookChapter>) {
        chapters.forEach { chapter ->
            insert(chapter)
        }
    }

    override suspend fun update(chapter: BookChapter) {
        database.bookChapterQueries.update(
            title = chapter.title,
            is_volume = chapter.isVolume.toSqlBoolean(),
            base_url = chapter.baseUrl,
            chapter_index = chapter.index.toLong(),
            is_vip = chapter.isVip.toSqlBoolean(),
            is_pay = chapter.isPay.toSqlBoolean(),
            resource_url = chapter.resourceUrl,
            tag = chapter.tag,
            word_count = chapter.wordCount,
            start = chapter.start,
            end = chapter.end,
            start_fragment_id = chapter.startFragmentId,
            end_fragment_id = chapter.endFragmentId,
            variable = chapter.variable,
            url = chapter.url,
            book_url = chapter.bookUrl
        )
    }

    override suspend fun deleteByBookUrl(bookUrl: String) {
        database.bookChapterQueries.deleteByBookUrl(bookUrl)
    }

    override suspend fun renameTitle(bookUrl: String, index: Int, expectedUrl: String, title: String): BookChapter {
        val context = coroutineContext
        context.ensureActive()
        return database.bookChapterQueries.transactionWithResult {
            context.ensureActive()
            val chapter = database.bookChapterQueries
                .selectByBookUrlAndIndex(bookUrl, index.toLong(), ::mapChapter).executeAsOneOrNull()
            require(chapter != null && chapter.url == expectedUrl) { "Chapter changed; reopen the content editor" }
            database.bookChapterQueries.updateTitle(title, bookUrl, index.toLong(), expectedUrl)
            context.ensureActive()
            chapter.copy(title = title)
        }
    }

    override suspend fun getChapterCount(bookUrl: String): Int {
        return database.bookChapterQueries.countByBookUrl(bookUrl).executeAsOne().toInt()
    }

    override suspend fun replaceChapters(bookUrl: String, chapters: List<BookChapter>) {
        database.bookChapterQueries.deleteByBookUrl(bookUrl)
        chapters.forEach { chapter ->
            insert(chapter)
        }
    }

    override suspend fun getLastChapterIndex(bookUrl: String): Int? {
        return getChaptersByBookUrl(bookUrl).maxOfOrNull(BookChapter::index)
    }

    override suspend fun updateWordCount(bookUrl: String, chapterUrl: String, wordCount: String) {
        database.bookChapterQueries.updateWordCount(
            word_count = wordCount,
            book_url = bookUrl,
            url = chapterUrl
        )
    }

    private fun mapChapter(
        url: String,
        title: String,
        is_volume: Long,
        base_url: String,
        book_url: String,
        chapter_index: Long,
        is_vip: Long,
        is_pay: Long,
        resource_url: String?,
        tag: String?,
        word_count: String?,
        start: Long?,
        end: Long?,
        start_fragment_id: String?,
        end_fragment_id: String?,
        variable: String?
    ): BookChapter = BookChapter.from(
        url = url,
        title = title,
        is_volume = is_volume,
        base_url = base_url,
        book_url = book_url,
        chapter_index = chapter_index,
        is_vip = is_vip,
        is_pay = is_pay,
        resource_url = resource_url,
        tag = tag,
        word_count = word_count,
        start = start,
        end = end,
        start_fragment_id = start_fragment_id,
        end_fragment_id = end_fragment_id,
        variable = variable
    )

    private fun Boolean.toSqlBoolean(): Long = if (this) 1L else 0L
}
