package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SharedCapabilityException
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.scripting.LegacyJsHostSurface
import io.legado.kmp.shared.scripting.LegacySourceJsRuntime
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlin.coroutines.coroutineContext

internal class AnalyzeRuleLegacyJsSupport(
    private val analyzeRule: AnalyzeRule,
    private val source: BookSource?,
    private val sourceStateStore: SourceStateStore?,
    private val jsExecutor: JsExecutor,
    private val connectGateway: LegacyJsConnectGateway?,
    private val headerResolver: SourceHeaderResolver?,
    private val sourceJsRuntime: SourceJsRuntime?,
    private val jsContextBindings: MutableMap<String, Any?>,
    private val getBaseUrl: () -> String?,
    private val getRedirectUrl: () -> String?,
    private val getCurrentChapter: () -> BookChapter?,
    private val copyVariablesTo: (MutableMap<String, Any?>) -> Unit,
    private val legacyReGetBook: (suspend () -> Book)?,
    private val legacyRefreshTocUrl: (suspend () -> Book)?
) {
    // Read mutable rule context at use time; network callbacks must not capture a snapshot.
    suspend fun execute(
        rule: kotlin.String,
        contentValue: kotlin.String,
        previousResult: AnalyzeResult,
        includeSourceHeadersInBindings: kotlin.Boolean = true,
        additionalBindings: Map<kotlin.String, Any?> = emptyMap()
    ): AnalyzeResult {
        val legacySource = source ?: return AnalyzeResult.StringVal("")
        val gateway = connectGateway
        val runtime = sourceJsRuntime ?: LegacySourceJsRuntime(sourceStateStore)
        val base = getBaseUrl() ?: legacySource.bookSourceUrl
        val sourceHeaderBindings = if (includeSourceHeadersInBindings) {
            linkedMapOf<String, Any?>(
                "headerMap" to buildLegacySourceHeaders(contentValue, includeLoginHeader = true)
            )
        } else {
            emptyMap()
        }
        val effectiveBindings = linkedMapOf<String, Any?>().apply {
            putAll(sourceHeaderBindings)
            putAll(additionalBindings)
        }
        val bindingPreamble = analyzeRule.prepareVariableBindings(coroutineContext)
        val jsVariables = buildLegacyJsVariables(contentValue, previousResult, effectiveBindings)
        val effectiveRuleData = buildLegacyRuleData(contentValue, effectiveBindings)
        val primitiveResult = (runtime as? LegacySourceJsRuntime)?.executePrimitiveRule(rule, legacySource, jsVariables)
        val jsResult = primitiveResult ?: runtime.execute(
            script = bindingPreamble + rule,
            source = legacySource,
            variables = jsVariables,
            connect = { urlRule, headerJson ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.executeForLegacyJs(
                    urlRule = urlRule,
                    source = legacySource,
                    headerJson = headerJson,
                    baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                    ruleData = effectiveRuleData,
                    chapter = getCurrentChapter()
                )
            },
            rawConnect = { urlRule, headerJson ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.executeForLegacyJsRaw(
                    urlRule = urlRule,
                    source = legacySource,
                    headerJson = headerJson,
                    baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                    ruleData = effectiveRuleData,
                    chapter = getCurrentChapter()
                )
            },
            getSourceHeaders = { includeLoginHeader ->
                buildLegacySourceHeaders(contentValue, includeLoginHeader)
            },
            getString = { ruleText ->
                analyzeRule.getString(ruleText)
            },
            getStringList = { ruleText ->
                analyzeRule.getStringList(ruleText)
            },
            getElementPayload = { ruleText ->
                legacyJsElementPayload(analyzeRule.getElement(ruleText))
            },
            setContent = { nextContent, nextBaseUrl ->
                analyzeRule.setContent(nextContent, nextBaseUrl ?: getBaseUrl())
            },
            setBaseUrl = { nextBaseUrl ->
                analyzeRule.setBaseUrl(nextBaseUrl)
            },
            startBrowser = { url, title ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.startBrowserForLegacyJs(legacySource, url, title)
            },
            startBrowserAwait = { url, title, refetchAfterSuccess ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.startBrowserAwaitForLegacyJs(legacySource, url, title, refetchAfterSuccess)
            },
            getVerificationCode = { imageUrl ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.getVerificationCodeForLegacyJs(legacySource, imageUrl)
            },
            openUrl = { url, mimeType ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.openUrlForLegacyJs(legacySource, url, mimeType)
            },
            webView = { html, url, js ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.executeWebViewForLegacyJs(
                    source = legacySource,
                    url = url,
                    html = html,
                    javaScript = js,
                )
            },
            webViewGetSource = { html, url, js, sourceRegex ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.executeWebViewForLegacyJs(
                    source = legacySource,
                    url = url,
                    html = html,
                    javaScript = js,
                    sourceRegex = sourceRegex,
                )
            },
            webViewGetOverrideUrl = { html, url, js, overrideUrlRegex ->
                val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                availableGateway.executeWebViewForLegacyJs(
                    source = legacySource,
                    url = url,
                    html = html,
                    javaScript = js,
                    overrideUrlRegex = overrideUrlRegex,
                )
            },
            readLocalScript = { path ->
                gateway?.readLocalScriptForLegacyJs(path)
            },
            host = LegacyJsHostSurface.fromCallbacks(
                source = legacySource,
                connect = { urlRule, headerJson ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.executeForLegacyJs(
                        urlRule = urlRule,
                        source = legacySource,
                        headerJson = headerJson,
                        baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = getCurrentChapter()
                    )
                },
                rawConnect = { urlRule, headerJson ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.executeForLegacyJsRaw(
                        urlRule = urlRule,
                        source = legacySource,
                        headerJson = headerJson,
                        baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = getCurrentChapter()
                    )
                },
                getString = { ruleText ->
                    analyzeRule.getString(ruleText)
                },
                getStringList = { ruleText ->
                    analyzeRule.getStringList(ruleText)
                },
                getElementPayload = { ruleText ->
                    legacyJsElementPayload(analyzeRule.getElement(ruleText))
                },
                legacyGet = { key ->
                    analyzeRule.getVariable(key) ?: ""
                },
                legacyPut = { key, value ->
                    analyzeRule.put(key, value)
                },
                legacyDelete = { key ->
                    analyzeRule.put(key, null)
                },
                setContent = { nextContent, nextBaseUrl ->
                    analyzeRule.setContent(nextContent, nextBaseUrl ?: getBaseUrl())
                },
                setBaseUrl = { nextBaseUrl ->
                    analyzeRule.setBaseUrl(nextBaseUrl)
                },
                startBrowser = { url, title ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.startBrowserForLegacyJs(legacySource, url, title)
                },
                startBrowserAwait = { url, title, refetchAfterSuccess ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.startBrowserAwaitForLegacyJs(legacySource, url, title, refetchAfterSuccess)
                },
                getVerificationCode = { imageUrl ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.getVerificationCodeForLegacyJs(legacySource, imageUrl)
                },
                openUrl = { url, mimeType ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.openUrlForLegacyJs(legacySource, url, mimeType)
                },
                showToast = { message, long ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.showToastForLegacyJs(legacySource, message, long)
                },
                webView = { html, url, js ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.executeWebViewForLegacyJs(
                        source = legacySource,
                        url = url,
                        html = html,
                        javaScript = js,
                    )
                },
                webViewGetSource = { html, url, js, sourceRegex ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.executeWebViewForLegacyJs(
                        source = legacySource,
                        url = url,
                        html = html,
                        javaScript = js,
                        sourceRegex = sourceRegex,
                    )
                },
                webViewGetOverrideUrl = { html, url, js, overrideUrlRegex ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.executeWebViewForLegacyJs(
                        source = legacySource,
                        url = url,
                        html = html,
                        javaScript = js,
                        overrideUrlRegex = overrideUrlRegex,
                    )
                },
                readLocalScript = { path ->
                    gateway?.readLocalScriptForLegacyJs(path)
                },
                downloadFile = { urlRule ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.downloadFileForLegacyJs(
                        source = legacySource,
                        urlRule = urlRule,
                        baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = getCurrentChapter(),
                    )
                },
                writeHexFile = { contentHex, urlRule ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.writeHexFileForLegacyJs(
                        source = legacySource,
                        contentHex = contentHex,
                        urlRule = urlRule,
                        baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = getCurrentChapter(),
                    )
                },
                readFile = { path ->
                    gateway?.readFileForLegacyJs(path)
                },
                readTextFile = { path, charsetName ->
                    gateway?.readTextFileForLegacyJs(path, charsetName) ?: ""
                },
                deleteFile = { path ->
                    gateway?.deleteFileForLegacyJs(path) ?: false
                },
                getTextInFolder = { path ->
                    gateway?.getTextInFolderForLegacyJs(path) ?: ""
                },
                getZipByteArrayContent = { url, path ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.getZipByteArrayContentForLegacyJs(
                        source = legacySource,
                        url = url,
                        path = path,
                        baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = getCurrentChapter(),
                    )
                },
                getZipStringContent = { url, path, charsetName ->
                    val availableGateway = gateway ?: throw missingLegacyJsNetworkCapability()
                    availableGateway.getZipStringContentForLegacyJs(
                        source = legacySource,
                        url = url,
                        path = path,
                        charsetName = charsetName,
                        baseUrl = base.ifBlank { legacySource.bookSourceUrl },
                        ruleData = effectiveRuleData,
                        chapter = getCurrentChapter(),
                    )
                },
                reGetBook = {
                    val updatedBook = legacyReGetBook?.invoke()
                        ?: error("只能在 preUpdateJs 中调用")
                    analyzeRule.setBookContext(updatedBook)
                    jsContextBindings["book"] as? Map<String, Any?>
                },
                refreshTocUrl = {
                    val updatedBook = legacyRefreshTocUrl?.invoke()
                        ?: error("只能在 preUpdateJs 中调用")
                    analyzeRule.setBookContext(updatedBook)
                    jsContextBindings["book"] as? Map<String, Any?>
                }
            )
        )
        sourceStateKey()?.let { sourceKey ->
            jsContextBindings["loginHeader"] = runBlocking { sourceStateStore?.getLoginHeader(sourceKey) }
            jsContextBindings["sourceVariable"] = runBlocking { sourceStateStore?.getSourceVariable(sourceKey) }
        }
        return analyzeResultFromJs(jsResult) { error ->
            val capability = error.exception as? SharedCapabilityException
            if (capability != null) throw capability
            throw IllegalStateException(error.message, error.exception)
        }
    }

    private fun buildLegacyRuleData(
        contentValue: kotlin.String,
        additionalBindings: Map<kotlin.String, Any?> = emptyMap()
    ): Map<String, Any?> {
        return linkedMapOf<String, Any?>().apply {
            putAll(buildLegacyJsVariables(contentValue, AnalyzeResult.StringVal(contentValue), additionalBindings))
        }
    }

    private fun buildLegacyJsVariables(
        contentValue: kotlin.String,
        previousResult: AnalyzeResult,
        additionalBindings: Map<String, Any?> = emptyMap()
    ): Map<String, Any?> {
        return linkedMapOf<String, Any?>().apply {
            put("body", contentValue)
            put("src", contentValue)
            put("baseUrl", getBaseUrl() ?: "")
            getCurrentChapter()?.title?.let { put("title", it) }
            putAll(jsContextBindings)
            copyVariablesTo(this)
            putAll(additionalBindings)
            bindLegacyJsResult(
                previousResult,
                legacyJsValueFromAnalyzeResult(previousResult) ?: contentValue,
                replaceResult = !containsKey("result")
            )
        }
    }

    fun buildTransientBindings(previousResult: AnalyzeResult): Map<String, Any?> {
        return LinkedHashMap<String, Any?>().apply {
            putAll(jsContextBindings)
            copyVariablesTo(this)
            val payload = jsValueFromAnalyzeResult(previousResult)
            bindLegacyJsResult(previousResult, payload, replaceResult = payload != null)
        }
    }

    private fun buildTransientBindings(rawResult: Any?): Map<String, Any?> {
        return LinkedHashMap<String, Any?>().apply {
            putAll(jsContextBindings)
            copyVariablesTo(this)
            val payload = toJsCompatibleValue(rawResult)
            bindLegacyJsResult(rawResult, payload, replaceResult = payload != null)
        }
    }

    private fun MutableMap<String, Any?>.bindLegacyJsResult(
        rawResult: Any?,
        payload: Any?,
        replaceResult: Boolean
    ) {
        val effectiveRawResult = if (replaceResult) {
            put("result", payload)
            rawResult
        } else {
            get("result").also { overriddenResult ->
                if (containsKey("result")) {
                    put("result", toJsCompatibleValue(overriddenResult))
                }
            }
        }
        // Bind only after all variable merges; clear stale or user-supplied metadata, too.
        put(LEGACY_HTML_RESULT_KIND_BINDING, legacyHtmlResultKind(effectiveRawResult)?.bindingValue)
        put(LEGACY_DOM_INPUT_DESCRIPTORS_BINDING, legacyDomInputDescriptors(effectiveRawResult))
        put(LEGACY_JSON_INPUT_DESCRIPTORS_BINDING, legacyJsonInputDescriptors(effectiveRawResult))
    }

    private suspend fun buildLegacySourceHeaders(
        contentValue: kotlin.String,
        includeLoginHeader: kotlin.Boolean
    ): Map<String, String> {
        val legacySource = source ?: return emptyMap()
        val sourceKey = legacySource.bookSourceUrl
        val base = getBaseUrl() ?: legacySource.bookSourceUrl
        val effectiveHeaderResolver = headerResolver ?: SourceHeaderResolver(jsExecutor)
        val sourceVariable = sourceStateStore?.getSourceVariable(sourceKey)
        val sourceVariableMap = sourceStateStore?.getSourceVariableMap(sourceKey).orEmpty()
        val headerBindings = linkedMapOf<String, Any?>(
            "baseUrl" to base,
            "url" to (getRedirectUrl() ?: base),
            "result" to contentValue,
            "sourceVariable" to sourceVariable,
            "sourceVariableMap" to sourceVariableMap
        )
        val resolved = when (val headerRule = legacySource.header?.trim().orEmpty()) {
            "" -> emptyMap()
            else -> when {
                headerRule.startsWith("@js:", ignoreCase = true) -> {
                    parseLegacyHeaderJson(
                        execute(
                            headerRule.substring(4).trim(),
                            contentValue,
                            AnalyzeResult.StringVal(contentValue),
                            includeSourceHeadersInBindings = false,
                            additionalBindings = headerBindings
                        ).asString()
                    )
                }

                headerRule.startsWith("<js>", ignoreCase = true) &&
                    headerRule.endsWith("</js>", ignoreCase = true) -> {
                    parseLegacyHeaderJson(
                        execute(
                            headerRule.substring(4, headerRule.length - 5).trim(),
                            contentValue,
                            AnalyzeResult.StringVal(contentValue),
                            includeSourceHeadersInBindings = false,
                            additionalBindings = headerBindings
                        ).asString()
                    )
                }

                else -> effectiveHeaderResolver.resolve(
                    headerRule = headerRule,
                    variables = linkedMapOf<String, Any?>(
                        "baseUrl" to base,
                        "url" to (getRedirectUrl() ?: base),
                        "result" to contentValue,
                        "sourceVariable" to sourceVariable,
                        "sourceVariableMap" to sourceVariableMap,
                        "source" to mapOf(
                            "bookSourceUrl" to legacySource.bookSourceUrl,
                            "bookSourceName" to legacySource.bookSourceName,
                            "loginUrl" to legacySource.loginUrl,
                            "loginCheckJs" to legacySource.loginCheckJs,
                            "enabledCookieJar" to legacySource.enabledCookieJar
                        )
                    )
                )
            }
        }
        return LinkedHashMap<String, String>().apply {
            putAll(resolved)
            if (includeLoginHeader) {
                putAll(sourceStateStore?.getLoginHeaderMap(sourceKey).orEmpty())
            }
        }
    }

    private fun parseLegacyHeaderJson(content: kotlin.String): Map<String, String> {
        val trimmed = content.trim()
        if (!trimmed.startsWith("{")) return emptyMap()
        return runCatching {
            val root = kotlinx.serialization.json.Json.parseToJsonElement(trimmed) as? JsonObject
                ?: return emptyMap()
            root.entries.mapNotNull { (key, value) ->
                value.jsonPrimitive.contentOrNull?.let { key to it }
            }.toMap(LinkedHashMap())
        }.getOrElse { emptyMap() }
    }

    private fun sourceStateKey(): kotlin.String? = source?.bookSourceUrl?.takeIf { it.isNotBlank() }

    private fun missingLegacyJsNetworkCapability(): SharedCapabilityException {
        return SharedCapabilityException(
            capabilityGapKey = "legacy_js_network_helpers_unsupported",
            message = "Legacy JS network helpers are not implemented in shared execution yet"
        )
    }
}
