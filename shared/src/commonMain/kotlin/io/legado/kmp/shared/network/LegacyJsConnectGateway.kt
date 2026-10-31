package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.preferences.AppRuntimeConfig

interface LegacyJsConnectGateway {
    suspend fun defaultUserAgent(): String = AppRuntimeConfig.DEFAULT_USER_AGENT

    /** A direct Jsoup connection has its own headers and in-memory cookie session. */
    suspend fun executeJsoupForLegacyJs(requestJson: String): String {
        throw SharedCapabilityException("legacy_js_jsoup_network_unsupported", "当前网关不支持 Jsoup 网络请求")
    }

    /**
     * Resolves the final media HTTP intent without sending it. AnalyzeUrl/header JS retain their existing semantics.
     * This is NOT executeText: native media responses do not run source.loginCheckJs or write cookies back here.
     * Book-audio callers must have checked the chapter response; HTTP TTS rejects response scripts in its facade.
     */
    suspend fun prepareMediaForLegacyJs(
        urlRule: String,
        source: BookSource,
        headerJson: String? = null,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): PreparedMediaRequest {
        throw UnsupportedMediaRequestException("当前网关不支持原生媒体请求准备")
    }

    suspend fun executeForLegacyJs(
        urlRule: String,
        source: BookSource,
        headerJson: String? = null,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null
    ): SourceResponse

    /**
     * Book-resource intent, separate from raw java.get/head/post connections.
     * A null source must not inherit stored source state or cookies. Gateways must opt in to that path.
     */
    suspend fun executeBookResource(
        urlRule: String,
        source: BookSource?,
        baseUrl: String = source?.bookSourceUrl.orEmpty(),
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): SourceResponse {
        if (source == null) {
            throw SharedCapabilityException(
                capabilityGapKey = "book_resource_without_source_unsupported",
                message = "当前网关不支持无书源的书籍资源请求",
            )
        }
        return executeForLegacyJs(
            urlRule = urlRule,
            source = source,
            baseUrl = baseUrl,
            ruleData = ruleData,
            chapter = chapter,
        )
    }

    suspend fun executeForLegacyJsRaw(
        urlRule: String,
        source: BookSource,
        headerJson: String? = null,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null
    ): SourceResponse = executeForLegacyJs(
        urlRule = urlRule,
        source = source,
        headerJson = headerJson,
        baseUrl = baseUrl,
        ruleData = ruleData,
        chapter = chapter
    )

    suspend fun startBrowserForLegacyJs(
        source: BookSource,
        url: String,
        title: String,
    ) {
        throw SharedCapabilityException(
            capabilityGapKey = "browser_verification_unsupported",
            message = "Legacy JS browser verification flows are not implemented in shared execution yet"
        )
    }

    suspend fun startBrowserAwaitForLegacyJs(
        source: BookSource,
        url: String,
        title: String,
        refetchAfterSuccess: Boolean,
    ): SourceResponse {
        throw SharedCapabilityException(
            capabilityGapKey = "browser_verification_unsupported",
            message = "Legacy JS browser verification flows are not implemented in shared execution yet"
        )
    }

    suspend fun getVerificationCodeForLegacyJs(
        source: BookSource,
        imageUrl: String,
    ): String {
        throw SharedCapabilityException(
            capabilityGapKey = "browser_verification_unsupported",
            message = "Legacy JS verification code flows are not implemented in shared execution yet"
        )
    }

    suspend fun openUrlForLegacyJs(
        source: BookSource,
        url: String,
        mimeType: String?,
    ) {
        throw SharedCapabilityException(
            capabilityGapKey = "open_url_unsupported",
            message = "Legacy JS openUrl flows are not implemented in shared execution yet"
        )
    }

    suspend fun showToastForLegacyJs(
        source: BookSource,
        message: String,
        long: Boolean,
    ) {
        throw SharedCapabilityException(
            capabilityGapKey = "toast_unsupported",
            message = "Legacy JS toast flows are not implemented in shared execution yet"
        )
    }

    suspend fun executeWebViewForLegacyJs(
        source: BookSource,
        url: String?,
        html: String?,
        javaScript: String?,
        sourceRegex: String? = null,
        overrideUrlRegex: String? = null,
    ): String? {
        throw SharedCapabilityException(
            capabilityGapKey = "webview_request_unsupported",
            message = "Legacy JS webView requests are not implemented in shared execution yet"
        )
    }

    suspend fun readLocalScriptForLegacyJs(path: String): String? = null

    suspend fun downloadFileForLegacyJs(
        source: BookSource,
        urlRule: String,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): String {
        throw SharedCapabilityException(
            capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
            message = "Legacy JS local file helpers are not implemented in shared execution yet"
        )
    }

    suspend fun writeHexFileForLegacyJs(
        source: BookSource,
        contentHex: String,
        urlRule: String,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): String {
        throw SharedCapabilityException(
            capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
            message = "Legacy JS local file helpers are not implemented in shared execution yet"
        )
    }

    suspend fun readFileForLegacyJs(path: String): ByteArray? = null

    suspend fun readTextFileForLegacyJs(path: String, charsetName: String?): String = readLocalScriptForLegacyJs(path) ?: ""

    suspend fun deleteFileForLegacyJs(path: String): Boolean = false

    suspend fun getTextInFolderForLegacyJs(path: String): String = ""

    suspend fun getZipByteArrayContentForLegacyJs(
        source: BookSource,
        url: String,
        path: String,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): ByteArray? = null

    suspend fun getZipStringContentForLegacyJs(
        source: BookSource,
        url: String,
        path: String,
        charsetName: String?,
        baseUrl: String = source.bookSourceUrl,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): String = ""
}
