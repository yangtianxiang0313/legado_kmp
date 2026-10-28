package io.legado.kmp.shared.domain.rss

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.analyze.SimpleRuleData
import io.legado.kmp.shared.model.RssArticle
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

object RssParserByRule {

    suspend fun parse(
        sortName: String,
        sortUrl: String,
        redirectUrl: String,
        body: String?,
        rssSource: RssSource,
        variables: Map<String, String> = emptyMap(),
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null
    ): Pair<List<RssArticle>, String?> {
        currentCoroutineContext().ensureActive()
        val payload = body?.takeIf { it.isNotBlank() }
            ?: error("Failed to access website:${rssSource.sourceUrl}")

        val ruleArticles = rssSource.ruleArticles?.trim()
        if (ruleArticles.isNullOrBlank()) {
            val result = RssParserDefault.parse(sortName, payload, rssSource.sourceUrl, redirectUrl)
            currentCoroutineContext().ensureActive()
            return result
        }

        val source = rssSource.asBookSourceShim()
        val baseUrl = rssRuleBaseUrl(sortUrl)
        val analyzeRule = AnalyzeRule(
            source = source,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        analyzeRule.setRuleData(SimpleRuleData(source, variables))
        analyzeRule.setContent(payload, baseUrl).setRedirectUrl(redirectUrl)

        var listRule = ruleArticles
        var reverse = false
        if (listRule.startsWith("-")) {
            reverse = true
            listRule = listRule.substring(1)
        }

        val items = analyzeRule.getElements(listRule)
        currentCoroutineContext().ensureActive()
        val nextUrl = rssSource.ruleNextPage?.trim()?.takeIf { it.isNotEmpty() }?.let { nextRule ->
            if (nextRule.equals("PAGE", ignoreCase = true)) {
                sortUrl
            } else {
                val next = analyzeRule.getRssString(nextRule)
                if (next.isEmpty()) next else resolveAgainst(sortUrl, next)
            }
        }

        // Each article gets an independent copy of the page-level rule variables.
        val articleSeed = analyzeRule.getVariables()
        val articles = items.mapNotNull { item ->
            currentCoroutineContext().ensureActive()
            val itemRule = AnalyzeRule(
                source = source,
                sourceStateStore = sourceStateStore,
                jsExecutor = jsExecutor,
                connectGateway = connectGateway,
                headerResolver = headerResolver,
                sourceJsRuntime = sourceJsRuntime
            )
            itemRule.setRuleData(SimpleRuleData(source, articleSeed))
            itemRule.setContent(item, baseUrl).setRedirectUrl(redirectUrl)

            val title = itemRule.getRssString(rssSource.ruleTitle)
            val pubDate = itemRule.getRssString(rssSource.rulePubDate)
            val description = rssSource.ruleDescription?.takeIf { it.isNotBlank() }
                ?.let { itemRule.getRssString(it) }
            val image = itemRule.getRssString(rssSource.ruleImage, isUrl = true)
            val link = resolveAgainst(rssSource.sourceUrl, itemRule.getRssString(rssSource.ruleLink))

            // Capture after link: any field can write variables consumed by the content page.
            val articleVariables = itemRule.getVariables()
            if (title.isBlank()) return@mapNotNull null
            RssArticle(
                origin = rssSource.sourceUrl,
                sort = sortName,
                title = title,
                link = link,
                pubDate = pubDate,
                description = description,
                image = image,
                variable = articleVariables.takeIf { it.isNotEmpty() }?.let { json.encodeToString(it) }
            )
        }.toMutableList()

        if (reverse) {
            articles.reverse()
        }
        currentCoroutineContext().ensureActive()
        return articles to nextUrl
    }

    private suspend fun AnalyzeRule.getRssString(rule: String?, isUrl: Boolean = false): String {
        currentCoroutineContext().ensureActive()
        val value = getString(rule, isUrl = isUrl)
        currentCoroutineContext().ensureActive()
        return value
    }

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }
}
