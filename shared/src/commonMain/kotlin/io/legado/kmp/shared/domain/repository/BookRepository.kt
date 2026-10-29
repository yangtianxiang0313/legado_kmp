package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.domain.localbook.EpubCatalogReflowPlan
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.flow.Flow
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.CoroutineContext

/** Keep the caller's cancellation checks while a cache move/commit is being finalized. */
internal class WebFileMetadataMergeContext(val callerContext: CoroutineContext) : AbstractCoroutineContextElement(Key) {
    companion object Key : CoroutineContext.Key<WebFileMetadataMergeContext>
}

/** The transaction's latest snapshot; persisted is false for conflicts, no-ops and missing books. */
data class ReadingProgressUpdateResult(
    val book: Book?,
    val persisted: Boolean,
)

/** The book and directory actually committed by one chapter reorder transaction. */
data class ChapterListReorderResult(
    val book: Book,
    val chapters: List<BookChapter>,
)

/**
 * Repository interface for Book operations
 */
interface BookRepository {

    /**
     * Observe all books ordered by order and latest chapter time
     */
    fun observeAllBooks(): Flow<List<Book>>

    /**
     * Observe books by group
     */
    fun observeBooksByGroup(groupId: Long): Flow<List<Book>>

    /**
     * Observe a specific book by URL
     */
    fun observeBook(bookUrl: String): Flow<Book?>

    /**
     * Get all books (one-time query)
     */
    suspend fun getAllBooks(): List<Book>

    /**
     * Get a book by URL
     */
    suspend fun getBook(bookUrl: String): Book?

    /** Get exact-name matches in database order, without shelf sorting. */
    suspend fun getBooksByName(bookName: String): List<Book>

    /**
     * Get books by origin (book source)
     */
    suspend fun getBooksByOrigin(origin: String): List<Book>

    /**
     * Get books by group
     */
    suspend fun getBooksByGroup(groupId: Long): List<Book>

    /**
     * Search books by name or author
     */
    suspend fun searchBooks(query: String): List<Book>

    /**
     * Insert a new book
     */
    suspend fun insert(book: Book)

    /**
     * Update an existing book
     */
    suspend fun update(book: Book)

    /**
     * Insert or update a book
     */
    suspend fun insertOrUpdate(book: Book)

    /**
     * Atomically insert a local book and its chapters only if its URL is absent.
     * Returns the complete stored book without writes if the URL already exists.
     * New books require matching chapter book URLs, unique nonblank chapter URLs,
     * complete zero-based indices and a matching totalChapterNum (zero permits no chapters).
     * Invalid new input throws; cancellation or failure before commit rolls back all writes.
     */
    @Throws(Exception::class)
    suspend fun insertLocalBookIfAbsent(book: Book, chapters: List<BookChapter>): Book

    /**
     * Merge web-file metadata into an imported local book in one synchronous database transaction.
     * Recheck the online book's URL, origin, isWebFile and original name/author/coverUrl/intro
     * against expectedOnlineBook, and require its source to still have the FILE type.
     * Recheck the local book's URL, isLocal, origin, type and the same four original fields
     * against expectedLocalBook. Prefer nonblank online name/author/intro and assign the raw
     * online coverUrl, including null. Update only these four columns, preserving every other
     * latest stored value, including raw config, custom fields and reading progress. Rename
     * uniquely local-owned bookmarks in the same transaction; the target domain may contain
     * only the explicit online counterpart and must have no existing bookmarks.
     * Missing/changed state, ambiguous bookmark ownership or a target identity collision returns
     * null without writes, preserving the local import. Check cancellation before writes and
     * before commit; cancellation/failure before commit rolls back every write. Return the
     * committed local book without any post-commit query or cancellation check.
     */
    suspend fun mergeWebFileMetadataIfUnchanged(expectedOnlineBook: Book, expectedLocalBook: Book): Book?

    /**
     * Associate a remote origin with a still-matching local import. Compare URL/local identity,
     * origin, type and raw variable before writing only origin/variable. Preserve archive origins,
     * other remote primary origins and all latest progress, raw config, metadata and related rows.
     * Return null for missing/changed snapshots; cancellation before commit rolls back. A successful
     * commit is returned without any post-commit query or cancellation check.
     */
    suspend fun associateRemoteOriginIfUnchanged(remoteOrigin: String, expectedLocalBook: Book): Book?

    /**
     * Explicitly prepare a NOT_SHELF book only if its URL is absent, in one transaction.
     * An existing row is returned unchanged, including its latest source, type and raw JSON.
     * Does not write chapters, bookmarks or content caches.
     */
    suspend fun insertPreviewIfAbsent(book: Book): Book

    /** Save metadata while atomically preserving the stored reading progress. */
    suspend fun insertOrUpdatePreservingReadingProgress(book: Book): Book

    /** Change only the latest stored grouping and optionally shelf membership in one transaction. */
    suspend fun updateGroupPreservingState(bookUrl: String, groupId: Long, addToShelf: Boolean): Book?

    /** Only clear NOT_SHELF or delete a still-preview book row; never delete shelf books or related data. */
    suspend fun completePreviewReadingExit(bookUrl: String, expectedOrigin: String, addToShelf: Boolean): Book?

    /**
     * Atomically edit only the latest stored book info; absent books return null without insertion.
     * Null fields preserve stored values; strings retain whitespace and empty values. Cover/intro
     * overrides equal to their original values are cleared. bookType is an index (0 text, 1 audio,
     * 2 image), not a mask; other indices throw. All other state and type bits remain unchanged.
     */
    suspend fun updateBookInfoPreservingState(
        bookUrl: String,
        name: String? = null,
        author: String? = null,
        coverUrl: String? = null,
        intro: String? = null,
        bookType: Int? = null
    ): Book?

