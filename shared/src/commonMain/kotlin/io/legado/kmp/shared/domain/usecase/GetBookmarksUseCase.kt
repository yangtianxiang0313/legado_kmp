package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.BookmarkRepository
import io.legado.kmp.shared.model.Bookmark
import kotlinx.coroutines.flow.Flow

/**
 * Use case for getting bookmarks
 * Encapsulates the business logic for bookmark retrieval
 */
class GetBookmarksUseCase(
    private val repository: BookmarkRepository
) {
    /**
     * Observe all bookmarks as a Flow
     *
     * @return Flow emitting list of all bookmarks
     */
    operator fun invoke(): Flow<List<Bookmark>> {
        return repository.observeAllBookmarks()
    }

    /**
     * Get all bookmarks (one-time)
     *
     * @return List of all bookmarks
     */
    suspend fun getAll(): List<Bookmark> {
        return repository.getAllBookmarks()
    }

    /**
     * Observe bookmarks for a specific book as a Flow
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @return Flow emitting list of bookmarks for the book
     */
    operator fun invoke(bookName: String, bookAuthor: String): Flow<List<Bookmark>> {
        return repository.observeByBook(bookName, bookAuthor)
    }

    /**
     * Get bookmarks for a specific book (one-time)
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @return List of bookmarks for the book
     */
    suspend fun getByBook(bookName: String, bookAuthor: String): List<Bookmark> {
        return repository.getByBook(bookName, bookAuthor)
    }

    /**
     * Get a specific bookmark by its timestamp
     *
     * @param time The timestamp of the bookmark
     * @return The bookmark if found, null otherwise
     */
    suspend fun getByTime(time: Long): Bookmark? {
        return repository.getByTime(time)
    }

    /**
     * Search bookmarks in a specific book
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @param key The search keyword
     * @return List of matching bookmarks
     */
    suspend fun searchInBook(
        bookName: String,
        bookAuthor: String,
        key: String
    ): List<Bookmark> {
        return repository.searchInBook(bookName, bookAuthor, key)
    }

    /**
     * Count bookmarks for a specific book
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @return The number of bookmarks for the book
     */
    suspend fun countByBook(bookName: String, bookAuthor: String): Int {
        return repository.countByBook(bookName, bookAuthor)
    }
}

/**
 * Use case for saving bookmarks (insert or update)
 */
class SaveBookmarkUseCase(
    private val repository: BookmarkRepository
) {
    /**
     * Save a bookmark (insert or update)
     *
     * @param bookmark The bookmark to save
     * @return The timestamp of the saved bookmark
     */
    suspend operator fun invoke(bookmark: Bookmark): Long {
        repository.save(bookmark)
        return bookmark.time
    }

    /**
     * Insert a new bookmark
     *
     * @param bookmark The bookmark to insert
     * @return The timestamp of the inserted bookmark
     */
    suspend fun insert(bookmark: Bookmark): Long {
        return repository.insert(bookmark)
    }

    /**
     * Update an existing bookmark
     *
     * @param bookmark The bookmark with updated values
     */
    suspend fun update(bookmark: Bookmark) {
        repository.update(bookmark)
    }

    /**
     * Update only the content (note) of a bookmark
     *
     * @param time The timestamp of the bookmark
     * @param content The new note content
     */
    suspend fun updateContent(time: Long, content: String) {
        repository.updateContent(time, content)
    }

    /**
     * Create a new bookmark with current timestamp
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @param chapterIndex The index of the chapter
     * @param chapterPos The position within the chapter
     * @param chapterName The name of the chapter
     * @param bookText The text snippet around the position
     * @param content Optional user note
     * @return The created bookmark with its timestamp
     */
    suspend fun create(
        bookName: String,
        bookAuthor: String,
        chapterIndex: Int,
        chapterPos: Int,
        chapterName: String = "",
        bookText: String = "",
        content: String = ""
    ): Bookmark {
        val bookmark = Bookmark(
            bookName = bookName,
            bookAuthor = bookAuthor,
            chapterIndex = chapterIndex,
            chapterPos = chapterPos,
            chapterName = chapterName,
            bookText = bookText,
            content = content
        )
        repository.insert(bookmark)
        return bookmark
    }
}

/**
 * Use case for deleting bookmarks
 */
class DeleteBookmarkUseCase(
    private val repository: BookmarkRepository
) {
    /**
     * Delete a specific bookmark by its timestamp
     *
     * @param time The timestamp of the bookmark to delete
     */
    suspend operator fun invoke(time: Long) {
        repository.deleteByTime(time)
    }

    /**
     * Delete a specific bookmark
     *
     * @param bookmark The bookmark to delete
     */
    suspend fun delete(bookmark: Bookmark) {
        repository.deleteByTime(bookmark.time)
    }

    /**
     * Delete all bookmarks for a specific book
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     */
    suspend fun deleteByBook(bookName: String, bookAuthor: String) {
        repository.deleteByBook(bookName, bookAuthor)
    }

    /**
     * Delete all bookmarks
     * Use with caution!
     */
    suspend fun deleteAll() {
        repository.deleteAll()
    }
}
