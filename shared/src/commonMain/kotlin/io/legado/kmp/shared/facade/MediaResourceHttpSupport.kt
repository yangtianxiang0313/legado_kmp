package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.network.PreparedMediaRequest
import io.legado.kmp.shared.network.mergeRequestCookieHeader
import io.legado.kmp.shared.network.parseStoredSetCookie
import io.legado.kmp.shared.network.withSplitSetCookieHeaders
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

private val mediaResourcePublicHeaders = setOf(
    "user-agent", "accept", "accept-language", "accept-encoding", "cache-control", "pragma",
    "range", "if-range", "content-type",
)

internal suspend fun mediaResourceHeadersForUrl(
    cookies: CookieRepository,
    request: PreparedMediaRequest,
    targetUrl: String,
): Map<String, String> {
    val context = mediaResourceContext(request)
    val current = mediaResourceUrl(request.url)
    val origin = mediaResourceUrl(context.headerOriginUrl)
    val target = mediaResourceUrl(targetUrl)
    requireMediaResourceSecureTarget(origin, current)
    requireMediaResourceSecureTarget(origin, target)
    requireMediaResourceSecureTarget(current, target)
    val sameOrigin = current.sameMediaResourceOrigin(origin) && target.sameMediaResourceOrigin(origin)
    val headers = request.headers.filterKeys { name ->
        !name.equals("Cookie", ignoreCase = true) && !name.equals("CookieJar", ignoreCase = true) &&
            !name.equals("proxy", ignoreCase = true) && (sameOrigin || name.lowercase() in mediaResourcePublicHeaders)
    }.toMutableMap()
    // The previous Cookie may contain path-scoped jar entries; only context has explicit provenance.
    val jarCookie = cookies.requestCookieHeader(targetUrl)
    jarCookie?.let { requireMediaResourceHeaders(mapOf("Cookie" to it)) }
    mergeRequestCookieHeader(jarCookie, context.explicitCookie.takeIf { sameOrigin })?.let { headers["Cookie"] = it }
    requireMediaResourceHeaders(headers)
    return headers.toMap()
}

internal suspend fun recordMediaResourceCookies(
    cookies: CookieRepository,
    request: PreparedMediaRequest,
    responseUrl: String,
    setCookieHeaders: List<String>,
) {
    val context = mediaResourceContext(request)
    val current = mediaResourceUrl(request.url)
    val origin = mediaResourceUrl(context.headerOriginUrl)
    val response = mediaResourceUrl(responseUrl)
    requireMediaResourceSecureTarget(origin, current)
    requireMediaResource(current.sameMediaResourceOrigin(response) && current.encodedPath == response.encodedPath &&
        current.parameters == response.parameters,
        "unexpectedResponseUrl", "请逐跳处理媒体响应，不能同步隐式重定向后的 Cookie")
    requireMediaResourceCookieFields(setCookieHeaders)
    val fields = mapOf("Set-Cookie" to setCookieHeaders).withSplitSetCookieHeaders().getValue("Set-Cookie")
    requireMediaResourceCookieFields(fields)
    val now = currentTimeMillis()
    val parsed = fields.mapNotNull { parseStoredSetCookie(responseUrl, it, now) }
    currentCoroutineContext().ensureActive()
    if (parsed.isNotEmpty()) {
        cookies.saveCookies(responseUrl, parsed,
            persistCookies = context.sourceUrl.isNotBlank() && context.enabledCookieJar)
    }
}
