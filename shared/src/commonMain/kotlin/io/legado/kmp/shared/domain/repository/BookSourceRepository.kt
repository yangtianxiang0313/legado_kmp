package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourcePart
import io.legado.kmp.shared.model.BookSourceType
import kotlinx.coroutines.flow.Flow

/**
 * Repository interface for BookSource operations
 */
interface BookSourceRepository {

    /**
     * Observe all book sources ordered by custom order
     */
    fun observeAllBookSources(): Flow<List<BookSource>>

    /**
     * Observe enabled book sources
     */
    fun observeEnabledBookSources(): Flow<List<BookSource>>

    /**
     * Observe disabled book sources
     */
    fun observeDisabledBookSources(): Flow<List<BookSource>>

    /**
     * Observe book sources available for explore
     */
    fun observeExploreBookSources(): Flow<List<BookSource>>

    /**
     * Observe book sources with login URL
     */
    fun observeLoginBookSources(): Flow<List<BookSource>>

    /**
     * Observe book sources by group
     */
    fun observeBookSourcesByGroup(group: String): Flow<List<BookSource>>

    /**
     * Observe enabled book sources by group
     */
    fun observeEnabledBookSourcesByGroup(group: String): Flow<List<BookSource>>

    /**
     * Observe book sources with no group
     */
    fun observeNoGroupBookSources(): Flow<List<BookSource>>

    /**
     * Get all book sources (one-time query)
     */
    suspend fun getAllBookSources(): List<BookSource>

    /**
     * Get enabled book sources
     */
    suspend fun getEnabledBookSources(): List<BookSource>

    /**
     * Get disabled book sources
     */
    suspend fun getDisabledBookSources(): List<BookSource>

    /**
     * Get explore book sources
     */
    suspend fun getExploreBookSources(): List<BookSource>

    /**
     * Get a book source by URL
     */
    suspend fun getBookSource(url: String): BookSource?

    /**
     * Get book sources by type
     */
    suspend fun getBookSourcesByType(type: Int): List<BookSource>

    /**
     * Get book sources by group
     */
    suspend fun getBookSourcesByGroup(group: String): List<BookSource>

    /**
     * Get enabled book sources by group
     */
    suspend fun getEnabledBookSourcesByGroup(group: String): List<BookSource>

    /**
     * Get book sources with no group
     */
    suspend fun getNoGroupBookSources(): List<BookSource>

    /**
     * Get book sources with login URL
     */
    suspend fun getLoginBookSources(): List<BookSource>

    /**
     * Search book sources by keyword (searches name, group, URL, comment)
     */
    suspend fun searchBookSources(keyword: String): List<BookSource>

    /**
     * Search enabled book sources by keyword
     */
    suspend fun searchEnabledBookSources(keyword: String): List<BookSource>

    /**
     * Observe search results
     */
    fun observeSearchBookSources(keyword: String): Flow<List<BookSource>>

    /**
     * Observe search results for enabled sources
     */
    fun observeSearchEnabledBookSources(keyword: String): Flow<List<BookSource>>

    /**
     * Get all distinct groups
     */
    suspend fun getAllGroups(): List<String>

    /**
     * Get all distinct groups from enabled sources
     */
    suspend fun getEnabledGroups(): List<String>

    /**
     * Get all distinct groups from explore sources
     */
    suspend fun getExploreGroups(): List<String>

    /**
     * Observe all groups
     */
    fun observeAllGroups(): Flow<List<String>>

    /**
     * Observe enabled groups
     */
    fun observeEnabledGroups(): Flow<List<String>>

    /**
     * Observe explore groups
     */
    fun observeExploreGroups(): Flow<List<String>>

    /**
     * Insert a new book source
     */
    suspend fun insert(bookSource: BookSource)

    /**
     * Update an existing book source
     */
    suspend fun update(bookSource: BookSource)

    suspend fun updateIfUnchanged(expected: BookSource, updated: BookSource): Boolean

    /**
     * Insert or update a book source
     */
    suspend fun insertOrUpdate(bookSource: BookSource)

    /**
     * Insert or update multiple book sources
     */
    suspend fun insertOrUpdate(bookSources: List<BookSource>)

    /**
     * Delete a book source
     */
    suspend fun delete(bookSource: BookSource)

    /**
     * Delete a book source by URL
     */
    suspend fun deleteByUrl(url: String)

    /**
     * Delete multiple book sources
     */
    suspend fun delete(bookSources: List<BookSource>)

    /**
     * Enable or disable a book source
     */
    suspend fun setEnabled(url: String, enabled: Boolean)

    /**
     * Enable or disable explore for a book source
     */
    suspend fun setEnabledExplore(url: String, enabled: Boolean)

    /**
     * Update the order of a book source
     */
    suspend fun updateOrder(url: String, order: Int)

    /**
     * Update the order of multiple book sources
     */
    suspend fun updateOrder(bookSources: List<BookSource>)

    /**
     * Update the group of a book source
     */
    suspend fun updateGroup(url: String, group: String?)

    /**
     * Update the group of multiple book sources
     */
    suspend fun updateGroup(bookSources: List<BookSource>)

    /**
     * Get total book source count
     */
    suspend fun getBookSourceCount(): Int

    /**
     * Get minimum custom order
     */
    suspend fun getMinOrder(): Int?

    /**
     * Get maximum custom order
     */
    suspend fun getMaxOrder(): Int?

    /**
     * Get text book sources with book URL pattern
     */
    suspend fun getTextSourcesWithPattern(): List<BookSource>

    /**
     * Get enabled book source for adding book by URL pattern
     */
    suspend fun getBookSourceForAddBook(baseUrl: String): BookSource?

    fun observeAllBookSourceParts(): Flow<List<BookSourcePart>>

    fun observeEnabledBookSourceParts(): Flow<List<BookSourcePart>>

    fun observeEnabledExploreBookSourceParts(): Flow<List<BookSourcePart>>

    fun observeLoginBookSourceParts(): Flow<List<BookSourcePart>>

    fun observeBookSourcePartsByGroup(group: String): Flow<List<BookSourcePart>>

    fun observeEnabledBookSourcePartsByGroup(group: String): Flow<List<BookSourcePart>>

    fun observeSearchBookSourceParts(keyword: String): Flow<List<BookSourcePart>>

    fun observeSearchEnabledBookSourceParts(keyword: String): Flow<List<BookSourcePart>>

    suspend fun getAllBookSourceParts(): List<BookSourcePart>

    suspend fun getEnabledBookSourceParts(): List<BookSourcePart>

    suspend fun getEnabledExploreBookSourceParts(): List<BookSourcePart>

    suspend fun getLoginBookSourceParts(): List<BookSourcePart>

    suspend fun getBookSourcePartsByGroup(group: String): List<BookSourcePart>

    suspend fun getEnabledBookSourcePartsByGroup(group: String): List<BookSourcePart>

    suspend fun searchBookSourceParts(keyword: String): List<BookSourcePart>

    suspend fun searchEnabledBookSourceParts(keyword: String): List<BookSourcePart>

    suspend fun getTextBookSourcePartsWithPattern(): List<BookSourcePart>
}
