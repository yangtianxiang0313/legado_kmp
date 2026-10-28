package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.legado.kmp.shared.network.MediaResourceContext
import io.legado.kmp.shared.network.PreparedMediaRequest
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal object MediaResourceLimits {
    const val URL_BYTES = 64 * 1024
    const val HEADERS = 128
    const val HEADER_NAME_BYTES = 256
    const val HEADER_VALUE_BYTES = 16 * 1024
    const val HEADER_BYTES = 64 * 1024
    const val SET_COOKIES = 128
}

internal class MediaResourceFailure(val reason: String, message: String) : Exception(message)

internal fun requireMediaResource(value: Boolean, reason: String, message: String) {
    if (!value) throw MediaResourceFailure(reason, message)
}

private fun mediaResourceBounded(value: String, limit: Int): Boolean =
    value.length <= limit && value.encodeToByteArray().size <= limit

private fun mediaResourceAuthorityIsValid(value: String): Boolean {
    val authority = value.substringAfter("://").takeWhile { it != '/' && it != '?' && it != '#' }
    if (authority.isEmpty() || '@' in authority) return false
    val portSuffix = if (authority.startsWith('[')) {
        val closing = authority.indexOf(']')
        if (closing <= 1) return false
        authority.substring(closing + 1)
    } else {
        if (authority.count { it == ':' } > 1) return false
        authority.indexOf(':').takeIf { it >= 0 }?.let { authority.substring(it) }.orEmpty()
    }
    if (portSuffix.isEmpty()) return true
    if (!portSuffix.startsWith(':')) return false
    val port = portSuffix.drop(1)
    // Url may normalize an explicit zero port to the protocol default; inspect this lexeme too.
    return port.isNotEmpty() && port.all { it in '0'..'9' } && port.toIntOrNull()?.let { it in 1..65535 } == true
}

internal fun mediaResourceUrl(value: String): Url {
    requireMediaResource(mediaResourceBounded(value, MediaResourceLimits.URL_BYTES) && value.isNotBlank() &&
        (value.startsWith("http://", ignoreCase = true) || value.startsWith("https://", ignoreCase = true)) &&
        value.none { it.code <= 32 || it.code == 127 || it == '\\' } && mediaResourceAuthorityIsValid(value),
        "invalidUrl", "媒体资源地址无效或超过大小限制")
    val parsed = Url(value)
    requireMediaResource(parsed.protocol.name in setOf("http", "https") && parsed.host.isNotBlank() &&
        parsed.port in 1..65535 && parsed.user == null && parsed.password == null,
        "invalidUrl", "媒体资源仅支持不含内嵌凭据的有效 HTTP(S) 地址")
    return parsed
}

internal fun Url.sameMediaResourceOrigin(other: Url): Boolean =
    protocol == other.protocol && host.equals(other.host, ignoreCase = true) && port == other.port

internal fun requireMediaResourceSecureTarget(origin: Url, target: Url) {
    requireMediaResource(origin.protocol.name != "https" || target.protocol.name != "http",
        "insecureRedirect", "媒体资源不允许从 HTTPS 降级到 HTTP")
}

internal fun requireMediaResourceHeaders(headers: Map<String, String>) {
    requireMediaResource(headers.size <= MediaResourceLimits.HEADERS, "invalidHeaders", "媒体请求头数量超过限制")
    var bytes = 0
    for ((name, value) in headers) {
        requireMediaResource(name.isNotEmpty() && name.length <= MediaResourceLimits.HEADER_NAME_BYTES &&
            name.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "!#$%&'*+-.^_`|~" } &&
            value.none { it.code < 32 && it != '\t' || it.code == 127 } &&
            mediaResourceBounded(value, MediaResourceLimits.HEADER_VALUE_BYTES),
            "invalidHeaders", "媒体请求头无效或超过大小限制")
        bytes += name.length + value.encodeToByteArray().size + 4
        requireMediaResource(bytes <= MediaResourceLimits.HEADER_BYTES, "invalidHeaders", "媒体请求头总大小超过限制")
    }
}

internal fun mediaResourceContext(request: PreparedMediaRequest): MediaResourceContext {
    requireMediaResourceHeaders(request.headers)
    val context = request.resourceContext ?: MediaResourceContext(
        sourceUrl = "",
        headerOriginUrl = request.url,
        explicitCookie = request.headers.entries.filter { it.key.equals("Cookie", ignoreCase = true) }
            .joinToString("; ") { it.value }.ifBlank { null },
        enabledCookieJar = false,
    )
    requireMediaResource(mediaResourceBounded(context.sourceUrl, MediaResourceLimits.URL_BYTES) &&
        context.sourceUrl.none { it.code < 32 || it.code == 127 },
        "invalidContext", "媒体资源书源标识无效或超过大小限制")
    context.explicitCookie?.let { requireMediaResourceHeaders(mapOf("Cookie" to it)) }
    return context
}

internal fun requireMediaResourceCookieFields(fields: List<String>) {
    requireMediaResource(fields.size <= MediaResourceLimits.SET_COOKIES, "cookiesTooLarge", "媒体响应 Cookie 数量超过限制")
    var bytes = 0
    for (field in fields) {
        requireMediaResourceHeaders(mapOf("Set-Cookie" to field))
        bytes += "Set-Cookie".length + field.encodeToByteArray().size + 4
        requireMediaResource(bytes <= MediaResourceLimits.HEADER_BYTES, "cookiesTooLarge", "媒体响应 Cookie 总大小超过限制")
    }
}

internal suspend fun <T> recoverMediaResource(method: String, block: suspend () -> T): T = try {
    currentCoroutineContext().ensureActive()
    block().also { currentCoroutineContext().ensureActive() }
} catch (error: Throwable) {
    currentCoroutineContext().ensureActive()
    findFacadeRequestCancellation(error)?.let { throw it }
    // No cause, raw upstream message or crash log may retain URLs, headers or cookie contents.
    throw when (error) {
        is MediaResourceFailure -> RecoverableSharedException("MediaResourceFacade.${error.reason}", error.message.orEmpty())
        else -> RecoverableSharedException("MediaResourceFacade.$method", "媒体资源请求处理失败，请检查书源或登录状态")
    }
}
