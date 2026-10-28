package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.Cache

interface CacheRepository {
    suspend fun get(key: String): Cache?
    suspend fun getValue(key: String, now: Long = io.legado.kmp.shared.util.currentTimeMillis()): String?
    suspend fun getAll(): List<Cache>
    suspend fun getByPrefix(prefix: String): List<Cache> = getAll().filter { it.key.startsWith(prefix) }
    suspend fun insert(cache: Cache)
    suspend fun replaceValueIfUnchanged(previous: Cache, value: String): Boolean
    suspend fun delete(key: String)
    suspend fun deleteByPrefix(prefix: String) {
        getByPrefix(prefix).forEach { delete(it.key) }
    }
    suspend fun deleteSourceVariables(key: String)
    suspend fun clearDeadline(now: Long = io.legado.kmp.shared.util.currentTimeMillis())
}
