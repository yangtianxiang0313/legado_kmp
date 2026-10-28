package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.analyze.SimpleRuleData
import io.legado.kmp.shared.content.BookHelp
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourceType
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.rule.BookListRule
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.util.formatChineseWordCount
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Book list parser
 * Handles search and explore book list parsing with book source rules
 *
 * Original: legado/app/src/main/java/io/legado/app/model/webBook/BookList.kt
 */
object BookList {

    /**
     * Parse book list from HTML/JSON content
     *
     * @param bookSource Book source configuration
     * @param baseUrl Base URL for resolving relative URLs
     * @param body HTML/JSON content
     * @param isSearch Whether this is a search (true) or explore (false) request
     * @return List of SearchBook
     */
    suspend fun analyzeBookList(
        bookSource: BookSource,
        baseUrl: String,
        body: String,
        isSearch: Boolean = true,
        redirectUrl: String = baseUrl,
        initialVariables: Map<String, Any?> = emptyMap(),
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null,
        filter: ((name: String, author: String) -> Boolean)? = null,
        shouldBreak: ((size: Int) -> Boolean)? = null,
        debugSink: BookSourceDebugSink? = null
    ): List<SearchBook> {
        if (body.isBlank()) {
            return emptyList()
        }

        val rule: BookListRule? = if (isSearch) {
            bookSource.getSearchRule()
        } else {
            val exploreRule = bookSource.getExploreRule()
            if (exploreRule.bookList.isNullOrBlank()) {
                bookSource.getSearchRule()
            } else {
                exploreRule
            }
        }

        return try {
            val analyzeRule = AnalyzeRule(
                source = bookSource,
                sourceStateStore = sourceStateStore,
                jsExecutor = jsExecutor,
                connectGateway = connectGateway,
                headerResolver = headerResolver,
                sourceJsRuntime = sourceJsRuntime
            )
            analyzeRule.setContent(body, baseUrl)
            analyzeRule.setRedirectUrl(redirectUrl)
            initialVariables.forEach { (key, value) ->
                analyzeRule.put(
                    key,
                    when (value) {
                        null -> null
                        is String -> value
                        else -> value.toString()
                    }
                )
            }
            val effectiveRedirectUrl = redirectUrl.ifBlank { baseUrl }
            val detailBaseUrl = if (effectiveRedirectUrl != baseUrl) {
                effectiveRedirectUrl
            } else {
                baseUrl
            }
            val isRedirect = detailBaseUrl != baseUrl

            if (
                isSearch &&
                bookSource.hasBookUrlPattern &&
                matchesBookUrlPattern(bookSource.bookUrlPattern.orEmpty(), baseUrl, detailBaseUrl)
            ) {
                debugSink?.log(message = "≡链接为详情页")
                parseInfoItem(
                    bookSource = bookSource,
                    analyzeRule = analyzeRule,
                    body = body,
                    baseUrl = detailBaseUrl,
                    redirectUrl = detailBaseUrl,
                    isRedirect = isRedirect,
                    sourceStateStore = sourceStateStore,
                    jsExecutor = jsExecutor,
                    connectGateway = connectGateway,
                    headerResolver = headerResolver,
                    sourceJsRuntime = sourceJsRuntime
                )
                    ?.takeIf { filter?.invoke(it.name, it.author) != false }
                    ?.let { return listOf(it) }
            }

            if (rule == null) {
                return emptyList()
            }

            var ruleList = rule.bookList?.trim().orEmpty()
            var reverse = false
            if (ruleList.startsWith("-")) {
                reverse = true
                ruleList = ruleList.substring(1)
            }
            if (ruleList.startsWith("+")) {
                ruleList = ruleList.substring(1)
            }

            debugSink?.log(message = "┌获取书籍列表")
            val items = try {
                if (ruleList.isBlank()) {
                    emptyList()
                } else {
                    analyzeRule.getElements(ruleList)
                }
            } catch (error: Exception) {
                error.rethrowIfSharedCapability()
                throw webBookParseFailure(
                    stage = if (isSearch) "search.list" else "explore.list",
                    source = bookSource,
                    baseUrl = baseUrl,
                    detail = "unable to resolve book list items",
                    rule = ruleList,
                    cause = error
                )
            }

            val books = if (items.isEmpty() && !bookSource.hasBookUrlPattern) {
                debugSink?.log(message = "└列表为空,按详情页解析")
                parseInfoItem(
                    bookSource = bookSource,
                    analyzeRule = analyzeRule,
                    body = body,
                    baseUrl = detailBaseUrl,
                    redirectUrl = detailBaseUrl,
                    isRedirect = isRedirect,
                    sourceStateStore = sourceStateStore,
                    jsExecutor = jsExecutor,
                    connectGateway = connectGateway,
                    headerResolver = headerResolver,
                    sourceJsRuntime = sourceJsRuntime
                )
                    ?.takeIf { filter?.invoke(it.name, it.author) != false }
                    ?.let(::listOf)
                    ?: emptyList()
            } else {
                debugSink?.log(message = "└列表大小:${items.size}")
                var firstFailure: Exception? = null
                val parsed = mutableListOf<SearchBook>()
                val listVariables = analyzeRule.getVariables()
                for ((index, item) in items.withIndex()) {
                    val book = try {
                        parseBookItem(
                            item = item,
                            bookSource = bookSource,
                            rule = rule,
                            baseUrl = baseUrl,
                            parentRule = analyzeRule,
                            initialVariables = listVariables,
                            body = body,
                            sourceStateStore = sourceStateStore,
                            jsExecutor = jsExecutor,
                            connectGateway = connectGateway,
                            headerResolver = headerResolver,
                            sourceJsRuntime = sourceJsRuntime,
                            logFirstItem = index == 0,
                            debugSink = debugSink
                        )
                    } catch (error: Exception) {
                        error.rethrowIfSharedCapability()
                        if (firstFailure == null) {
                            firstFailure = error
                        }
                        null
                    }
                    if (book != null) {
                        if (filter?.invoke(book.name, book.author) != false) {
                            parsed += book
                        }
                        if (shouldBreak?.invoke(parsed.size) == true) {
                            break
                        }
                    }
                }
                if (parsed.isEmpty() && items.isNotEmpty() && firstFailure != null) {
                    throw firstFailure as Exception
                }
                parsed
            }

            val unique = LinkedHashSet(books)
            val result = unique.toMutableList()
            if (reverse) {
                result.reverse()
            }
            debugSink?.log(message = "◇书籍总数:${result.size}")
            result
        } catch (e: WebBookParseException) {
            throw e
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            throw webBookParseFailure(
                stage = if (isSearch) "search.parse" else "explore.parse",
                source = bookSource,
                baseUrl = baseUrl,
                detail = "unexpected parser failure",
                cause = e
            )
        }
    }

