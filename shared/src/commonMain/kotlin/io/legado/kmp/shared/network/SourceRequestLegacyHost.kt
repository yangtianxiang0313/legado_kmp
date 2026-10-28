package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.scripting.LegacyJsHostSurface

internal fun createSourceRequestLegacyHost(
    source: BookSource,
    request: BuiltUrl,
    ruleData: Map<String, Any?>,
    chapter: BookChapter?,
    gateway: LegacyJsConnectGateway,
    login: suspend () -> Unit,
    getSourceHeaders: suspend (Boolean) -> Map<String, String>,
    getStrResponse: suspend (String?, String?, String?) -> String,
    webView: suspend (String?, String?, String?, String?, String?) -> String?,
): LegacyJsHostSurface {
    return LegacyJsHostSurface.fromCallbacks(
        source = source,
        connect = { urlRule, headerJson ->
            gateway.executeForLegacyJs(
                urlRule = urlRule,
                source = source,
                headerJson = headerJson,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter
            )
        },
        rawConnect = { urlRule, headerJson ->
            gateway.executeForLegacyJsRaw(
                urlRule = urlRule,
                source = source,
                headerJson = headerJson,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter
            )
        },
        login = login,
        getResponse = { headerJson ->
            gateway.executeForLegacyJs(
                urlRule = request.ruleUrl,
                source = source,
                headerJson = headerJson,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter
            )
        },
        getStrResponse = getStrResponse,
        getSourceHeaders = getSourceHeaders,
        startBrowser = { url, title ->
            gateway.startBrowserForLegacyJs(source, url, title)
        },
        startBrowserAwait = { url, title, refetchAfterSuccess ->
            gateway.startBrowserAwaitForLegacyJs(source, url, title, refetchAfterSuccess)
        },
        getVerificationCode = { imageUrl ->
            gateway.getVerificationCodeForLegacyJs(source, imageUrl)
        },
        openUrl = { url, mimeType ->
            gateway.openUrlForLegacyJs(source, url, mimeType)
        },
        showToast = { message, long ->
            gateway.showToastForLegacyJs(source, message, long)
        },
        webView = { html, url, js ->
            webView(html, url, js, null, null)
        },
        webViewGetSource = { html, url, js, sourceRegex ->
            webView(html, url, js, sourceRegex, null)
        },
        webViewGetOverrideUrl = { html, url, js, overrideUrlRegex ->
            webView(html, url, js, null, overrideUrlRegex)
        },
        readLocalScript = { path ->
            gateway.readLocalScriptForLegacyJs(path)
        },
        downloadFile = { urlRule ->
            gateway.downloadFileForLegacyJs(
                source = source,
                urlRule = urlRule,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter
            )
        },
        writeHexFile = { contentHex, urlRule ->
            gateway.writeHexFileForLegacyJs(
                source = source,
                contentHex = contentHex,
                urlRule = urlRule,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter
            )
        },
        readFile = { path ->
            gateway.readFileForLegacyJs(path)
        },
        readTextFile = { path, charsetName ->
            gateway.readTextFileForLegacyJs(path, charsetName)
        },
        deleteFile = { path ->
            gateway.deleteFileForLegacyJs(path)
        },
        getTextInFolder = { path ->
            gateway.getTextInFolderForLegacyJs(path)
        },
        getZipByteArrayContent = { url, path ->
            gateway.getZipByteArrayContentForLegacyJs(
                source = source,
                url = url,
                path = path,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter,
            )
        },
        getZipStringContent = { url, path, charsetName ->
            gateway.getZipStringContentForLegacyJs(
                source = source,
                url = url,
                path = path,
                charsetName = charsetName,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter,
            )
        },
    )
}
