package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.flow.Flow

interface BookChapterRepository {

    fun observeChaptersByBookUrl(bookUrl: String): Flow<List<BookChapter>>

    suspend fun getChaptersByBookUrl(bookUrl: String): List<BookChapter>

    suspend fun getChapter(bookUrl: String, index: Int): BookChapter?

    suspend fun getChapter(bookUrl: String, title: String): BookChapter?

    suspend fun search(
        bookUrl: String,
        keyword: String,
        start: Int? = null,
        end: Int? = null
    ): List<BookChapter>

    suspend fun insert(chapter: BookChapter)

    suspend fun insertAll(chapters: List<BookChapter>)

    suspend fun update(chapter: BookChapter)

    suspend fun renameTitle(bookUrl: String, index: Int, expectedUrl: String, title: String): BookChapter

    suspend fun deleteByBookUrl(bookUrl: String)

    suspend fun getChapterCount(bookUrl: String): Int

    suspend fun replaceChapters(bookUrl: String, chapters: List<BookChapter>)

    suspend fun getLastChapterIndex(bookUrl: String): Int?

    suspend fun updateWordCount(bookUrl: String, chapterUrl: String, wordCount: String)
}