    private suspend fun parseInfoItem(
        bookSource: BookSource,
        analyzeRule: AnalyzeRule,
        body: String,
        baseUrl: String,
        redirectUrl: String,
        isRedirect: Boolean,
        sourceStateStore: SourceStateStore?,
        jsExecutor: JsExecutor,
        connectGateway: LegacyJsConnectGateway?,
        headerResolver: SourceHeaderResolver?,
        sourceJsRuntime: SourceJsRuntime?
    ): SearchBook? {
        val book = Book(
            bookUrl = if (isRedirect) redirectUrl else baseUrl,
            origin = bookSource.bookSourceUrl,
            originName = bookSource.bookSourceName,
            type = getBookType(bookSource),
            variable = analyzeRule.getVariables()
                .takeIf { it.isNotEmpty() }
                ?.let { searchBookJson.encodeToString(it) }
        )
        val resolved = try {
            BookInfo.getBookInfo(
                bookSource = bookSource,
                book = book,
                baseUrl = baseUrl,
                body = body,
                redirectUrl = redirectUrl,
                canReName = false,
                sourceStateStore = sourceStateStore,
                jsExecutor = jsExecutor,
                connectGateway = connectGateway,
                headerResolver = headerResolver,
                sourceJsRuntime = sourceJsRuntime
            )
        } catch (error: Exception) {
            error.rethrowIfSharedCapability()
            throw webBookParseFailure(
                stage = "search.detailFallback",
                source = bookSource,
                baseUrl = baseUrl,
                detail = "fallback detail-page parsing failed",
                cause = error
            )
        }
        if (resolved.name.isBlank()) return null
        return SearchBook.fromBook(resolved).apply {
            infoHtml = body
        }
    }

    private fun matchesBookUrlPattern(pattern: String, requestUrl: String, resolvedUrl: String): Boolean {
        if (pattern.isBlank()) return false
        val regex = Regex(pattern)
        return requestUrl.matches(regex) || resolvedUrl.matches(regex)
    }

