package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource

data class SourceExecutionContext(
    val request: BuiltUrl,
    val requestConfig: HttpRequestConfig,
    val source: BookSource? = null,
    val defaultHeaders: Map<String, String> = emptyMap(),
    val ruleData: Map<String, Any?> = emptyMap(),
    val chapter: BookChapter? = null,
    val cookieDomain: String,
    val proxy: String? = null
)

interface WebViewRequestExecutor {
    suspend fun executeText(context: SourceExecutionContext): HttpResponse
}

interface ProxyRequestExecutor {
    suspend fun executeText(context: SourceExecutionContext, proxy: String): HttpResponse
}

interface MediaRequestExecutor {
    suspend fun execute(context: SourceExecutionContext): HttpResponse
}

data class MultipartUploadRequest(
    val url: String,
    val multipartType: String? = null,
    val parts: List<MultipartUploadPart>,
)

interface UploadRequestExecutor {
    suspend fun execute(context: SourceExecutionContext, upload: MultipartUploadRequest): HttpResponse
}

data class LegacyWebViewRequest(
    val html: String? = null,
    val url: String? = null,
    val javaScript: String? = null,
    val webViewDelayTime: Long = 0L,
    val headers: Map<String, String> = emptyMap(),
    val proxy: String? = null,
    val sourceRegex: String? = null,
    val overrideUrlRegex: String? = null,
    val source: BookSource? = null,
)

interface InteractiveSourceCapability {
    suspend fun executeWebView(request: LegacyWebViewRequest): String?

    suspend fun executeProxy(context: SourceExecutionContext, proxy: String): HttpResponse

    suspend fun executeMedia(context: SourceExecutionContext): HttpResponse

    suspend fun startBrowser(source: BookSource?, url: String, title: String)

    suspend fun startBrowserAwait(
        source: BookSource?,
        url: String,
        title: String,
        refetchAfterSuccess: Boolean,
    ): SourceResponse

    suspend fun getVerificationCode(source: BookSource?, imageUrl: String): String

    suspend fun openUrl(source: BookSource?, url: String, mimeType: String?)

    suspend fun showToast(source: BookSource?, message: String, long: Boolean)
}

internal fun encodeMediaBodyAsHex(response: HttpResponse): HttpResponse {
    val hexBody = response.body.encodeHexString()
    return response.copy(
        bodyText = hexBody,
        errorBodyText = response.errorBodyText ?: response.bodyText.takeIf { !response.isSuccessful }
    )
}

internal fun ByteArray.encodeHexString(): String {
    if (isEmpty()) return ""
    val chars = CharArray(size * 2)
    forEachIndexed { index, byte ->
        val value = byte.toInt() and 0xff
        chars[index * 2] = HEX_DIGITS[value ushr 4]
        chars[index * 2 + 1] = HEX_DIGITS[value and 0x0f]
    }
    return chars.concatToString()
}

private val HEX_DIGITS = "0123456789abcdef".toCharArray()
