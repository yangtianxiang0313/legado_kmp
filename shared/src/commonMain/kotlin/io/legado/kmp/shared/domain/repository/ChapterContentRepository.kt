package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.flow.SharedFlow

/**
 * Event emitted when chapter content is saved.
 * Equivalent to legado's `EventBus.SAVE_CONTENT` which posts `Pair<Book, BookChapter>`.
 */
data class SaveContentEvent(val book: Book, val chapter: BookChapter)

interface ChapterContentRepository {
    /**
     * Flow of save-content events, equivalent to legado's EventBus.SAVE_CONTENT.
     * Emits a [SaveContentEvent] each time [saveContent] succeeds.
     * UI layers (chapter list, cache activity, search content) can collect this
     * to update cached-chapter indicators in real time.
     */
    val saveContentEvents: SharedFlow<SaveContentEvent>

    suspend fun hasContent(book: Book, chapter: BookChapter): Boolean
    suspend fun getContent(book: Book, chapter: BookChapter): String?
    suspend fun saveContent(book: Book, chapter: BookChapter, content: String): Boolean
    suspend fun deleteContent(book: Book, chapter: BookChapter): Boolean

    /**
     * Preserve cached bodies and title-removal markers before chapter indices or titles change.
     * [chapters] must be the complete chapter list for [book], retaining pre-reorder indices.
     * Publishes URL-keyed caching only after every existing legacy file is copied.
     * Legacy files are retained; copy failures and cancellation propagate to the caller.
     * Repeated calls after publication are no-ops. Original local book files are never modified.
     */
    suspend fun prepareForChapterReorder(book: Book, chapters: List<BookChapter>)

    /** Delete all cached content for all books */
    suspend fun clearCache(): Boolean

    /** Delete all cached content for a specific book */
    suspend fun clearCache(book: Book): Boolean

    /**
     * List visible bodies and title markers using current [BookChapter.getFileName] names.
     * Internal format markers and unpublished URL copies are excluded.
     */
    suspend fun getChapterFiles(book: Book): Set<String>

    /**
     * Set whether to remove duplicate title for a specific chapter.
     * When removeSameTitle is false, a ".nr" marker file is created.
     * When removeSameTitle is true, the marker file is removed.
     */
    suspend fun setRemoveSameTitle(book: Book, chapter: BookChapter, removeSameTitle: Boolean)

    /**
     * Check whether duplicate title removal is enabled for a specific chapter.
     * Returns true if the ".nr" marker file does NOT exist.
     */
    suspend fun removeSameTitle(book: Book, chapter: BookChapter): Boolean

    /**
     * Rename/move a book's cache folder from old name to new name.
     * Used when a book changes source and its folder name changes.
     * Mirrors legado BookHelp.updateCacheFolder.
     *
     * @return true if the move succeeded or the old folder didn't exist
     */
    suspend fun moveCacheFolder(oldFolderName: String, newFolderName: String): Boolean

    /**
     * List all book cache folder names currently on disk.
     * Used by clearInvalidCache to identify orphaned cache folders.
     */
    suspend fun listCacheFolders(): List<String>

    /**
     * Delete a cache folder by name.
     * Used by clearInvalidCache to remove orphaned cache directories.
     */
    suspend fun deleteCacheFolder(folderName: String): Boolean
}
