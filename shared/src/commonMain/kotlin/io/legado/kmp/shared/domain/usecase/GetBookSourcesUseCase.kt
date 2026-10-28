package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourcePart
import io.legado.kmp.shared.model.BookSourceType
import kotlinx.coroutines.flow.Flow

/**
 * Use case for getting book sources
 * Encapsulates the business logic for book source retrieval
 */
class GetBookSourcesUseCase(
    private val repository: BookSourceRepository
) {
    /**
     * Observe all book sources
     */
    operator fun invoke(): Flow<List<BookSource>> {
        return repository.observeAllBookSources()
    }

    /**
     * Get all book sources (one-time)
     */
    suspend fun getAll(): List<BookSource> {
        return repository.getAllBookSources()
    }

    /**
     * Get enabled book sources
     */
    fun observeEnabled(): Flow<List<BookSource>> {
        return repository.observeEnabledBookSources()
    }

    /**
     * Get enabled book sources (one-time)
     */
    suspend fun getEnabled(): List<BookSource> {
        return repository.getEnabledBookSources()
    }

    fun observeEnabledParts(): Flow<List<BookSourcePart>> {
        return repository.observeEnabledBookSourceParts()
    }

    suspend fun getEnabledParts(): List<BookSourcePart> {
        return repository.getEnabledBookSourceParts()
    }

    fun observeEnabledGroups(): Flow<List<String>> {
        return repository.observeEnabledGroups()
    }

    fun observeAllGroups(): Flow<List<String>> {
        return repository.observeAllGroups()
    }

    fun observeEnabledExploreParts(): Flow<List<BookSourcePart>> {
        return repository.observeEnabledExploreBookSourceParts()
    }

    suspend fun getEnabledExploreParts(): List<BookSourcePart> {
        return repository.getEnabledExploreBookSourceParts()
    }

    /**
     * Get a specific book source by URL
     */
    suspend fun getByUrl(url: String): BookSource? {
        return repository.getBookSource(url)
    }

    /**
     * Get book sources by group
     */
    fun observeByGroup(group: String): Flow<List<BookSource>> {
        return repository.observeBookSourcesByGroup(group)
    }

    /**
     * Get book sources by group (one-time)
     */
    suspend fun getByGroup(group: String): List<BookSource> {
        return repository.getBookSourcesByGroup(group)
    }

    fun observePartsByGroup(group: String): Flow<List<BookSourcePart>> {
        return repository.observeBookSourcePartsByGroup(group)
    }

    suspend fun getPartsByGroup(group: String): List<BookSourcePart> {
        return repository.getBookSourcePartsByGroup(group)
    }

    fun observeEnabledPartsByGroup(group: String): Flow<List<BookSourcePart>> {
        return repository.observeEnabledBookSourcePartsByGroup(group)
    }

    suspend fun getEnabledPartsByGroup(group: String): List<BookSourcePart> {
        return repository.getEnabledBookSourcePartsByGroup(group)
    }

    /**
     * Search book sources by keyword
     */
    suspend fun search(keyword: String): List<BookSource> {
        return repository.searchBookSources(keyword)
    }

    suspend fun searchParts(keyword: String): List<BookSourcePart> {
        return repository.searchBookSourceParts(keyword)
    }

    suspend fun searchEnabledParts(keyword: String): List<BookSourcePart> {
        return repository.searchEnabledBookSourceParts(keyword)
    }

    /**
     * Get text book sources with URL pattern
     */
    suspend fun getTextSourcesWithPattern(): List<BookSource> {
        return repository.getTextSourcesWithPattern()
    }

    suspend fun getTextPartsWithPattern(): List<BookSourcePart> {
        return repository.getTextBookSourcePartsWithPattern()
    }

    /**
     * Get all groups
     */
    suspend fun getAllGroups(): List<String> {
        return repository.getAllGroups()
    }

    /**
     * Get enabled groups
     */
    suspend fun getEnabledGroups(): List<String> {
        return repository.getEnabledGroups()
    }

    /**
     * Get explore groups
     */
    suspend fun getExploreGroups(): List<String> {
        return repository.getExploreGroups()
    }
}

/**
 * Use case for saving/updating book sources
 */
class SaveBookSourceUseCase(
    private val repository: BookSourceRepository
) {
    /**
     * Insert or update a single book source
     */
    suspend operator fun invoke(bookSource: BookSource) {
        repository.insertOrUpdate(bookSource)
    }

    suspend fun updateIfUnchanged(expected: BookSource, updated: BookSource): Boolean =
        repository.updateIfUnchanged(expected, updated)

    /**
     * Insert or update multiple book sources
     */
    suspend fun insertOrUpdate(bookSources: List<BookSource>) {
        repository.insertOrUpdate(bookSources)
    }

    /**
     * Enable or disable a book source
     */
    suspend fun setEnabled(url: String, enabled: Boolean) {
        repository.setEnabled(url, enabled)
    }

    suspend fun setEnabledExplore(url: String, enabled: Boolean) {
        repository.setEnabledExplore(url, enabled)
    }

    /**
     * Update the order of a book source
     */
    suspend fun updateOrder(url: String, order: Int) {
        repository.updateOrder(url, order)
    }

    /**
     * Update the group of a book source
     */
    suspend fun updateGroup(url: String, group: String?) {
        repository.updateGroup(url, group)
    }
}

/**
 * Use case for deleting book sources
 */
class DeleteBookSourceUseCase(
    private val repository: BookSourceRepository
) {
    /**
     * Delete a book source by URL
     */
    suspend operator fun invoke(url: String) {
        repository.deleteByUrl(url)
    }

    /**
     * Delete a book source
     */
    suspend fun delete(bookSource: BookSource) {
        repository.delete(bookSource)
    }

    /**
     * Delete multiple book sources
     */
    suspend fun deleteAll(bookSources: List<BookSource>) {
        repository.delete(bookSources)
    }
}
