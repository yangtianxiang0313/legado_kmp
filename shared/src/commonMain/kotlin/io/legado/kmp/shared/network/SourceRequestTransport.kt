package io.legado.kmp.shared.network

import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.takeFrom
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import kotlinx.coroutines.withTimeoutOrNull

internal class SourceRequestTransport(
    private val httpUseCase: HttpUseCase,
    private val cookieRepository: CookieRepository,
    private val interactiveCapability: InteractiveSourceCapability?,
    private val webViewRequestExecutor: WebViewRequestExecutor?,
    private val proxyRequestExecutor: ProxyRequestExecutor?,
    private val mediaRequestExecutor: MediaRequestExecutor?,
    private val uploadRequestExecutor: UploadRequestExecutor?,
    private val defaultUserAgent: suspend () -> String,
) {

    suspend fun prepareMedia(request: BuiltUrl, source: BookSource, defaultHeaders: Map<String, String>): PreparedMediaRequest {
        requireNativeMediaCapabilities(request, defaultHeaders)
        if (source.concurrentRate?.trim().orEmpty().let { it.isNotBlank() && it != "0" }) {
            throw UnsupportedMediaRequestException("原生音频不支持书源并发限速规则")
        }
        return withCookies(request, defaultHeaders, source.enabledCookieJar, followRedirects = false).toPreparedMediaRequest()
    }

    suspend fun createContext(
        request: BuiltUrl,
        source: BookSource?,
        defaultHeaders: Map<String, String>,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        followRedirects: Boolean = true
    ): SourceExecutionContext {
        val cookieDomain = extractCookieDomain(request.url)
        val proxy = extractProxy(request, defaultHeaders)
        val requestConfig = withCookies(
            request = request,
            defaultHeaders = defaultHeaders,
            enableCookieJar = source?.enabledCookieJar == true,
            followRedirects = followRedirects
        )
        return SourceExecutionContext(
            request = request,
            requestConfig = requestConfig,
            source = source,
            defaultHeaders = defaultHeaders,
            ruleData = ruleData,
            chapter = chapter,
            cookieDomain = cookieDomain,
            proxy = proxy
        )
    }

    suspend fun executeText(
        context: SourceExecutionContext,
        allowRedirectResponse: Boolean = false
    ): HttpResponse {
        val request = context.request
        val proxy = context.proxy
        val persistCookies = context.source?.enabledCookieJar == true
        if (!request.type.isNullOrBlank()) {
            AnalyzeUrl.getByteArrayIfDataUri(request.urlNoQuery)?.let { bytes ->
                return HttpResponse(
                    statusCode = 200,
                    statusText = "OK",
                    headers = emptyMap(),
                    allHeaders = emptyMap(),
                    body = bytes,
                    bodyText = bytes.encodeHexString(),
                    url = request.url
                )
            }
        }

        return when {
            !request.type.isNullOrBlank() -> {
                // Typed requests retain the legacy binary HTTP/proxy route.
                executeExternalWithRetry(
                    retry = request.retry,
                    requestUrl = context.requestConfig.url,
                    persistCookies = persistCookies
                ) {
                    val binaryResponse = if (!proxy.isNullOrBlank()) {
                        executeProxy(context, proxy)
                    } else {
                        executeScopedHttp(context)
                    }
                    encodeMediaBodyAsHex(binaryResponse)
                }
            }
            request.useWebView -> executeWebView(context, allowRedirectResponse)
            !proxy.isNullOrBlank() -> {
                executeExternalWithRetry(
                    retry = request.retry,
                    requestUrl = context.requestConfig.url,
                    persistCookies = persistCookies
                ) {
                    executeProxy(context, proxy)
                }
            }
            else -> {
                val response = executeExternalWithRetry(
                    retry = request.retry,
                    requestUrl = context.requestConfig.url,
                    persistCookies = persistCookies
                ) {
                    executeScopedHttp(context)
                }
                if (!response.isSuccessful && !(allowRedirectResponse && response.isRedirect)) {
                    throw HttpException(response.statusCode, response.statusText)
                }
                response
            }
        }
    }

    suspend fun executeUpload(
        context: SourceExecutionContext,
        fileName: String,
        fileData: ByteArray,
        contentType: String
    ): HttpResponse {
        val request = context.request
        val upload = MultipartUploadRequest(
            url = request.urlNoQuery,
            multipartType = request.type,
            parts = buildMultipartUploadParts(
                body = request.body,
                fileName = fileName,
                fileData = fileData,
                contentType = contentType
            )
        )
        return executeExternalWithRetry(
            retry = request.retry,
            requestUrl = context.requestConfig.url,
            persistCookies = context.source?.enabledCookieJar == true
        ) {
            val uploadContext = context.copy(requestConfig = context.requestConfig.copy(method = HttpMethod.POST))
            executeScopedHttp(uploadContext) { config ->
                if (config.method == HttpMethod.POST) {
                    uploadRequestExecutor?.execute(context.copy(requestConfig = config), upload.copy(url = config.url))
                        ?: throw UnsupportedUploadRequestException("AnalyzeUrl upload requests are not implemented in shared execution yet")
                } else if (!context.proxy.isNullOrBlank()) {
                    executeRawProxy(context.copy(requestConfig = config), context.proxy)
                } else {
                    httpUseCase.execute(config).getOrThrow()
                }
            }
        }
    }

    private suspend fun executeWebView(
        context: SourceExecutionContext,
        allowRedirectResponse: Boolean
    ): HttpResponse {
        val request = context.request
        val source = context.source
        val proxy = context.proxy
        val persistCookies = source?.enabledCookieJar == true
        if (request.sourceRegex == null && webViewRequestExecutor != null) {
            // The legacy String result cannot carry navigation response metadata.
            val response = webViewRequestExecutor.executeText(context)
            saveResponseCookies(context.requestConfig.url, response, persistCookies)
            if (!response.isSuccessful && !(allowRedirectResponse && response.isRedirect)) {
                throw HttpException(response.statusCode, response.statusText)
            }
            return response
        }

        val interactiveResponse = when {
            request.method == HttpMethod.POST && request.sourceRegex != null -> {
                val initialResponse = if (!proxy.isNullOrBlank()) {
                    executeProxy(context, proxy)
                } else {
                    executeScopedHttp(context)
                }
                saveResponseCookies(context.requestConfig.url, initialResponse, persistCookies)
                interactiveCapability?.executeWebView(
                    LegacyWebViewRequest(
                        html = initialResponse.bodyText,
                        url = initialResponse.url.ifBlank { request.url },
                        javaScript = request.webJs,
                        webViewDelayTime = request.webViewDelayTime,
                        sourceRegex = request.sourceRegex,
                        headers = context.requestConfig.headers,
                        proxy = proxy,
                        source = source
                    )
                )?.let { body ->
                    initialResponse.copy(
                        body = body.encodeToByteArray(),
                        bodyText = body,
                        url = initialResponse.url.ifBlank { request.url }
                    )
                }
            }
            request.method != HttpMethod.POST -> {
                interactiveCapability?.executeWebView(
                    LegacyWebViewRequest(
                        url = request.url,
                        javaScript = request.webJs,
                        webViewDelayTime = request.webViewDelayTime,
                        sourceRegex = request.sourceRegex,
                        headers = context.requestConfig.headers,
                        proxy = proxy,
                        source = source
                    )
                )?.let { body ->
                    HttpResponse(
                        statusCode = 200,
                        statusText = "OK",
                        headers = emptyMap(),
                        body = body.encodeToByteArray(),
                        bodyText = body,
                        url = request.url
                    )
                }
            }
            else -> null
        }
        val response = interactiveResponse
            ?: webViewRequestExecutor?.executeText(context)
            ?: throw UnsupportedWebViewRequestException(
                "AnalyzeUrl webView requests are not implemented in shared execution yet"
            )
        saveResponseCookies(context.requestConfig.url, response, persistCookies)
        return response
    }

    private suspend fun executeProxy(context: SourceExecutionContext, proxy: String): HttpResponse {
        return executeScopedHttp(context) { config -> executeRawProxy(context.copy(requestConfig = config), proxy) }
    }

    private suspend fun executeRawProxy(context: SourceExecutionContext, proxy: String): HttpResponse =
        interactiveCapability?.executeProxy(context, proxy)
            ?: proxyRequestExecutor?.executeText(context, proxy)
            ?: throw UnsupportedProxyRequestException(
                "AnalyzeUrl proxy requests are not implemented in shared execution yet"
            )

    private suspend fun refreshCookieContext(context: SourceExecutionContext): SourceExecutionContext {
        val explicit = context.request.toHttpRequestConfig(context.defaultHeaders).headers.entries
            .filter { it.key.equals("Cookie", ignoreCase = true) }.joinToString("; ") { it.value }
        val config = context.requestConfig
        val headers = config.headers.filterKeys { !it.equals("Cookie", ignoreCase = true) }.toMutableMap()
        mergeRequestCookieHeader(cookieRepository.requestCookieHeader(config.url), explicit)
            ?.let { headers["Cookie"] = it }
        return context.copy(requestConfig = config.copy(headers = headers))
    }

    private suspend fun withCookies(
        request: BuiltUrl,
        defaultHeaders: Map<String, String>,
        enableCookieJar: Boolean,
        followRedirects: Boolean = true
    ): HttpRequestConfig {
        val config = request.toHttpRequestConfig(defaultHeaders).copy(
            followRedirects = followRedirects
        )
        val headers = LinkedHashMap(config.headers)
        headers.putDefaultUserAgent(defaultUserAgent)
        headers.entries.removeAll { it.key.equals("proxy", ignoreCase = true) }
        val explicitCookie = headers.entries.filter { it.key.equals("Cookie", ignoreCase = true) }
            .joinToString("; ") { it.value }
        val mergedCookie = mergeRequestCookieHeader(
            cookieRepository.requestCookieHeader(config.url),
            explicitCookie
        )
        headers.entries.removeAll { it.key.equals("Cookie", ignoreCase = true) }
        if (!mergedCookie.isNullOrBlank()) {
            headers["Cookie"] = mergedCookie
        }

        if (enableCookieJar) {
            headers[COOKIE_JAR_HEADER] = "1"
        } else {
            headers.remove(COOKIE_JAR_HEADER)
        }

        normalizeExplicitUrlHeaders(headers)

        return config.copy(headers = headers)
    }

    private suspend fun executeExternalWithRetry(
        retry: Int,
        requestUrl: String,
        persistCookies: Boolean,
        execute: suspend () -> HttpResponse
    ): HttpResponse {
        var lastResponse: HttpResponse? = null
        for (attempt in 0..retry.coerceAtLeast(0)) {
            val response = execute()
            lastResponse = response
            saveResponseCookies(requestUrl, response, persistCookies)
            if (response.isSuccessful) {
                return response
            }
        }
        return lastResponse ?: throw HttpException(0, "Empty HTTP response")
    }

    private suspend fun saveResponseCookies(
        requestUrl: String,
        response: HttpResponse,
        persistCookies: Boolean
    ) {
        val responseUrl = response.url.ifBlank { requestUrl }
        val setCookieHeaders = response.allHeaders.withSplitSetCookieHeaders()
            .flatMap { (name, values) ->
                if (name.equals("Set-Cookie", ignoreCase = true)) values else emptyList()
            }
            .ifEmpty {
                response.headers.mapValues { listOf(it.value) }.withSplitSetCookieHeaders().entries
                    .filter { it.key.equals("Set-Cookie", ignoreCase = true) }.flatMap { it.value }
            }
        if (setCookieHeaders.isEmpty()) return
        val now = io.legado.kmp.shared.util.currentTimeMillis()
        cookieRepository.saveCookies(
            responseUrl,
            setCookieHeaders.mapNotNull { parseStoredSetCookie(responseUrl, it, now) },
            persistCookies = persistCookies
        )
    }

    /** Disable implicit redirects so Cookie is re-evaluated for every actual target URL. */
    private suspend fun executeScopedHttp(
        context: SourceExecutionContext,
        send: suspend (HttpRequestConfig) -> HttpResponse = { httpUseCase.execute(it).getOrThrow() },
    ): HttpResponse =
        // Only this deadline becomes a network failure; cancellation of the caller still propagates.
        withTimeoutOrNull(context.requestConfig.timeout.inWholeMilliseconds.coerceAtLeast(1L)) {
            val initial = context.requestConfig
            var current = initial.copy(followRedirects = false)
            var explicitCookie = context.request.toHttpRequestConfig(context.defaultHeaders).headers.entries
                .filter { it.key.equals("Cookie", ignoreCase = true) }.joinToString("; ") { it.value }.ifBlank { null }
            var redirects = 0
            while (true) {
                val headers = current.headers.filterKeys { !it.equals("Cookie", ignoreCase = true) }.toMutableMap()
                mergeRequestCookieHeader(cookieRepository.requestCookieHeader(current.url), explicitCookie)
                    ?.let { headers["Cookie"] = it }
                current = current.copy(headers = headers)
                val response = send(current)
                if (!initial.followRedirects || response.statusCode !in COOKIE_REDIRECT_STATUSES) return@withTimeoutOrNull response
                val location = response.headers.entries.firstOrNull { it.key.equals("Location", ignoreCase = true) }?.value
                    ?: response.allHeaders.entries.firstOrNull { it.key.equals("Location", ignoreCase = true) }?.value?.firstOrNull()
                    ?: return@withTimeoutOrNull response
                val origin = httpCookieUrl(response.url.ifBlank { current.url }) ?: return@withTimeoutOrNull response
                val target = runCatching {
                    URLBuilder(origin).apply {
                        if (location.isNotEmpty() && !location.startsWith('#')) parameters.clear()
                    }.takeFrom(location).build()
                }.getOrNull() ?: return@withTimeoutOrNull response
                if (target.protocol.name !in setOf("http", "https") ||
                    (origin.protocol.name == "https" && target.protocol.name == "http")
                ) return@withTimeoutOrNull response
                saveResponseCookies(current.url, response, context.source?.enabledCookieJar == true)
                if (++redirects > 20) throw NetworkException("Too many HTTP redirects")
                val sameOrigin = origin.sameCookieOrigin(target)
                if (!sameOrigin) explicitCookie = null
                val redirectToGet = response.statusCode != 307 && response.statusCode != 308 &&
                    current.method != HttpMethod.GET && current.method != HttpMethod.HEAD
                current = current.copy(
                    url = target.toString(),
                    method = if (redirectToGet) HttpMethod.GET else current.method,
                    headers = current.headers.filterKeys { name ->
                        !name.equals("Cookie", ignoreCase = true) &&
                            !(redirectToGet && COOKIE_REDIRECT_BODY_HEADERS.any { it.equals(name, ignoreCase = true) }) &&
                            !(!sameOrigin && COOKIE_REDIRECT_AUTH_HEADERS.any { it.equals(name, ignoreCase = true) })
                    },
                    parameters = emptyMap(),
                    body = current.body.takeUnless { redirectToGet },
                    bodyBytes = current.bodyBytes.takeUnless { redirectToGet }
                )
            }
            @Suppress("UNREACHABLE_CODE")
            error("Unreachable cookie redirect state")
        } ?: throw NetworkException("Request timed out after ${context.requestConfig.timeout.inWholeMilliseconds} ms")

    private fun Url.sameCookieOrigin(other: Url): Boolean =
        protocol == other.protocol && host.equals(other.host, ignoreCase = true) && port == other.port

    private fun extractProxy(
        request: BuiltUrl,
        defaultHeaders: Map<String, String>
    ): String? {
        return request.proxy?.takeIf { it.isNotBlank() }
            ?: request.headers.entries.firstOrNull { it.key.equals("proxy", ignoreCase = true) }?.value
            ?: defaultHeaders.entries.firstOrNull { it.key.equals("proxy", ignoreCase = true) }?.value
    }

    private companion object {
        private const val COOKIE_JAR_HEADER = "CookieJar"
        private val COOKIE_REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
        private val COOKIE_REDIRECT_BODY_HEADERS = setOf("Content-Type", "Content-Length", "Transfer-Encoding", "X-HTTP-Method-Override")
        private val COOKIE_REDIRECT_AUTH_HEADERS = setOf("Authorization", "Proxy-Authorization")
    }
}
