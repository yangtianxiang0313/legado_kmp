package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.TxtTocRule
import kotlinx.coroutines.flow.Flow

interface TxtTocRuleRepository {
    fun observeAll(): Flow<List<TxtTocRule>>
    suspend fun getAll(): List<TxtTocRule>
    suspend fun getEnabled(): List<TxtTocRule>
    suspend fun getDisabled(): List<TxtTocRule>
    suspend fun count(): Int
    suspend fun get(id: Long): TxtTocRule?
    suspend fun getMinOrder(): Int
    suspend fun getMaxOrder(): Int
    suspend fun insert(rule: TxtTocRule)
    suspend fun update(rule: TxtTocRule)
    suspend fun delete(id: Long)
    suspend fun deleteDefault()
}
