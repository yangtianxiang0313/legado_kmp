package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.DeleteReplaceRuleUseCase
import io.legado.kmp.shared.domain.usecase.GetReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.SaveReplaceRuleUseCase
import io.legado.kmp.shared.model.ReplaceRule
import kotlin.coroutines.cancellation.CancellationException

class ReplaceRuleFacade(
    private val getReplaceRulesUseCase: GetReplaceRulesUseCase,
    private val saveReplaceRuleUseCase: SaveReplaceRuleUseCase,
    private val deleteReplaceRuleUseCase: DeleteReplaceRuleUseCase,
) {
    fun watchRules(onUpdate: (List<ReplaceRule>) -> Unit): FlowSubscription {
        return watchFlow(getReplaceRulesUseCase(), onUpdate, label = "ReplaceRuleFacade.rules")
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getAllRules(): List<ReplaceRule> {
        return runRecoverable("ReplaceRuleFacade.getAllRules") {
            getReplaceRulesUseCase.getAll()
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getById(id: Long): ReplaceRule? {
        return runRecoverable("ReplaceRuleFacade.getById") {
            getReplaceRulesUseCase.getById(id)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun searchByName(name: String): List<ReplaceRule> {
        return runRecoverable("ReplaceRuleFacade.searchByName") {
            getReplaceRulesUseCase.searchByName(name)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getByGroup(group: String): List<ReplaceRule> {
        return runRecoverable("ReplaceRuleFacade.getByGroup") {
            getReplaceRulesUseCase.getByGroup(group)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveRule(rule: ReplaceRule): Long {
        return runRecoverable("ReplaceRuleFacade.saveRule") {
            saveReplaceRuleUseCase(rule)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun createRule(name: String, pattern: String, replacement: String): ReplaceRule {
        return runRecoverable("ReplaceRuleFacade.createRule") {
            saveReplaceRuleUseCase.create(name, pattern, replacement)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun toggleEnabled(id: Long) {
        runRecoverable("ReplaceRuleFacade.toggleEnabled") {
            saveReplaceRuleUseCase.toggleEnabled(id)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun updateEnabled(id: Long, enabled: Boolean) {
        runRecoverable("ReplaceRuleFacade.updateEnabled") {
            saveReplaceRuleUseCase.updateEnabled(id, enabled)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun updateOrder(id: Long, order: Int) {
        runRecoverable("ReplaceRuleFacade.updateOrder") {
            saveReplaceRuleUseCase.updateOrder(id, order)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun saveRules(rules: List<ReplaceRule>) {
        runRecoverable("ReplaceRuleFacade.saveRules") {
            saveReplaceRuleUseCase.insertAll(rules)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteRule(id: Long) {
        runRecoverable("ReplaceRuleFacade.deleteRule") {
            deleteReplaceRuleUseCase(id)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun deleteRules(rules: List<ReplaceRule>) {
        runRecoverable("ReplaceRuleFacade.deleteRules") {
            deleteReplaceRuleUseCase.deleteAll(rules)
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun count(): Int {
        return runRecoverable("ReplaceRuleFacade.count") {
            getReplaceRulesUseCase.count()
        }
    }
}
