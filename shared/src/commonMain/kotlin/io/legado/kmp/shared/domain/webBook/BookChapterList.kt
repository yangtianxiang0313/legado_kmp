package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.exception.TocEmptyException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.serializeVariableMap
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.scripting.JsResult
import io.legado.kmp.shared.scripting.SourceJsRuntime
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Book chapter list parser
 * Handles table of contents parsing with book source rules
 *
 * Original: legado/app/src/main/java/io/legado/app/model/webBook/BookChapterList.kt
 */
object BookChapterList {

    data class ParsedChapterPage(
        val chapters: List<BookChapter>,
        val nextUrls: List<String>,
        val reverse: Boolean,
        val formatJs: String?,
        val variables: Map<String, String> = emptyMap()
    )

    suspend fun getChapterList(
        bookSource: BookSource,
        book: Book,
        baseUrl: String,
        body: String,
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null
    ): List<BookChapter> {
        val page = parseChapterPage(
            bookSource = bookSource,
            book = book,
            baseUrl = baseUrl,
            redirectUrl = baseUrl,
            body = body,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime,
            getNextUrls = false
        )
        return finalizeChapterList(
            chapters = page.chapters,
            reverse = page.reverse,
            reverseToc = book.config.reverseToc,
            formatJs = page.formatJs,
            jsExecutor = jsExecutor,
            sourceStateStore = sourceStateStore,
            sourceKey = bookSource.bookSourceUrl
        )
    }

    suspend fun parseChapterPage(
        bookSource: BookSource,
        book: Book,
        baseUrl: String,
        redirectUrl: String,
        body: String,
        sourceStateStore: SourceStateStore? = null,
        jsExecutor: JsExecutor = JsExecutor.Default,
        connectGateway: LegacyJsConnectGateway? = null,
        headerResolver: SourceHeaderResolver? = null,
        sourceJsRuntime: SourceJsRuntime? = null,
        getNextUrls: Boolean = true,
        runtimeVariables: Map<String, String> = emptyMap(),
        debugSink: BookSourceDebugSink? = null,
        debugLog: Boolean = debugSink != null
    ): ParsedChapterPage {
        if (body.isBlank()) {
            return ParsedChapterPage(emptyList(), emptyList(), false, null)
        }

        val logger = debugSink.takeIf { debugLog }
        val rule = bookSource.ruleToc ?: return ParsedChapterPage(emptyList(), emptyList(), false, null)
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
        analyzeRule.setBookContext(book)
        book.variableMap.forEach { (key, value) ->
            analyzeRule.put(key, value)
        }
        runtimeVariables.forEach { (key, value) ->
            analyzeRule.put(key, value)
        }

        var listRule = rule.chapterList?.trim().orEmpty()
        var reverse = false
        if (listRule.startsWith("-")) {
            reverse = true
            listRule = listRule.substring(1)
        }
        if (listRule.startsWith("+")) {
            listRule = listRule.substring(1)
        }

        val nextUrls = if (getNextUrls && !rule.nextTocUrl.isNullOrBlank()) {
            try {
                logger?.log(message = "┌获取目录下一页列表")
                val currentUrl = resolveLegacyAbsoluteUrl(redirectUrl, redirectUrl)
                val urls = analyzeRule.getStringList(rule.nextTocUrl, isUrl = true)
                    .filter { it.isNotBlank() && resolveLegacyAbsoluteUrl(redirectUrl, it) != currentUrl }
                    .distinct()
                logger?.log(message = "└${urls.joinToString()}")
                urls
            } catch (error: Exception) {
                if (error is CancellationException) throw error
                error.rethrowIfSharedCapability()
                logger?.log(message = "└${error.message.orEmpty()}")
                throw webBookParseFailure(
                    stage = "toc.nextPageUrl",
                    source = bookSource,
                    baseUrl = redirectUrl,
                    detail = "failed to parse next toc URLs",
                    rule = rule.nextTocUrl,
                    cause = error
                )
            }
        } else {
            emptyList()
        }

        logger?.log(message = "┌获取目录列表")
        val items = try {
            if (listRule.isBlank()) emptyList() else analyzeRule.getElements(listRule)
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            logger?.log(message = "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.list",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to resolve toc entries",
                rule = listRule,
                cause = error
            )
        }
        logger?.log(message = "└列表大小:${items.size}")
        val chapters = items.mapIndexedNotNull { index, item ->
            parseChapter(
                parentRule = analyzeRule,
                item = item,
                bookSource = bookSource,
                book = book,
                baseUrl = baseUrl,
                redirectUrl = redirectUrl,
                index = index,
                sourceStateStore = sourceStateStore,
                jsExecutor = jsExecutor,
                connectGateway = connectGateway,
                headerResolver = headerResolver,
                sourceJsRuntime = sourceJsRuntime,
                logFirstChapter = index == 0 && debugLog,
                debugSink = debugSink
            )
        }
        logger?.log(message = "└目录列表解析完成")
        chapters.firstOrNull()?.let { firstChapter ->
            logger?.log(message = "≡首章信息")
            logger?.log(message = "◇章节名称:${firstChapter.title}")
            logger?.log(message = "◇章节链接:${firstChapter.url}")
            logger?.log(message = "◇章节信息:${firstChapter.tag.orEmpty()}")
            logger?.log(message = "◇是否VIP:${firstChapter.isVip}")
            logger?.log(message = "◇是否购买:${firstChapter.isPay}")
        }

        return ParsedChapterPage(
            chapters = chapters,
            nextUrls = nextUrls,
            reverse = reverse,
            formatJs = rule.formatJs,
            variables = analyzeRule.getVariables()
        )
    }

