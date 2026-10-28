package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.TxtTocRuleRepository
import io.legado.kmp.shared.model.TxtTocRule
import kotlinx.coroutines.flow.Flow

class GetTxtTocRulesUseCase(
    private val repository: TxtTocRuleRepository
) {
    operator fun invoke(): Flow<List<TxtTocRule>> = repository.observeAll()
    suspend fun getAll(): List<TxtTocRule> = repository.getAll()
    suspend fun getEnabled(): List<TxtTocRule> = repository.getEnabled()
    suspend fun getDisabled(): List<TxtTocRule> = repository.getDisabled()
    suspend fun count(): Int = repository.count()
    suspend fun get(id: Long): TxtTocRule? = repository.get(id)
    suspend fun minOrder(): Int = repository.getMinOrder()
    suspend fun maxOrder(): Int = repository.getMaxOrder()
}

class SaveTxtTocRuleUseCase(
    private val repository: TxtTocRuleRepository
) {
    suspend fun insert(rule: TxtTocRule) = repository.insert(rule)
    suspend fun update(rule: TxtTocRule) = repository.update(rule)
}

class DeleteTxtTocRuleUseCase(
    private val repository: TxtTocRuleRepository
) {
    suspend fun delete(id: Long) = repository.delete(id)
    suspend fun deleteDefault() = repository.deleteDefault()
}
