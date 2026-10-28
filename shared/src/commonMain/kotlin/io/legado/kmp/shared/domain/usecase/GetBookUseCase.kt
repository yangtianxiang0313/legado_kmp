package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.EpubCatalogReflowPlan
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ChapterListReorderResult
import io.legado.kmp.shared.domain.repository.ReadingProgressUpdateResult
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.flow.Flow
import kotlin.coroutines.cancellation.CancellationException

/**
 * Use case for getting books
 */
class GetBooksUseCase(
    private val repository: BookRepository
) {
    /**
     * Observe all books
     */
    operator fun invoke(): Flow<List<Book>> {
        return repository.observeAllBooks()
    }

    /**
     * Observe books by group
     */
    fun getByGroup(groupId: Long): Flow<List<Book>> {
        return repository.observeBooksByGroup(groupId)
    }

    /**
     * Get all books (one-time)
     */
    suspend fun getAll(): List<Book> {
        return repository.getAllBooks()
    }

    /**
     * Get recent books
     */
    suspend fun getRecent(limit: Int = 10): List<Book> {
        return repository.getRecentBooks(limit)
    }

    /**
     * Get updated books
     */
    suspend fun getUpdated(limit: Int = 10): List<Book> {
        return repository.getUpdatedBooks(limit)
    }
}

/**
 * Use case for getting a single book
 */
class GetBookUseCase(
    private val repository: BookRepository
) {
    /**
     * Observe a book by URL
     */
    operator fun invoke(bookUrl: String): Flow<Book?> {
        return repository.observeBook(bookUrl)
    }

    /**
     * Get a book by URL (one-time)
     */
    suspend fun get(bookUrl: String): Book? {
        return repository.getBook(bookUrl)
    }

    /**
     * Check if a book exists
     */
    suspend fun exists(bookUrl: String): Boolean {
        return repository.getBook(bookUrl) != null
    }
}

/**
 * Use case for saving a book
 */
class SaveBookUseCase(
    private val repository: BookRepository
) {
    /**
     * Insert or update a book
     */
    suspend operator fun invoke(book: Book) {
        repository.insertOrUpdate(book)
    }

    /** Insert a local book and its chapters without changing any existing book at the same URL. */
    @Throws(Exception::class)
    suspend fun insertLocalBookIfAbsent(book: Book, chapters: List<BookChapter>): Book {
        return repository.insertLocalBookIfAbsent(book, chapters)
    }

    /** Only an explicit preview/read action may recreate a missing NOT_SHELF book. */
    suspend fun insertPreviewIfAbsent(book: Book): Book {
        return repository.insertPreviewIfAbsent(book)
    }

    /** Save metadata without replacing progress changed by an active reader. */
    suspend fun preservingReadingProgress(book: Book): Book {
        return repository.insertOrUpdatePreservingReadingProgress(book)
    }

    suspend fun updateGroup(bookUrl: String, groupId: Long): Book? {
        return repository.updateGroupPreservingState(bookUrl, groupId, addToShelf = groupId > 0)
    }

    suspend fun completePreviewReadingExit(bookUrl: String, expectedOrigin: String, addToShelf: Boolean): Book? {
        return repository.completePreviewReadingExit(bookUrl, expectedOrigin, addToShelf)
    }

    /** 仅更新编辑字段并保留其他状态；null 保持原值，bookType 为 0 正文 / 1 音频 / 2 图片。 */
    suspend fun updateBookInfo(
        bookUrl: String,
        name: String? = null,
        author: String? = null,
        coverUrl: String? = null,
        intro: String? = null,
        bookType: Int? = null,
    ): Book? {
        return repository.updateBookInfoPreservingState(
            bookUrl = bookUrl,
            name = name,
            author = author,
            coverUrl = coverUrl,
            intro = intro,
            bookType = bookType,
        )
    }

    suspend fun updateCustomVariable(bookUrl: String, expectedOrigin: String, value: String): Book {
        return repository.updateCustomVariable(bookUrl, expectedOrigin, value)
            ?: throw CancellationException("Book was removed or its source changed")
    }

    suspend fun updatePageAnimation(bookUrl: String, expectedOrigin: String, pageAnimation: Int): Book {
        return repository.updatePageAnimation(bookUrl, expectedOrigin, pageAnimation)
            ?: throw CancellationException("Book was removed or its source changed")
    }

    suspend fun updateReadSimulation(
        bookUrl: String,
        expectedOrigin: String,
        enabled: Boolean,
        startDateIso: String,
        startChapter: Int,
        dailyChapters: Int,
    ): Book {
        return repository.updateReadSimulation(bookUrl, expectedOrigin, enabled, startDateIso, startChapter, dailyChapters)
            ?: throw CancellationException("Cannot update read simulation: book was removed or its source changed")
    }

    suspend fun updateImageStyle(bookUrl: String, expectedOrigin: String, imageStyle: String): Book {
        return repository.updateImageStyle(bookUrl, expectedOrigin, imageStyle)
            ?: throw CancellationException("Cannot update image style: book was removed or its source changed")
    }

    suspend fun updateCharset(bookUrl: String, expectedOrigin: String, charset: String): Book {
        return repository.updateCharset(bookUrl, expectedOrigin, charset)
            ?: throw CancellationException("Cannot update charset: book was removed or its source changed")
    }

    /** Save metadata and optional chapters only while the expected source is still current. */
    suspend fun ifSourceUnchanged(
        expected: Book,
        book: Book,
        chapters: List<BookChapter>? = null,
        allowInsert: Boolean = false,
        epubReflowPlan: EpubCatalogReflowPlan? = null,
    ): Book {
        return repository.saveMetadataIfSourceUnchanged(expected, book, chapters, allowInsert, epubReflowPlan)
            ?: throw CancellationException("Book was removed or its source or chapter list changed")
    }

    /** Replace a source and its full chapter list only if the original snapshot is still current. */
    suspend fun replaceSourceIfUnchanged(
        current: Book,
        replacement: Book,
        chapters: List<BookChapter>
    ): Book? {
        return repository.replaceSourceIfUnchanged(current, replacement, chapters)
    }

    /** Reverse once, cancelling rather than retrying against a different directory snapshot. */
    @Throws(Exception::class)
    suspend fun reverseChapterListIfUnchanged(expected: Book, expectedChapters: List<BookChapter>): ChapterListReorderResult {
        return repository.reverseChapterListIfUnchanged(expected, expectedChapters)
            ?: throw CancellationException("Book was removed or its chapter list changed")
    }

    /**
     * Insert a new book
     */
    suspend fun insert(book: Book) {
        repository.insert(book)
    }

    /**
     * Update an existing book
     */
    suspend fun update(book: Book) {
        repository.update(book)
    }
}