    /**
     * Parse a single book item from list.
     * Aligned with original: reuses parent AnalyzeRule with setContent(item),
     * adds ensureActive() between field extractions.
     */
    private suspend fun parseBookItem(
        item: Any,
        bookSource: BookSource,
        rule: BookListRule,
        baseUrl: String,
        parentRule: AnalyzeRule,
        initialVariables: Map<String, String>,
        body: String,
        sourceStateStore: SourceStateStore?,
        jsExecutor: JsExecutor,
        connectGateway: LegacyJsConnectGateway?,
        headerResolver: SourceHeaderResolver?,
        sourceJsRuntime: SourceJsRuntime?,
        logFirstItem: Boolean = false,
        debugSink: BookSourceDebugSink? = null
    ): SearchBook? {
        return try {
            val itemRuleData = SimpleRuleData(
                bookSource = bookSource,
                initialVariables = initialVariables
            )
            val itemRule = parentRule
            itemRule.setRuleData(itemRuleData)
            itemRule.setContent(item, baseUrl)

            var bookContext = Book(
                bookUrl = baseUrl,
                origin = bookSource.bookSourceUrl,
                originName = bookSource.bookSourceName,
                type = getBookType(bookSource),
                originOrder = bookSource.customOrder,
                variable = itemRuleData.getVariables()
                    .takeIf { it.isNotEmpty() }
                    ?.let { searchBookJson.encodeToString(it) }
            )
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取书名")
            val rawName = try {
                rule.name?.let { itemRule.getString(it) }.orEmpty()
            } catch (error: Exception) {
                error.rethrowIfSharedCapability()
                throw webBookParseFailure(
                    stage = "search.name",
                    source = bookSource,
                    baseUrl = baseUrl,
                    detail = "failed to parse book name",
                    rule = rule.name,
                    cause = error
                )
            }
            val name = formatBookName(rawName).takeIf { it.isNotEmpty() } ?: return null
            debugSink.logFirstItem(logFirstItem, "└$name")
            bookContext = bookContext.copy(name = name)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取作者")
            val author = runCatching {
                formatBookAuthor(rule.author?.let { itemRule.getString(it) }.orEmpty())
            }.getOrElse { error ->
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                ""
            }
            debugSink.logFirstItem(logFirstItem, "└$author")
            bookContext = bookContext.copy(author = author)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取分类")
            val kind = runCatching { rule.kind?.let { itemRule.getStringList(it) }?.joinToString(",") }.getOrElse { error ->
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                null
            }
            debugSink.logFirstItem(logFirstItem, "└${kind.orEmpty()}")
            bookContext = bookContext.copy(kind = kind)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取字数")
            val wordCount = runCatching { rule.wordCount?.let { formatWordCount(itemRule.getString(it)) } }.getOrElse { error ->
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                null
            }
            debugSink.logFirstItem(logFirstItem, "└${wordCount.orEmpty()}")
            bookContext = bookContext.copy(wordCount = wordCount)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取最新章节")
            val latestChapter = runCatching { rule.lastChapter?.let { itemRule.getString(it) }?.trim() }.getOrElse { error ->
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                null
            }
            debugSink.logFirstItem(logFirstItem, "└${latestChapter.orEmpty()}")
            bookContext = bookContext.copy(latestChapterTitle = latestChapter)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取简介")
            val intro = runCatching { rule.intro?.let { formatIntro(itemRule.getString(it)) } }.getOrElse { error ->
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                null
            }
            debugSink.logFirstItem(logFirstItem, "└${intro.orEmpty()}")
            bookContext = bookContext.copy(intro = intro)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取封面链接")
            val coverUrl = runCatching {
                rule.coverUrl?.let { itemRule.getStringList(it, isUrl = true).firstOrNull() }
            }.getOrElse { error ->
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                null
            }
            debugSink.logFirstItem(logFirstItem, "└${coverUrl.orEmpty()}")
            bookContext = bookContext.copy(coverUrl = coverUrl)
            itemRule.setBookContext(bookContext)

            coroutineContext.ensureActive()
            debugSink.logFirstItem(logFirstItem, "┌获取详情页链接")
            val bookUrl = try {
                rule.bookUrl?.let { itemRule.getString(it, isUrl = true) }?.takeIf { it.isNotBlank() } ?: baseUrl
            } catch (error: Exception) {
                error.rethrowIfSharedCapability()
                debugSink.logFirstItem(logFirstItem, "└${error.message.orEmpty()}")
                baseUrl
            }
            val resolvedBookUrl = bookUrl.takeIf { it.isNotBlank() } ?: baseUrl
            val effectiveBookUrl = if (resolvedBookUrl == baseUrl) {
                extractWindowOpenUrl(item.toString())?.let { resolveLegacyAbsoluteUrl(baseUrl, it) } ?: resolvedBookUrl
            } else {
                resolvedBookUrl
            }
            debugSink.logFirstItem(logFirstItem, "└$effectiveBookUrl")

            return SearchBook(
                bookUrl = effectiveBookUrl,
                name = name,
                author = author,
                intro = intro,
                coverUrl = coverUrl,
                kind = kind,
                wordCount = wordCount,
                latestChapterTitle = latestChapter,
                tocUrl = "",
                origin = bookSource.bookSourceUrl,
                originName = bookSource.bookSourceName,
                type = getBookType(bookSource),
                originOrder = bookSource.customOrder,
                variable = itemRuleData.getVariables()
                    .takeIf { it.isNotEmpty() }
                    ?.let { searchBookJson.encodeToString(it) }
            ).apply {
                if (baseUrl == effectiveBookUrl) {
                    infoHtml = body
                }
            }
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            null
        }
    }

