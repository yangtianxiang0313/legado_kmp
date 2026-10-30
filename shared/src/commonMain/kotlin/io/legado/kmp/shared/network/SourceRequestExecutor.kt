package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.scripting.LegacyJsHostSurface
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

data class SourceRequestResult(
    val response: HttpResponse
) {
    val bodyText: String
        get() = response.bodyText

    /**
     * Raw byte array body.
     * Aligned with legado's AnalyzeUrl.getByteArrayAwait() and
     * getInputStreamAwait(). In KMP there is no InputStream; this
     * ByteArray covers the same use-case (binary content: images,
     * fonts, audio streams, etc.). Callers that need streaming
     * semantics should wrap with a platform-specific InputStream
     * adapter if needed.
     */
    val bodyBytes: ByteArray
        get() = response.body

    val finalUrl: String
        get() = response.url.ifBlank { "" }
}

class LoginCheckFailedException(
    message: String
) : Exception(message)

class UnsupportedWebViewRequestException(
    message: String
) : SharedCapabilityException("webview_request_unsupported", message)

class UnsupportedProxyRequestException(
    message: String
) : SharedCapabilityException("proxy_request_unsupported", message)

class UnsupportedMediaRequestException(
    message: String
) : SharedCapabilityException("media_request_unsupported", message)

class UnsupportedUploadRequestException(
    message: String
) : SharedCapabilityException("upload_request_unsupported", message)

