package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.serializeVariableMap
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.AnalyzeUrlLegacyContext
import io.legado.kmp.shared.network.BuiltUrl
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore

internal class WebBookRequestSupport(
    val requestExecutor: SourceRequestExecutor,
    val headerResolver: SourceHeaderResolver,
    val sourceStateStore: SourceStateStore,
    val jsExecutor: JsExecutor,
    val sourceJsRuntime: SourceJsRuntime?,
) {
    suspend fun buildHeaders(
        source: BookSource,
        requestVariables: Map<String, Any?>,
        request: BuiltUrl,
        chapter: BookChapter? = null,
    ): Map<String, String> = requestExecutor.resolveSourceHeaders(
        source = source, request = request, includeLoginHeader = true, ruleData = requestVariables, chapter = chapter,
    )

    fun withRequestVariables(book: Book, variables: Map<String, String>, replace: Boolean = false): Book {
        if (variables.isEmpty() && !replace) return book
        val current = book.variableMap
        val merged = if (replace) variables else current + variables
        if (merged == current) return book
        return book.copy(variable = serializeVariableMap(merged)).also {
            it.infoHtml = book.infoHtml
            it.tocHtml = book.tocHtml
            it.downloadUrls = book.downloadUrls
        }
    }

    suspend fun applySourceVariables(analyzeUrl: AnalyzeUrl, source: BookSource) {
        sourceStateStore.getSourceVariableMap(source.bookSourceUrl).forEach { (key, value) ->
            analyzeUrl.setString(key, value)
        }
    }

    fun createAnalyzeUrl(
        source: BookSource,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): AnalyzeUrl = AnalyzeUrl(
        jsExecutor = jsExecutor,
        legacyContext = AnalyzeUrlLegacyContext(
            source = source, sourceStateStore = sourceStateStore, gateway = requestExecutor,
            sourceJsRuntime = sourceJsRuntime, ruleData = ruleData, chapter = chapter,
        ),
    )

    fun buildBookVariables(book: Book): Map<String, Any?> = linkedMapOf(
        "book" to mapOf(
            "bookUrl" to book.bookUrl, "tocUrl" to book.tocUrl, "origin" to book.origin,
            "originName" to book.originName, "name" to book.name, "author" to book.author,
            "kind" to book.kind, "intro" to book.intro, "coverUrl" to book.displayCoverUrl,
            "latestChapterTitle" to book.latestChapterTitle, "totalChapterNum" to book.totalChapterNum,
            "variable" to book.variableMap,
        ),
        "bookUrl" to book.bookUrl, "bookName" to book.name, "bookCoverUrl" to book.displayCoverUrl,
        "bookTotalChapterNum" to book.totalChapterNum, "author" to book.author,
    )

    fun buildChapterVariables(chapter: BookChapter): Map<String, Any?> = linkedMapOf(
        "chapter" to mapOf(
            "url" to chapter.url, "title" to chapter.title, "bookUrl" to chapter.bookUrl,
            "index" to chapter.index, "baseUrl" to chapter.baseUrl, "variable" to chapter.variableMap,
        ),
        "chapterUrl" to chapter.url, "title" to chapter.title, "chapterIndex" to chapter.index,
    )
}
