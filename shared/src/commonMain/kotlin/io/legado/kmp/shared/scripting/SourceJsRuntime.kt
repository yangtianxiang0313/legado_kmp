package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.SharedCapabilityException
import io.legado.kmp.shared.network.SourceResponse

interface SourceJsRuntime {
    suspend fun execute(
        script: String,
        source: BookSource? = null,
        variables: Map<String, Any?> = emptyMap(),
        connect: suspend (urlRule: String, headerJson: String?) -> SourceResponse,
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
        setContent: suspend (content: Any?, baseUrl: String?) -> Unit = { _, _ -> },
        setBaseUrl: suspend (baseUrl: String?) -> Unit = {},
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
        webViewUserAgent: suspend () -> String = { LegacyJsHostSurface.DEFAULT_WEB_VIEW_USER_AGENT },
        androidId: suspend () -> String = { "shared-android-id" },
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
        readLocalScript: suspend (path: String) -> String? = { null },
        host: LegacyJsHostSurface = LegacyJsHostSurface.fromCallbacks(
            source = source,
            connect = connect,
            rawConnect = rawConnect,
            login = login,
            getResponse = getResponse,
            getStrResponse = getStrResponse,
            getSourceHeaders = getSourceHeaders,
            getString = getString,
            getStringList = getStringList,
            getElementPayload = getElementPayload,
            setContent = setContent,
            setBaseUrl = setBaseUrl,
            startBrowser = startBrowser,
            startBrowserAwait = startBrowserAwait,
            getVerificationCode = getVerificationCode,
            openUrl = openUrl,
            webViewUserAgent = webViewUserAgent,
            androidId = androidId,
            webView = webView,
            webViewGetSource = webViewGetSource,
            webViewGetOverrideUrl = webViewGetOverrideUrl,
            readLocalScript = readLocalScript,
        )
    ): JsResult
}