    private fun extractWindowOpenUrl(text: String): String? {
        return windowOpenRegex.find(text)?.groupValues?.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun BookSourceDebugSink?.logFirstItem(enabled: Boolean, message: String) {
        if (enabled) {
            this?.log(message = message)
        }
    }

    private val searchBookJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    private val nbspRegex = Regex("(&nbsp;)+")
    private val espRegex = Regex("(&ensp;|&emsp;)")
    private val noPrintRegex = Regex("(&thinsp;|&zwnj;|&zwj;|\\u2009|\\u200C|\\u200D)")
    private val wrapHtmlRegex = Regex("</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>")
    private val commentRegex = Regex("<!--[^>]*-->")
    private val otherHtmlRegex = Regex("</?[a-zA-Z]+(?=[ >])[^<>]*>")
    private val indent1Regex = Regex("\\s*\\n+\\s*")
    private val indent2Regex = Regex("^[\\n\\s]+")
    private val lastRegex = Regex("[\\n\\s]+$")
    private val windowOpenRegex = Regex("""window\.open\(\s*['"]([^'"]+)['"]""", RegexOption.IGNORE_CASE)

    private fun formatBookName(name: String): String {
        return BookHelp.formatBookName(name)
    }

    private fun formatBookAuthor(author: String): String {
        return BookHelp.formatBookAuthor(author)
    }

    private fun formatIntro(intro: String): String {
        return intro.replace(nbspRegex, " ")
            .replace(espRegex, " ")
            .replace(noPrintRegex, "")
            .replace(wrapHtmlRegex, "\n")
            .replace(commentRegex, "")
            .replace(otherHtmlRegex, "")
            .replace(indent1Regex, "\n　　")
            .replace(indent2Regex, "　　")
            .replace(lastRegex, "")
    }

    private fun formatWordCount(value: String): String {
        val trimmed = value.trim()
        val words = trimmed.toIntOrNull()
        return when {
            words == null -> trimmed
            words <= 0 -> ""
            else -> formatChineseWordCount(words)
        }
    }

    private fun getBookType(bookSource: BookSource): Int {
        return when (bookSource.bookSourceType) {
            BookSourceType.FILE -> BookType.TEXT or BookType.WEB_FILE
            BookSourceType.IMAGE -> BookType.IMAGE
            BookSourceType.AUDIO -> BookType.AUDIO
            else -> BookType.TEXT
        }
    }

    /**
     * Validate explore JSON configuration for a book source.
     * Aligned with legado BookList.checkExploreJson().
     * W11: checkExploreJson.
     *
     * Checks that the exploreUrl can be parsed as valid JSON with title/url entries.
     * Returns null if valid, or an error message describing the parsing issue.
     *
     * @param bookSource the book source to validate
     * @return null if valid, error message string if invalid
     */
    fun checkExploreJson(bookSource: BookSource): String? {
        val exploreUrl = bookSource.exploreUrl
        if (exploreUrl.isNullOrBlank()) return null
        return try {
            val json = Json { ignoreUnknownKeys = true; isLenient = true }
            val element = json.parseToJsonElement(exploreUrl)
            if (element is kotlinx.serialization.json.JsonArray) {
                // Valid JSON array — check each entry has title
                for (item in element) {
                    if (item is kotlinx.serialization.json.JsonObject) {
                        val title = item["title"]
                        if (title == null) {
                            return "Explore kind missing 'title' field"
                        }
                    }
                }
                null // valid
            } else {
                // Not a JSON array — could be a legacy URL pattern, which is also valid
                null
            }
        } catch (e: Exception) {
            "Explore URL JSON parse error: ${e.message}"
        }
    }
}
