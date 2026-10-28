package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.model.Cache

class CacheRepositoryImpl(
    private val database: LegadoDatabase
) : CacheRepository {

    override suspend fun get(key: String): Cache? {
        return database.cacheQueries.selectByKey(key).executeAsOneOrNull()?.let {
            Cache.from(
                key = it.key,
                value = it.value_,
                deadline = it.deadline
            )
        }
    }

    override suspend fun getValue(key: String, now: Long): String? {
        return database.cacheQueries.selectValueByKey(key, now).executeAsOneOrNull()?.value_
    }

    override suspend fun getAll(): List<Cache> {
        return database.cacheQueries.selectAll().executeAsList().map {
            Cache.from(
                key = it.key,
                value = it.value_,
                deadline = it.deadline
            )
        }
    }

    override suspend fun getByPrefix(prefix: String): List<Cache> =
        database.cacheQueries.selectByPrefix(prefix).executeAsList().map {
            Cache.from(key = it.key, value = it.value_, deadline = it.deadline)
        }

    override suspend fun insert(cache: Cache) {
        database.cacheQueries.insert(
            key = cache.key,
            value_ = cache.value,
            deadline = cache.deadline
        )
    }

    override suspend fun delete(key: String) {
        database.cacheQueries.deleteByKey(key)
    }

    override suspend fun deleteByPrefix(prefix: String) {
        database.cacheQueries.deleteByPrefix(prefix)
    }

    override suspend fun replaceValueIfUnchanged(previous: Cache, value: String): Boolean =
        database.cacheQueries.transactionWithResult {
            database.cacheQueries.replaceValueIfUnchanged(value, previous.key, previous.value, previous.deadline)
            database.cacheQueries.selectChangedRows().executeAsOne() == 1L
        }

    override suspend fun deleteSourceVariables(key: String) {
        database.cacheQueries.deleteSourceVariables(key, key, key, key)
    }

    override suspend fun clearDeadline(now: Long) {
        database.cacheQueries.clearDeadline(now)
    }
}
