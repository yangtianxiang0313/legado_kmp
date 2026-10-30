package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.SharedCapabilityException
import io.legado.kmp.shared.network.SourceResponse

class LegacyJsHostSurface(
    val connect: suspend (urlRule: String, headerJson: String?) -> SourceResponse,
    val connectAll: suspend (urlRules: List<String>, headerJson: String?) -> List<SourceResponse> = { urlRules, headerJson ->
        connectLegacyJsRequestBatch(urlRules, headerJson, connect)
    },
    val rawConnect: suspend (urlRule: String, headerJson: String?) -> SourceResponse = connect,
    val login: suspend () -> Unit = {},
    val getResponse: suspend (headerJson: String?) -> SourceResponse? = { null },
    val getStrResponse: suspend (jsStr: String?, sourceRegex: String?, headerJson: String?) -> String? = { _, _, headerJson ->
        getResponse(headerJson)?.bodyText
    },
    val getSourceHeaders: suspend (includeLoginHeader: Boolean) -> Map<String, String> = { emptyMap() },
    val getString: suspend (rule: String) -> String? = { null },
    val getStringList: suspend (rule: String) -> List<String>? = { null },
    val getElementPayload: suspend (rule: String) -> Map<String, Any?>? = { null },
    val legacyGet: suspend (key: String) -> String = { "" },
    val legacyPut: suspend (key: String, value: String?) -> Unit = { _, _ -> },
    val legacyDelete: suspend (key: String) -> Unit = {},
    val setContent: suspend (content: Any?, baseUrl: String?) -> Unit = { _, _ -> },
    val setBaseUrl: suspend (baseUrl: String?) -> Unit = {},
    val reGetBook: suspend () -> Map<String, Any?>? = {
        error("只能在 preUpdateJs 中调用")
    },
    val refreshTocUrl: suspend () -> Map<String, Any?>? = {
        error("只能在 preUpdateJs 中调用")
    },
    val startBrowser: suspend (url: String, title: String) -> Unit = { _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "browser_verification_unsupported",
            message = "Legacy JS browser verification flows are not implemented in shared execution yet"
        )
    },
    val startBrowserAwait: suspend (
        url: String,
        title: String,
        refetchAfterSuccess: Boolean,
    ) -> SourceResponse = { _, _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "browser_verification_unsupported",
            message = "Legacy JS browser verification flows are not implemented in shared execution yet"
        )
    },
    val getVerificationCode: suspend (imageUrl: String) -> String = {
        throw SharedCapabilityException(
            capabilityGapKey = "browser_verification_unsupported",
            message = "Legacy JS verification code flows are not implemented in shared execution yet"
        )
    },
    val openUrl: suspend (url: String, mimeType: String?) -> Unit = { _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "open_url_unsupported",
            message = "Legacy JS openUrl flows are not implemented in shared execution yet"
        )
    },
    val showToast: suspend (message: String, long: Boolean) -> Unit = { _, _ -> },
    val webViewUserAgent: suspend () -> String = { DEFAULT_WEB_VIEW_USER_AGENT },
    val androidId: suspend () -> String = { "shared-android-id" },
    val webView: suspend (html: String?, url: String?, js: String?) -> String? = { _, _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "webview_request_unsupported",
            message = "Legacy JS webView requests are not implemented in shared execution yet"
        )
    },
    val webViewGetSource: suspend (
        html: String?,
        url: String?,
        js: String?,
        sourceRegex: String,
    ) -> String? = { _, _, _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "webview_request_unsupported",
            message = "Legacy JS webView source capture is not implemented in shared execution yet"
        )
    },
    val webViewGetOverrideUrl: suspend (
        html: String?,
        url: String?,
        js: String?,
        overrideUrlRegex: String,
    ) -> String? = { _, _, _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "webview_request_unsupported",
            message = "Legacy JS webView override URL capture is not implemented in shared execution yet"
        )
    },
    val fetchRemoteScript: suspend (url: String) -> String? = { null },
    val readLocalScript: suspend (path: String) -> String? = { null },
    val downloadFile: suspend (urlRule: String) -> String = {
        throw SharedCapabilityException(
            capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
            message = "Legacy JS local file helpers are not implemented in shared execution yet"
        )
    },
    val writeHexFile: suspend (contentHex: String, urlRule: String) -> String = { _, _ ->
        throw SharedCapabilityException(
            capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
            message = "Legacy JS local file helpers are not implemented in shared execution yet"
        )
    },
    val readFile: suspend (path: String) -> ByteArray? = { null },
    val readTextFile: suspend (path: String, charsetName: String?) -> String = { path, _ ->
        readLocalScript(path) ?: ""
    },
    val deleteFile: suspend (path: String) -> Boolean = { false },
    val getTextInFolder: suspend (path: String) -> String = { "" },
    val getZipByteArrayContent: suspend (url: String, path: String) -> ByteArray? = { _, _ -> null },
    val getZipStringContent: suspend (url: String, path: String, charsetName: String?) -> String = { _, _, _ -> "" },
    val rssSearchBook: (suspend (key: String) -> Unit)? = null,
    val rssAddBook: (suspend (bookUrl: String) -> Unit)? = null,
) {

    suspend fun cacheFile(url: String): String {
        return fetchRemoteScript(url)
            ?: throw SharedCapabilityException(
                capabilityGapKey = "legacy_js_remote_script_unsupported",
                message = "Legacy JS remote script loading is not implemented in shared execution yet"
            )
    }

    suspend fun importScript(path: String): String {
        return if (path.startsWith("http", ignoreCase = true)) {
            cacheFile(path)
        } else {
            readLocalScript(path)
                ?.takeIf { it.isNotBlank() }
                ?: throw SharedCapabilityException(
                    capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
                    message = "Legacy JS local file helpers are not implemented in shared execution yet"
                )
        }
    }

    companion object {
        fun unsupported(): LegacyJsHostSurface {
            return LegacyJsHostSurface(
                connect = { _, _ ->
                    throw SharedCapabilityException(
                        capabilityGapKey = "legacy_js_network_helpers_unsupported",
                        message = "Legacy JS network helpers are not implemented in shared execution yet"
                    )
                }
            )
        }

        fun fromCallbacks(
            source: BookSource? = null,
            connect: suspend (urlRule: String, headerJson: String?) -> SourceResponse,
            connectAll: suspend (urlRules: List<String>, headerJson: String?) -> List<SourceResponse> = { urlRules, headerJson ->
                connectLegacyJsRequestBatch(urlRules, headerJson, connect)
            },
            rawConnect: suspend (urlRule: String, headerJson: String?) -> SourceResponse = connect,
            login: suspend () -> Unit = {},
            getResponse: suspend (headerJson: String?) -> SourceResponse? = { null },
            getStrResponse: suspend (jsStr: String?, sourceRegex: String?, headerJson: String?) -> String? = { _, _, headerJson ->
                getResponse(headerJson)?.bodyText
            },
            getSourceHeaders: suspend (includeLoginHeader: Boolean) -> Map<String, String> = { emptyMap() },
            getString: suspend (rule: String) -> String? = { null },
            getStringList: suspend (rule: String) -> List<String>? = { null },
            getElementPayload: suspend (rule: String) -> Map<String, Any?>? = { null },
            legacyGet: suspend (key: String) -> String = { "" },
            legacyPut: suspend (key: String, value: String?) -> Unit = { _, _ -> },
            legacyDelete: suspend (key: String) -> Unit = {},
            setContent: suspend (content: Any?, baseUrl: String?) -> Unit = { _, _ -> },
            setBaseUrl: suspend (baseUrl: String?) -> Unit = {},
            reGetBook: suspend () -> Map<String, Any?>? = {
                error("只能在 preUpdateJs 中调用")
            },
            refreshTocUrl: suspend () -> Map<String, Any?>? = {
                error("只能在 preUpdateJs 中调用")
            },
            startBrowser: suspend (url: String, title: String) -> Unit = { _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "browser_verification_unsupported",
                    message = "Legacy JS browser verification flows are not implemented in shared execution yet"
                )
            },
            startBrowserAwait: suspend (
                url: String,
                title: String,
                refetchAfterSuccess: Boolean,
            ) -> SourceResponse = { _, _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "browser_verification_unsupported",
                    message = "Legacy JS browser verification flows are not implemented in shared execution yet"
                )
            },
            getVerificationCode: suspend (imageUrl: String) -> String = {
                throw SharedCapabilityException(
                    capabilityGapKey = "browser_verification_unsupported",
                    message = "Legacy JS verification code flows are not implemented in shared execution yet"
                )
            },
            openUrl: suspend (url: String, mimeType: String?) -> Unit = { _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "open_url_unsupported",
                    message = "Legacy JS openUrl flows are not implemented in shared execution yet"
                )
            },
            showToast: suspend (message: String, long: Boolean) -> Unit = { _, _ -> },
            webViewUserAgent: suspend () -> String = { DEFAULT_WEB_VIEW_USER_AGENT },
            androidId: suspend () -> String = {
                source?.bookSourceUrl?.hashCode()?.toUInt()?.toString(16) ?: "shared-android-id"
            },
            webView: suspend (html: String?, url: String?, js: String?) -> String? = { _, _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "webview_request_unsupported",
                    message = "Legacy JS webView requests are not implemented in shared execution yet"
                )
            },
            webViewGetSource: suspend (
                html: String?,
                url: String?,
                js: String?,
                sourceRegex: String,
            ) -> String? = { _, _, _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "webview_request_unsupported",
                    message = "Legacy JS webView source capture is not implemented in shared execution yet"
                )
            },
            webViewGetOverrideUrl: suspend (
                html: String?,
                url: String?,
                js: String?,
                overrideUrlRegex: String,
            ) -> String? = { _, _, _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "webview_request_unsupported",
                    message = "Legacy JS webView override URL capture is not implemented in shared execution yet"
                )
            },
            fetchRemoteScript: suspend (url: String) -> String? = { url ->
                connect(url, null).bodyText
            },
            readLocalScript: suspend (path: String) -> String? = { null },
            downloadFile: suspend (urlRule: String) -> String = {
                throw SharedCapabilityException(
                    capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
                    message = "Legacy JS local file helpers are not implemented in shared execution yet"
                )
            },
            writeHexFile: suspend (contentHex: String, urlRule: String) -> String = { _, _ ->
                throw SharedCapabilityException(
                    capabilityGapKey = "legacy_js_local_file_helpers_unsupported",
                    message = "Legacy JS local file helpers are not implemented in shared execution yet"
                )
            },
            readFile: suspend (path: String) -> ByteArray? = { null },
            readTextFile: suspend (path: String, charsetName: String?) -> String = { path, _ ->
                readLocalScript(path) ?: ""
            },
            deleteFile: suspend (path: String) -> Boolean = { false },
            getTextInFolder: suspend (path: String) -> String = { "" },
            getZipByteArrayContent: suspend (url: String, path: String) -> ByteArray? = { _, _ -> null },
            getZipStringContent: suspend (url: String, path: String, charsetName: String?) -> String = { _, _, _ -> "" },
            rssSearchBook: (suspend (key: String) -> Unit)? = null,
            rssAddBook: (suspend (bookUrl: String) -> Unit)? = null,
        ): LegacyJsHostSurface {
            return LegacyJsHostSurface(
                connect = connect,
                connectAll = connectAll,
                rawConnect = rawConnect,
                login = login,
                getResponse = getResponse,
                getStrResponse = getStrResponse,
                getSourceHeaders = getSourceHeaders,
                getString = getString,
                getStringList = getStringList,
                getElementPayload = getElementPayload,
                legacyGet = legacyGet,
                legacyPut = legacyPut,
                legacyDelete = legacyDelete,
                setContent = setContent,
                setBaseUrl = setBaseUrl,
                reGetBook = reGetBook,
                refreshTocUrl = refreshTocUrl,
                startBrowser = startBrowser,
                startBrowserAwait = startBrowserAwait,
                getVerificationCode = getVerificationCode,
                openUrl = openUrl,
                showToast = showToast,
                webViewUserAgent = webViewUserAgent,
                androidId = androidId,
                webView = webView,
                webViewGetSource = webViewGetSource,
                webViewGetOverrideUrl = webViewGetOverrideUrl,
                fetchRemoteScript = fetchRemoteScript,
                readLocalScript = readLocalScript,
                downloadFile = downloadFile,
                writeHexFile = writeHexFile,
                readFile = readFile,
                readTextFile = readTextFile,
                deleteFile = deleteFile,
                getTextInFolder = getTextInFolder,
                getZipByteArrayContent = getZipByteArrayContent,
                getZipStringContent = getZipStringContent,
                rssSearchBook = rssSearchBook,
                rssAddBook = rssAddBook,
            )
        }

        internal const val DEFAULT_WEB_VIEW_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14; K) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/133.0.0.0 Mobile Safari/537.36"
    }
}