/**
 * Use case for deleting a book
 */
class DeleteBookUseCase(
    private val repository: BookRepository
) {
    /**
     * Delete a book
     */
    suspend operator fun invoke(book: Book) {
        repository.delete(book)
    }

    /**
     * Delete a book by URL
     */
    suspend fun deleteByUrl(bookUrl: String) {
        repository.deleteByUrl(bookUrl)
    }

    /**
     * Delete all books in a group
     */
    suspend fun deleteByGroup(groupId: Long) {
        repository.deleteByGroup(groupId)
    }
}

/**
 * Use case for updating reading progress
 */
class UpdateReadingProgressUseCase(
    private val repository: BookRepository
) {
    /**
     * Update reading progress
     */
    suspend operator fun invoke(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int = 0
    ) {
        repository.updateReadingProgress(
            bookUrl = bookUrl,
            chapterIndex = chapterIndex,
            chapterTitle = chapterTitle,
            chapterPos = chapterPos
        )
    }

    /** Explicit progress write with a confirmed database snapshot for optional upload. */
    suspend fun persist(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int = 0
    ): Book? {
        return repository.updateReadingProgressAndGet(bookUrl, chapterIndex, chapterTitle, chapterPos)
    }

    /** Passive loads must not overwrite progress changed since their starting snapshot. */
    suspend fun ifUnchanged(current: Book, updated: Book): ReadingProgressUpdateResult {
        return repository.updateReadingProgressIfUnchanged(current, updated)
    }

    /** External reader progress keeps its supplied clock without replacing other book fields. */
    suspend fun ifUnchangedAtTime(current: Book, updated: Book, timestamp: Long): ReadingProgressUpdateResult {
        return repository.updateReadingProgressIfUnchanged(current, updated, importedTimestamp = timestamp)
    }
}

/**
 * Use case for searching books
 */
class SearchBooksUseCase(
    private val repository: BookRepository
) {
    /**
     * Search books by name or author
     */
    suspend operator fun invoke(query: String): List<Book> {
        return if (query.isBlank()) {
            repository.getAllBooks()
        } else {
            repository.searchBooks(query)
        }
    }
}
