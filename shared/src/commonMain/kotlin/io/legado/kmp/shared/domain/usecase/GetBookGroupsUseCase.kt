package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.BookGroupRepository
import io.legado.kmp.shared.model.BookGroup
import kotlinx.coroutines.flow.Flow

/**
 * Use case for getting book groups
 * Encapsulates the business logic for book group retrieval
 */
class GetBookGroupsUseCase(
    private val repository: BookGroupRepository
) {
    /**
     * Observe all book groups
     */
    operator fun invoke(): Flow<List<BookGroup>> {
        return repository.observeAllBookGroups()
    }

    /**
     * Get all book groups (one-time)
     */
    suspend fun getAll(): List<BookGroup> {
        return repository.getAllBookGroups()
    }

    /**
     * Observe visible book groups
     */
    fun observeVisible(): Flow<List<BookGroup>> {
        return repository.observeVisibleBookGroups()
    }

    /**
     * Get visible book groups (one-time)
     */
    suspend fun getVisible(): List<BookGroup> {
        return repository.getVisibleBookGroups()
    }

    /**
     * Observe custom user-created groups
     */
    fun observeCustom(): Flow<List<BookGroup>> {
        return repository.observeCustomGroups()
    }

    /**
     * Get custom groups (one-time)
     */
    suspend fun getCustom(): List<BookGroup> {
        return repository.getCustomGroups()
    }

    /**
     * Get a specific book group by ID
     */
    suspend fun getById(id: Long): BookGroup? {
        return repository.getBookGroupById(id)
    }

    /**
     * Get a book group by name
     */
    suspend fun getByName(name: String): BookGroup? {
        return repository.getBookGroupByName(name)
    }

    /**
     * Get group names by group ID (bit flag)
     */
    suspend fun getGroupNames(id: Long): List<String> {
        return repository.getGroupNames(id)
    }

    /**
     * Get an unused group ID
     */
    suspend fun getUnusedGroupId(): Long {
        return repository.getUnusedGroupId()
    }

    /**
     * Check if a new group can be added
     */
    suspend fun canAddGroup(): Boolean {
        return repository.canAddGroup()
    }

    /**
     * Create all special system groups
     */
    fun createSystemGroups(): List<BookGroup> {
        return repository.createSystemGroups()
    }
}

/**
 * Use case for saving/updating book groups
 */
class SaveBookGroupUseCase(
    private val repository: BookGroupRepository
) {
    /**
     * Insert or update a book group
     */
    suspend operator fun invoke(bookGroup: BookGroup) {
        repository.insertOrUpdate(bookGroup)
    }

    /**
     * Enable/show a book group
     */
    suspend fun enableGroup(id: Long) {
        repository.enableGroup(id)
    }
}

/**
 * Use case for deleting book groups
 */
class DeleteBookGroupUseCase(
    private val repository: BookGroupRepository
) {
    /**
     * Delete a book group by ID
     */
    suspend operator fun invoke(id: Long) {
        repository.deleteById(id)
    }

    /**
     * Delete a book group
     */
    suspend fun delete(bookGroup: BookGroup) {
        repository.delete(bookGroup)
    }
}
