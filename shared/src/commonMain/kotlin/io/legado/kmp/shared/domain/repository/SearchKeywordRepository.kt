package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.SearchKeyword
import kotlinx.coroutines.flow.Flow

interface SearchKeywordRepository {
    fun observeByUsage(): Flow<List<SearchKeyword>>
    fun observeByTime(): Flow<List<SearchKeyword>>
    fun observeSearch(keyword: String): Flow<List<SearchKeyword>>
    suspend fun getAll(): List<SearchKeyword>
    suspend fun get(word: String): SearchKeyword?
    suspend fun insert(keyword: SearchKeyword)
    suspend fun update(keyword: SearchKeyword)
    suspend fun delete(word: String)
    suspend fun deleteAll()
    suspend fun recordUsage(word: String, now: Long = io.legado.kmp.shared.util.currentTimeMillis())
}
