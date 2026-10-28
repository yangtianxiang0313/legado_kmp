package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.BookGroup
import kotlinx.coroutines.flow.Flow

/**
 * Repository interface for BookGroup operations
 */
interface BookGroupRepository {

    /**
     * Observe all book groups ordered by order
     */
    fun observeAllBookGroups(): Flow<List<BookGroup>>

    /**
     * Observe visible book groups
     */
    fun observeVisibleBookGroups(): Flow<List<BookGroup>>

    /**
     * Observe custom user-created groups (groupId >= 0)
     */
    fun observeCustomGroups(): Flow<List<BookGroup>>

    /**
     * Get all book groups (one-time query)
     */
    suspend fun getAllBookGroups(): List<BookGroup>

    /**
     * Get visible book groups (one-time query)
     */
    suspend fun getVisibleBookGroups(): List<BookGroup>

    /**
     * Get custom user-created groups (one-time query)
     */
    suspend fun getCustomGroups(): List<BookGroup>

    /**
     * Get a book group by ID
     */
    suspend fun getBookGroupById(id: Long): BookGroup?

    /**
     * Get a book group by name
     */
    suspend fun getBookGroupByName(name: String): BookGroup?

    /**
     * Insert a new book group
     */
    suspend fun insert(bookGroup: BookGroup)

    /**
     * Update an existing book group
     */
    suspend fun update(bookGroup: BookGroup)

    /**
     * Insert or update a book group
     */
    suspend fun insertOrUpdate(bookGroup: BookGroup)

    /**
     * Delete a book group
     */
    suspend fun delete(bookGroup: BookGroup)

    /**
     * Delete a book group by ID
     */
    suspend fun deleteById(id: Long)

    /**
     * Enable/show a book group
     */
    suspend fun enableGroup(id: Long)

    /**
     * Get total book group count
     */
    suspend fun getBookGroupCount(): Int

    /**
     * Get sum of all custom group IDs
     * Used for finding unused group IDs
     */
    suspend fun getIdsSum(): Long

    /**
     * Get maximum order value
     */
    suspend fun getMaxOrder(): Int?

    /**
     * Check if a new group can be added (max 63 custom groups)
     */
    suspend fun canAddGroup(): Boolean

    /**
     * Get group names by group ID (bit flag)
     * Returns names of groups that match the bit flag
     */
    suspend fun getGroupNames(id: Long): List<String>

    /**
     * Get an unused group ID (power of 2)
     */
    suspend fun getUnusedGroupId(): Long

    /**
     * Check if an ID is a valid power of 2
     * Used for validating custom group IDs
     */
    fun isValidPowerOfTwo(id: Long): Boolean

    /**
     * Create all special system groups
     */
    fun createSystemGroups(): List<BookGroup>
}
