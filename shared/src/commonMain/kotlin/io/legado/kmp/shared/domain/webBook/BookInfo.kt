package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.content.BookHelp
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.serializeVariableMap
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.util.formatChineseWordCount
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Book info parser
 * Handles book detail page parsing with book source rules
 *
 * Original: legado/app/src/main/java/io/legado/app/model/webBook/BookInfo.kt
 */
object BookInfo {

    private val nbspRegex = Regex("(&nbsp;)+")
    private val espRegex = Regex("(&ensp;|&emsp;)")
    private val noPrintRegex = Regex("(&thinsp;|&zwnj;|&zwj;|\\u2009|\\u200C|\\u200D)")
    private val wrapHtmlRegex = Regex("</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>")
    private val commentRegex = Regex("<!--[^>]*-->")
    private val otherHtmlRegex = Regex("</?[a-zA-Z]+(?=[ >])[^<>]*>")
    private val indent1Regex = Regex("\\s*\\n+\\s*")
    private val indent2Regex = Regex("^[\\n\\s]+")
    private val lastRegex = Regex("[\\n\\s]+$")

    /**
     * Parse book info from HTML/JSON content
     *
     * @param bookSource Book source configuration
     * @param book Current book (with bookUrl set)
     * @param baseUrl Logical detail request URL, including request options
     * @param body HTML/JSON content
     * @param redirectUrl Response URL for resolving relative URLs
     * @return Updated Book with info filled in
     */
    suspend fun getBookInfo(
        bookSource: BookSource,
        book: Book,
        baseUrl: String,
        body: String,
        redirectUrl: String = baseUrl,
        canReName: Boolean = true,
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null,
        debugSink: BookSourceDebugSink? = null
    ): Book {
        if (body.isBlank()) {
            throw webBookParseFailure(
                stage = "detail.body",
                source = bookSource,
                baseUrl = baseUrl,
                detail = "book info body is empty"
            )
        }

        val rule = bookSource.getBookInfoRule()

        val analyzeRule = AnalyzeRule(
            source = bookSource,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        analyzeRule.setContent(body, baseUrl)
        analyzeRule.setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)
        analyzeRule.setBookContext(book)
        book.variableMap.forEach { (key, value) ->
            analyzeRule.put(key, value)
        }
        var bookContext = book

        rule.init?.takeIf { it.isNotBlank() }?.let { initRule ->
            try {
                debugSink?.log(message = "┌详情页预处理")
                analyzeRule.setContent(analyzeRule.getElement(initRule), baseUrl)
                debugSink?.log(message = "└$initRule")
            } catch (error: Exception) {
                error.rethrowIfSharedCapability()
                debugSink?.log(message = "└${error.message.orEmpty()}")
                throw webBookParseFailure(
                    stage = "detail.init",
                    source = bookSource,
                    baseUrl = baseUrl,
                    detail = "detail init rule failed",
                    rule = initRule,
                    cause = error
                )
            }
        }

        val allowRename = canReName && !rule.canReName.isNullOrBlank()

        coroutineContext.ensureActive()
        var name = book.name
        debugSink?.log(message = "┌获取书名")
        val parsedName = try {
            rule.name
                ?.let { analyzeRule.getString(it) }
                ?.let(::formatBookName)
                ?.takeIf { it.isNotEmpty() }
        } catch (error: Exception) {
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            throw error
        }
        if (parsedName != null && (allowRename || name.isEmpty())) {
            name = parsedName
        }
        debugSink?.log(message = "└$name")
        bookContext = bookContext.copy(name = name)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        var author = book.author
        debugSink?.log(message = "┌获取作者")
        val parsedAuthor = try {
            rule.author
                ?.let { analyzeRule.getString(it) }
                ?.let(::formatBookAuthor)
                ?.takeIf { it.isNotEmpty() }
        } catch (error: Exception) {
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            throw error
        }
        if (parsedAuthor != null && (allowRename || author.isEmpty())) {
            author = parsedAuthor
        }
        debugSink?.log(message = "└$author")
        bookContext = bookContext.copy(author = author)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取分类")
        val kind = runCatching {
            rule.kind
                ?.let { analyzeRule.getStringList(it) }
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?.joinToString(",")
                ?.takeIf { it.isNotEmpty() }
        }.getOrElse { error ->
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            null
        } ?: book.kind
        debugSink?.log(message = "└${kind.orEmpty()}")
        bookContext = bookContext.copy(kind = kind)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取字数")
        val wordCount = runCatching {
            rule.wordCount
                ?.let { analyzeRule.getString(it) }
                ?.let(::formatWordCount)
                ?.takeIf { it.isNotEmpty() }
        }.getOrElse { error ->
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            null
        } ?: book.wordCount
        debugSink?.log(message = "└${wordCount.orEmpty()}")
        bookContext = bookContext.copy(wordCount = wordCount)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取最新章节")
        val lastChapter = runCatching {
            rule.lastChapter
                ?.let { analyzeRule.getString(it) }
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
        }.getOrElse { error ->
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            null
        } ?: book.latestChapterTitle
        debugSink?.log(message = "└${lastChapter.orEmpty()}")
        bookContext = bookContext.copy(latestChapterTitle = lastChapter)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取简介")
        val intro = runCatching {
            rule.intro
                ?.let { analyzeRule.getString(it) }
                ?.let(::formatIntro)
                ?.takeIf { it.isNotEmpty() }
        }.getOrElse { error ->
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            null
        } ?: book.intro
        debugSink?.log(message = "└${intro.orEmpty()}")
        bookContext = bookContext.copy(intro = intro)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取封面链接")
        val coverUrl = runCatching {
            rule.coverUrl
                ?.let { analyzeRule.getStringList(it, isUrl = true).firstOrNull() }
        }.getOrElse { error ->
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            null
        } ?: book.coverUrl
        debugSink?.log(message = "└${coverUrl.orEmpty()}")
        bookContext = bookContext.copy(coverUrl = coverUrl)
        analyzeRule.setBookContext(bookContext)

        coroutineContext.ensureActive()
        val resolvedTocUrl = if (!bookSource.isFile) {
            debugSink?.log(message = "┌获取目录链接")
            val tocUrl = try {
                rule.tocUrl
                    ?.let { analyzeRule.getString(it, isUrl = true) }
                    ?.trim()
                    ?.takeIf { it.isNotEmpty() }
                    ?: baseUrl
            } catch (error: Exception) {
                error.rethrowIfSharedCapability()
                debugSink?.log(message = "└${error.message.orEmpty()}")
                throw error
            }
            debugSink?.log(message = "└$tocUrl")
            tocUrl
        } else {
            book.tocUrl
        }

        // Android writes detail-rule variables into the same book used by chapter parsing.
        val variables = book.variableMap + analyzeRule.getVariables()
        val updated = book.copy(
            name = name,
            author = author,
            intro = intro,
            coverUrl = coverUrl,
            kind = kind,
            wordCount = wordCount,
            latestChapterTitle = lastChapter,
            tocUrl = resolvedTocUrl,
            variable = if (variables == book.variableMap) book.variable else serializeVariableMap(variables),
        ).apply {
            // Book.copy omits transient HTML; keep the TOC cache only for the same request.
            infoHtml = book.infoHtml
            tocHtml = book.tocHtml.takeIf { resolvedTocUrl == book.tocUrl }
        }

        if (bookSource.isFile) {
            val downloadUrls = rule.downloadUrls
                ?.let { analyzeRule.getStringList(it, isUrl = true) }
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?.distinct()
                .orEmpty()
            if (downloadUrls.isEmpty()) {
                throw webBookParseFailure(
                    stage = "detail.downloadUrls",
                    source = bookSource,
                    baseUrl = redirectUrl,
                    detail = "download URL is empty",
                    rule = rule.downloadUrls
                )
            }
            updated.downloadUrls = downloadUrls
        } else if (resolvedTocUrl == baseUrl) {
            updated.tocHtml = body
        }

        return updated
    }

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
}
