package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.Bookmark
import kotlinx.coroutines.flow.Flow

/**
 * Repository interface for Bookmark operations
 * Abstracts the data source and provides a clean API for the domain layer
 */
interface BookmarkRepository {

    /**
     * Observe all bookmarks as a Flow
     * The Flow will emit updates whenever bookmarks change
     *
     * @return Flow emitting list of all bookmarks
     */
    fun observeAllBookmarks(): Flow<List<Bookmark>>

    /**
     * Observe bookmarks for a specific book as a Flow
     * The Flow will emit updates whenever bookmarks for this book change
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @return Flow emitting list of bookmarks for the book
     */
    fun observeByBook(bookName: String, bookAuthor: String): Flow<List<Bookmark>>

    /**
     * Get all bookmarks (one-time query)
     *
     * @return List of all bookmarks
     */
    suspend fun getAllBookmarks(): List<Bookmark>

    /**
     * Get bookmarks for a specific book (one-time query)
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @return List of bookmarks for the book
     */
    suspend fun getByBook(bookName: String, bookAuthor: String): List<Bookmark>

    /**
     * Get a specific bookmark by its timestamp
     *
     * @param time The timestamp of the bookmark
     * @return The bookmark if found, null otherwise
     */
    suspend fun getByTime(time: Long): Bookmark?

    /**
     * Search bookmarks in a specific book
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @param key The search keyword
     * @return List of matching bookmarks
     */
    suspend fun searchInBook(bookName: String, bookAuthor: String, key: String): List<Bookmark>

    /**
     * Insert a new bookmark
     *
     * @param bookmark The bookmark to insert
     * @return The timestamp of the inserted bookmark
     */
    suspend fun insert(bookmark: Bookmark): Long

    /**
     * Update an existing bookmark
     *
     * @param bookmark The bookmark with updated values
     */
    suspend fun update(bookmark: Bookmark)

    /**
     * Update only the content (note) of a bookmark
     *
     * @param time The timestamp of the bookmark
     * @param content The new note content
     */
    suspend fun updateContent(time: Long, content: String)

    /**
     * Delete a specific bookmark by its timestamp
     *
     * @param time The timestamp of the bookmark to delete
     */
    suspend fun deleteByTime(time: Long)

    /**
     * Delete all bookmarks for a specific book
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     */
    suspend fun deleteByBook(bookName: String, bookAuthor: String)

    /**
     * Delete all bookmarks
     */
    suspend fun deleteAll()

    /**
     * Insert or update a bookmark (upsert)
     *
     * @param bookmark The bookmark to insert or update
     */
    suspend fun save(bookmark: Bookmark)

    /**
     * Count bookmarks for a specific book
     *
     * @param bookName The name of the book
     * @param bookAuthor The author of the book
     * @return The number of bookmarks for the book
     */
    suspend fun countByBook(bookName: String, bookAuthor: String): Int
}