    /** Change only custom in the latest variable JSON; a missing book or changed origin returns null. */
    suspend fun updateCustomVariable(bookUrl: String, expectedOrigin: String, value: String): Book?

    /**
     * Change only pageAnim in the latest stored read_config, preserving every other field.
     * Accepts -1 (clear) or 0..4; returns the transaction's stored book, or null if absent/source changed.
     */
    suspend fun updatePageAnimation(bookUrl: String, expectedOrigin: String, pageAnimation: Int): Book?

    /**
     * Merge only readSimulating/startDate/startChapter/dailyChapters into the latest read_config.
     * Requires a strict yyyy-MM-dd calendar date and nonnegative chapter values, including zero.
     * Malformed/non-object JSON throws; unknown keys and all other book state remain unchanged.
     * Returns the committed book, or null if absent/source changed; never inserts a missing book.
     */
    suspend fun updateReadSimulation(
        bookUrl: String,
        expectedOrigin: String,
        enabled: Boolean,
        startDateIso: String,
        startChapter: Int,
        dailyChapters: Int,
    ): Book?

    /**
     * Change only imageStyle in the latest stored read_config; SINGLE also sets pageAnim to 0.
     * Preserve the supplied string and every other JSON field. Malformed/non-object JSON throws.
     * Returns the committed book, or null if absent/source changed; never inserts a missing book.
     */
    suspend fun updateImageStyle(bookUrl: String, expectedOrigin: String, imageStyle: String): Book?

    /**
     * Change only charset, clearing local chapter offsets in the same transaction when it changes.
     * Preserve every other book column and leave remote chapters intact. Strings are not normalized.
     * Returns the committed book, or null if absent/source changed; never inserts a missing book.
     */
    suspend fun updateCharset(bookUrl: String, expectedOrigin: String, charset: String): Book?

    /**
     * Save same-source metadata and optionally replace the full chapter list in one transaction.
     * Returns null if the stored origin/reverse flag differs from expected, the book is absent and
     * insertion is not allowed, or a directory replacement's TOC URL/count changed since expected.
     * Replacement URL/origin and every chapter's bookUrl must match expected.
     * Preserves the latest stored progress and lastCheckCount exactly as
     * insertOrUpdatePreservingReadingProgress does. Null chapters leave the list unchanged;
     * an empty list explicitly clears it. Invalid input throws; cancellation or failure rolls back.
     * Replacement transient fields are retained in the returned book but are not persisted.
     */
    suspend fun saveMetadataIfSourceUnchanged(
        expected: Book,
        replacement: Book,
        chapters: List<BookChapter>? = null,
        allowInsert: Boolean = false,
        epubReflowPlan: EpubCatalogReflowPlan? = null,
    ): Book?

    /**
     * Atomically replace a source and its full chapter list, preserving the latest user state.
     * Returns null for changed source/progress, a missing current book, or an occupied different URL.
     * Keeps the replacement's mapped chapter index/title and resets its character position to zero.
     * Invalid replacement data throws before any writes.
     */
    suspend fun replaceSourceIfUnchanged(
        current: Book,
        replacement: Book,
        chapters: List<BookChapter>
    ): Book?

    /**
     * Reverse a nonempty, complete directory in one synchronous database transaction.
     * Returns null if the book/source/TOC/reverse flag or chapter structure changed.
     * Chapter word counts and all other book metadata come from the latest stored rows.
     * Preserves the current chapter by URL and only remaps its index and bookmark indices.
     * Ambiguous shared bookmarks, invalid directories or unmappable progress throw;
     * cancellation or failure before commit rolls back every write.
     * Success returns the committed book and reordered chapters without any post-commit query.
     */
    @Throws(Exception::class)
    suspend fun reverseChapterListIfUnchanged(expected: Book, expectedChapters: List<BookChapter>): ChapterListReorderResult?

    /**
     * Delete a book
     */
    suspend fun delete(book: Book)

    /**
     * Delete a book by URL
     */
    suspend fun deleteByUrl(bookUrl: String)

    /**
     * Delete all books in a group
     */
    suspend fun deleteByGroup(groupId: Long)

    /**
     * Update reading progress
     */
    suspend fun updateReadingProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int
    )

    /** Unconditionally update progress and return the written snapshot, or null if absent. */
    suspend fun updateReadingProgressAndGet(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int
    ): Book?

    /** Compare index, title, position and time, then update within the same transaction. */
    suspend fun updateReadingProgressIfUnchanged(
        current: Book,
        updated: Book,
        importedTimestamp: Long? = null,
    ): ReadingProgressUpdateResult

    /**
     * Update audio reading progress (also resets lastCheckCount to 0)
     */
    suspend fun updateAudioReadingProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int
    )

    /**
     * Update latest chapter info
     */
    suspend fun updateLatestChapter(bookUrl: String, chapterTitle: String?)

    /**
     * Get total book count
     */
    suspend fun getBookCount(): Int

    /**
     * Get book count by group
     */
    suspend fun getBookCountByGroup(groupId: Long): Int

    /**
     * Get recent books (ordered by last read time)
     */
    suspend fun getRecentBooks(limit: Int = 10): List<Book>

    /**
     * Get updated books (ordered by latest chapter time)
     */
    suspend fun getUpdatedBooks(limit: Int = 10): List<Book>
}
