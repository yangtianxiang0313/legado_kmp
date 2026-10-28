package io.legado.kmp.shared.network

import io.ktor.http.Url
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Final HTTP intent only; preparing it does not send the media request. Never log this object. */
data class PreparedMediaRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val bodyBase64: String?,
    val timeoutMillis: Long,
    val allowsSystemAsset: Boolean = false,
    val resourceContext: MediaResourceContext? = null,
) {
    override fun toString(): String = "PreparedMediaRequest(redacted)"
}

/** Cookie provenance before jar merging; retain headerOriginUrl throughout a resource chain. */
data class MediaResourceContext(
    val sourceUrl: String,
    val headerOriginUrl: String,
    val explicitCookie: String?,
    val enabledCookieJar: Boolean,
) {
    override fun toString(): String = "MediaResourceContext(redacted)"
}

/** Native single-response audio cannot execute these source transport capabilities. */
internal fun requireNativeMediaCapabilities(request: BuiltUrl, defaultHeaders: Map<String, String>) {
    fun unsupported(message: String): Nothing = throw UnsupportedMediaRequestException(message)
    if (request.useWebView || !request.webJs.isNullOrBlank() || !request.sourceRegex.isNullOrBlank() || request.webViewDelayTime != 0L) {
        unsupported("原生音频不支持 WebView 请求或 WebView 脚本")
    }
    if (!request.proxy.isNullOrBlank() || (defaultHeaders + request.headers).any { (key, value) ->
            key.equals("proxy", ignoreCase = true) && value.isNotBlank()
        }) unsupported("原生音频不支持书源代理")
    if (!request.type.isNullOrBlank()) unsupported("原生音频不支持 type 二进制转换、解密或自定义媒体处理")
    if (request.serverId != null) unsupported("原生音频不支持远程服务器请求")
    if (request.retry > 0) unsupported("原生音频不支持 URL 规则自动重试，请重试播放")
    if (request.method != HttpMethod.GET && request.method != HttpMethod.POST) {
        unsupported("原生音频只支持 GET 和 POST")
    }
}

@OptIn(ExperimentalEncodingApi::class)
internal fun HttpRequestConfig.toPreparedMediaRequest(): PreparedMediaRequest {
    val parsed = runCatching { Url(url) }.getOrNull()
    require(parsed != null && parsed.protocol.name in setOf("http", "https") && parsed.host.isNotBlank()) {
        "原生音频需要有效的 HTTP(S) 请求"
    }
    require(parsed.user.isNullOrEmpty() && parsed.password.isNullOrEmpty()) { "原生音频不支持 URL 内嵌凭据" }
    val bytes = bodyBytes ?: body?.encodeToByteArray()
    require((bytes?.size ?: 0) <= 1024 * 1024) { "音频请求正文超过 1 MiB 上限" }
    val nativeHeaders = headers.filterKeys { !it.equals("CookieJar", ignoreCase = true) }
    require(nativeHeaders.none { (name, value) -> name.any { it == '\r' || it == '\n' } || value.any { it == '\r' || it == '\n' } }) {
        "音频请求头无效"
    }
    return PreparedMediaRequest(url, method.name, nativeHeaders, bytes?.let { Base64.encode(it) }, timeout.inWholeMilliseconds.coerceAtLeast(1))
}
