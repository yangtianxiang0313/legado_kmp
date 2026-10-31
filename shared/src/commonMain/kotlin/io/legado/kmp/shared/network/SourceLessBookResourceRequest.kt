package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.Cookie
import io.legado.kmp.shared.model.CookieHostSnapshot
import io.legado.kmp.shared.model.StoredHttpCookie

/** HTTP(S) URL/options and caller variables only; no synthetic source or source-host JS runtime. */
internal suspend fun prepareSourceLessBookResourceRequest(
    jsExecutor: JsExecutor,
    urlRule: String,
    baseUrl: String,
    ruleData: Map<String, Any?>,
    chapter: BookChapter?,
): BuiltUrl {
    val analyzeUrl = AnalyzeUrl(jsExecutor = jsExecutor)
    analyzeUrl.setVariables(ruleData.filterKeys { it != "source" && it != "cookie" })
    chapter?.let {
        analyzeUrl.set(
            "chapter",
            mapOf(
                "url" to it.url,
                "title" to it.title,
                "bookUrl" to it.bookUrl,
                "index" to it.index,
                "baseUrl" to it.baseUrl,
                "variable" to it.variableMap,
            ),
        )
    }
    val request = analyzeUrl.build(urlRule, baseUrl)
    // Check the final target after URL-option JS; data URIs belong to the facade's local path.
    require(httpCookieUrl(request.url) != null) {
        "Source-less book resources require a valid HTTP(S) URL"
    }
    return request
}

internal fun createSourceLessBookResourceTransport(
    httpUseCase: HttpUseCase,
    proxyRequestExecutor: ProxyRequestExecutor?,
    defaultUserAgent: suspend () -> String,
): SourceRequestTransport = SourceRequestTransport(
    httpUseCase = httpUseCase,
    cookieRepository = SourceLessBookResourceCookies,
    // WebView capabilities own shared cookie stores independently of the transport repository.
    interactiveCapability = null,
    webViewRequestExecutor = null,
    proxyRequestExecutor = proxyRequestExecutor,
    mediaRequestExecutor = null,
    uploadRequestExecutor = null,
    defaultUserAgent = defaultUserAgent,
)

/** Neither reads nor retains cookies, including response/redirect cookies from previous requests. */
private object SourceLessBookResourceCookies : CookieRepository {
    override suspend fun getCookiesForUrl(url: String): List<StoredHttpCookie> = emptyList()

    override suspend fun getCookiesForHost(url: String): List<StoredHttpCookie> = emptyList()

    override suspend fun saveCookies(
        url: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean,
        persistCookies: Boolean,
    ) = Unit

    override suspend fun replaceCookiesForHost(
        url: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean,
        persistCookies: Boolean,
    ) = Unit

    override suspend fun replaceCookiesForHosts(
        snapshots: List<CookieHostSnapshot>,
        persistSession: Boolean,
    ) = Unit

    override suspend fun requestCookieHeader(url: String): String? = null

    override suspend fun get(url: String): Cookie? = null

    override suspend fun getAll(): List<Cookie> = emptyList()

    override suspend fun getOkHttpCookies(): List<Cookie> = emptyList()

    override suspend fun insert(cookie: Cookie) = Unit

    override suspend fun update(cookie: Cookie) = Unit

    override suspend fun delete(url: String) = Unit

    override suspend fun deleteOkHttp() = Unit
}
