package io.legado.kmp.shared.domain.rss

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.analyze.SimpleRuleData
import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.AnalyzeUrlLegacyContext
import io.legado.kmp.shared.network.BuiltUrl
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.LegacyJsHostSurface
import io.legado.kmp.shared.scripting.LegacySourceJsRuntime
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.util.splitLegacyPayloadItems

class RssService(
    private val requestExecutor: SourceRequestExecutor,
    private val headerResolver: SourceHeaderResolver,
    private val sourceStateStore: SourceStateStore,
    private val cacheRepository: CacheRepository? = null,
    private val sourceJsRuntime: SourceJsRuntime? = null,
    private val jsExecutor: JsExecutor = JsExecutor.Default
) {
    private val sortCache = RssSortCache(sourceStateStore, cacheRepository)

    suspend fun getSortUrls(source: RssSource): Result<List<Pair<String, String>>> = runCatching {
        val raw = source.sortUrl?.trim().orEmpty()
        if (raw.isBlank()) {
            return@runCatching listOf("" to source.sourceUrl)
        }

        val payload = if (isJsRule(raw)) {
            sortCache.getOrLoad(source, raw) {
                executeSortJs(source, raw)
            }
        } else {
            raw
        }
        parseSortPayload(source, payload)
    }

    suspend fun clearSortCache(source: RssSource) {
        sortCache.clear(source)
    }

    suspend fun getArticles(
        sortName: String,
        sortUrl: String,
        source: RssSource,
        page: Int = 1
    ): Result<Pair<List<RssArticle>, String?>> = runCatching {
        val requestVariables = linkedMapOf<String, Any?>().apply {
            putAll(sourceStateStore.getSourceVariableMap(source.sourceUrl))
            put("page", page)
            put("searchPage", page)
        }
        val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
        analyzeUrl.setVariables(requestVariables)
        val request = analyzeUrl.build(sortUrl, source.sourceUrl)
        requestVariables.putAll(request.usedVariables)
        val response = requestExecutor.executeText(
            request = request,
            source = source.asBookSourceShim(),
            defaultHeaders = buildHeaders(source, requestVariables, request),
            ruleData = requestVariables
        ).getOrThrow()
        RssParserByRule.parse(
            sortName = sortName,
            sortUrl = sortUrl,
            redirectUrl = response.finalUrl.ifBlank { request.url },
            body = response.bodyText,
            rssSource = source,
            variables = requestVariables.mapValuesNotNullString(),
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = requestExecutor,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
    }

    suspend fun getContent(
        article: RssArticle,
        source: RssSource
    ): Result<String> = runCatching {
        val ruleContent = source.ruleContent?.takeIf { it.isNotBlank() } ?: return@runCatching article.content.orEmpty()
        val requestVariables = linkedMapOf<String, Any?>().apply {
            putAll(sourceStateStore.getSourceVariableMap(source.sourceUrl))
            putAll(article.variableMap)
            put("link", article.link)
        }
        val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
        analyzeUrl.setVariables(requestVariables)
        val request = analyzeUrl.build(article.link, article.origin)
        requestVariables.putAll(request.usedVariables)
        val response = requestExecutor.executeText(
            request = request,
            source = source.asBookSourceShim(),
            defaultHeaders = buildHeaders(source, requestVariables, request),
            ruleData = requestVariables
        ).getOrThrow()

        val analyzeRule = AnalyzeRule(
            source = source.asBookSourceShim(),
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = requestExecutor,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        analyzeRule.setRuleData(SimpleRuleData(source.asBookSourceShim(), requestVariables.mapValuesNotNullString()))
        analyzeRule.setContent(response.bodyText, request.url)
        analyzeRule.setRedirectUrl(response.finalUrl.ifBlank { request.url })
        analyzeRule.getString(ruleContent)
    }

    private suspend fun executeSortJs(source: RssSource, sortRule: String): String {
        val runtime = sourceJsRuntime ?: LegacySourceJsRuntime(sourceStateStore)
        val script = extractScript(sortRule)
        val result = runtime.execute(
            script = script,
            source = source.asBookSourceShim(),
            variables = emptyMap(),
            connect = { urlRule, headerJson ->
                requestExecutor.executeForLegacyJs(
                    urlRule = urlRule,
                    source = source.asBookSourceShim(),
                    headerJson = headerJson,
                    baseUrl = source.sourceUrl,
                    ruleData = emptyMap(),
                    chapter = null
                )
            },
            rawConnect = { urlRule, headerJson ->
                requestExecutor.executeForLegacyJsRaw(
                    urlRule = urlRule,
                    source = source.asBookSourceShim(),
                    headerJson = headerJson,
                    baseUrl = source.sourceUrl,
                    ruleData = emptyMap(),
                    chapter = null
                )
            },
            host = LegacyJsHostSurface.fromCallbacks(
                source = source.asBookSourceShim(),
                connect = { urlRule, headerJson ->
                    requestExecutor.executeForLegacyJs(urlRule, source.asBookSourceShim(), headerJson)
                },
                jsoupExecute = requestExecutor::executeJsoupForLegacyJs,
            ),
        )
        return when (result) {
            is JsResult.JsString -> result.value
            is JsResult.JsError -> throw IllegalStateException(result.message, result.exception)
            else -> result.asString()
        }.trim()
    }

    private fun parseSortPayload(source: RssSource, payload: String): List<Pair<String, String>> {
        val result = splitLegacyPayloadItems(payload)
            .mapNotNull { line ->
                val trimmed = line.trim()
                if (trimmed.isBlank()) return@mapNotNull null
                val name = trimmed.substringBefore("::").trim()
                val url = trimmed.substringAfter("::", "").trim()
                if (url.isBlank()) return@mapNotNull null
                val resolved = if (url.startsWith("{{")) url else resolveAgainst(source.sourceUrl, url)
                name to resolved
            }
        return result.ifEmpty { listOf("" to source.sourceUrl) }
    }

    private suspend fun buildHeaders(
        source: RssSource,
        requestVariables: Map<String, Any?>,
        request: BuiltUrl
    ): Map<String, String> {
        return requestExecutor.resolveSourceHeaders(
            source = source.asBookSourceShim(),
            request = request,
            includeLoginHeader = false,
            ruleData = requestVariables
        )
    }

    private fun createAnalyzeUrl(
        source: RssSource,
        ruleData: Map<String, Any?> = emptyMap()
    ): AnalyzeUrl {
        return AnalyzeUrl(
            jsExecutor = jsExecutor,
            legacyContext = AnalyzeUrlLegacyContext(
                source = source.asBookSourceShim(),
                sourceStateStore = sourceStateStore,
                gateway = requestExecutor,
                sourceJsRuntime = sourceJsRuntime,
                ruleData = ruleData
            )
        )
    }

    private fun isJsRule(value: String): Boolean {
        return value.startsWith("@js:", ignoreCase = true) || value.startsWith("<js>", ignoreCase = true)
    }

    private fun extractScript(value: String): String {
        val trimmed = value.trim()
        return when {
            trimmed.startsWith("@js:", ignoreCase = true) -> trimmed.substring(4).trim()
            trimmed.startsWith("<js>", ignoreCase = true) && trimmed.endsWith("</js>", ignoreCase = true) -> {
                trimmed.substring(4, trimmed.length - 5).trim()
            }
            else -> trimmed
        }
    }

    private fun Map<String, Any?>.mapValuesNotNullString(): Map<String, String> {
        return entries.mapNotNull { (key, value) -> value?.toString()?.let { key to it } }.toMap()
    }
}
