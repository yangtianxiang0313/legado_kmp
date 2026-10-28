package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.SearchKeywordRepository
import io.legado.kmp.shared.model.SearchKeyword
import kotlinx.coroutines.flow.Flow

class GetSearchKeywordsUseCase(
    private val repository: SearchKeywordRepository
) {
    fun byUsage(): Flow<List<SearchKeyword>> = repository.observeByUsage()
    fun byTime(): Flow<List<SearchKeyword>> = repository.observeByTime()
    fun search(keyword: String): Flow<List<SearchKeyword>> = repository.observeSearch(keyword)
    suspend fun getAll(): List<SearchKeyword> = repository.getAll()
    suspend fun get(word: String): SearchKeyword? = repository.get(word)
}

class SaveSearchKeywordUseCase(
    private val repository: SearchKeywordRepository
) {
    suspend fun insert(keyword: SearchKeyword) = repository.insert(keyword)
    suspend fun update(keyword: SearchKeyword) = repository.update(keyword)
    suspend fun recordUsage(word: String, now: Long = io.legado.kmp.shared.util.currentTimeMillis()) =
        repository.recordUsage(word, now)
}

class DeleteSearchKeywordUseCase(
    private val repository: SearchKeywordRepository
) {
    suspend fun delete(word: String) = repository.delete(word)
    suspend fun deleteAll() = repository.deleteAll()
}