    suspend fun finalizeChapterList(
        chapters: List<BookChapter>,
        reverse: Boolean,
        reverseToc: Boolean,
        formatJs: String?,
        jsExecutor: JsExecutor = JsExecutor.Default,
        sourceStateStore: SourceStateStore? = null,
        sourceKey: String? = null
    ): List<BookChapter> {
        val ordered = chapters.toMutableList()
        if (!reverse) {
            ordered.reverse()
        }
        val unique = LinkedHashSet(ordered)
        val deduplicated = unique.toMutableList()
        if (!reverseToc) {
            deduplicated.reverse()
        }

        val indexed = deduplicated.mapIndexed { index, chapter ->
            chapter.copy(index = index)
        }.toMutableList()

        if (!formatJs.isNullOrBlank()) {
            jsExecutor.withMutableContext(mapOf("gInt" to 0)) { context ->
                for (index in indexed.indices) {
                    coroutineContext.ensureActive()
                    val chapter = indexed[index]
                    val chapterBinding = FormatJsChapterBinding(
                        chapter, sourceStateStore, sourceKey, coroutineContext
                    ) { updated ->
                        indexed[index] = updated
                    }
                    val bindings = mapOf(
                        "index" to index + 1,
                        "title" to chapter.title,
                        "chapter" to chapterBinding
                    )
                    // Android keeps object mutations on failure/null, and accepts an empty title.
                    when (val result = context.execute(formatJs, bindings)) {
                        is JsResult.JsError, is JsResult.JsNull, is JsResult.JsUndefined -> Unit
                        else -> chapterBinding.setProperty("title", result.asString())
                    }
                }
            }
        }

        if (indexed.isEmpty()) {
            throw TocEmptyException("Chapter list is empty")
        }

        return indexed
    }

