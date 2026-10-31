package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.WebBookChapterContent
import io.legado.kmp.shared.domain.webBook.BookContent
import io.legado.kmp.shared.domain.webBook.BookSourceDebugRawBucket
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.domain.webBook.ChapterContent
import io.legado.kmp.shared.domain.webBook.resolveLegacyAbsoluteUrl
import io.legado.kmp.shared.domain.webBook.rethrowIfSharedCapability
import io.legado.kmp.shared.domain.webBook.webBookParseFailure
import io.legado.kmp.shared.exception.ContentEmptyException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.serializeVariableMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal class WebBookContentLoader(
    private val support: WebBookRequestSupport,
    private val chapterRepository: BookChapterRepository?,
) {

    @Suppress("UNUSED_PARAMETER")
    suspend fun load(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
        needSave: Boolean,
        debugSink: BookSourceDebugSink?,
        nextChapterUrl: String?,
        concurrency: Int,
    ): Result<WebBookChapterContent> {
        return try {
            currentCoroutineContext().ensureActive()
            require(concurrency > 0) { "Content concurrency must be positive" }
            // Content persistence remains at the facade; needSave never controls chapter metadata updates.
            if (source.ruleContent?.content.isNullOrEmpty()) {
                return Result.success(WebBookChapterContent(chapter, chapter.url))
            }
            if (chapter.isVolume && chapter.url.startsWith(chapter.title)) {
                return Result.success(WebBookChapterContent(chapter, chapter.tag.orEmpty()))
            }

            val chapterBoundaryUrl = nextChapterUrl ?: chapterRepository
                ?.getChapter(book.bookUrl, chapter.index + 1)
                ?.url
                ?: chapterRepository?.getChapter(book.bookUrl, 0)?.url
            val variables = ContentVariables(
                support = support,
                chapter = chapter,
                request = support.buildBookVariables(book) + support.buildChapterVariables(chapter),
                runtime = book.variableMap + chapter.variableMap,
            ).also { it.request.putAll(it.runtime) }
            val visitedUrls = linkedSetOf<String>()
            val contentParts = mutableListOf<String>()
            val firstPageBaseUrl = chapter.getAbsoluteURL()
            val firstPage = loadContentPage(
                source = source,
                book = book,
                variables = variables,
                requestUrl = firstPageBaseUrl,
                getNextPageUrls = true,
                chapterBoundaryUrl = chapterBoundaryUrl,
                debugSink = debugSink,
                requestBaseUrl = book.tocUrl,
            )
            val firstPageRedirectUrl = firstPage.redirectUrl
            visitedUrls += firstPageBaseUrl
            visitedUrls += firstPageRedirectUrl
            variables.apply(firstPage.content.variables)
            variables.applyWrites(firstPage.writtenVariables)
            firstPage.content.title
                ?.takeIf { it != variables.chapter.title }
                ?.let { newTitle ->
                    variables.updateTitle(newTitle)
                }
            contentParts += firstPage.content.content
            logPage(debugSink, contentParts.size, firstPage.content)

            when (firstPage.content.nextUrls.size) {
                0 -> Unit
                1 -> {
                    var nextUrl = firstPage.content.nextUrls.first()
                    while (nextUrl.isNotBlank() && visitedUrls.add(nextUrl)) {
                        currentCoroutineContext().ensureActive()
                        if (isChapterBoundary(firstPageRedirectUrl, nextUrl, chapterBoundaryUrl)) break
                        val page = loadContentPage(
                            source = source,
                            book = book,
                            variables = variables,
                            requestUrl = nextUrl,
                            getNextPageUrls = true,
                            chapterBoundaryUrl = chapterBoundaryUrl,
                            debugSink = debugSink,
                        )
                        visitedUrls += page.redirectUrl
                        variables.apply(page.content.variables)
                        variables.applyWrites(page.writtenVariables)
                        contentParts += page.content.content
                        logPage(debugSink, contentParts.size, page.content)
                        nextUrl = page.content.nextUrls.firstOrNull().orEmpty()
                    }
                }

                else -> {
                    if (concurrency == 1) {
                        // Unlike independent workers, serial sources inherit every preceding page's variables.
                        for (nextUrl in firstPage.content.nextUrls) {
                            currentCoroutineContext().ensureActive()
                            if (!visitedUrls.add(nextUrl)) continue
                            if (isChapterBoundary(firstPageRedirectUrl, nextUrl, chapterBoundaryUrl)) continue
                            val page = loadContentPage(
                                source = source,
                                book = book,
                                variables = variables,
                                requestUrl = nextUrl,
                                getNextPageUrls = false,
                                chapterBoundaryUrl = chapterBoundaryUrl,
                                debugSink = debugSink,
                            )
                            visitedUrls += page.redirectUrl
                            variables.apply(page.content.variables)
                            variables.applyWrites(page.writtenVariables)
                            contentParts += page.content.content
                            logPage(debugSink, contentParts.size, page.content)
                        }
                    } else {
                        // Reserve raw rules on the caller, retaining POST options as part of their identity.
                        val nextUrls = firstPage.content.nextUrls.filter { nextUrl ->
                            nextUrl.isNotBlank() && visitedUrls.add(nextUrl) &&
                                !isChapterBoundary(firstPageRedirectUrl, nextUrl, chapterBoundaryUrl)
                        }
                        val seed = variables.copy()
                        val pages = orderedBookPages(nextUrls, concurrency) { nextUrl ->
                            loadContentPage(
                                source = source,
                                book = book,
                                variables = seed.copy(),
                                requestUrl = nextUrl,
                                getNextPageUrls = false,
                                chapterBoundaryUrl = chapterBoundaryUrl,
                                debugSink = debugSink,
                            )
                        }
                        for (page in pages) {
                            currentCoroutineContext().ensureActive()
                            // Full maps include the seed; only explicit writes may override an earlier page.
                            variables.applyWrites(page.writtenVariables)
                            contentParts += page.content.content
                            logPage(debugSink, contentParts.size, page.content)
                        }
                    }
                }
            }

            currentCoroutineContext().ensureActive()
            var content = contentParts.joinToString("\n")
            source.ruleContent?.replaceRegex
                ?.takeIf { it.isNotBlank() }
                ?.let { replaceRegex ->
                    debugSink?.log(message = "\u250c\u5e94\u7528\u6b63\u6587\u66ff\u6362\u89c4\u5219")
                    val beforeLength = content.length
                    content = BookContent.applyJoinedReplaceRegex(
                        replaceRegex = replaceRegex,
                        content = content,
                        bookSource = source,
                        book = book,
                        chapter = variables.chapter,
                        baseUrl = firstPageBaseUrl,
                        redirectUrl = firstPageRedirectUrl,
                        nextChapterUrl = chapterBoundaryUrl,
                        sourceStateStore = support.sourceStateStore,
                        jsExecutor = support.jsExecutor,
                        connectGateway = support.requestExecutor,
                        headerResolver = support.headerResolver,
                        sourceJsRuntime = support.sourceJsRuntime,
                    )
                    debugSink?.log(message = "\u2514\u6b63\u6587\u957f\u5ea6:${beforeLength}->${content.length}")
                }
            currentCoroutineContext().ensureActive()
            if (!variables.chapter.isVolume && content.isBlank()) {
                throw ContentEmptyException(
                    webBookParseFailure(
                        stage = "content.empty",
                        source = source,
                        baseUrl = firstPageRedirectUrl,
                        detail = "parsed content is empty",
                    ).message,
                )
            }
            val updatedChapter = variables.chapter
            if (
                updatedChapter.title != chapter.title ||
                updatedChapter.url != chapter.url ||
                updatedChapter.baseUrl != chapter.baseUrl ||
                updatedChapter.variable != chapter.variable
            ) {
                chapterRepository?.update(updatedChapter)
            }
            currentCoroutineContext().ensureActive()
            debugSink?.log(message = "\u25c7\u672c\u7ae0\u603b\u9875\u6570:${contentParts.size}")
            debugSink?.log(message = "\u25c7\u6b63\u6587\u603b\u957f\u5ea6:${content.length}")
            Result.success(WebBookChapterContent(updatedChapter, content))
        } catch (error: CancellationException) {
            throw error
        } catch (error: PageRequestFailure) {
            currentCoroutineContext().ensureActive()
            Result.failure(error.failure)
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            error.rethrowIfSharedCapability()
            if (error is ContentEmptyException) {
                return Result.failure(error)
            }
            Result.failure(
                webBookParseFailure(
                    stage = "repository.content",
                    source = source,
                    baseUrl = chapter.getAbsoluteURL(),
                    detail = "chapter content request or parsing failed for ${chapter.title}",
                    cause = error,
                ),
            )
        }
    }

    private suspend fun loadContentPage(
        source: BookSource,
        book: Book,
        variables: ContentVariables,
        requestUrl: String,
        getNextPageUrls: Boolean,
        chapterBoundaryUrl: String?,
        debugSink: BookSourceDebugSink?,
        requestBaseUrl: String = "",
    ): ContentPage {
        currentCoroutineContext().ensureActive()
        debugSink?.log(message = "\ufe3e\u52a0\u8f7d\u6b63\u6587\u9875:$requestUrl")
        val analyzeUrl = support.createAnalyzeUrl(
            source = source,
            ruleData = variables.request,
            chapter = variables.chapter,
        )
        support.applySourceVariables(analyzeUrl, source)
        analyzeUrl.setVariables(variables.request)
        val builtRequest = analyzeUrl.build(requestUrl, requestBaseUrl)
        val urlWrites = analyzeUrl.getWrittenVariables()
        variables.apply(urlWrites)
        val contentWebJs = source.ruleContent?.webJs
        val contentSourceRegex = source.ruleContent?.sourceRegex
        val usesContentWebViewFallback =
            (builtRequest.webJs.isNullOrBlank() && !contentWebJs.isNullOrBlank()) ||
                (builtRequest.sourceRegex.isNullOrBlank() && !contentSourceRegex.isNullOrBlank())
        val request = builtRequest.copy(
            useWebView = builtRequest.useWebView || usesContentWebViewFallback,
            webJs = builtRequest.webJs.takeUnless { it.isNullOrBlank() } ?: contentWebJs,
            sourceRegex = builtRequest.sourceRegex.takeUnless { it.isNullOrBlank() } ?: contentSourceRegex,
        )
        val response = support.requestExecutor.executeText(
            request = request,
            source = source,
            defaultHeaders = support.buildHeaders(source, variables.request, request, variables.chapter),
            ruleData = variables.request,
            chapter = variables.chapter,
        ).getOrElse { failure ->
            if (failure is CancellationException) throw failure
            // Returned transport failures were not wrapped as repository parsing errors in the old path.
            throw PageRequestFailure(failure)
        }
        currentCoroutineContext().ensureActive()
        debugSink?.raw(BookSourceDebugRawBucket.CONTENT, response.bodyText)
        val redirectUrl = response.finalUrl.ifBlank { request.url }
        val page = BookContent.getContent(
            bookSource = source,
            book = book,
            chapter = variables.chapter,
            baseUrl = requestUrl,
            redirectUrl = redirectUrl,
            body = response.bodyText,
            nextChapterUrl = chapterBoundaryUrl,
            getNextPageUrls = getNextPageUrls,
            sourceStateStore = support.sourceStateStore,
            jsExecutor = support.jsExecutor,
            connectGateway = support.requestExecutor,
            headerResolver = support.headerResolver,
            sourceJsRuntime = support.sourceJsRuntime,
            runtimeVariables = variables.runtime,
            debugSink = debugSink,
        )
        currentCoroutineContext().ensureActive()
        return ContentPage(
            content = page,
            redirectUrl = redirectUrl,
            writtenVariables = linkedMapOf<String, String?>().apply {
                putAll(urlWrites)
                putAll(page.writtenVariables)
            },
        )
    }

    private fun isChapterBoundary(baseUrl: String, nextUrl: String, chapterBoundaryUrl: String?): Boolean {
        if (chapterBoundaryUrl.isNullOrEmpty()) return false
        return resolveLegacyAbsoluteUrl(baseUrl, nextUrl) == resolveLegacyAbsoluteUrl(baseUrl, chapterBoundaryUrl)
    }

    private fun logPage(debugSink: BookSourceDebugSink?, index: Int, page: ChapterContent) {
        debugSink?.log(message = "\u25c7\u6b63\u6587\u5206\u9875:$index \u957f\u5ea6:${page.content.length} \u4e0b\u4e00\u9875:${page.nextUrls.size}")
    }

    private data class ContentPage(
        val content: ChapterContent,
        val redirectUrl: String,
        val writtenVariables: Map<String, String?>,
    )

    private class PageRequestFailure(val failure: Throwable) : Exception(failure)

    private class ContentVariables(
        private val support: WebBookRequestSupport,
        chapter: BookChapter,
        request: Map<String, Any?>,
        runtime: Map<String, String>,
    ) {
        var chapter = chapter
            private set
        val request = LinkedHashMap(request.mapValues { copyRequestValue(it.value) })
        val runtime = LinkedHashMap(runtime)

        fun copy(): ContentVariables = ContentVariables(support, chapter.copy(), request, runtime)

        fun updateTitle(title: String) {
            chapter = chapter.copy(title = title)
            request.putAll(support.buildChapterVariables(chapter))
        }

        fun apply(variables: Map<String, String>) {
            val changed = variables.filter { (key, value) -> runtime[key] != value }
            if (changed.isEmpty()) return
            runtime.putAll(changed)
            chapter = chapter.copy(
                variable = serializeVariableMap(chapter.variableMap + changed).takeIf { it.isNotEmpty() },
            )
            request.putAll(support.buildChapterVariables(chapter))
            request.putAll(changed)
        }

        fun applyWrites(variables: Map<String, String?>) {
            if (variables.isEmpty()) return
            val chapterVariables = chapter.variableMap.toMutableMap()
            for ((key, value) in variables) {
                if (value == null) {
                    runtime.remove(key)
                    chapterVariables.remove(key)
                } else {
                    runtime[key] = value
                    chapterVariables[key] = value
                }
            }
            chapter = chapter.copy(
                variable = serializeVariableMap(chapterVariables).takeIf { it.isNotEmpty() },
            )
            request.putAll(support.buildChapterVariables(chapter))
            for ((key, value) in variables) {
                if (value == null) request.remove(key) else request[key] = value
            }
        }

        companion object {
            // Request bindings contain nested book/chapter maps; workers must not alias those maps either.
            private fun copyRequestValue(value: Any?): Any? = when (value) {
                is Map<*, *> -> value.entries.associate { it.key to copyRequestValue(it.value) }
                is List<*> -> value.map { copyRequestValue(it) }
                else -> value
            }
        }
    }
}
