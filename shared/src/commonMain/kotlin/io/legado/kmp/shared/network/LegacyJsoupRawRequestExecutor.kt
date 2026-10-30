package io.legado.kmp.shared.network

import io.ktor.http.HttpHeaders
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Only the java.get/head/post helpers opt into the application's attributed cookie jar. */
internal class LegacyJsoupRawRequestExecutor(
    private val requests: LegacyJsoupRequestExecutor,
    private val cookieRepository: CookieRepository,
) {
    suspend fun execute(request: BuiltUrl, source: BookSource, headerJson: String?): SourceResponse {
        val context = currentCoroutineContext()
        context.ensureActive()
        val headers = linkedMapOf<String, String>()
        fun putHeaders(values: Map<String, String>) {
            values.forEach { (name, value) ->
                context.ensureActive()
                require(legacyJsoupToken(name) && value.none { it < ' ' || it == '\u007f' }) {
                    "Invalid raw Jsoup HTTP header"
                }
                headers.keys.firstOrNull { it.equals(name, true) }?.let(headers::remove)
                headers[name] = value
            }
        }
        putHeaders(decodeRawHeaders(headerJson))
        putHeaders(request.headers)
        val option = request.rawOption { context.ensureActive() }
        requireRawCapabilities(request, headers, option)
        // Android checks presence, not the value; the internal marker must never reach the server.
        val cookieJarEnabled = source.enabledCookieJar || headers.keys.any { it.equals(COOKIE_JAR_HEADER, true) }
        headers.keys.filter { it.equals(COOKIE_JAR_HEADER, true) }.forEach(headers::remove)
        val target = legacyJsoupUrl(request.url)
        val method = request.method.name
        val body = if (request.method == HttpMethod.POST) {
            request.body ?: option?.urlOptionValueToString("body").takeIf { request.rawBody }.orEmpty()
        } else null

        return ConcurrentRateLimiter(source).withLimit {
            context.ensureActive()
            if (cookieJarEnabled) {
                val stored = cookieRepository.requestCookieHeader(target.toString())
                val explicit = headers.entries.firstOrNull { it.key.equals(HttpHeaders.Cookie, true) }?.value
                // The pinned Android implementation merges (requestCookie, storedCookie): stored wins.
                val merged = mergeRequestCookieHeader(explicit, stored)
                headers.keys.filter { it.equals(HttpHeaders.Cookie, true) }.forEach(headers::remove)
                if (merged != null) headers[HttpHeaders.Cookie] = merged
            }
            context.ensureActive()
            val response = requests.execute(
                LegacyJsoupRequest(
                    url = target.toString(), method = method, headers = headers, requestBody = body,
                    followRedirects = false, ignoreContentType = true,
                ),
            )
            context.ensureActive()
            if (cookieJarEnabled) {
                val now = currentTimeMillis()
                val cookies = response.allHeaders.entries
                    .filter { it.key.equals(HttpHeaders.SetCookie, true) }
                    .flatMap { it.value }
                    .mapNotNull {
                        context.ensureActive()
                        parseStoredSetCookie(response.url, it, now)
                    }
                if (cookies.isNotEmpty()) cookieRepository.saveCookies(response.url, cookies)
            }
            context.ensureActive()
            // Jsoup errors still fail, but only after Set-Cookie has reached the repository.
            if (response.statusCode !in 200..399) {
                throw HttpException(
                    response.statusCode,
                    "HttpStatusException: HTTP error fetching URL. Status=${response.statusCode}",
                )
            }
            response.toSourceResponse { context.ensureActive() }
        }
    }
}

private fun decodeRawHeaders(content: String?): Map<String, String> {
    if (content == null) return emptyMap()
    val root = requireNotNull(decodeLegacyUrlOptionObject(content)) { "Raw request headers must be a map" }
    return root.mapValues { (_, value) ->
        when {
            value is JsonNull -> ""
            value is JsonPrimitive && value.isString -> value.content
            else -> throw IllegalArgumentException("Raw request headers must have string names and values")
        }
    }
}

private fun requireRawCapabilities(request: BuiltUrl, headers: Map<String, String>, option: JsonObject?) {
    val declaredMethod = option?.urlOptionString("method")?.uppercase()
    require((declaredMethod == null || declaredMethod in RAW_METHODS) && request.method.name in RAW_METHODS) {
        "Raw Jsoup helpers support only GET, HEAD and POST"
    }
    if (!request.proxy.isNullOrBlank() || headers.keys.any { it.equals("proxy", true) }) {
        throw UnsupportedProxyRequestException("Raw Jsoup helpers do not support proxy requests")
    }
    if (request.useWebView || !request.webJs.isNullOrBlank() || !request.sourceRegex.isNullOrBlank() ||
        request.webViewDelayTime != 0L
    ) {
        throw UnsupportedWebViewRequestException("Raw Jsoup helpers do not support WebView requests")
    }
    if (!request.type.isNullOrBlank()) {
        throw UnsupportedMediaRequestException("Raw Jsoup helpers do not support typed media requests")
    }
    if (request.serverId != null || request.retry != 0 || !request.charset.isNullOrBlank()) {
        throw SharedCapabilityException(
            "legacy_js_raw_request_options_unsupported",
            "Raw Jsoup helpers do not support serverId, retry or charset URL options",
        )
    }
    require(request.method == HttpMethod.POST || request.body == null) {
        "Raw Jsoup GET and HEAD must not have a request body"
    }
}

private fun BuiltUrl.rawOption(check: () -> Unit): JsonObject? {
    // Use the evaluated rule, not the caller's template, for method validation and blank raw bodies.
    var start = ruleUrl.indexOf(',')
    while (start >= 0) {
        check()
        val candidate = ruleUrl.substring(start + 1).trimStart()
        if (candidate.startsWith('{')) {
            val option = decodeLegacyUrlOptionObject(candidate)
            check()
            if (option != null) return option
        }
        start = ruleUrl.indexOf(',', start + 1)
    }
    return null
}

private const val COOKIE_JAR_HEADER = "CookieJar"
private val RAW_METHODS = setOf("GET", "HEAD", "POST")
