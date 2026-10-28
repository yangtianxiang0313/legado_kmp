package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor

class LegacyImageDecoder(
    private val sourceJsRuntime: SourceJsRuntime = LegacySourceJsRuntime(),
    private val jsExecutor: JsExecutor = JsExecutor(),
) {

    suspend fun decode(
        src: String,
        bytes: ByteArray,
        isCover: Boolean,
        source: BookSource?,
        book: Book? = null,
    ): ByteArray? {
        val ruleJs = resolveRuleJs(source, isCover)
        if (ruleJs.isNullOrBlank()) return bytes
        val jsResult = sourceJsRuntime.execute(
            script = buildImageDecodeScript(ruleJs),
            source = source,
            variables = linkedMapOf(
                "src" to src,
                "result" to bytes.map { it.toInt() },
                "book" to book?.toLegacyJsBook()
            ),
            connect = { _, _ -> unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持网络请求") },
            rawConnect = { _, _ -> unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持网络请求") },
            login = {},
            getResponse = { null },
            getSourceHeaders = { emptyMap() },
            getString = { null },
            getStringList = { null },
            getElementPayload = { null },
            setContent = { _, _ -> },
            setBaseUrl = {},
            startBrowser = { _, _ -> },
            startBrowserAwait = { _, _, _ -> unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持浏览器验证") },
            getVerificationCode = { unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持验证码") },
            webViewUserAgent = { "" },
            androidId = { "" },
            webView = { _, _, _ -> unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持 webView") },
            webViewGetSource = { _, _, _, _ -> unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持 webView") },
            webViewGetOverrideUrl = { _, _, _, _ -> unsupportedImageDecodeOperation(jsExecutor, "图片解密不支持 webView") },
            readLocalScript = { null },
            host = LegacyJsHostSurface.unsupported(),
        )
        return jsResult.toImageDecodedBytesOrNull()
    }

    private fun resolveRuleJs(source: BookSource?, isCover: Boolean): String? {
        if (source == null) return null
        return if (isCover) {
            source.coverDecodeJs
        } else {
            source.ruleContent?.imageDecode
        }
    }
}

private fun unsupportedImageDecodeOperation(jsExecutor: JsExecutor, message: String): Nothing {
    throw jsExecutor.runtimeCapabilityFailure() ?: IllegalStateException(message)
}

private fun Book.toLegacyJsBook(): Map<String, Any?> {
    return linkedMapOf(
        "bookUrl" to bookUrl,
        "tocUrl" to tocUrl,
        "name" to name,
        "author" to author,
        "kind" to kind,
        "coverUrl" to displayCoverUrl,
        "intro" to displayIntro,
        "wordCount" to wordCount,
        "latestChapterTitle" to latestChapterTitle,
        "origin" to origin,
        "originName" to originName,
        "originOrder" to originOrder,
        "type" to type,
        "totalChapterNum" to totalChapterNum,
        "variable" to variableMap
    )
}
