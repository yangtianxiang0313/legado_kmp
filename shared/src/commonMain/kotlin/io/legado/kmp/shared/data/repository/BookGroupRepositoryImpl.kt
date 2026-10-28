package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.data.database.schema.Book_groups
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.BookGroupRepository
import io.legado.kmp.shared.model.BookGroup
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * SQLDelight implementation of BookGroupRepository
 */
class BookGroupRepositoryImpl(
    private val database: LegadoDatabase
) : BookGroupRepository {

    override fun observeAllBookGroups(): Flow<List<BookGroup>> {
        return database.bookGroupQueries
            .selectAll { group_id, group_name, cover, order, enable_refresh, show, book_sort ->
                mapToBookGroup(group_id, group_name, cover, order, enable_refresh, show, book_sort)
            }
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeVisibleBookGroups(): Flow<List<BookGroup>> {
        return database.bookGroupQueries
            .selectVisible { group_id, group_name, cover, order, enable_refresh, show, book_sort ->
                mapToBookGroup(group_id, group_name, cover, order, enable_refresh, show, book_sort)
            }
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override fun observeCustomGroups(): Flow<List<BookGroup>> {
        return database.bookGroupQueries
            .selectCustomGroups { group_id, group_name, cover, order, enable_refresh, show, book_sort ->
                mapToBookGroup(group_id, group_name, cover, order, enable_refresh, show, book_sort)
            }
            .asFlow()
            .mapToList(Dispatchers.Default)
    }

    override suspend fun getAllBookGroups(): List<BookGroup> {
        return database.bookGroupQueries
            .selectAll()
            .executeAsList()
            .map { bookGroup -> mapToBookGroupFromDataClass(bookGroup) }
    }

    override suspend fun getVisibleBookGroups(): List<BookGroup> {
        return database.bookGroupQueries
            .selectVisible()
            .executeAsList()
            .map { bookGroup -> mapToBookGroupFromDataClass(bookGroup) }
    }

    override suspend fun getCustomGroups(): List<BookGroup> {
        return database.bookGroupQueries
            .selectCustomGroups()
            .executeAsList()
            .map { bookGroup -> mapToBookGroupFromDataClass(bookGroup) }
    }

    override suspend fun getBookGroupById(id: Long): BookGroup? {
        return database.bookGroupQueries
            .selectById(id)
            .executeAsOneOrNull()
            ?.let { bookGroup -> mapToBookGroupFromDataClass(bookGroup) }
    }

    override suspend fun getBookGroupByName(name: String): BookGroup? {
        return database.bookGroupQueries
            .selectByName(name)
            .executeAsOneOrNull()
            ?.let { bookGroup -> mapToBookGroupFromDataClass(bookGroup) }
    }

    override suspend fun insert(bookGroup: BookGroup) {
        database.bookGroupQueries.insert(
            group_id = bookGroup.groupId,
            group_name = bookGroup.groupName,
            cover = bookGroup.cover,
            order = bookGroup.order.toLong(),
            enable_refresh = if (bookGroup.enableRefresh) 1L else 0L,
            show = if (bookGroup.show) 1L else 0L,
            book_sort = bookGroup.bookSort.toLong()
        )
    }

    override suspend fun update(bookGroup: BookGroup) {
        database.bookGroupQueries.update(
            group_name = bookGroup.groupName,
            cover = bookGroup.cover,
            order = bookGroup.order.toLong(),
            enable_refresh = if (bookGroup.enableRefresh) 1L else 0L,
            show = if (bookGroup.show) 1L else 0L,
            book_sort = bookGroup.bookSort.toLong(),
            group_id = bookGroup.groupId
        )
    }

    override suspend fun insertOrUpdate(bookGroup: BookGroup) {
        val existing = getBookGroupById(bookGroup.groupId)
        if (existing != null) {
            update(bookGroup)
        } else {
            insert(bookGroup)
        }
    }

    override suspend fun delete(bookGroup: BookGroup) {
        database.bookGroupQueries.delete(bookGroup.groupId)
    }

    override suspend fun deleteById(id: Long) {
        database.bookGroupQueries.delete(id)
    }

    override suspend fun enableGroup(id: Long) {
        database.bookGroupQueries.updateShow(id)
    }

    override suspend fun getBookGroupCount(): Int {
        return database.bookGroupQueries.countAll().executeAsOne().toInt()
    }

    override suspend fun getIdsSum(): Long {
        return database.bookGroupQueries.sumIds().executeAsOne().SUM ?: 0L
    }

    override suspend fun getMaxOrder(): Int? {
        return database.bookGroupQueries.maxOrder().executeAsOne().MAX?.toInt()
    }

    override suspend fun canAddGroup(): Boolean {
        return database.bookGroupQueries.canAddGroup().executeAsOne()
    }

    override suspend fun getGroupNames(id: Long): List<String> {
        // Get all custom groups and check if their ID is in the flag
        return getCustomGroups()
            .filter { it.groupId > 0 && (id and it.groupId) != 0L }
            .map { it.groupName }
    }

    override suspend fun getUnusedGroupId(): Long {
        var id = 1L
        val idsSum = getIdsSum()
        while (id and idsSum != 0L) {
            id = id shl 1
        }
        return id
    }

    override fun isValidPowerOfTwo(id: Long): Boolean {
        if (id < 0) return true // Special groups are valid
        // Check if it's a power of 2
        return id > 0 && (id and (id - 1)) == 0L
    }

    override fun createSystemGroups(): List<BookGroup> {
        return listOf(
            BookGroup.createAllGroup(),
            BookGroup.createLocalGroup(),
            BookGroup.createAudioGroup(),
            BookGroup.createNetNoneGroup(),
            BookGroup.createLocalNoneGroup(),
            BookGroup.createErrorGroup()
        )
    }

    /**
     * Map from mapper parameters to domain model
     */
    private fun mapToBookGroup(
        group_id: Long,
        group_name: String,
        cover: String?,
        order: Long,
        enable_refresh: Long,
        show: Long,
        book_sort: Long
    ): BookGroup = BookGroup(
        groupId = group_id,
        groupName = group_name,
        cover = cover,
        order = order.toInt(),
        enableRefresh = enable_refresh == 1L,
        show = show == 1L,
        bookSort = book_sort.toInt()
    )

    /**
     * Map from SQLDelight generated data class to domain model
     */
    private fun mapToBookGroupFromDataClass(bookGroup: Book_groups): BookGroup = BookGroup(
        groupId = bookGroup.group_id,
        groupName = bookGroup.group_name,
        cover = bookGroup.cover,
        order = bookGroup.order.toInt(),
        enableRefresh = bookGroup.enable_refresh == 1L,
        show = bookGroup.show == 1L,
        bookSort = bookGroup.book_sort.toInt()
    )
}
