package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.RssSource
import kotlinx.coroutines.flow.Flow

interface RssSourceRepository {
    suspend fun getByKey(key: String): RssSource?
    suspend fun getRssSources(vararg sourceUrls: String): List<RssSource>
    suspend fun getAll(): List<RssSource>
    suspend fun size(): Int

    fun observeAll(): Flow<List<RssSource>>
    fun observeSearch(key: String): Flow<List<RssSource>>
    fun observeGroupSearch(key: String): Flow<List<RssSource>>
    fun observeEnabled(): Flow<List<RssSource>>
    fun observeDisabled(): Flow<List<RssSource>>
    fun observeLogin(): Flow<List<RssSource>>
    fun observeNoGroup(): Flow<List<RssSource>>
    fun observeEnabled(searchKey: String): Flow<List<RssSource>>
    fun observeEnabledByGroup(searchKey: String): Flow<List<RssSource>>
    fun observeGroups(): Flow<List<String>>
    fun observeEnabledGroups(): Flow<List<String>>

    suspend fun getAllGroups(): List<String>
    suspend fun getMinOrder(): Int?
    suspend fun getMaxOrder(): Int?
    suspend fun getNoGroup(): List<RssSource>
    suspend fun getByGroup(group: String): List<RssSource>
    suspend fun has(key: String): Boolean

    suspend fun insert(vararg rssSource: RssSource)
    suspend fun update(vararg rssSource: RssSource)
    suspend fun delete(vararg rssSource: RssSource)
    suspend fun delete(sourceUrl: String)
    suspend fun deleteDefault()
    suspend fun enable(sourceUrl: String, enable: Boolean)
}
