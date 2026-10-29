package io.legado.kmp.shared.scripting

import com.dokar.quickjs.binding.define
import com.dokar.quickjs.binding.function
import com.dokar.quickjs.binding.toJsObject
import com.dokar.quickjs.quickJs
import io.legado.kmp.shared.analyze.LEGACY_DOM_INPUT_DESCRIPTORS_BINDING
import io.legado.kmp.shared.analyze.LEGACY_HTML_RESULT_KIND_BINDING
import io.legado.kmp.shared.analyze.LEGACY_JSON_INPUT_DESCRIPTORS_BINDING
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.SharedCapabilityException
import io.legado.kmp.shared.network.SourceResponse
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.util.ChineseConverter
import io.legado.kmp.shared.util.md5Hex
import io.legado.kmp.shared.util.toNumChapter
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.IO
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.datetime.TimeZone
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.coroutines.ContinuationInterceptor
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

private const val LEGACY_NETWORK_SCRIPT_TIMEOUT_MS = 30_000L

class LegacySourceJsRuntime(
    private val sourceStateStore: SourceStateStore? = null,
    private val executionTimeoutMs: Long = LEGACY_NETWORK_SCRIPT_TIMEOUT_MS,
    private val cookieRepository: io.legado.kmp.shared.domain.repository.CookieRepository? = null,
) : SourceJsRuntime {

    private val scriptCache = LegacySourceScriptCache()
    private val compiledExecution = LegacyCompiledExecution()
    private val librarySupport = LegacySourceJsLibrarySupport(sourceStateStore)
    private val sourceSnapshotCache = LegacySourceSnapshotCache()

    internal suspend fun executePrimitiveRule(
        script: String,
        source: BookSource,
        variables: Map<String, Any?>,
    ): JsResult? = executeLegacyPrimitiveRule(script, source, variables, executionTimeoutMs) {
        sourceSnapshotCache.code(source)
    }

    /**
     * Remove cached scope/script for a given jsLib.
     * Aligned with legado SharedJsScope.remove(jsLib).
     */
    fun removeScope(jsLib: String?) {
        if (jsLib.isNullOrBlank()) return
        val key = jsLib.trim().md5Hex()
        scriptCache.removeLibrary(key)
        compiledExecution.removeLibrary(key)
    }

    /**
     * Clear all cached scopes.
     * Aligned with legado SharedJsScope.scopeMap eviction.
     */
    fun clearScopes() {
        scriptCache.clear()
        compiledExecution.clear()
        sourceSnapshotCache.clear()
        LegacyCompiledShim.clear()
    }

    override
    suspend fun execute(
        script: String,
        source: BookSource?,
        variables: Map<String, Any?>,
        connect: suspend (urlRule: String, headerJson: String?) -> SourceResponse,
        rawConnect: suspend (urlRule: String, headerJson: String?) -> SourceResponse,
        login: suspend () -> Unit,
        getResponse: suspend (headerJson: String?) -> SourceResponse?,
        getStrResponse: suspend (jsStr: String?, sourceRegex: String?, headerJson: String?) -> String?,
        getSourceHeaders: suspend (includeLoginHeader: Boolean) -> Map<String, String>,
        getString: suspend (rule: String) -> String?,
        getStringList: suspend (rule: String) -> List<String>?,
        getElementPayload: suspend (rule: String) -> Map<String, Any?>?,
        setContent: suspend (content: Any?, baseUrl: String?) -> Unit,
        setBaseUrl: suspend (baseUrl: String?) -> Unit,
        startBrowser: suspend (url: String, title: String) -> Unit,
        startBrowserAwait: suspend (url: String, title: String, refetchAfterSuccess: Boolean) -> SourceResponse,
        getVerificationCode: suspend (imageUrl: String) -> String,
        openUrl: suspend (url: String, mimeType: String?) -> Unit,
        webViewUserAgent: suspend () -> String,
        androidId: suspend () -> String,
        webView: suspend (html: String?, url: String?, js: String?) -> String?,
        webViewGetSource: suspend (html: String?, url: String?, js: String?, sourceRegex: String) -> String?,
        webViewGetOverrideUrl: suspend (html: String?, url: String?, js: String?, overrideUrlRegex: String) -> String?,
        readLocalScript: suspend (path: String) -> String?,
        host: LegacyJsHostSurface,
    ): JsResult = withContext(Dispatchers.IO) {
        // QuickJS schedules jobs, not synchronous evaluation; keep hostCall off caller callback queues.
        try {
            withTimeout(executionTimeoutMs) {
                val executionContext = currentCoroutineContext()
                fun <T> hostCall(block: suspend CoroutineScope.() -> T): T =
                    runBlocking(executionContext.minusKey(ContinuationInterceptor)) {
                        ensureActive()
                        block()
                    }

                val effectiveHost = LegacyJsHostSurface.fromCallbacks(
                    source = source,
                    connect = connect,
                    connectAll = host.connectAll,
                    rawConnect = rawConnect,
                    login = login,
                    getResponse = getResponse,
                    getStrResponse = getStrResponse,
                    getSourceHeaders = getSourceHeaders,
                    getString = getString,
                    getStringList = getStringList,
                    getElementPayload = getElementPayload,
                    legacyGet = host.legacyGet,
                    legacyPut = host.legacyPut,
                    legacyDelete = host.legacyDelete,
                    setContent = setContent,
                    setBaseUrl = setBaseUrl,
                    reGetBook = host.reGetBook,
                    refreshTocUrl = host.refreshTocUrl,
                    startBrowser = startBrowser,
                    startBrowserAwait = startBrowserAwait,
                    getVerificationCode = getVerificationCode,
                    openUrl = openUrl,
                    showToast = host.showToast,
                    webViewUserAgent = webViewUserAgent,
                    androidId = androidId,
                    webView = webView,
                    webViewGetSource = webViewGetSource,
                    webViewGetOverrideUrl = webViewGetOverrideUrl,
                    fetchRemoteScript = host.fetchRemoteScript,
                    readLocalScript = readLocalScript,
                    downloadFile = host.downloadFile,
                    writeHexFile = host.writeHexFile,
                    readFile = host.readFile,
                    readTextFile = host.readTextFile,
                    deleteFile = host.deleteFile,
                    getTextInFolder = host.getTextInFolder,
                    getZipByteArrayContent = host.getZipByteArrayContent,
                    getZipStringContent = host.getZipStringContent,
                    rssSearchBook = host.rssSearchBook,
                    rssAddBook = host.rssAddBook,
                )
                quickJs(Dispatchers.Default) {
                    val sourceKey = source?.bookSourceUrl
                    define("source") {
                        function("getLoginHeader") { _ ->
                            sourceKey?.let { hostCall { sourceStateStore?.getLoginHeader(it) } }
                        }
                        function("putLoginHeader") { args ->
                            val value = args.firstOrNull()?.toString()
                            if (!sourceKey.isNullOrBlank() && value != null) {
                                hostCall { sourceStateStore?.putLoginHeader(sourceKey, value) }
                            }
                            null
                        }
                        function("getLoginInfo") { _ ->
                            sourceKey?.let { hostCall { sourceStateStore?.getLoginInfo(it) } }
                        }
                        function("getLoginInfoMap") { _ ->
                            sourceKey?.let {
                                hostCall { sourceStateStore?.getLoginInfoMap(it) }?.toJsObject()
                            }
                        }
                        function("putLoginInfo") { args ->
                            val value = args.firstOrNull()?.toString()
                            if (sourceKey.isNullOrBlank() || value == null) {
                                false
                            } else {
                                hostCall { sourceStateStore?.putLoginInfo(sourceKey, value) } == true
                            }
                        }
                        function("removeLoginInfo") { _ ->
                            if (!sourceKey.isNullOrBlank()) {
                                hostCall { sourceStateStore?.removeLoginInfo(sourceKey) }
                            }
                            null
                        }
                        function("getVariable") { args ->
                            val key = args.firstOrNull()?.toString()?.takeIf { it.isNotBlank() }
                            if (sourceKey.isNullOrBlank()) {
                                ""
                            } else if (key == null) {
                                hostCall { sourceStateStore?.getSourceVariable(sourceKey) } ?: ""
                            } else {
                                hostCall { sourceStateStore?.getSourceVariableMap(sourceKey)?.get(key) } ?: ""
                            }
                        }
                        function("getVariableMap") { _ ->
                            sourceKey?.let {
                                hostCall { sourceStateStore?.getSourceVariableMap(it) }?.toJsObject()
                            }
                        }
                        function("setVariable") { args ->
                            val first = args.firstOrNull()?.toString()
                            val value = args.getOrNull(1)?.toString()
                            if (!sourceKey.isNullOrBlank()) {
                                if (args.size >= 2 && !first.isNullOrBlank()) {
                                    hostCall { sourceStateStore?.putSourceVariable(sourceKey, first, value) }
                                } else if (first != null) {
                                    hostCall { sourceStateStore?.setSourceVariable(sourceKey, first) }
                                }
                            }
                            value ?: first
                        }
                        function("removeLoginHeader") { _ ->
                            if (!sourceKey.isNullOrBlank()) {
                                hostCall { sourceStateStore?.removeLoginHeader(sourceKey) }
                            }
                            null
                        }
                        function("put") { args ->
                            val key = args.firstOrNull()?.toString().orEmpty()
                            val value = args.getOrNull(1)
                            if (!sourceKey.isNullOrBlank() && key.isNotBlank()) {
                                hostCall {
                                    sourceStateStore?.putStoredValue(sourceKey, key, value?.toString().orEmpty())
                                }
                            }
                            value
                        }
                        function("get") { args ->
                            val key = args.firstOrNull()?.toString().orEmpty()
                            if (sourceKey.isNullOrBlank() || key.isBlank()) {
                                ""
                            } else {
                                hostCall { sourceStateStore?.getStoredValue(sourceKey, key) } ?: ""
                            }
                        }
                        function("login") { _ ->
                            hostCall { effectiveHost.login() }
                            null
                        }
                        function("getHeaderMap") { args ->
                            val includeLoginHeader = args.firstOrNull()?.toString()?.toBooleanStrictOrNull() == true
                            hostCall {
                                effectiveHost.getSourceHeaders(includeLoginHeader).toJsObject()
                            }
                        }
                        function("getLoginHeaderMap") { _ ->
                            sourceKey?.let {
                                hostCall { sourceStateStore?.getLoginHeaderMap(it) }?.toJsObject()
                            }
                        }
                        function("getKey") { _ ->
                            sourceKey
                        }
                        function("getTag") { _ ->
                            source?.bookSourceName
                        }
                        function("getBookSourceUrl") { _ ->
                            sourceKey
                        }
                        function("getBookSourceComment") { _ ->
                            source?.bookSourceComment
                        }
                    }
                    function("__legacyGet") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (key.isBlank()) {
                            ""
                        } else {
                            hostCall { effectiveHost.legacyGet(key) }
                        }
                    }
                    function("__legacyPut") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        val value = args.getOrNull(1)
                        if (key.isNotBlank()) {
                            hostCall { effectiveHost.legacyPut(key, value?.toString()) }
                        }
                        value
                    }
                    function("__legacyDelete") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (key.isNotBlank()) {
                            hostCall { effectiveHost.legacyDelete(key) }
                        }
                        null
                    }
                    function("__legacyCacheGet") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (sourceKey.isNullOrBlank() || key.isBlank()) {
                            ""
                        } else {
                            hostCall { sourceStateStore?.getStoredValue(sourceKey, "__cache__$key") } ?: ""
                        }
                    }
                    function("__legacyCachePut") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        val value = args.getOrNull(1)
                        val saveTimeSeconds = args.getOrNull(2)
                            ?.toString()
                            ?.toIntOrNull()
                            ?: 0
                        if (!sourceKey.isNullOrBlank() && key.isNotBlank()) {
                            hostCall {
                                sourceStateStore?.putStoredValue(
                                    sourceKey,
                                    "__cache__$key",
                                    value?.toString(),
                                    saveTimeSeconds = saveTimeSeconds
                                )
                            }
                        }
                        value
                    }
                    function("__legacyCacheRemove") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (!sourceKey.isNullOrBlank() && key.isNotBlank()) {
                            hostCall {
                                sourceStateStore?.removeStoredValue(sourceKey, "__cache__$key")
                                sourceStateStore?.removeStoredValue(sourceKey, "__cache_file__$key")
                            }
                        }
                        if (key.isNotBlank()) {
                            legacyMemoryCache.remove(key)
                        }
                        null
                    }
                    function("__legacyCacheFileGet") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (sourceKey.isNullOrBlank() || key.isBlank()) {
                            ""
                        } else {
                            hostCall { sourceStateStore?.getStoredValue(sourceKey, "__cache_file__$key") } ?: ""
                        }
                    }
                    function("__legacyCacheFilePut") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        val value = args.getOrNull(1)
                        val saveTimeSeconds = args.getOrNull(2)
                            ?.toString()
                            ?.toIntOrNull()
                            ?: 0
                        if (!sourceKey.isNullOrBlank() && key.isNotBlank()) {
                            hostCall {
                                sourceStateStore?.putStoredValue(
                                    sourceKey,
                                    "__cache_file__$key",
                                    value?.toString(),
                                    saveTimeSeconds = saveTimeSeconds
                                )
                            }
                        }
                        value
                    }
                    function("__legacyCacheMemoryGet") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (key.isBlank()) {
                            null
                        } else {
                            legacyMemoryCache[key]
                        }
                    }
                    function("__legacyCacheMemoryPut") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        val value = args.getOrNull(1)
                        if (key.isNotBlank()) {
                            legacyMemoryCache[key] = value
                        }
                        value
                    }
                    function("__legacyCacheMemoryRemove") { args ->
                        val key = args.firstOrNull()?.toString().orEmpty()
                        if (key.isNotBlank()) {
                            legacyMemoryCache.remove(key)
                        }
                        null
                    }
                    bindLegacyCryptoHost(json)
                    bindLegacyFontHost(
                        connect = { urlRule, headerJson -> hostCall { effectiveHost.connect(urlRule, headerJson) } },
                        readFile = { path -> hostCall { effectiveHost.readFile(path) } },
                    )
                    function("__legacyUnsupportedCapability") { args ->
                        val capabilityGapKey = args.firstOrNull()?.toString()
                            ?.takeUnless { it.isNullOrBlank() }
                            ?: "legacy_js_host_helper_unsupported"
                        val message = args.getOrNull(1)?.toString()
                            ?.takeUnless { it.isBlank() }
                            ?: "Legacy JS host helper is not implemented in shared runtime"
                        throw SharedCapabilityException(capabilityGapKey, message)
                    }
                    function("__legacyConnect") { args ->
                        val urlRule = args.firstOrNull()?.toString().orEmpty()
                        val headerJson = args.getOrNull(1)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.connect(urlRule, headerJson).toLegacyJsMap().toJsObject()
                        }
                    }
                    function("__legacyConnectAll") { args ->
                        val headerJson = args.lastOrNull()?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        val urlRules = args.dropLast(1)
                            .mapNotNull { it?.toString()?.takeUnless(String::isBlank) }
                        hostCall {
                            json.encodeToString(
                                effectiveHost.connectAll(urlRules, headerJson).map { response ->
                                    response.toLegacyJsMap().toJsonElement()
                                }
                            )
                        }
                    }
                    function("__legacyConnectRaw") { args ->
                        val urlRule = args.firstOrNull()?.toString().orEmpty()
                        val headerJson = args.getOrNull(1)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.rawConnect(urlRule, headerJson).toLegacyJsMap().toJsObject()
                        }
                    }
                    function("__legacyPost") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val body = args.getOrNull(1)?.toString().orEmpty()
                        val headerJson = args.getOrNull(2)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        val postUrl = buildString {
                            append(url)
                            append(",{\"method\":\"POST\"")
                            append(",\"rawBody\":true")
                            append(",\"body\":")
                            append(json.encodeToString(body))
                            if (headerJson != null) {
                                append(",\"headers\":")
                                append(headerJson)
                            }
                            append("}")
                        }
                        hostCall {
                            effectiveHost.rawConnect(postUrl, headerJson).toLegacyJsMap().toJsObject()
                        }
                    }
                    function("__legacyGetResponse") { args ->
                        val headerJson = args.firstOrNull()?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.getResponse(headerJson)?.toLegacyJsMap()?.toJsObject()
                        }
                    }
                    function("__legacyGetStrResponse") { args ->
                        val jsStr = args.getOrNull(0)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        val sourceRegex = args.getOrNull(1)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        val headerJson = args.getOrNull(2)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.getStrResponse(jsStr, sourceRegex, headerJson).orEmpty()
                        }
                    }
                    function("__legacyRuleGetString") { args ->
                        val rule = args.firstOrNull()?.toString().orEmpty()
                        if (rule.isBlank()) {
                            null
                        } else {
                            hostCall { effectiveHost.getString(rule) }
                        }
                    }
                    function("__legacyRuleGetStringList") { args ->
                        val rule = args.firstOrNull()?.toString().orEmpty()
                        if (rule.isBlank()) {
                            null
                        } else {
                            hostCall { effectiveHost.getStringList(rule) }?.let(json::encodeToString)
                        }
                    }
                    function("__legacyRuleGetElementPayload") { args ->
                        val rule = args.firstOrNull()?.toString().orEmpty()
                        if (rule.isBlank()) {
                            null
                        } else {
                            hostCall { effectiveHost.getElementPayload(rule) }?.let { payload ->
                                json.encodeToString(payload.toJsonElement())
                            }
                        }
                    }
                    function("__legacyRuleSetContent") { args ->
                        val content = args.firstOrNull()?.toString().orEmpty()
                        val baseUrl = args.getOrNull(1)?.toString()?.takeUnless {
                            it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.setContent(content, baseUrl)
                        }
                        null
                    }
                    function("__legacyRuleSetDomContent") { args ->
                        val baseUrl = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        hostCall { effectiveHost.setContent(legacyJsDomContent(args.firstOrNull()), baseUrl) }
                        null
                    }
                    function("__legacyRuleSetBaseUrl") { args ->
                        val baseUrl = args.firstOrNull()?.toString()?.takeUnless {
                            it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.setBaseUrl(baseUrl)
                        }
                        null
                    }
                    function("__legacyReGetBook") { _ ->
                        hostCall {
                            effectiveHost.reGetBook()?.toJsObject()
                        }
                    }
                    function("__legacyRefreshTocUrl") { _ ->
                        hostCall {
                            effectiveHost.refreshTocUrl()?.toJsObject()
                        }
                    }
                    function("__legacyHtmlSelect") { args ->
                        val html = args.firstOrNull()?.toString().orEmpty()
                        val selector = args.getOrNull(1)?.toString().orEmpty()
                        json.encodeToString(legacyHtmlSelect(html, selector).toJsonElement())
                    }
                    function("__legacyDomParse") { args ->
                        val html = args.firstOrNull()?.toString().orEmpty()
                        val baseUri = args.getOrNull(1)?.toString().orEmpty()
                        json.encodeToString(legacyJsDomParse(html, baseUri).toJsonElement())
                    }
                    function("__legacyDomSelect") { args ->
                        val payload = args.firstOrNull()?.toString().orEmpty()
                        val selector = args.getOrNull(1)?.toString().orEmpty()
                        json.encodeToString(legacyJsDomSelect(payload, selector).toJsonElement())
                    }
                    function("__legacyDomAttribute") { args ->
                        legacyJsDomAttribute(
                            args.firstOrNull()?.toString().orEmpty(),
                            args.getOrNull(1)?.toString().orEmpty(),
                        )
                    }
                    function("__legacyStartBrowser") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val title = args.getOrNull(1)?.toString().orEmpty()
                        hostCall {
                            effectiveHost.startBrowser(url, title)
                        }
                        null
                    }
                    function("__legacyStartBrowserAwait") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val title = args.getOrNull(1)?.toString().orEmpty()
                        val refetchAfterSuccess = args.getOrNull(2)?.toString()?.toBooleanStrictOrNull() ?: true
                        hostCall {
                            effectiveHost.startBrowserAwait(url, title, refetchAfterSuccess).toLegacyJsMap().toJsObject()
                        }
                    }
                    function("__legacyGetVerificationCode") { args ->
                        val imageUrl = args.firstOrNull()?.toString().orEmpty()
                        hostCall {
                            effectiveHost.getVerificationCode(imageUrl)
                        }
                    }
                    function("__legacyOpenUrl") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val mimeType = args.getOrNull(1)
                            ?.toString()
                            ?.takeUnless { it == "undefined" || it == "null" || it.isBlank() }
                        require(url.length < 64 * 1024) { "openUrl parameter url too long" }
                        hostCall {
                            effectiveHost.openUrl(url, mimeType)
                        }
                        null
                    }
                    effectiveHost.rssSearchBook?.let { searchBook ->
                        function("__legacyRssSearchBook") { args ->
                            val key = args.firstOrNull()?.toString().orEmpty()
                            hostCall { searchBook(key) }
                            null
                        }
                    }
                    effectiveHost.rssAddBook?.let { addBook ->
                        function("__legacyRssAddBook") { args ->
                            val bookUrl = args.firstOrNull()?.toString().orEmpty()
                            hostCall { addBook(bookUrl) }
                            null
                        }
                    }
                    function("__legacyToast") { args ->
                        val message = args.firstOrNull()?.toString() ?: "null"
                        val long = args.getOrNull(1)?.toString()?.toBooleanStrictOrNull() ?: false
                        hostCall {
                            effectiveHost.showToast(message, long)
                        }
                        null
                    }
                    function("__legacyAndroidId") { _ ->
                        hostCall {
                            effectiveHost.androidId()
                        }
                    }
                    function("__legacyGetWebViewUA") { _ ->
                        hostCall {
                            effectiveHost.webViewUserAgent()
                        }
                    }
                    function("__legacyCacheFile") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val saveTimeSeconds = args.getOrNull(1)?.toString()?.toIntOrNull() ?: 0
                        hostCall {
                            librarySupport.loadRemoteScript(sourceKey, url, effectiveHost, saveTimeSeconds)
                        }
                    }
                    function("__legacyImportScript") { args ->
                        val path = args.firstOrNull()?.toString().orEmpty()
                        hostCall {
                            if (path.startsWith("http", ignoreCase = true)) {
                                librarySupport.loadRemoteScript(sourceKey, path, effectiveHost)
                            } else {
                                effectiveHost.importScript(path)
                            }
                        }
                    }
                    function("__legacyDownloadFile") { args ->
                        val first = args.firstOrNull()?.toString().orEmpty()
                        val second = args.getOrNull(1)?.toString()?.takeUnless {
                            it == "undefined" || it == "null"
                        }
                        hostCall {
                            if (second == null) {
                                effectiveHost.downloadFile(first)
                            } else {
                                effectiveHost.writeHexFile(first, second)
                            }
                        }
                    }
                    function("__legacyReadFile") { args ->
                        val path = args.firstOrNull()?.toString().orEmpty()
                        hostCall {
                            effectiveHost.readFile(path)
                        }
                    }
                    function("__legacyReadTxtFile") { args ->
                        val path = args.firstOrNull()?.toString().orEmpty()
                        val charsetName = args.getOrNull(1)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.readTextFile(path, charsetName)
                        }
                    }
                    function("__legacyDeleteFile") { args ->
                        val path = args.firstOrNull()?.toString().orEmpty()
                        hostCall {
                            effectiveHost.deleteFile(path)
                        }
                    }
                    function("__legacyGetTxtInFolder") { args ->
                        val path = args.firstOrNull()?.toString().orEmpty()
                        hostCall {
                            effectiveHost.getTextInFolder(path)
                        }
                    }
                    function("__legacyGetZipByteArrayContent") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val path = args.getOrNull(1)?.toString().orEmpty()
                        hostCall {
                            effectiveHost.getZipByteArrayContent(url, path)
                        }
                    }
                    function("__legacyGetZipStringContent") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val path = args.getOrNull(1)?.toString().orEmpty()
                        val charsetName = args.getOrNull(2)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        }
                        hostCall {
                            effectiveHost.getZipStringContent(url, path, charsetName)
                        }
                    }
                    function("__legacyWebView") { args ->
                        val html = args.firstOrNull()?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val url = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val js = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        hostCall {
                            effectiveHost.webView(html, url, js)
                        }
                    }
                    function("__legacyWebViewGetSource") { args ->
                        val html = args.firstOrNull()?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val url = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val js = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val sourceRegex = args.getOrNull(3)?.toString().orEmpty()
                        hostCall {
                            effectiveHost.webViewGetSource(html, url, js, sourceRegex)
                        }
                    }
                    function("__legacyWebViewGetOverrideUrl") { args ->
                        val html = args.firstOrNull()?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val url = args.getOrNull(1)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val js = args.getOrNull(2)?.toString()?.takeUnless { it == "undefined" || it == "null" }
                        val overrideUrlRegex = args.getOrNull(3)?.toString().orEmpty()
                        hostCall {
                            effectiveHost.webViewGetOverrideUrl(html, url, js, overrideUrlRegex)
                        }
                    }
                    function("__legacySourceGetHeaderMap") { args ->
                        val includeLoginHeader = args.firstOrNull()?.toString()?.toBooleanStrictOrNull() == true
                        hostCall {
                            effectiveHost.getSourceHeaders(includeLoginHeader).toJsObject()
                        }
                    }
                    function("__legacySourceGetLoginHeaderMap") { _ ->
                        sourceKey?.let {
                            hostCall { sourceStateStore?.getLoginHeaderMap(it) }?.toJsObject()
                        }
                    }
                    function("__legacySourceGetLoginInfoMap") { _ ->
                        sourceKey?.let {
                            hostCall { sourceStateStore?.getLoginInfoMap(it) }?.toJsObject()
                        }
                    }
                    function("__legacySourceGetVariableMap") { _ ->
                        sourceKey?.let {
                            hostCall { sourceStateStore?.getSourceVariableMap(it) }?.toJsObject()
                        }
                    }
                    function("__legacyTimeFormat") { args ->
                        val ts = args.firstOrNull()?.toString()?.toDoubleOrNull()?.toLong() ?: 0L
                        formatTimestamp(ts, TimeZone.currentSystemDefault())
                    }
                    function("__legacyTimeFormatUTC") { args ->
                        val ts = args.firstOrNull()?.toString()?.toDoubleOrNull()?.toLong() ?: 0L
                        val pattern = args.getOrNull(1)?.toString()?.takeUnless {
                            it.isBlank() || it == "undefined" || it == "null"
                        } ?: DEFAULT_LEGACY_DATE_PATTERN
                        val shiftMillis = args.getOrNull(2)?.toString()?.toLongOrNull() ?: 0L
                        formatTimestamp(ts + shiftMillis, TimeZone.UTC, pattern)
                    }
                    function("__legacyEncodeURI") { args ->
                        val str = args.firstOrNull()?.toString().orEmpty()
                        val charset = args.getOrNull(1)?.toString()?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
                        try {
                            str.legacyUrlEncode(charset ?: "UTF-8")
                        } catch (_: Exception) {
                            ""
                        }
                    }
                    function("__legacyBase64Decode") { args ->
                        val encoded = args.firstOrNull()?.toString().orEmpty()
                        try {
                            @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
                            val decoded = Base64.decode(encoded.normalizedLegacyBase64(args.getOrNull(1).legacyBase64Flags()))
                            val charset = args.getOrNull(1)?.toString()?.takeIf { it.toIntOrNull() == null }
                            if (charset.isNullOrBlank()) {
                                decoded.decodeToString()
                            } else {
                                TextCodec.decode(decoded, charset)
                            }
                        } catch (_: Exception) { "" }
                    }
                    function("__legacyBase64DecodeToByteArray") { args ->
                        val encoded = args.firstOrNull()
                            ?.toString()
                            ?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
                            ?: return@function null
                        try {
                            @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
                            Base64.decode(encoded.normalizedLegacyBase64(args.getOrNull(1).legacyBase64Flags()))
                        } catch (_: Exception) {
                            null
                        }
                    }
                    function("__legacyBase64Encode") { args ->
                        val plain = args.firstOrNull()?.toString().orEmpty()
                        @OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
                        Base64.encode(plain.encodeToByteArray()).withLegacyBase64Flags(args.getOrNull(1).legacyBase64Flags())
                    }
                    function("__legacyStrToBytes") { args ->
                        val text = args.firstOrNull()?.toString().orEmpty()
                        val charset = args.getOrNull(1)?.toString()?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
                        if (charset == null) {
                            text.encodeToByteArray()
                        } else {
                            TextCodec.encode(text, charset)
                        }
                    }
                    function("__legacyBytesToStr") { args ->
                        val bytesJson = args.firstOrNull()?.toString().orEmpty()
                        val charset = args.getOrNull(1)?.toString()?.takeUnless { it.isBlank() || it == "undefined" || it == "null" }
                        val bytes = bytesJson.toLegacyByteArray()
                        if (charset == null) {
                            bytes.decodeToString()
                        } else {
                            TextCodec.decode(bytes, charset)
                        }
                    }
                    function("__legacyT2s") { args ->
                        ChineseConverter.t2s(args.firstOrNull()?.toString().orEmpty())
                    }
                    function("__legacyS2t") { args ->
                        ChineseConverter.s2t(args.firstOrNull()?.toString().orEmpty())
                    }
                    function("__legacyToNumChapter") { args ->
                        toNumChapter(args.firstOrNull()?.toString().orEmpty())
                    }
                    function("__legacyHexDecodeToString") { args ->
                        val hexStr = args.firstOrNull()?.toString().orEmpty()
                        try {
                            hexStr.decodeLegacyHexBytes().decodeToString()
                        } catch (_: Exception) { "" }
                    }
                    function("__legacyHexDecodeToByteArray") { args ->
                        val hexStr = args.firstOrNull()?.toString().orEmpty()
                        try {
                            hexStr.decodeLegacyHexBytes()
                        } catch (_: Exception) {
                            ByteArray(0)
                        }
                    }
                    function("__legacyLog") { args ->
                        val message = args.firstOrNull()?.toString().orEmpty()
                        // RSS navigation scripts can contain private article URLs or action payloads.
                        if (effectiveHost.rssSearchBook == null && effectiveHost.rssAddBook == null) {
                            io.legado.kmp.shared.facade.AppLogStore.record(
                                level = "D",
                                tag = sourceKey ?: "JS",
                                message = message,
                            )
                        }
                        message
                    }
                    function("__legacyRemoveCookie") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        if (url.isNotBlank() && cookieRepository != null) {
                            val domain = io.legado.kmp.shared.network.extractCookieDomain(url)
                            hostCall {
                                cookieRepository.delete(domain)
                            }
                            io.legado.kmp.shared.network.SessionCookieStore.remove(domain)
                        }
                        null
                    }
                    function("__legacyGetCookie") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        if (url.isBlank() || cookieRepository == null) {
                            ""
                        } else {
                            hostCall { cookieRepository.requestCookieHeader(url) } ?: ""
                        }
                    }
                    function("__legacySetCookie") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val cookie = args.getOrNull(1)?.toString().orEmpty()
                        if (url.isNotBlank() && cookieRepository != null) {
                            val domain = io.legado.kmp.shared.network.extractCookieDomain(url)
                            hostCall {
                                cookieRepository.insert(
                                    io.legado.kmp.shared.model.Cookie(domain, cookie)
                                )
                            }
                        }
                        null
                    }
                    function("__legacyReplaceCookie") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val cookie = args.getOrNull(1)?.toString().orEmpty()
                        if (url.isNotBlank() && cookie.isNotBlank() && cookieRepository != null) {
                            val domain = io.legado.kmp.shared.network.extractCookieDomain(url)
                            val oldCookie = hostCall { cookieRepository.get(domain)?.cookie }
                            val merged = io.legado.kmp.shared.network.mergeCookieStrings(oldCookie, cookie)
                            if (!merged.isNullOrBlank()) {
                                hostCall {
                                    cookieRepository.insert(
                                        io.legado.kmp.shared.model.Cookie(domain, merged)
                                    )
                                }
                            }
                        }
                        null
                    }
                    function("__legacyCookieGetKey") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val key = args.getOrNull(1)?.toString().orEmpty()
                        if (url.isBlank() || key.isBlank() || cookieRepository == null) {
                            ""
                        } else {
                            val cookie = hostCall { cookieRepository.requestCookieHeader(url) }.orEmpty()
                            cookie.split(';').firstNotNullOfOrNull { part ->
                                val separator = part.indexOf('=')
                                if (separator > 0 && part.substring(0, separator).trim() == key) part.substring(separator + 1) else null
                            } ?: ""
                        }
                    }
                    function("__legacyHexEncodeToString") { args ->
                        val utf8 = args.firstOrNull()?.toString().orEmpty()
                        try {
                            utf8.encodeToByteArray().joinToString("") {
                                (it.toInt() and 0xff).toString(16).padStart(2, '0')
                            }
                        } catch (_: Exception) { "" }
                    }
                    function("__legacyRandomUUID") { _ ->
                        randomUUID()
                    }
                    function("__legacyHtmlFormat") { args ->
                        val html = args.firstOrNull()?.toString().orEmpty()
                        legacyHtmlFormat(html)
                    }
                    function("__legacyHttpRequestUrl") { args ->
                        legacyHttpRequestUrl(args.firstOrNull()?.toString().orEmpty())
                    }
                    function("__legacyToURL") { args ->
                        val url = args.firstOrNull()?.toString().orEmpty()
                        val baseUrl = args.getOrNull(1)
                            ?.toString()
                            ?.takeUnless { it == "undefined" || it == "null" || it.isBlank() }
                        json.encodeToString(legacyJsUrl(url, baseUrl).toJsonElement())
                    }

                    val cachedNormalized = scriptCache.normalized(script)
                    // Evaluate jsLib after capturing the private DOM exporter, not inside the trusted preamble.
                    val jsLibTrimmed = source?.jsLib?.trim()?.takeIf { it.isNotBlank() }
                    val preambleKey = jsLibTrimmed?.md5Hex() ?: ""
                    val library = scriptCache.library(preambleKey) {
                        jsLibTrimmed?.let { librarySupport.load(it, sourceKey, effectiveHost) }.orEmpty()
                    }
                    val inputs = buildString {
                        append(buildVariablesCode(variables))
                        appendLine()
                        append(sourceSnapshotCache.code(source))
                        appendLine()
                    }
                    val execution = buildLegacyJsDomExecution(library, cachedNormalized)
                    // Private-name inputs can shadow hoisted shim declarations in the original
                    // single script. Keep that rare collision path in the same eval.
                    val shadowsShim = variables.keys.any {
                        it.startsWith("__legacy") && it !in SHIM_INPUT_METADATA
                    }
                    if (shadowsShim) {
                        legacyJsDomResult(evaluate<Any?>(inputs + LEGACY_SHIM + "\n\n" + execution))
                    } else {
                        evaluate<Any?>(inputs + "void 0;")
                        LegacyCompiledShim.install(this)
                        legacyJsDomResult(compiledExecution.evaluate(this, execution, preambleKey))
                    }
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Exception) {
            JsResult.JsError(
                message = error.message ?: "Unknown error",
                exception = error,
                stackTrace = error.stackTraceToString()
            )
        }
    }

    private companion object {
        private val SHIM_INPUT_METADATA = setOf(
            LEGACY_HTML_RESULT_KIND_BINDING,
            LEGACY_DOM_INPUT_DESCRIPTORS_BINDING,
            LEGACY_JSON_INPUT_DESCRIPTORS_BINDING,
        )
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
        private val legacyMemoryCache = LinkedHashMap<String, Any?>()
    }
}

internal fun SourceResponse.toLegacyJsMap(): Map<String, Any?> {
    return linkedMapOf(
        "url" to url,
        "body" to bodyText,
        "statusCode" to statusCode,
        "code" to statusCode,
        "statusText" to statusText,
        "message" to statusText,
        "headers" to headers.toJsObject(),
        "allHeaders" to allHeaders.toJsObject(),
        "errorBody" to errorBodyText,
        "isSuccessful" to (statusCode in 200..299)
    )
}
