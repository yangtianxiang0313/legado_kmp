package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.BuiltUrl
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.scripting.LegacyJsHostSurface
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal const val RSS_NAVIGATION_ERROR_MESSAGE = "订阅文章跳转规则执行失败，请检查订阅源配置"

internal class RssArticleNavigationActions {
    private val values = mutableListOf<RssArticleNavigationAction>()

    suspend fun searchBook(key: String) = append(RssArticleNavigationActionKind.SEARCH_BOOK, key, 512)

    suspend fun addBook(bookUrl: String) = append(RssArticleNavigationActionKind.ADD_BOOK, bookUrl, 8192)

    fun snapshot(): List<RssArticleNavigationAction> = values.toList()

    private suspend fun append(kind: RssArticleNavigationActionKind, value: String, limit: Int) {
        currentCoroutineContext().ensureActive()
        require(values.size < 16 && value.isNotBlank() && value.length <= limit &&
            value.none { it.code < 32 || it.code == 127 }) { "RSS navigation action rejected" }
        values.add(RssArticleNavigationAction(kind, value))
    }
}

// Android String?.isTrue(), not JavaScript truthiness. In particular, "null" is checked before trim.
internal fun String.isRssNavigationTrue(): Boolean {
    if (isBlank() || this == "null") return false
    return !trim().let { value ->
        value.equals("false", ignoreCase = true) || value.equals("no", ignoreCase = true) ||
            value.equals("not", ignoreCase = true) || value == "0"
    }
}

internal fun createRssArticleNavigationHost(
    source: BookSource,
    variables: Map<String, Any?>,
    executor: SourceRequestExecutor,
    actions: RssArticleNavigationActions,
): LegacyJsHostSurface = LegacyJsHostSurface.fromCallbacks(
    source = source,
    connect = { urlRule, headerJson ->
        executor.executeForLegacyJs(
            urlRule = urlRule,
            source = source,
            headerJson = headerJson,
            baseUrl = source.bookSourceUrl,
            ruleData = variables,
        )
    },
    rawConnect = { urlRule, headerJson ->
        executor.executeForLegacyJsRaw(
            urlRule = urlRule,
            source = source,
            headerJson = headerJson,
            baseUrl = source.bookSourceUrl,
            ruleData = variables,
        )
    },
    getSourceHeaders = { includeLoginHeader ->
        executor.resolveSourceHeaders(
            source = source,
            request = BuiltUrl(
                ruleUrl = source.bookSourceUrl,
                url = source.bookSourceUrl,
                urlNoQuery = source.bookSourceUrl,
                baseUrl = source.bookSourceUrl,
            ),
            includeLoginHeader = includeLoginHeader,
            ruleData = variables,
        )
    },
    rssSearchBook = actions::searchBook,
    rssAddBook = actions::addBook,
)
