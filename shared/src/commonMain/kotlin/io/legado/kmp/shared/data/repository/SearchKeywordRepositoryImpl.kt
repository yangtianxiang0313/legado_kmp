package io.legado.kmp.shared.data.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.SearchKeywordRepository
import io.legado.kmp.shared.model.SearchKeyword
import io.legado.kmp.shared.model.touch
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

class SearchKeywordRepositoryImpl(
    private val database: LegadoDatabase
) : SearchKeywordRepository {

    override fun observeByUsage(): Flow<List<SearchKeyword>> {
        return database.searchKeywordQueries.selectByUsage(
            mapper = SearchKeyword::from
        )
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { it }
    }

    override fun observeByTime(): Flow<List<SearchKeyword>> {
        return database.searchKeywordQueries.selectByTime(
            mapper = SearchKeyword::from
        )
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { it }
    }

    override fun observeSearch(keyword: String): Flow<List<SearchKeyword>> {
        return database.searchKeywordQueries.search(
            keyword,
            mapper = SearchKeyword::from
        )
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { it }
    }

    override suspend fun getAll(): List<SearchKeyword> {
        return database.searchKeywordQueries.selectAll(
            mapper = SearchKeyword::from
        ).executeAsList()
    }

    override suspend fun get(word: String): SearchKeyword? {
        return database.searchKeywordQueries.selectByWord(
            word = word,
            mapper = SearchKeyword::from
        ).executeAsOneOrNull()
    }

    override suspend fun insert(keyword: SearchKeyword) {
        database.searchKeywordQueries.insert(
            word = keyword.word,
            usage = keyword.usage.toLong(),
            last_use_time = keyword.lastUseTime
        )
    }

    override suspend fun update(keyword: SearchKeyword) {
        database.searchKeywordQueries.update(
            usage = keyword.usage.toLong(),
            last_use_time = keyword.lastUseTime,
            word = keyword.word
        )
    }

    override suspend fun delete(word: String) {
        database.searchKeywordQueries.deleteByWord(word)
    }

    override suspend fun deleteAll() {
        database.searchKeywordQueries.deleteAll()
    }

    override suspend fun recordUsage(word: String, now: Long) {
        val existing = get(word)
        if (existing == null) {
            insert(SearchKeyword(word = word, usage = 1, lastUseTime = now))
        } else {
            update(existing.touch(now))
        }
    }
}
