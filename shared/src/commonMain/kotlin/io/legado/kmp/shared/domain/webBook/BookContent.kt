package io.legado.kmp.shared.domain.webBook

import com.fleeksoft.ksoup.nodes.Element
import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.content.BookImageMarkup
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.util.unescapeHtml4
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Book content parser result
 */
data class ChapterContent(
    val content: String,
    val nextUrls: List<String> = emptyList(),
    val title: String? = null,
    val variables: Map<String, String> = emptyMap()
)

/**
 * Book content parser
 * Handles chapter content parsing with book source rules
 *
 * Original: legado/app/src/main/java/io/legado/app/model/webBook/BookContent.kt
 */
object BookContent {

    /**
     * Parse a single chapter content fragment from HTML/JSON content
     *
     * @param bookSource Book source configuration
     * @param book Book info
     * @param chapter Chapter info
     * @param baseUrl Base URL for resolving relative URLs
     * @param body HTML/JSON content
     * @param nextChapterUrl Next chapter URL for reference
     * @return ChapterContent with a possibly empty fragment and next-page URLs
     */
    suspend fun getContent(
        bookSource: BookSource,
        book: Book,
        chapter: BookChapter,
        baseUrl: String,
        body: String,
        redirectUrl: String = baseUrl,
        nextChapterUrl: String? = null,
        getNextPageUrls: Boolean = true,
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null,
        runtimeVariables: Map<String, String> = emptyMap(),
        debugSink: BookSourceDebugSink? = null
    ): ChapterContent {
        if (body.isBlank()) {
            return ChapterContent("")
        }

        val rule = bookSource.ruleContent ?: return ChapterContent(body)

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
        analyzeRule.setChapterContext(chapter)
        book.variableMap.forEach { (key, value) -> analyzeRule.put(key, value) }
        chapter.variableMap.forEach { (key, value) -> analyzeRule.put(key, value) }
        runtimeVariables.forEach { (key, value) -> analyzeRule.put(key, value) }
        analyzeRule.setNextChapterUrl(nextChapterUrl?.takeIf { it.isNotBlank() })

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取章节名称")
        val title = runCatching {
            rule.title
                ?.takeIf { it.isNotBlank() }
                ?.let { analyzeRule.getString(it) }
                ?.trim()
                ?.takeIf { it.isNotEmpty() }
        }.getOrElse { error ->
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            null
        }
        debugSink?.log(message = "└${title ?: chapter.title}")

        val contentRule = rule.content ?: return ChapterContent(
            content = body,
            title = title,
            variables = analyzeRule.getVariables()
        )

        coroutineContext.ensureActive()
        debugSink?.log(message = "┌获取正文内容")
        var content = try {
            analyzeRule.getString(contentRule, unescape = false)
        } catch (error: Exception) {
            error.rethrowIfSharedCapability()
            debugSink?.log(message = "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "content.body",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter content",
                rule = contentRule,
                cause = error
            )
        }
        val requestContext = coroutineContext
        content = formatContent(content, redirectUrl) { requestContext.ensureActive() }
        debugSink?.log(message = "└${content.previewForDebug()}")

        val nextUrls = if (getNextPageUrls) {
            rule.nextContentUrl
                ?.takeIf { it.isNotBlank() }
                ?.let { nextRule ->
                    try {
                        debugSink?.log(message = "┌获取正文下一页")
                        val resolvedNextChapterUrl = nextChapterUrl
                            ?.takeIf { it.isNotBlank() }
                            ?.let { resolveLegacyAbsoluteUrl(redirectUrl, it) }
                        val resolvedCurrentUrl = resolveLegacyAbsoluteUrl(redirectUrl, redirectUrl)
                        val urls = analyzeRule.getStringList(nextRule, isUrl = true)
                            .filter { it.isNotBlank() }
                            .filterNot { candidate ->
                                resolveLegacyAbsoluteUrl(redirectUrl, candidate) == resolvedCurrentUrl
                            }
                            .filterNot { candidate ->
                                resolvedNextChapterUrl != null &&
                                        resolveLegacyAbsoluteUrl(redirectUrl, candidate) == resolvedNextChapterUrl
                            }
                            .distinct()
                        debugSink?.log(message = "└${urls.joinToString()}")
                        urls
                    } catch (error: Exception) {
                        error.rethrowIfSharedCapability()
                        debugSink?.log(message = "└${error.message.orEmpty()}")
                        throw webBookParseFailure(
                            stage = "content.nextPageUrl",
                            source = bookSource,
                            baseUrl = redirectUrl,
                            detail = "failed to parse next content URLs",
                            rule = nextRule,
                            cause = error
                        )
                    }
                }
                .orEmpty()
        } else {
            emptyList()
        }

        return ChapterContent(
            content = content,
            nextUrls = nextUrls,
            title = title,
            variables = analyzeRule.getVariables()
        )
    }

    private fun String.previewForDebug(limit: Int = 500): String {
        val normalized = replace("\r\n", "\n")
            .replace('\r', '\n')
            .trim()
        return if (normalized.length <= limit) {
            normalized
        } else {
            normalized.take(limit) + "..."
        }
    }