    private suspend fun parseChapter(
        parentRule: AnalyzeRule,
        item: Any,
        bookSource: BookSource,
        book: Book,
        baseUrl: String,
        redirectUrl: String,
        index: Int,
        sourceStateStore: SourceStateStore?,
        jsExecutor: JsExecutor,
        connectGateway: LegacyJsConnectGateway?,
        headerResolver: SourceHeaderResolver?,
        sourceJsRuntime: SourceJsRuntime?,
        logFirstChapter: Boolean = false,
        debugSink: BookSourceDebugSink? = null
    ): BookChapter? {
        val rule = bookSource.ruleToc ?: return null

        val itemRule = AnalyzeRule(
            source = bookSource,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime
        )
        itemRule.setContent(item, baseUrl)
        itemRule.setRedirectUrl(redirectUrl)
        itemRule.setBookContext(book.copy(variable = serializeVariableMap(parentRule.getVariables())))
        itemRule.inheritBookVariableState(parentRule)

        var chapterContext = BookChapter(
            bookUrl = book.bookUrl,
            index = index,
            title = "",
            url = "",
            baseUrl = redirectUrl
        )
        itemRule.setChapterContext(chapterContext)

        coroutineContext.ensureActive()
        debugSink.logFirstChapter(logFirstChapter, "┌获取章节名称")
        val chapterName = try {
            itemRule.getString(rule.chapterName).trim()
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            debugSink.logFirstChapter(logFirstChapter, "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.chapterName",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter title",
                rule = rule.chapterName,
                cause = error
            )
        }
        debugSink.logFirstChapter(logFirstChapter, "└$chapterName")
        chapterContext = chapterContext.copy(title = chapterName)
        itemRule.setChapterContext(chapterContext)
        coroutineContext.ensureActive()
        debugSink.logFirstChapter(logFirstChapter, "┌获取章节链接")
        val rawChapterUrl = try {
            rule.chapterUrl
                ?.takeIf { it.isNotBlank() }
                ?.let { itemRule.getUrlWithoutFallback(it) }
                ?.trim()
                .orEmpty()
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            debugSink.logFirstChapter(logFirstChapter, "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.chapterUrl",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter URL",
                rule = rule.chapterUrl,
                cause = error
            )
        }
        // Variables written while parsing name/URL acquire their durable chapter identity now.
        chapterContext = chapterContext.copy(url = rawChapterUrl)
        itemRule.setChapterContext(chapterContext)
        val updateTime = try {
            rule.updateTime?.let { itemRule.getString(it) }?.trim()?.takeIf { it.isNotEmpty() }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            debugSink.logFirstChapter(logFirstChapter, "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.updateTime",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter update time",
                rule = rule.updateTime,
                cause = error
            )
        }
        val isVolume = try {
            legacyRuleIsTrue(rule.isVolume?.let { itemRule.getString(it) })
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            debugSink.logFirstChapter(logFirstChapter, "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.isVolume",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter volume flag",
                rule = rule.isVolume,
                cause = error
            )
        }
        val resolvedUrl = when {
            rawChapterUrl.isNotBlank() -> rawChapterUrl
            isVolume -> chapterName + index
            else -> baseUrl
        }
        debugSink.logFirstChapter(logFirstChapter, "└$resolvedUrl")
        debugSink.logFirstChapter(logFirstChapter, "┌获取章节信息")
        debugSink.logFirstChapter(logFirstChapter, "└${updateTime.orEmpty()}")
        chapterContext = chapterContext.copy(
            url = resolvedUrl,
            isVolume = isVolume,
            tag = updateTime
        )
        itemRule.setChapterContext(chapterContext)
        // Android skips empty titles only after URL/update-time/volume rules have run.
        if (chapterName.isEmpty()) return null

        val isVip = try {
            debugSink.logFirstChapter(logFirstChapter, "┌获取是否VIP")
            legacyRuleIsTrue(rule.isVip?.let { itemRule.getString(it) })
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            debugSink.logFirstChapter(logFirstChapter, "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.isVip",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter VIP flag",
                rule = rule.isVip,
                cause = error
            )
        }
        debugSink.logFirstChapter(logFirstChapter, "└$isVip")
        val isPay = try {
            debugSink.logFirstChapter(logFirstChapter, "┌获取是否购买")
            legacyRuleIsTrue(rule.isPay?.let { itemRule.getString(it) })
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            debugSink.logFirstChapter(logFirstChapter, "└${error.message.orEmpty()}")
            throw webBookParseFailure(
                stage = "toc.isPay",
                source = bookSource,
                baseUrl = redirectUrl,
                detail = "failed to parse chapter payment flag",
                rule = rule.isPay,
                cause = error
            )
        }
        debugSink.logFirstChapter(logFirstChapter, "└$isPay")

        return BookChapter(
            bookUrl = book.bookUrl,
            index = index,
            title = chapterName,
            url = resolvedUrl,
            baseUrl = redirectUrl,
            isVolume = isVolume,
            isVip = isVip,
            isPay = isPay,
            tag = updateTime,
            variable = itemRule.getVariables()
                .takeIf { it.isNotEmpty() }
                ?.let { bookChapterJson.encodeToString(it) }
        )
    }

    private fun BookSourceDebugSink?.logFirstChapter(enabled: Boolean, message: String) {
        if (enabled) {
            this?.log(message = message)
        }
    }

    private val bookChapterJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }
}