class SourceRequestExecutor(
    private val httpUseCase: HttpUseCase,
    private val cookieRepository: CookieRepository,
    private val jsExecutor: JsExecutor = JsExecutor.Default,
    private val sourceStateStore: SourceStateStore? = null,
    private val headerResolver: SourceHeaderResolver = SourceHeaderResolver(jsExecutor),
    private val sourceJsRuntime: SourceJsRuntime? = null,
    private val interactiveCapability: InteractiveSourceCapability? = null,
    private val webViewRequestExecutor: WebViewRequestExecutor? = null,
    private val proxyRequestExecutor: ProxyRequestExecutor? = null,
    private val mediaRequestExecutor: MediaRequestExecutor? = null,
    private val uploadRequestExecutor: UploadRequestExecutor? = null,
    private val fileAccess: FileAccess? = null,
    private val appFilesDirectory: AppFilesDirectory? = null,
) : LegacyJsConnectGateway {
    private val transport = SourceRequestTransport(
        httpUseCase, cookieRepository, interactiveCapability, webViewRequestExecutor,
        proxyRequestExecutor, mediaRequestExecutor, uploadRequestExecutor, ::defaultUserAgent,
    )
    private val legacyFiles = SourceRequestLegacyFiles(
        fileAccess = fileAccess,
        appFilesDirectory = appFilesDirectory,
        prepareRequest = ::prepareLegacyRequest,
        executeRequest = { request, source, ruleData, chapter ->
            executeTextInternal(
                request = request,
                source = source,
                defaultHeaders = buildDefaultHeaders(source, request),
                ruleData = ruleData,
                chapter = chapter,
                applyLoginCheck = false,
            ).response
        },
    )

    override suspend fun defaultUserAgent(): String = headerResolver.defaultUserAgent()

    /** Builds one file-download intent, without probing or sending its final HTTP request. */
    internal suspend fun prepareFileRequest(
        urlRule: String,
        source: BookSource,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        onVariablesWritten: ((Map<String, String>) -> Unit)? = null,
    ): SourceExecutionContext {
        val request = prepareLegacyRequest(
            source, urlRule, baseUrl, ruleData, null, seedVariables = ruleData, onVariablesWritten = onVariablesWritten,
        )
        val headers = LinkedHashMap(resolveSourceHeaders(source, request, true, ruleData)).apply {
            applyCompatibilityDefaults(request.baseUrl.ifBlank { source.bookSourceUrl }, request.url)
        }
        return transport.createContext(request, source, headers, ruleData, null, followRedirects = false)
    }

    override suspend fun prepareMediaForLegacyJs(
        urlRule: String,
        source: BookSource,
        headerJson: String?,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): PreparedMediaRequest {
        val request = prepareLegacyRequest(source, urlRule, baseUrl, ruleData, chapter)
        val declared = headerJson?.let(::parseHeaderJson)
            ?: resolveSourceHeaders(source, request, includeLoginHeader = true)
        val headers = LinkedHashMap(declared).apply {
            if (headerJson == null) applyCompatibilityDefaults(
                request.baseUrl.ifBlank { source.bookSourceUrl }, request.url, includeCacheControl = false,
            )
        }
        val explicitCookie = request.toHttpRequestConfig(headers).headers.entries
            .filter { it.key.equals("Cookie", ignoreCase = true) }.joinToString("; ") { it.value }.ifBlank { null }
        val prepared = transport.prepareMedia(request, source, headers)
        val systemHeaders = setOf("user-agent", "keep-alive", "connection", "cache-control", "accept", "accept-language", "referer", "origin")
        // Only inferred browser defaults may be omitted by AVFoundation's own HTTP/HLS loader.
        val allowsSystemAsset = (declared.keys + request.headers.keys).all { it.equals("User-Agent", ignoreCase = true) } &&
            prepared.method == "GET" && prepared.bodyBase64 == null &&
            prepared.headers.keys.all { it.lowercase() in systemHeaders }
        return prepared.copy(
            allowsSystemAsset = allowsSystemAsset,
            resourceContext = MediaResourceContext(source.bookSourceUrl, prepared.url, explicitCookie, source.enabledCookieJar),
        )
    }

    suspend fun executeText(
        request: BuiltUrl,
        source: BookSource? = null,
        defaultHeaders: Map<String, String> = emptyMap(),
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null
    ): Result<SourceRequestResult> = runCatching {
        executeTextInternal(
            request = request,
            source = source,
            defaultHeaders = defaultHeaders,
            ruleData = ruleData,
            chapter = chapter,
            applyLoginCheck = true
        )
    }

    suspend fun executeUpload(
        request: BuiltUrl,
        fileName: String,
        fileData: ByteArray,
        contentType: String,
        source: BookSource? = null,
        defaultHeaders: Map<String, String> = emptyMap(),
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null
    ): Result<SourceRequestResult> = runCatching {
        executeUploadInternal(
            request = request,
            fileName = fileName,
            fileData = fileData,
            contentType = contentType,
            source = source,
            defaultHeaders = defaultHeaders,
            ruleData = ruleData,
            chapter = chapter,
            applyLoginCheck = true
        )
    }

    override suspend fun executeForLegacyJs(
        urlRule: String,
        source: BookSource,
        headerJson: String?,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?
    ): SourceResponse {
        val builtRequest = prepareLegacyRequest(source, urlRule, baseUrl, ruleData, chapter)
        val defaultHeaders = headerJson?.let(::parseHeaderJson) ?: buildDefaultHeaders(source, builtRequest)
        return SourceResponse.fromHttpResponse(
            executeTextInternal(
                request = builtRequest,
                source = source,
                defaultHeaders = defaultHeaders,
                ruleData = ruleData,
                chapter = chapter,
                applyLoginCheck = false,
                followRedirects = true,
                allowRedirectResponse = false
            ).response
        )
    }

    override suspend fun executeForLegacyJsRaw(
        urlRule: String,
        source: BookSource,
        headerJson: String?,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?
    ): SourceResponse {
        val builtRequest = prepareLegacyRequest(source, urlRule, baseUrl, ruleData, chapter)
        val defaultHeaders = headerJson?.let(::parseHeaderJson) ?: buildDefaultHeaders(source, builtRequest)
        return SourceResponse.fromHttpResponse(
            executeTextInternal(
                request = builtRequest,
                source = source,
                defaultHeaders = defaultHeaders,
                ruleData = ruleData,
                chapter = chapter,
                applyLoginCheck = false,
                followRedirects = false,
                allowRedirectResponse = true
            ).response
        )
    }

    override suspend fun startBrowserForLegacyJs(
        source: BookSource,
        url: String,
        title: String,
    ) {
        startBrowser(source, url, title)
    }

    override suspend fun startBrowserAwaitForLegacyJs(
        source: BookSource,
        url: String,
        title: String,
        refetchAfterSuccess: Boolean,
    ): SourceResponse {
        return startBrowserAwait(source, url, title, refetchAfterSuccess)
    }

    override suspend fun getVerificationCodeForLegacyJs(
        source: BookSource,
        imageUrl: String,
    ): String {
        return getVerificationCode(source, imageUrl)
    }

    override suspend fun openUrlForLegacyJs(
        source: BookSource,
        url: String,
        mimeType: String?,
    ) {
        openUrl(source, url, mimeType)
    }

    override suspend fun showToastForLegacyJs(
        source: BookSource,
        message: String,
        long: Boolean,
    ) {
        showToast(source, message, long)
    }

    override suspend fun executeWebViewForLegacyJs(
        source: BookSource,
        url: String?,
        html: String?,
        javaScript: String?,
        sourceRegex: String?,
        overrideUrlRegex: String?,
    ): String? {
        val requestUrl = url?.takeIf { it.isNotBlank() } ?: source.bookSourceUrl
        return executeLegacyWebView(
            source = source,
            request = BuiltUrl(
                ruleUrl = requestUrl,
                url = requestUrl,
                urlNoQuery = requestUrl.substringBefore("?"),
                baseUrl = AnalyzeUrl.getBaseUrl(requestUrl),
                useWebView = true,
                webJs = javaScript,
            ),
            html = html,
            url = url,
            js = javaScript,
            sourceRegex = sourceRegex,
            overrideUrlRegex = overrideUrlRegex,
        )
    }

    override suspend fun readLocalScriptForLegacyJs(path: String): String? = legacyFiles.readLocalScript(path)

    override suspend fun downloadFileForLegacyJs(
        source: BookSource,
        urlRule: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): String = legacyFiles.downloadFile(source, urlRule, baseUrl, ruleData, chapter)

    override suspend fun writeHexFileForLegacyJs(
        source: BookSource,
        contentHex: String,
        urlRule: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): String = legacyFiles.writeHexFile(source, contentHex, urlRule, baseUrl, ruleData, chapter)

    override suspend fun readFileForLegacyJs(path: String): ByteArray? = legacyFiles.readFile(path)

    override suspend fun readTextFileForLegacyJs(path: String, charsetName: String?): String =
        legacyFiles.readTextFile(path, charsetName)

    override suspend fun deleteFileForLegacyJs(path: String): Boolean = legacyFiles.deleteFile(path)

    override suspend fun getTextInFolderForLegacyJs(path: String): String = legacyFiles.getTextInFolder(path)

    override suspend fun getZipByteArrayContentForLegacyJs(
        source: BookSource,
        url: String,
        path: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): ByteArray? = legacyFiles.getZipByteArrayContent(source, url, path, baseUrl, ruleData, chapter)

    override suspend fun getZipStringContentForLegacyJs(
        source: BookSource,
        url: String,
        path: String,
        charsetName: String?,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): String = legacyFiles.getZipStringContent(source, url, path, charsetName, baseUrl, ruleData, chapter)

    private suspend fun prepareLegacyRequest(
        source: BookSource,
        urlRule: String,
        baseUrl: String,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        seedVariables: Map<String, Any?> = emptyMap(),
        onVariablesWritten: ((Map<String, String>) -> Unit)? = null,
    ): BuiltUrl {
        val analyzeUrl = AnalyzeUrl(
            jsExecutor = jsExecutor,
            legacyContext = AnalyzeUrlLegacyContext(
                source = source,
                sourceStateStore = sourceStateStore,
                cookieRepository = cookieRepository,
                gateway = this,
                sourceJsRuntime = sourceJsRuntime,
                ruleData = ruleData,
                chapter = chapter,
            ),
        )
        applySourceVariables(analyzeUrl, source)
        analyzeUrl.setVariables(seedVariables)
        // Simple {{name}} expressions read URL variables before invoking the JS context.
        if (ruleData["speakText"] is String) {
            analyzeUrl.setString("speakText", ruleData["speakText"] as String)
            analyzeUrl.setInt("speakSpeed", (ruleData["speakSpeed"] as? Number)?.toInt())
            (ruleData["text"] as? String)?.let { analyzeUrl.setString("text", it) }
        }
        return analyzeUrl.build(urlRule, baseUrl).also {
            onVariablesWritten?.invoke(analyzeUrl.getWrittenVariables())
        }
    }

    private suspend fun executeTextInternal(
        request: BuiltUrl,
        source: BookSource?,
        defaultHeaders: Map<String, String>,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        applyLoginCheck: Boolean,
        followRedirects: Boolean = true,
        allowRedirectResponse: Boolean = false,
    ): SourceRequestResult {
        val context = transport.createContext(request, source, defaultHeaders, ruleData, chapter, followRedirects)
        if (!request.type.isNullOrBlank()) {
            AnalyzeUrl.getByteArrayIfDataUri(request.urlNoQuery)?.let { bytes ->
                return SourceRequestResult(
                    HttpResponse(
                        statusCode = 200,
                        statusText = "OK",
                        headers = emptyMap(),
                        allHeaders = emptyMap(),
                        body = bytes,
                        bodyText = bytes.encodeHexString(),
                        url = request.url,
                    ),
                )
            }
        }
        return ConcurrentRateLimiter(source).withLimit {
            finalizeResponse(
                response = transport.executeText(context, allowRedirectResponse),
                source = source,
                request = request,
                ruleData = ruleData,
                chapter = chapter,
                cookieDomain = context.cookieDomain,
                applyLoginCheck = applyLoginCheck,
            )
        }
    }

    private suspend fun finalizeResponse(
        response: HttpResponse,
        source: BookSource?,
        request: BuiltUrl,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        cookieDomain: String,
        applyLoginCheck: Boolean
    ): SourceRequestResult {
        val normalizedResponse = patchXmlResponseBody(response)
        if (!applyLoginCheck) {
            return SourceRequestResult(normalizedResponse)
        }
        return applyLoginCheck(
            response = normalizedResponse,
            source = source,
            request = request,
            ruleData = ruleData,
            chapter = chapter,
            cookieDomain = cookieDomain
        )
    }

    private fun patchXmlResponseBody(response: HttpResponse): HttpResponse {
        val contentType = response.findHeader("Content-Type") ?: return response
        val patchedBody = AnalyzeUrl.patchXmlDeclaration(response.bodyText, contentType)
        if (patchedBody == response.bodyText) {
            return response
        }
        return response.copy(
            bodyText = patchedBody,
            body = patchedBody.encodeToByteArray()
        )
    }

    private suspend fun executeUploadInternal(
        request: BuiltUrl,
        fileName: String,
        fileData: ByteArray,
        contentType: String,
        source: BookSource?,
        defaultHeaders: Map<String, String>,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        applyLoginCheck: Boolean,
    ): SourceRequestResult {
        val context = transport.createContext(request, source, defaultHeaders, ruleData, chapter)
        return finalizeResponse(
            response = transport.executeUpload(context, fileName, fileData, contentType),
            source = source,
            request = request,
            ruleData = ruleData,
            chapter = chapter,
            cookieDomain = context.cookieDomain,
            applyLoginCheck = applyLoginCheck,
        )
    }

    private fun createLegacyJsHostSurface(
        source: BookSource,
        request: BuiltUrl,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
    ): LegacyJsHostSurface = createSourceRequestLegacyHost(
        source = source,
        request = request,
        ruleData = ruleData,
        chapter = chapter,
        gateway = this,
        login = { executeLogin(source) },
        getSourceHeaders = { includeLoginHeader -> buildSourceHeaders(source, request, includeLoginHeader) },
        getStrResponse = { jsStr, sourceRegex, headerJson ->
            executeStrResponseForLegacyJs(source, request, ruleData, chapter, jsStr, sourceRegex, headerJson)
        },
        webView = { html, url, js, sourceRegex, overrideUrlRegex ->
            executeLegacyWebView(source, request, html, url, js, sourceRegex, overrideUrlRegex)
        },
    )

    private suspend fun readLegacyLocalScript(path: String): String? = legacyFiles.readLocalScript(path)

    private suspend fun startBrowser(source: BookSource, url: String, title: String) {
        interactiveCapability?.startBrowser(source, url, title)
            ?: throw SharedCapabilityException(
                capabilityGapKey = "browser_verification_unsupported",
                message = "Legacy JS browser verification flows are not implemented in shared execution yet"
            )
    }

    private suspend fun startBrowserAwait(
        source: BookSource,
        url: String,
        title: String,
        refetchAfterSuccess: Boolean
    ): SourceResponse {
        return interactiveCapability?.startBrowserAwait(source, url, title, refetchAfterSuccess)
            ?: throw SharedCapabilityException(
                capabilityGapKey = "browser_verification_unsupported",
                message = "Legacy JS browser verification flows are not implemented in shared execution yet"
            )
    }

    private suspend fun getVerificationCode(source: BookSource, imageUrl: String): String {
        return interactiveCapability?.getVerificationCode(source, imageUrl)
            ?: throw SharedCapabilityException(
                capabilityGapKey = "browser_verification_unsupported",
                message = "Legacy JS verification code flows are not implemented in shared execution yet"
            )
    }

    private suspend fun openUrl(source: BookSource, url: String, mimeType: String?) {
        interactiveCapability?.openUrl(source, url, mimeType)
            ?: throw SharedCapabilityException(
                capabilityGapKey = "open_url_unsupported",
                message = "Legacy JS openUrl flows are not implemented in shared execution yet"
            )
    }

    private suspend fun showToast(source: BookSource, message: String, long: Boolean) {
        interactiveCapability?.showToast(source, message, long)
            ?: throw SharedCapabilityException(
                capabilityGapKey = "toast_unsupported",
                message = "Legacy JS toast flows are not implemented in shared execution yet"
            )
    }

    private suspend fun executeLegacyWebView(
        source: BookSource,
        request: BuiltUrl,
        html: String?,
        url: String?,
        js: String?,
        sourceRegex: String? = null,
        overrideUrlRegex: String? = null
    ): String? {
        return interactiveCapability?.executeWebView(
            LegacyWebViewRequest(
                html = html,
                url = url,
                javaScript = js,
                webViewDelayTime = request.webViewDelayTime,
                headers = buildDefaultHeaders(source, request),
                proxy = extractProxy(request, buildDefaultHeaders(source, request)),
                sourceRegex = sourceRegex,
                overrideUrlRegex = overrideUrlRegex,
                source = source,
            )
        ) ?: throw SharedCapabilityException(
            capabilityGapKey = "webview_request_unsupported",
            message = "Legacy JS webView requests are not implemented in shared execution yet"
        )
    }

    private suspend fun executeStrResponseForLegacyJs(
        source: BookSource,
        request: BuiltUrl,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        jsStr: String?,
        sourceRegex: String?,
        headerJson: String?
    ): String {
        val effectiveJs = request.webJs?.takeIf { it.isNotBlank() }
            ?: jsStr?.takeIf { it.isNotBlank() }
        val effectiveSourceRegex = request.sourceRegex?.takeIf { it.isNotBlank() }
            ?: sourceRegex?.takeIf { it.isNotBlank() }
        if (effectiveJs == null && effectiveSourceRegex == null) {
            return executeForLegacyJs(
                urlRule = request.ruleUrl,
                source = source,
                headerJson = headerJson,
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                ruleData = ruleData,
                chapter = chapter
            ).bodyText
        }
        if (!request.type.isNullOrBlank()) {
            throw UnsupportedWebViewRequestException(
                "java.getStrResponse WebView does not support typed media requests"
            )
        }
        if (effectiveSourceRegex != null && interactiveCapability == null) {
            throw UnsupportedWebViewRequestException(
                "java.getStrResponse sourceRegex WebView requires interactive capability"
            )
        }
        val webViewRequest = request.copy(
            useWebView = true,
            webJs = effectiveJs,
            sourceRegex = effectiveSourceRegex
        )
        val defaultHeaders = headerJson?.let(::parseHeaderJson)
            ?: buildDefaultHeaders(source, webViewRequest)
        return executeTextInternal(
            request = webViewRequest,
            source = source,
            defaultHeaders = defaultHeaders,
            ruleData = ruleData,
            chapter = chapter,
            applyLoginCheck = false
        ).response.bodyText
    }

    private suspend fun applyLoginCheck(
        response: HttpResponse,
        source: BookSource?,
        request: BuiltUrl,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        cookieDomain: String
    ): SourceRequestResult {
        val checkedSource = source ?: return SourceRequestResult(response)
        val checkJs = checkedSource.loginCheckJs?.takeIf { it.isNotBlank() } ?: return SourceRequestResult(response)
        val sourceResponse = SourceResponse.fromHttpResponse(response)
        val requestHeaders = transport.createContext(
            request = request,
            source = checkedSource,
            defaultHeaders = buildDefaultHeaders(checkedSource, request),
            ruleData = ruleData,
            chapter = chapter,
        ).requestConfig.headers
        val host = createLegacyJsHostSurface(
            source = checkedSource,
            request = request,
            ruleData = ruleData,
            chapter = chapter
        )
        val jsResult = legacySourceJsRuntime(sourceJsRuntime, sourceStateStore, cookieRepository).execute(
            script = checkJs,
            source = checkedSource,
            variables = buildLoginVariables(
                response = sourceResponse,
                request = request,
                source = checkedSource,
                ruleData = ruleData,
                chapter = chapter,
                cookieDomain = cookieDomain,
                requestHeaders = requestHeaders
            ),
            connect = host.connect,
            rawConnect = host.rawConnect,
            login = host.login,
            getResponse = host.getResponse,
            getStrResponse = host.getStrResponse,
            getSourceHeaders = host.getSourceHeaders,
            startBrowser = host.startBrowser,
            startBrowserAwait = host.startBrowserAwait,
            readLocalScript = host.readLocalScript,
            host = host
        )
        val result = normalizeLoginCheckResult(jsResult, sourceResponse, checkedSource.bookSourceName.ifBlank { response.url })
        if (!result.passed) {
            throw LoginCheckFailedException("Login check failed for ${checkedSource.bookSourceName.ifBlank { response.url }}")
        }
        return SourceRequestResult((result.response ?: sourceResponse).toHttpResponse())
    }

    private suspend fun buildLoginVariables(
        response: SourceResponse,
        request: BuiltUrl,
        source: BookSource?,
        ruleData: Map<String, Any?>,
        chapter: BookChapter?,
        cookieDomain: String,
        requestHeaders: Map<String, String>
    ): Map<String, Any?> {
        val variables = LinkedHashMap<String, Any?>()
        variables["baseUrl"] = request.baseUrl
        variables["url"] = response.url
        variables["body"] = response.bodyText
        variables["headers"] = response.headers
        variables["statusCode"] = response.statusCode
        variables["status"] = response.statusCode
        variables["statusText"] = response.statusText
        variables["allHeaders"] = response.allHeaders
        variables["cookie"] = cookieRepository.requestCookieHeader(response.url.ifBlank { request.url }).orEmpty()
        variables["headerMap"] = requestHeaders
        variables["result"] = response.toJsMap()
        variables["response"] = response.toJsMap()
        variables["source"] = source?.let {
            mapOf(
                "bookSourceUrl" to it.bookSourceUrl,
                "bookSourceName" to it.bookSourceName,
                "loginUrl" to it.loginUrl,
                "loginCheckJs" to it.loginCheckJs,
                "enabledCookieJar" to it.enabledCookieJar
            )
        }
        source?.let {
            variables["sourceHeaderMap"] = buildSourceHeaders(it, request, includeLoginHeader = false)
            variables["sourceHeaderMapWithLogin"] = buildSourceHeaders(it, request, includeLoginHeader = true)
        }
        variables.putAll(ruleData)
        chapter?.let {
            variables["chapter"] = mapOf(
                "url" to it.url,
                "title" to it.title,
                "bookUrl" to it.bookUrl,
                "index" to it.index,
                "baseUrl" to it.baseUrl,
                "variable" to it.variableMap
            )
        }
        return variables
    }

    private suspend fun buildSourceHeaders(
        source: BookSource,
        request: BuiltUrl,
        includeLoginHeader: Boolean
    ): Map<String, String> {
        return resolveSourceHeaders(
            source = source,
            request = request,
            includeLoginHeader = includeLoginHeader
        )
    }

    internal suspend fun resolveSourceHeaders(
        source: BookSource,
        request: BuiltUrl,
        includeLoginHeader: Boolean,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): Map<String, String> {
        val sourceKey = source.bookSourceUrl
        val sourceVariable = sourceStateStore?.getSourceVariable(sourceKey)
        val sourceVariableMap = sourceStateStore?.getSourceVariableMap(sourceKey).orEmpty()
        val loginHeaderMap = if (includeLoginHeader) {
            sourceStateStore?.getLoginHeaderMap(sourceKey).orEmpty()
        } else {
            emptyMap()
        }
        val variables = linkedMapOf<String, Any?>().apply {
            putAll(ruleData)
            putAll(request.usedVariables)
            put("baseUrl", request.baseUrl)
            put("url", request.url)
            put("sourceVariable", sourceVariable)
            put("sourceVariableMap", sourceVariableMap)
            put(
                "source", mapOf(
                    "bookSourceUrl" to source.bookSourceUrl,
                    "bookSourceName" to source.bookSourceName,
                    "loginUrl" to source.loginUrl,
                    "loginCheckJs" to source.loginCheckJs,
                    "enabledCookieJar" to source.enabledCookieJar
                )
            )
        }
        val headers = resolveLegacySourceHeaderRule(
            source = source,
            request = request,
            variables = variables,
            chapter = chapter,
        ) ?: headerResolver.resolve(
            headerRule = source.header,
            variables = variables
        )
        return LinkedHashMap<String, String>().apply {
            putAllUserAgentAware(headers)
            putAllUserAgentAware(loginHeaderMap)
            putDefaultUserAgent(::defaultUserAgent)
        }
    }

    private suspend fun executeLogin(source: BookSource) {
        val loginUrl = source.loginUrl?.trim().orEmpty()
        if (loginUrl.isBlank()) return
        if (isJsLoginRule(loginUrl)) {
            val loginScript = extractLoginScript(loginUrl)
            val script = buildString {
                appendLine(loginScript)
                appendLine()
                appendLine("if(typeof login=='function'){")
                appendLine("  login.apply(this);")
                appendLine("} else {")
                appendLine("  throw('Function login not implements!!!')")
                appendLine("}")
            }
            val runtime = legacySourceJsRuntime(sourceJsRuntime, sourceStateStore, cookieRepository)
            val loginRequest = BuiltUrl(
                ruleUrl = source.bookSourceUrl,
                url = source.bookSourceUrl,
                urlNoQuery = source.bookSourceUrl.substringBefore("?"),
                baseUrl = source.bookSourceUrl,
            )
            val host = createLegacyJsHostSurface(
                source = source,
                request = loginRequest,
                ruleData = emptyMap(),
                chapter = null
            )
            val result = runtime.execute(
                script = script,
                source = source,
                variables = emptyMap(),
                connect = { urlRule, headerJson ->
                    executeForLegacyJs(
                        urlRule = urlRule,
                        source = source,
                        headerJson = headerJson,
                        baseUrl = source.bookSourceUrl,
                        ruleData = emptyMap(),
                        chapter = null
                    )
                },
                rawConnect = { urlRule, headerJson ->
                    executeForLegacyJsRaw(
                        urlRule = urlRule,
                        source = source,
                        headerJson = headerJson,
                        baseUrl = source.bookSourceUrl,
                        ruleData = emptyMap(),
                        chapter = null
                    )
                },
                readLocalScript = { path ->
                    readLegacyLocalScript(path)
                },
                getStrResponse = host.getStrResponse,
                host = host,
            )
            if (result is JsResult.JsError) {
                val capability = result.exception as? SharedCapabilityException
                if (capability != null) {
                    throw capability
                }
                throw IllegalStateException(result.message, result.exception)
            }
        }
    }

    private fun isJsLoginRule(loginUrl: String): Boolean {
        val trimmed = loginUrl.trim()
        if (trimmed.startsWith("@js:", ignoreCase = true) || trimmed.startsWith("<js>", ignoreCase = true)) {
            return true
        }
        if (trimmed.startsWith("http://", ignoreCase = true) ||
            trimmed.startsWith("https://", ignoreCase = true) ||
            trimmed.startsWith("/", ignoreCase = true)
        ) {
            return false
        }
        return trimmed.contains('\n') ||
            trimmed.contains("function") ||
            trimmed.contains("var ") ||
            trimmed.contains("source.") ||
            trimmed.contains("java.")
    }

    private fun extractLoginScript(loginUrl: String): String {
        val trimmed = loginUrl.trim()
        return when {
            trimmed.startsWith("@js:", ignoreCase = true) -> trimmed.substring(4).trim()
            trimmed.startsWith("<js>", ignoreCase = true) &&
                trimmed.endsWith("</js>", ignoreCase = true) -> {
                trimmed.substring(4, trimmed.length - 5).trim()
            }
            else -> trimmed
        }
    }

    private suspend fun buildDefaultHeaders(
        source: BookSource,
        request: BuiltUrl
    ): Map<String, String> {
        return LinkedHashMap<String, String>().apply {
            putAll(
                resolveSourceHeaders(
                    source = source,
                    request = request,
                    includeLoginHeader = true
                )
            )
            applyCompatibilityDefaults(
                baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                requestUrl = request.url.ifBlank { request.urlNoQuery }
            )
        }
    }

    private fun MutableMap<String, String>.applyCompatibilityDefaults(
        baseUrl: String,
        requestUrl: String,
        includeCacheControl: Boolean = true,
    ) {
        putIfMissing("Keep-Alive", "300")
        putIfMissing("Connection", "Keep-Alive")
        // Native media has its own persistent byte cache; retain explicit source/URL directives only.
        if (includeCacheControl) putIfMissing("Cache-Control", "no-cache")
        putIfMissing("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        putIfMissing("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")

        val referer = normalizeCompatibilityReferer(baseUrl, requestUrl)
        if (!referer.isNullOrBlank()) {
            putIfMissing("Referer", referer)
        }

        val origin = referer?.let(::deriveCompatibleOrigin)
        if (!origin.isNullOrBlank()) {
            putIfMissing("Origin", origin)
        }
    }

    private fun MutableMap<String, String>.putIfMissing(
        key: String,
        value: String
    ) {
        if (keys.none { it.equals(key, ignoreCase = true) }) {
            put(key, value)
        }
    }

    private suspend fun applySourceVariables(
        analyzeUrl: AnalyzeUrl,
        source: BookSource
    ) {
        sourceStateStore?.getSourceVariableMap(source.bookSourceUrl)
            .orEmpty()
            .forEach { (key, value) ->
                analyzeUrl.setString(key, value)
            }
    }

    private suspend fun resolveLegacySourceHeaderRule(
        source: BookSource,
        request: BuiltUrl,
        variables: Map<String, Any?>,
        chapter: BookChapter?,
    ): Map<String, String>? {
        val headerRule = source.header?.trim().orEmpty()
        if (!headerRule.startsWith("@js:", ignoreCase = true) &&
            !headerRule.isLegacyJsBlockRule()
        ) {
            return null
        }
        val script = when {
            headerRule.startsWith("@js:", ignoreCase = true) -> headerRule.substring(4).trim()
            else -> headerRule.extractLegacyJsBlockScript().trim()
        }
        val runtime = legacySourceJsRuntime(sourceJsRuntime, sourceStateStore, cookieRepository)
        val legacyHeaderVariables = linkedMapOf<String, Any?>().apply {
            putAll(variables)
            remove("source")
            if (!containsKey("baseUrl")) {
                put("baseUrl", request.baseUrl.ifBlank { source.bookSourceUrl })
            }
            if (!containsKey("url")) {
                put("url", request.url)
            }
        }
        val host = createLegacyJsHostSurface(
            source = source,
            request = request,
            ruleData = legacyHeaderVariables,
            chapter = chapter
        )
        val jsResult = runtime.execute(
            script = script,
            source = source,
            variables = legacyHeaderVariables,
            connect = { urlRule, headerJson ->
                executeForLegacyJs(
                    urlRule = urlRule,
                    source = source,
                    headerJson = headerJson,
                    baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                    ruleData = legacyHeaderVariables,
                    chapter = chapter
                )
            },
            rawConnect = { urlRule, headerJson ->
                executeForLegacyJsRaw(
                    urlRule = urlRule,
                    source = source,
                    headerJson = headerJson,
                    baseUrl = request.baseUrl.ifBlank { source.bookSourceUrl },
                    ruleData = legacyHeaderVariables,
                    chapter = chapter
                )
            },
            getSourceHeaders = { emptyMap() },
            readLocalScript = { path ->
                readLegacyLocalScript(path)
            },
            getStrResponse = host.getStrResponse,
            host = host,
        )
        return when (jsResult) {
            is JsResult.JsString -> parseHeaderJson(jsResult.value)
            is JsResult.JsObject -> jsResult.value
                .mapNotNull { (key, value) -> value?.toString()?.let { key to it } }
                .toMap(LinkedHashMap())
            is JsResult.JsError -> {
                val capability = jsResult.exception as? SharedCapabilityException
                if (capability != null) {
                    throw capability
                }
                throw IllegalStateException("source header JS execution failed: ${jsResult.message}", jsResult.exception)
            }
            else -> emptyMap()
        }
    }

    private fun parseHeaderJson(headerJson: String): Map<String, String> {
        return runCatching {
            val root = json.parseToJsonElement(headerJson) as? JsonObject ?: return emptyMap()
            root.entries.mapNotNull { entry ->
                entry.value.jsonPrimitive.contentOrNull?.let { entry.key to it }
            }.toMap(LinkedHashMap())
        }.getOrElse { emptyMap() }
    }

    private fun normalizeLoginCheckResult(
        jsResult: JsResult,
        response: SourceResponse,
        tag: String
    ): LoginCheckResult {
        return when (jsResult) {
            is JsResult.JsBoolean -> LoginCheckResult(passed = jsResult.value, response = response)
            is JsResult.JsNumber -> LoginCheckResult(passed = jsResult.value != 0.0, response = response)
            is JsResult.JsString -> {
                val trimmed = jsResult.value.trim()
                when {
                    trimmed.isEmpty() || FALSE_STRINGS.contains(trimmed.lowercase()) -> {
                        LoginCheckResult(passed = false, response = response)
                    }
                    trimmed == response.bodyText -> LoginCheckResult(passed = true, response = response)
                    else -> LoginCheckResult(
                        passed = true,
                        response = response.copy(bodyText = trimmed, body = trimmed.encodeToByteArray())
                    )
                }
            }
            is JsResult.JsObject -> {
                val passed = (jsResult.value["passed"]
                    ?: jsResult.value["success"]
                    ?: jsResult.value["loggedIn"]).toBooleanLike() ?: true
                val patched = buildSourceResponse(response, jsResult.value)
                LoginCheckResult(passed = passed, response = patched)
            }
            is JsResult.JsError -> {
                val capability = jsResult.exception as? SharedCapabilityException
                if (capability != null) {
                    throw capability
                }
                throw LoginCheckFailedException("loginCheckJs execution failed for $tag: ${jsResult.message}")
            }
            else -> LoginCheckResult(passed = true, response = response)
        }
    }

    private fun extractProxy(
        request: BuiltUrl,
        defaultHeaders: Map<String, String>
    ): String? {
        return request.proxy?.takeIf { it.isNotBlank() }
            ?: request.headers.entries.firstOrNull { it.key.equals("proxy", ignoreCase = true) }?.value
            ?: defaultHeaders.entries.firstOrNull { it.key.equals("proxy", ignoreCase = true) }?.value
    }

    private fun HttpResponse.findHeader(name: String): String? {
        return headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value
            ?: allHeaders.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value?.firstOrNull()
    }

    private companion object {
        private val FALSE_STRINGS = setOf("false", "0", "null", "undefined")
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
    }

}

internal fun normalizeCompatibilityReferer(baseUrl: String, requestUrl: String): String? {
    val referer = baseUrl.ifBlank { requestUrl }.takeIf { it.isNotBlank() } ?: return null
    return normalizePlatformRequestUrl(referer)
}

internal fun normalizeExplicitUrlHeaders(headers: MutableMap<String, String>) {
    val refererEntry = headers.entries.firstOrNull { it.key.equals("Referer", ignoreCase = true) }
    if (refererEntry != null) {
        normalizeExplicitReferer(refererEntry.value)?.let { refererEntry.setValue(it) }
    }
    val originEntry = headers.entries.firstOrNull { it.key.equals("Origin", ignoreCase = true) }
    if (originEntry != null) {
        normalizeExplicitOrigin(originEntry.value)?.let { originEntry.setValue(it) }
    }
}

internal fun normalizeExplicitReferer(value: String): String? {
    val trimmed = value.trim()
    if (trimmed.isBlank()) return null
    val withoutFragment = trimmed.substringBefore('#').trim()
    if (withoutFragment.isBlank()) return null
    return normalizePlatformRequestUrl(withoutFragment)
}

internal fun normalizeExplicitOrigin(value: String): String? {
    val trimmed = value.trim()
    if (trimmed.isBlank()) return null
    val normalized = normalizePlatformRequestUrl(trimmed.substringBefore('#').trim())
    return deriveCompatibleOrigin(normalized)
}

internal fun deriveCompatibleOrigin(url: String): String? {
    return runCatching {
        val parsed = Url(url)
        val port = parsed.port
        val defaultPort = when (parsed.protocol.name.lowercase()) {
            "http" -> 80
            "https" -> 443
            else -> -1
        }
        buildString {
            append(parsed.protocol.name)
            append("://")
            append(parsed.host)
            if (port > 0 && port != defaultPort) {
                append(':')
                append(port)
            }
        }
    }.getOrNull()
}
