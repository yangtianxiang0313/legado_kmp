package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.rss.asBookSourceShim
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

enum class RssArticleNavigationActionKind {
    SEARCH_BOOK,
    ADD_BOOK,
}

data class RssArticleNavigationAction(
    val kind: RssArticleNavigationActionKind,
    val value: String,
) {
    override fun toString(): String = "RssArticleNavigationAction(kind=$kind, value=redacted)"
}

data class RssArticleNavigationResult(
    val isOverridden: Boolean = false,
    val actions: List<RssArticleNavigationAction> = emptyList(),
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

/** Evaluates ReadRssActivity's source hook; the caller owns all navigation and confirmation UI. */
class RssArticleNavigationFacade(
    private val sources: RssSourceRepository,
    private val state: SourceStateStore,
    private val executor: SourceRequestExecutor,
    private val runtime: SourceJsRuntime,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): RssArticleNavigationFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RssArticleNavigationFacade(koin.get(), koin.get(), koin.get(), koin.get())
        } catch (_: Exception) {
            throw RecoverableSharedException("RssArticleNavigationFacade.create", "订阅文章跳转服务不可用，请重试")
        }
    }

    fun evaluateRequest(
        article: RssArticle,
        targetUrl: String,
        onResult: (RssArticleNavigationResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { evaluate(article, targetUrl) },
        cancelledResult = RssArticleNavigationResult(isCancelled = true),
        failureResult = { RssArticleNavigationResult(errorMessage = RSS_NAVIGATION_ERROR_MESSAGE) },
        onResult = { result ->
            try {
                onResult(result)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // The request helper logs callback exceptions, so never forward caller payloads.
                throw IllegalStateException("RSS navigation callback failed")
            }
        },
        facade = "RssArticleNavigationFacade",
        callbackMethod = "evaluateRequest",
        missingResultMessage = "RSS navigation result unavailable",
    )

    private suspend fun evaluate(article: RssArticle, targetUrl: String): RssArticleNavigationResult {
        val actions = RssArticleNavigationActions()
        try {
            currentCoroutineContext().ensureActive()
            val source = sources.getByKey(article.origin) ?: return RssArticleNavigationResult()
            val script = source.shouldOverrideUrlLoading?.takeIf { it.isNotBlank() }
                ?: return RssArticleNavigationResult()
            require(targetUrl.isNotBlank() && targetUrl.length <= 64 * 1024)
            val shim = source.asBookSourceShim()
            val sourceVariables = state.getSourceVariableMap(source.sourceUrl)
            val variables = linkedMapOf<String, Any?>().apply {
                putAll(sourceVariables)
                putAll(article.variableMap)
                put("link", article.link)
                put("baseUrl", source.sourceUrl)
                put("url", targetUrl)
                put("sourceVariable", state.getSourceVariable(source.sourceUrl))
                put("sourceVariableMap", sourceVariables)
            }
            val host = createRssArticleNavigationHost(shim, variables, executor, actions)
            // No probing, fallback evaluator, or replay: source jsLib and this hook execute once.
            val result = runtime.execute(
                script = script,
                source = shim,
                variables = variables,
                connect = host.connect,
                rawConnect = host.rawConnect,
                getSourceHeaders = host.getSourceHeaders,
                host = host,
            )
            currentCoroutineContext().ensureActive()
            if (result is JsResult.JsError) {
                findFacadeRequestCancellation(result.exception)?.let { throw it }
            }
            return RssArticleNavigationResult(
                isOverridden = result !is JsResult.JsError && result.asString().isRssNavigationTrue(),
                actions = actions.snapshot(),
                errorMessage = if (result is JsResult.JsError) RSS_NAVIGATION_ERROR_MESSAGE else null,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            currentCoroutineContext().ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            return RssArticleNavigationResult(
                actions = actions.snapshot(),
                errorMessage = RSS_NAVIGATION_ERROR_MESSAGE,
            )
        }
    }
}