    suspend fun getPayAction(
        bookSource: BookSource,
        book: Book,
        chapter: BookChapter,
        loginHeader: String? = null,
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null
    ): String {
        val payAction = bookSource.ruleContent?.payAction?.takeIf { it.isNotBlank() }
            ?: error("no pay action")
        val analyzeRule = AnalyzeRule(
            source = bookSource,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        analyzeRule.setContent(chapter.url.ifBlank { book.bookUrl }, chapter.getAbsoluteURL())
        analyzeRule.setBookContext(book)
        analyzeRule.setChapterContext(chapter)
        book.variableMap.forEach { (key, value) -> analyzeRule.put(key, value) }
        chapter.variableMap.forEach { (key, value) -> analyzeRule.put(key, value) }
        analyzeRule.put("bookName", book.name)
        analyzeRule.put("bookCoverUrl", book.displayCoverUrl)
        analyzeRule.put("bookTotalChapterNum", book.totalChapterNum.toString())
        analyzeRule.put("chapterIndex", chapter.index.toString())
        analyzeRule.put("chapterTitle", chapter.title)
        analyzeRule.put("chapterUrl", chapter.url)
        analyzeRule.put(
            "loginHeader",
            sourceStateStore?.getLoginHeader(bookSource.bookSourceUrl) ?: loginHeader
        )
        val trimmedPayAction = payAction.trim()
        return when {
            trimmedPayAction.startsWith("@js:", ignoreCase = true)
                    || trimmedPayAction.startsWith("<js>", ignoreCase = true) -> {
                analyzeRule.getString(trimmedPayAction)
            }

            trimmedPayAction.contains("{{") && trimmedPayAction.contains("}}") -> {
                resolveInlineJsTemplate(trimmedPayAction, analyzeRule)
            }

            else -> {
                analyzeRule.getString("@js:$trimmedPayAction")
            }
        }
    }

    internal suspend fun applyJoinedReplaceRegex(
        replaceRegex: String,
        content: String,
        bookSource: BookSource,
        book: Book,
        chapter: BookChapter,
        baseUrl: String,
        redirectUrl: String = baseUrl,
        nextChapterUrl: String? = null,
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null
    ): String {
        val analyzeRule = AnalyzeRule(
            source = bookSource,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        analyzeRule.setContent(content, baseUrl)
        analyzeRule.setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)
        analyzeRule.setBookContext(book)
        analyzeRule.setChapterContext(chapter)
        book.variableMap.forEach { (key, value) -> analyzeRule.put(key, value) }
        chapter.variableMap.forEach { (key, value) -> analyzeRule.put(key, value) }
        analyzeRule.setNextChapterUrl(nextChapterUrl?.takeIf { it.isNotBlank() })
        return applyReplaceRegex(
            replaceRegex = replaceRegex,
            content = content,
            analyzeRule = analyzeRule
        )
    }

    private suspend fun resolveInlineJsTemplate(
        template: String,
        analyzeRule: AnalyzeRule
    ): String {
        val result = StringBuilder()
        var index = 0
        while (index < template.length) {
            val start = template.indexOf("{{", index)
            if (start < 0) break
            val end = findInlineJsTemplateEnd(template, start + 2)
            if (end < 0) break
            result.append(template, index, start)
            val jsExpression = template.substring(start + 2, end).trim()
            val replacement = analyzeRule.getString("@js:$jsExpression")
            result.append(replacement)
            index = end + 2
        }
        result.append(template.substring(index))
        return result.toString()
    }

    private fun findInlineJsTemplateEnd(template: String, startIndex: Int): Int {
        var index = startIndex
        var quote: Char? = null
        var escaped = false
        var depth = 0
        var inLineComment = false
        var inBlockComment = false
        var inRegex = false
        var inRegexCharClass = false
        var previousSignificant: Char? = null
        while (index < template.length) {
            val char = template[index]
            if (inLineComment) {
                if (char == '\n' || char == '\r') inLineComment = false
                index++
                continue
            }
            if (inBlockComment) {
                if (char == '*' && index + 1 < template.length && template[index + 1] == '/') {
                    inBlockComment = false
                    index += 2
                } else {
                    index++
                }
                continue
            }
            if (escaped) {
                escaped = false
                index++
                continue
            }
            if (quote != null) {
                if (char == '\\') {
                    escaped = true
                } else if (char == quote) {
                    previousSignificant = quote
                    quote = null
                }
                index++
                continue
            }
            if (inRegex) {
                when {
                    char == '\\' -> escaped = true
                    char == '[' -> inRegexCharClass = true
                    char == ']' -> inRegexCharClass = false
                    char == '/' && !inRegexCharClass -> {
                        inRegex = false
                        previousSignificant = '/'
                    }
                }
                index++
                continue
            }
            if (char == '/' && index + 1 < template.length) {
                when (template[index + 1]) {
                    '/' -> {
                        inLineComment = true
                        index += 2
                        continue
                    }
                    '*' -> {
                        inBlockComment = true
                        index += 2
                        continue
                    }
                }
            }
            if (char == '/' && shouldStartInlineRegex(previousSignificant)) {
                inRegex = true
                inRegexCharClass = false
                index++
                continue
            }
            when (char) {
                '\'', '"', '`' -> quote = char
                '(', '[', '{' -> depth++
                ')', ']', '}' -> {
                    if (char == '}' && index + 1 < template.length &&
                        template[index + 1] == '}' && depth == 0
                    ) {
                        return index
                    }
                    if (depth > 0) depth--
                }
            }
            if (!char.isWhitespace()) previousSignificant = char
            index++
        }
        return -1
    }

    private fun shouldStartInlineRegex(previousSignificant: Char?): Boolean {
        return when (previousSignificant) {
            null,
            '(', '[', '{', ',', ';', ':', '=', '!', '?',
            '+', '-', '*', '%', '&', '|', '^', '~', '<', '>' -> true
            else -> false
        }
    }

    /**
     * Apply replaceRegex to content.
     * Aligned with original: splits by LFRegex, trims each line, joins, then
     * applies analyzeRule.getString(replaceRegex, contentStr), then re-indents.
     */
    private suspend fun applyReplaceRegex(
        replaceRegex: String,
        content: String,
        analyzeRule: AnalyzeRule
    ): String {
        val normalized = content
            .lines()
            .joinToString("\n") { it.trim() }
        val replacedByRule = analyzeRule.getString(replaceRegex, normalized)
        val replaced = if (replacedByRule == normalized) {
            applySingleColonReplaceFallback(replaceRegex, normalized) ?: replacedByRule
        } else {
            replacedByRule
        }
        return replaced
            .lines()
            .filter { it.isNotBlank() }
            .joinToString("\n") { "\u3000\u3000$it" }
    }

    /**
     * Compatibility fallback for replaceRegex values using legacy one-segment form:
     * `##pattern:replacement`.
     */
    private fun applySingleColonReplaceFallback(rule: String, content: String): String? {
        if (!rule.startsWith("##")) return null
        val payload = rule.removePrefix("##")
        if (payload.isBlank() || payload.contains("##")) return null
        val separator = payload.indexOf(':')
        if (separator <= 0) return null
        val pattern = payload.substring(0, separator)
        val replacement = payload.substring(separator + 1)
        return runCatching { content.replace(Regex(pattern), replacement) }
            .getOrElse { content.replace(pattern, replacement) }
    }

    /**
     * Format content text
     * - Remove excessive whitespace
     * - Normalize paragraphs
     * - Handle common formatting issues
     */
    private fun formatContent(content: String, redirectUrl: String, checkActive: () -> Unit): String {
        if (content.isBlank()) {
            return ""
        }

        // Canonical attributes protect URL options from text formatting and retain one entity-decoding step.
        val images = BookImageMarkup.images(content, checkActive)
        val normalizedImages = if (images.isEmpty()) content else buildString(content.length) {
            var cursor = 0
            for (image in images) {
                checkActive()
                append(content, cursor, image.range.first)
                val element = Element("img").attr("src", BookImageMarkup.absoluteSource(image.source, redirectUrl))
                image.alt?.let { element.attr("alt", it) }
                append(element.outerHtml().replace("\r", "&#13;").replace("\n", "&#10;").replace("\t", "&#9;"))
                cursor = image.range.last + 1
            }
            append(content, cursor, content.length)
        }
        checkActive()
        val formatted = normalizedImages
            .replace(Regex("(&nbsp;)+"), " ")
            .replace(Regex("&ensp;|&emsp;"), " ")
            .replace(Regex("&thinsp;|&zwnj;|&zwj;"), "")
            .replace(Regex("(?i)<br\\s*/?>"), "\n")
            .replace(Regex("(?i)</?(div|p|article|dd|dl|h\\d|hr)[^>]*>"), "\n")
            .replace(Regex("<!--[\\s\\S]*?-->"), "")
            .replace(Regex("(?i)</?(?!img\\b)[a-zA-Z]+(?=[ >])[^<>]*>"), "")
            // Normalize line endings
            .replace("\r\n", "\n")
            .replace("\r", "\n")
            // Remove excessive blank lines
            .replace(Regex("\n{3,}"), "\n\n")
            // Remove leading/trailing whitespace from lines
            .lines()
            .joinToString("\n") { it.trim() }
            // Remove leading/trailing whitespace from content
            .trim()
        // Text entities are display text; attribute entities must survive until the image consumer parses them.
        val formattedImages = BookImageMarkup.images(formatted, checkActive)
        if (formattedImages.isEmpty()) return unescapeHtml4(formatted)
        return buildString(formatted.length) {
            var cursor = 0
            for (image in formattedImages) {
                checkActive()
                append(unescapeHtml4(formatted.substring(cursor, image.range.first)))
                append(formatted, image.range.first, image.range.last + 1)
                cursor = image.range.last + 1
            }
            append(unescapeHtml4(formatted.substring(cursor)))
        }
    }
}
