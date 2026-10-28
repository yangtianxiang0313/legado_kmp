package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.model.Cache

class GetCacheUseCase(
    private val repository: CacheRepository
) {
    suspend fun get(key: String): Cache? = repository.get(key)
    suspend fun getValue(key: String, now: Long = io.legado.kmp.shared.util.currentTimeMillis()): String? =
        repository.getValue(key, now)
    suspend fun getAll(): List<Cache> = repository.getAll()
}

class SaveCacheUseCase(
    private val repository: CacheRepository
) {
    suspend fun insert(cache: Cache) = repository.insert(cache)

    suspend fun put(
        key: String,
        value: String?,
        saveTimeSeconds: Int = 0
    ) {
        val deadline = if (saveTimeSeconds == 0) {
            0L
        } else {
            io.legado.kmp.shared.util.currentTimeMillis() + saveTimeSeconds * 1000L
        }
        repository.insert(Cache(key = key, value = value, deadline = deadline))
    }
}

class DeleteCacheUseCase(
    private val repository: CacheRepository
) {
    suspend fun delete(key: String) = repository.delete(key)
    suspend fun deleteSourceVariables(key: String) = repository.deleteSourceVariables(key)
    suspend fun clearDeadline(now: Long = io.legado.kmp.shared.util.currentTimeMillis()) = repository.clearDeadline(now)
}
