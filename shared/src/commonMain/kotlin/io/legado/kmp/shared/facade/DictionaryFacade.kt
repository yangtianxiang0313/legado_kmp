package io.legado.kmp.shared.facade

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.domain.repository.DictRuleRepository
import io.legado.kmp.shared.model.DictRule
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.HttpException
import io.legado.kmp.shared.network.HttpUseCase
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceRequestExecutor
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

data class DictionaryLookupResult(
    val html: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

/** Android DictRule.search: URL keyword evaluation followed by the optional display rule. */
class DictionaryFacade(
    private val rules: DictRuleRepository,
    private val requests: SourceRequestExecutor,
    private val http: HttpUseCase,
    private val js: JsExecutor,
) {
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun loadRules(): List<DictRule> = runRecoverable("DictionaryFacade.loadRules") {
        rules.getEnabled().sortedBy { it.sortNumber }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun lookup(rule: DictRule, word: String): String = runRecoverable("DictionaryFacade.lookup") {
        require(word.isNotEmpty()) { "查询内容不能为空" }
        require(rule.urlRule.isNotBlank()) { "词典地址规则为空" }
        coroutineContext.ensureActive()
        val request = AnalyzeUrl(jsExecutor = js).setString("key", word).build(rule.urlRule)
        val result = requests.executeText(request).getOrThrow()
        coroutineContext.ensureActive()
        if (!result.response.isSuccessful) {
            throw HttpException(result.response.statusCode, result.response.statusText)
        }
        if (rule.showRule.isBlank()) {
            result.bodyText
        } else {
            AnalyzeRule(jsExecutor = js, httpUseCase = http)
                .setContent(result.bodyText)
                .getString(rule.showRule)
        }
    }

    fun lookupRequest(rule: DictRule, word: String, onResult: (DictionaryLookupResult) -> Unit): FlowSubscription =
        CancellableFacadeRequest.start(
            prepare = { DictionaryLookupResult(lookup(rule, word), null, false) },
            cancelledResult = DictionaryLookupResult(null, null, true),
            failureResult = { DictionaryLookupResult(null, it.message ?: "词典查询失败", false) },
            onResult = onResult,
            facade = "DictionaryFacade",
            callbackMethod = "lookupRequest.onResult",
            missingResultMessage = "词典查询未返回结果",
        )
}
