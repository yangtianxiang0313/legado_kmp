package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.domain.repository.RssSourceRepository
import io.legado.kmp.shared.domain.rss.asBookSourceShim
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.AnalyzeUrlLegacyContext
import io.legado.kmp.shared.network.BuiltUrl
import io.legado.kmp.shared.network.HttpMethod
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.network.mergeRequestCookieHeader
import io.legado.kmp.shared.network.normalizeExplicitUrlHeaders
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

data class RssArticleWebRequest(
    val source: RssSource,
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val bodyBase64: String?,
    val cookies: List<StoredHttpCookie>,
) {
    override fun toString(): String = "RssArticleWebRequest(redacted)"
}

data class RssArticleWebResult(
    val request: RssArticleWebRequest? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

/** Prepares the same URL/header context as ReadRssViewModel.loadUrl; it never loads the page. */
class RssArticleWebFacade(
    private val sources: RssSourceRepository,
    private val state: SourceStateStore,
    private val executor: SourceRequestExecutor,
    private val cookies: CookieRepository,
    private val runtime: SourceJsRuntime,
) {
    companion object {
        private const val PROXY_ERROR_CODE = "RssArticleWebFacade.proxy"
        private const val PROXY_ERROR_MESSAGE = "订阅浏览器和图片请求暂不支持代理，已停止请求"

        @Throws(RecoverableSharedException::class)
        fun create(): RssArticleWebFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            RssArticleWebFacade(koin.get(), koin.get(), koin.get(), koin.get(), koin.get())
        } catch (_: Exception) {
            throw RecoverableSharedException("RssArticleWebFacade.create", "订阅文章服务不可用，请重试")
        }
    }

    fun prepareRequest(article: RssArticle, navigation: Boolean, onResult: (RssArticleWebResult) -> Unit): FlowSubscription =
        CancellableFacadeRequest.start(
            prepare = { RssArticleWebResult(request = prepare(article, navigation)) },
            cancelledResult = RssArticleWebResult(isCancelled = true),
            failureResult = { RssArticleWebResult(errorMessage = failureMessage(it, "订阅文章请求准备失败，请检查订阅源配置后重试")) },
            onResult = onResult,
            facade = "RssArticleWebFacade",
            callbackMethod = "prepareRequest",
            missingResultMessage = "RSS browser preparation unavailable",
        )

    fun prepareResourceRequest(
        article: RssArticle,
        targetUrl: String,
        requestOriginUrl: String?,
        onResult: (RssArticleResourceResult) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = { RssArticleResourceResult(request = prepareResource(article, targetUrl, requestOriginUrl)) },
        cancelledResult = RssArticleResourceResult(isCancelled = true),
        failureResult = { RssArticleResourceResult(errorMessage = failureMessage(it, "订阅图片请求准备失败，请检查订阅源后重试")) },
        onResult = onResult,
        facade = "RssArticleWebFacade",
        callbackMethod = "prepareResourceRequest",
        missingResultMessage = "RSS resource preparation unavailable",
    )

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareResource(article: RssArticle, targetUrl: String, requestOriginUrl: String?): RssArticleResourceRequest {
        try {
            currentCoroutineContext().ensureActive()
            val target = resourceUrl(targetUrl)
            val origin = requestOriginUrl?.let(::resourceUrl)
            val source = sources.getByKey(article.origin)
            val sameOrigin = origin != null && target.protocol == origin.protocol && target.host.equals(origin.host, true) &&
                target.port == origin.port
            // Even foreign resources must honor source transport controls. Evaluate once before filtering credentials.
            val sourceHeaders = if (source != null) {
                val variables = article.variableMap + mapOf("link" to article.link, "image" to targetUrl)
                val built = BuiltUrl(targetUrl, targetUrl, targetUrl.substringBefore('?'), requestOriginUrl.orEmpty(), usedVariables = variables)
                executor.resolveSourceHeaders(source.asBookSourceShim(), built, false, variables)
            } else {
                emptyMap()
            }
            requireNoProxy(sourceHeaders)
            val forwardedHeaders = if (source != null && sameOrigin) sourceHeaders
                else mapOf("User-Agent" to executor.defaultUserAgent())
            // No source Cookie/Authorization/custom headers cross origins; the jar is scoped to the target URL.
            val headers = nativeHeaders(targetUrl, forwardedHeaders)
            currentCoroutineContext().ensureActive()
            return RssArticleResourceRequest(targetUrl, headers)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (error is RecoverableSharedException && error.code == PROXY_ERROR_CODE) throw error
            throw RecoverableSharedException("RssArticleWebFacade.resource", "订阅图片请求准备失败，请检查订阅源后重试")
        }
    }

    private fun failureMessage(error: Throwable, fallback: String): String =
        if (error is RecoverableSharedException && error.code == PROXY_ERROR_CODE) PROXY_ERROR_MESSAGE else fallback

    private fun requireNoProxy(headers: Map<String, String>, request: BuiltUrl? = null) {
        if (!request?.proxy.isNullOrBlank() ||
            request?.headers?.any { (key, value) -> key.equals("proxy", true) && value.isNotBlank() } == true ||
            headers.any { (key, value) -> key.equals("proxy", true) && value.isNotBlank() }
        ) {
            throw RecoverableSharedException(PROXY_ERROR_CODE, PROXY_ERROR_MESSAGE)
        }
    }

    private suspend fun nativeHeaders(url: String, prepared: Map<String, String>): Map<String, String> {
        val headers = LinkedHashMap(prepared)
        requireValidHeaders(headers)
        val explicitCookie = headers.entries.filter { it.key.equals("Cookie", true) }.joinToString("; ") { it.value }
        headers.keys.removeAll { it.equals("Cookie", true) || it.equals("CookieJar", true) || it.equals("proxy", true) }
        // Match withCookies: the source flag controls persistence, not reading the target's jar or explicit cookies.
        mergeRequestCookieHeader(cookies.requestCookieHeader(url), explicitCookie)?.let { headers["Cookie"] = it }
        normalizeExplicitUrlHeaders(headers)
        requireValidHeaders(headers)
        return headers
    }

    private fun requireValidHeaders(headers: Map<String, String>) {
        require(headers.size <= 128 && headers.all { (key, value) ->
            key.isNotEmpty() && key.length <= 256 && value.length <= 32768 &&
                key.none { it.code <= 32 || it.code >= 127 } && value.none { it == '\r' || it == '\n' }
        })
    }

    private fun resourceUrl(value: String): Url {
        require(value.length <= 32768 && value.none { it == '\r' || it == '\n' })
        return Url(value).also {
            require(it.protocol.name in setOf("http", "https") && it.host.isNotBlank())
            require(it.user.isNullOrEmpty() && it.password.isNullOrEmpty())
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepare(article: RssArticle, navigation: Boolean): RssArticleWebRequest {
        try {
            currentCoroutineContext().ensureActive()
            val source = requireNotNull(sources.getByKey(article.origin))
            val shim = source.asBookSourceShim()
            val variables = article.variableMap + ("link" to article.link)
            val analyze = AnalyzeUrl(legacyContext = AnalyzeUrlLegacyContext(
                source = shim, sourceStateStore = state, cookieRepository = cookies,
                gateway = executor, sourceJsRuntime = runtime, ruleData = variables,
            ))
            analyze.setVariables(state.getSourceVariableMap(source.sourceUrl) + variables)
            val built = analyze.build(article.link.ifBlank { source.sourceUrl }, article.origin)
            // Browser navigation deliberately excludes saved login headers, matching Android's hasLoginHeader=false.
            val headers = executor.resolveSourceHeaders(shim, built, includeLoginHeader = false, ruleData = variables)
            requireNoProxy(headers, built)
            if (navigation) {
                require(built.serverId == null && built.type.isNullOrBlank())
                require(built.requestJs.isNullOrBlank() && built.webJs.isNullOrBlank() && built.webViewDelayTime == 0L)
                require(built.method == HttpMethod.GET || built.method == HttpMethod.POST)
            }
            val config = built.toHttpRequestConfig(headers)
            val target = Url(config.url)
            require(target.protocol.name in setOf("http", "https") && target.host.isNotBlank())
            require(target.user.isNullOrEmpty() && target.password.isNullOrEmpty())
            val nativeHeaders = nativeHeaders(config.url, config.headers)
            val body = config.bodyBytes ?: config.body?.let { TextCodec.encode(it, built.charset ?: "UTF-8") }
            require((body?.size ?: 0) <= 1024 * 1024)
            // Seed attributed cookies as well as the merged header, preserving their path/security flags.
            // Keep source.enabledCookieJar unchanged: CookieJar headers are not an override in withCookies.
            val seed = cookies.getCookiesForHost(config.url)
            currentCoroutineContext().ensureActive()
            return RssArticleWebRequest(source, config.url, config.method.name, nativeHeaders,
                body?.let { Base64.encode(it) }, seed)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            if (error is RecoverableSharedException && error.code == PROXY_ERROR_CODE) throw error
            // Do not send URL rules, cookies, form bodies, or source script errors to CrashCollector.
            throw RecoverableSharedException("RssArticleWebFacade.prepare", "订阅文章请求准备失败，请检查订阅源配置后重试")
        }
    }
}
