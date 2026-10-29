package io.legado.kmp.shared.facade

import io.ktor.http.ContentType
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.HttpMethod
import io.legado.kmp.shared.network.SourceExecutionContext
import io.legado.kmp.shared.network.mergeRequestCookieHeader
import io.legado.kmp.shared.network.normalizeExplicitUrlHeaders
import io.legado.kmp.shared.network.parseStoredSetCookie
import io.legado.kmp.shared.network.withSplitSetCookieHeaders
import io.legado.kmp.shared.network.withoutNullUserAgent
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

@OptIn(ExperimentalEncodingApi::class)
internal fun prepareWebBookFileHttp(
    context: SourceExecutionContext,
    source: BookSource,
    book: Book,
    option: WebBookFileOption,
): WebBookFileRequest {
    val request = context.request
    val config = context.requestConfig
    fun supported(value: Boolean, message: String) = requireWebBookFile(value, "unsupported", message)
    supported(!request.useWebView && request.webJs.isNullOrBlank() && request.sourceRegex.isNullOrBlank() &&
        request.webViewDelayTime == 0L, "文件下载暂不支持 WebView 请求或脚本")
    supported(context.proxy.isNullOrBlank() && request.proxy.isNullOrBlank() &&
        (context.defaultHeaders.entries + request.headers.entries).none { (name, value) ->
            name.equals("proxy", ignoreCase = true) && value.isNotBlank()
        }, "文件下载暂不支持书源代理")
    supported(request.serverId == null, "文件下载暂不支持远程服务器请求")
    requireWebBookFile(request.retry >= 0, "invalidRetry", "文件下载重试次数不能为负数")
    supported(request.method == HttpMethod.GET || request.method == HttpMethod.POST, "文件下载仅支持 GET 和 POST 请求")
    // In a FILE source, type is a file-format hint, not an audio/decryption capability.
    supported(request.type.isNullOrBlank() || webBookFileTypeSuffix(request.type) != null, "文件下载的 type 必须是文件后缀或已知文件 MIME 类型")
    webBookFileUrl(config.url)
    requireWebBookFileHeaders(context.defaultHeaders)
    requireWebBookFileHeaders(request.headers)
    requireWebBookFileHeaders(config.headers)
    val headers = config.headers.filterKeys { !it.equals("CookieJar", ignoreCase = true) }
        .withoutNullUserAgent().toMutableMap()
    requireWebBookFileHeaders(headers)
    normalizeExplicitUrlHeaders(headers)
    requireWebBookFileHeaders(headers)
    val explicitCookie = request.toHttpRequestConfig(context.defaultHeaders).headers.entries
        .filter { it.key.equals("Cookie", ignoreCase = true) }.joinToString("; ") { it.value }.ifBlank { null }
    config.body?.let {
        requireWebBookFile(webBookFileBounded(it, WebBookFileLimits.BODY_BYTES), "bodyTooLarge", "文件请求正文超过 1 MiB 限制")
    }
    val contentType = headers.entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }?.value
    val charset = contentType?.let { ContentType.parse(it).parameters }
        ?.firstOrNull { it.name.equals("charset", ignoreCase = true) }?.value
        ?: request.charset?.takeUnless { it.equals("escape", ignoreCase = true) } ?: "UTF-8"
    val body = config.bodyBytes ?: config.body?.let { TextCodec.encode(it, charset) }
    requireWebBookFile((body?.size ?: 0) <= WebBookFileLimits.BODY_BYTES, "bodyTooLarge", "文件请求正文超过 1 MiB 限制")
    val resolvedName = webBookFileOption(book, option.urlRule, config.url, request.type)
    val fileName = if (resolvedName.suffix != "bin" || option.suffix == "bin") resolvedName.fileName else option.fileName
    return WebBookFileRequest(
        url = config.url,
        method = config.method.name,
        headers = headers.toMap(),
        bodyBase64 = body?.let { Base64.encode(it) },
        fileName = fileName,
        timeoutMillis = config.timeout.inWholeMilliseconds.coerceIn(1L, 120_000L),
        sourceUrl = source.bookSourceUrl,
        headerOriginUrl = config.url,
        explicitCookie = explicitCookie,
        enabledCookieJar = source.enabledCookieJar,
        retryCount = request.retry,
    )
}

internal suspend fun prepareWebBookFileRedirect(
    cookies: CookieRepository,
    request: WebBookFileRequest,
    targetUrl: String,
): Map<String, String> {
    val current = webBookFileUrl(request.url)
    val origin = webBookFileUrl(request.headerOriginUrl)
    val target = webBookFileUrl(targetUrl)
    requireWebBookFile(!(current.protocol.name == "https" && target.protocol.name == "http"),
        "insecureRedirect", "文件下载不允许从 HTTPS 重定向到 HTTP")
    requireWebBookFileHeaders(request.headers)
    request.explicitCookie?.let { requireWebBookFileHeaders(mapOf("Cookie" to it)) }
    val sameOrigin = current.sameWebBookFileOrigin(origin) && target.sameWebBookFileOrigin(origin)
    // An allowlist also excludes private, nonstandard source headers on a foreign origin.
    val publicHeaders = setOf("user-agent", "accept", "accept-language", "accept-encoding", "cache-control", "pragma", "range", "if-range", "content-type")
    val headers = request.headers.filterKeys { name ->
        !name.equals("Cookie", ignoreCase = true) && !name.equals("CookieJar", ignoreCase = true) &&
            !name.equals("proxy", ignoreCase = true) && (sameOrigin || name.lowercase() in publicHeaders)
    }.toMutableMap()
    // Never use request.headers[Cookie]: it includes jar cookies scoped to the previous path.
    val jarCookie = cookies.requestCookieHeader(targetUrl)
    jarCookie?.let { requireWebBookFileHeaders(mapOf("Cookie" to it)) }
    mergeRequestCookieHeader(jarCookie, request.explicitCookie.takeIf { sameOrigin })?.let { headers["Cookie"] = it }
    requireWebBookFileHeaders(headers)
    return headers.toMap()
}

internal suspend fun recordWebBookFileCookies(
    cookies: CookieRepository,
    request: WebBookFileRequest,
    responseUrl: String,
    setCookieHeaders: List<String>,
) {
    val current = webBookFileUrl(request.url)
    val response = webBookFileUrl(responseUrl)
    requireWebBookFile(current.sameWebBookFileOrigin(response) && current.encodedPath == response.encodedPath,
        "unexpectedResponseUrl", "请逐跳处理文件响应，不能回同步隐式重定向后的 Cookie")
    requireWebBookFile(setCookieHeaders.size <= WebBookFileLimits.SET_COOKIES, "cookiesTooLarge", "文件响应 Cookie 数量超过限制")
    var bytes = 0
    setCookieHeaders.forEach {
        requireWebBookFileHeaders(mapOf("Set-Cookie" to it))
        bytes += it.encodeToByteArray().size
        requireWebBookFile(bytes <= WebBookFileLimits.HEADER_BYTES, "cookiesTooLarge", "文件响应 Cookie 总大小超过限制")
    }
    val fields = mapOf("Set-Cookie" to setCookieHeaders).withSplitSetCookieHeaders().getValue("Set-Cookie")
    requireWebBookFile(fields.size <= WebBookFileLimits.SET_COOKIES, "cookiesTooLarge", "文件响应 Cookie 数量超过限制")
    val now = currentTimeMillis()
    val parsed = fields.mapNotNull { parseStoredSetCookie(responseUrl, it, now) }
    if (parsed.isNotEmpty()) cookies.saveCookies(responseUrl, parsed, persistCookies = request.enabledCookieJar)
}
