package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink

/** Directory scripts update book variables independently from per-chapter variables. */
data class WebBookChapterList(val book: Book, val chapters: List<BookChapter>)

data class WebBookChapterContent(val chapter: BookChapter, val content: String)

/**
 * Repository for web book operations
 * Handles network book sources
 */
interface WebBookRepository {

    /**
     * Search books from a source
     *
     * @param source Book source to search
     * @param keyword Search keyword
     * @param page Page number (optional)
     * @return Result containing list of search books
     */
    suspend fun searchBook(
        source: BookSource,
        keyword: String,
        page: Int? = 1,
        filter: ((name: String, author: String) -> Boolean)? = null,
        shouldBreak: ((size: Int) -> Boolean)? = null,
        debugSink: BookSourceDebugSink? = null,
    ): Result<List<SearchBook>>

    /**
     * Explore books from a source (discover books)
     *
     * @param source Book source to explore
     * @param exploreUrl URL to explore
     * @param page Page number (optional)
     * @return Result containing list of search books
     */
    suspend fun exploreBook(
        source: BookSource,
        exploreUrl: String,
        page: Int? = 1,
        debugSink: BookSourceDebugSink? = null,
    ): Result<List<SearchBook>>

    /**
     * Get detailed book information
     *
     * @param source Book source
     * @param bookUrl Book detail page URL
     * @return Result containing Book with details
     */
    suspend fun getBookInfo(
        source: BookSource,
        bookUrl: String,
        debugSink: BookSourceDebugSink? = null,
    ): Result<Book>

    /**
     * Get detailed book information for an existing book.
     *
     * Aligned with legado WebBook.getBookInfoAwait():
     * - When [book.infoHtml] is non-empty, parses it directly (skip network request)
     * - [canReName] controls whether parsed name/author overwrite existing values
     *
     * @param source Book source
     * @param book Existing book (may have infoHtml pre-cached from search)
     * @param canReName Whether to allow overwriting existing name/author
     * @return Result containing updated Book with details
     */
    suspend fun getBookInfo(
        source: BookSource,
        book: Book,
        canReName: Boolean = true,
        debugSink: BookSourceDebugSink? = null,
    ): Result<Book> {
        // Default implementation delegates to URL-based method
        return getBookInfo(source, book.bookUrl, debugSink)
    }

    /**
     * Get chapter list for a book
     *
     * @param source Book source
     * @param book Book to get chapters for
     * @return Result containing list of chapters
     */
    suspend fun getChapterList(
        source: BookSource,
        book: Book,
        debugSink: BookSourceDebugSink? = null,
    ): Result<List<BookChapter>>

    suspend fun getChapterListWithBook(
        source: BookSource,
        book: Book,
        debugSink: BookSourceDebugSink? = null,
    ): Result<WebBookChapterList> = getChapterList(source, book, debugSink).map { WebBookChapterList(book, it) }

    /**
     * Get content for a chapter
     *
     * @param source Book source
     * @param book Book containing the chapter
     * @param chapter Chapter to get content for
     * @param needSave Whether to persist the content (aligned with legado needSave parameter).
     *   When true, the caller or an upper layer is expected to save the content to cache.
     *   This parameter is passed through for use by higher-level orchestration.
     * @return Result containing chapter content text
     */
    suspend fun getChapterContent(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
        needSave: Boolean = true,
        debugSink: BookSourceDebugSink? = null,
        nextChapterUrl: String? = null,
    ): Result<String>

    suspend fun getChapterContentWithChapter(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
        needSave: Boolean = true,
        debugSink: BookSourceDebugSink? = null,
        nextChapterUrl: String? = null,
    ): Result<WebBookChapterContent> = getChapterContent(
        source, book, chapter, needSave, debugSink, nextChapterUrl,
    ).map { WebBookChapterContent(chapter, it) }
}
