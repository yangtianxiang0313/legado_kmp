package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.domain.repository.WebBookChapterList
import io.legado.kmp.shared.domain.webBook.BookChapterList
import io.legado.kmp.shared.domain.webBook.BookSourceDebugRawBucket
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.domain.webBook.displayName
import io.legado.kmp.shared.domain.webBook.rethrowIfSharedCapability
import io.legado.kmp.shared.domain.webBook.webBookParseFailure
import io.legado.kmp.shared.exception.TocEmptyException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal class WebBookTocLoader(private val support: WebBookRequestSupport) {

    suspend fun load(
        source: BookSource,
        book: Book,
        debugSink: BookSourceDebugSink?,
        concurrency: Int,
    ): Result<WebBookChapterList> {
        return try {
            require(concurrency > 0) { "TOC concurrency must be positive" }
            currentCoroutineContext().ensureActive()
            val tocUrl = book.tocUrl.ifEmpty { book.bookUrl }
            val variables = TocVariables(support, book, book.variableMap)
            val parsedPages = mutableListOf<BookChapterList.ParsedChapterPage>()

            val firstPage = if (book.bookUrl == tocUrl && !book.tocHtml.isNullOrEmpty()) {
                val body = book.tocHtml.orEmpty()
                debugSink?.raw(BookSourceDebugRawBucket.TOC, body)
                parseChapterPage(
                    source = source,
                    book = book,
                    variables = variables,
                    requestUrl = tocUrl,
                    redirectUrl = tocUrl,
                    body = body,
                    getNextUrls = true,
                    debugSink = debugSink,
                    debugLog = true,
                ).also { variables.apply(it.variables, replace = true) }
            } else {
                loadChapterPage(
                    source = source,
                    book = book,
                    variables = variables,
                    requestUrl = tocUrl,
                    getNextUrls = true,
                    debugSink = debugSink,
                    debugLog = true,
                    requestBaseUrl = book.bookUrl,
                )
            }
            parsedPages += firstPage

            val visitedNextUrls = linkedSetOf<String>()
            when (firstPage.nextUrls.size) {
                0 -> Unit
                1 -> {
                    var nextUrl = firstPage.nextUrls.first()
                    while (nextUrl.isNotBlank() && visitedNextUrls.add(nextUrl)) {
                        currentCoroutineContext().ensureActive()
                        val page = loadChapterPage(
                            source = source,
                            book = book,
                            variables = variables,
                            requestUrl = nextUrl,
                            getNextUrls = true,
                            debugSink = debugSink,
                            debugLog = false,
                        )
                        parsedPages += page
                        nextUrl = page.nextUrls.firstOrNull().orEmpty()
                    }
                }

                else -> {
                    val nextUrls = firstPage.nextUrls.filter { visitedNextUrls.add(it) }
                    if (concurrency == 1) {
                        // Sequential sources can use a previous page's writes to build the next request.
                        for (nextUrl in nextUrls) {
                            currentCoroutineContext().ensureActive()
                            parsedPages += loadChapterPage(
                                source = source,
                                book = book,
                                variables = variables,
                                requestUrl = nextUrl,
                                getNextUrls = false,
                                debugSink = debugSink,
                                debugLog = false,
                            )
                        }
                    } else {
                        val seed = variables.runtime.toMap()
                        val pages = orderedBookPages(nextUrls, concurrency) { nextUrl ->
                            val pageVariables = TocVariables(support, book, seed)
                            loadChapterPage(
                                source = source,
                                book = book,
                                variables = pageVariables,
                                requestUrl = nextUrl,
                                getNextUrls = false,
                                debugSink = debugSink,
                                debugLog = false,
                            )
                        }
                        for (page in pages) {
                            currentCoroutineContext().ensureActive()
                            parsedPages += page
                            variables.applyPageWrites(page.writtenVariables)
                        }
                    }
                }
            }

            currentCoroutineContext().ensureActive()
            val chapters = BookChapterList.finalizeChapterList(
                chapters = parsedPages.flatMap { it.chapters },
                reverse = firstPage.reverse,
                reverseToc = book.config.reverseToc,
                formatJs = firstPage.formatJs,
                jsExecutor = support.jsExecutor,
                sourceStateStore = support.sourceStateStore,
                sourceKey = source.bookSourceUrl,
            )
            currentCoroutineContext().ensureActive()
            debugSink?.log(message = "◇目录页数:${parsedPages.size}")
            debugSink?.log(message = "◇目录总数:${chapters.size}")
            Result.success(
                WebBookChapterList(
                    support.withRequestVariables(book, variables.runtime, replace = true),
                    chapters,
                )
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: PageRequestFailure) {
            currentCoroutineContext().ensureActive()
            error.failure.rethrowIfSharedCapability()
            Result.failure(error.failure)
        } catch (error: Exception) {
            currentCoroutineContext().ensureActive()
            error.rethrowIfSharedCapability()
            if (error is TocEmptyException) {
                return Result.failure(error)
            }
            Result.failure(
                webBookParseFailure(
                    stage = "repository.toc",
                    source = source,
                    baseUrl = book.tocUrl.ifEmpty { book.bookUrl },
                    detail = "chapter list request or parsing failed for ${source.displayName()}",
                    cause = error,
                )
            )
        }
    }

    private suspend fun loadChapterPage(
        source: BookSource,
        book: Book,
        variables: TocVariables,
        requestUrl: String,
        getNextUrls: Boolean,
        debugSink: BookSourceDebugSink?,
        debugLog: Boolean,
        requestBaseUrl: String = "",
    ): BookChapterList.ParsedChapterPage {
        currentCoroutineContext().ensureActive()
        debugSink?.log(message = "︾加载目录页:$requestUrl")
        val analyzeUrl = support.createAnalyzeUrl(source, ruleData = variables.request)
        support.applySourceVariables(analyzeUrl, source)
        analyzeUrl.setVariables(variables.request)
        val request = analyzeUrl.build(requestUrl, requestBaseUrl)
        val urlWrites = analyzeUrl.getWrittenVariables()
        variables.apply(urlWrites)
        val response = support.requestExecutor.executeText(
            request = request,
            source = source,
            defaultHeaders = support.buildHeaders(source, variables.request, request),
            ruleData = variables.request,
        ).getOrElse { error ->
            if (error is CancellationException) throw error
            error.rethrowIfSharedCapability()
            throw PageRequestFailure(error)
        }
        currentCoroutineContext().ensureActive()
        debugSink?.raw(BookSourceDebugRawBucket.TOC, response.bodyText)
        return parseChapterPage(
            source = source,
            book = book,
            variables = variables,
            requestUrl = requestUrl,
            redirectUrl = response.finalUrl.ifBlank { request.url },
            body = response.bodyText,
            getNextUrls = getNextUrls,
            debugSink = debugSink,
            debugLog = debugLog,
        ).let { page ->
            variables.apply(page.variables, replace = true)
            page.copy(writtenVariables = urlWrites + page.writtenVariables)
        }
    }

    private suspend fun parseChapterPage(
        source: BookSource,
        book: Book,
        variables: TocVariables,
        requestUrl: String,
        redirectUrl: String,
        body: String,
        getNextUrls: Boolean,
        debugSink: BookSourceDebugSink?,
        debugLog: Boolean,
    ): BookChapterList.ParsedChapterPage = BookChapterList.parseChapterPage(
        bookSource = source,
        book = support.withRequestVariables(book, variables.runtime, replace = true),
        baseUrl = requestUrl,
        redirectUrl = redirectUrl,
        body = body,
        sourceStateStore = support.sourceStateStore,
        jsExecutor = support.jsExecutor,
        connectGateway = support.requestExecutor,
        headerResolver = support.headerResolver,
        sourceJsRuntime = support.sourceJsRuntime,
        getNextUrls = getNextUrls,
        runtimeVariables = variables.runtime,
        debugSink = debugSink,
        debugLog = debugLog,
    )

    private class TocVariables(
        private val support: WebBookRequestSupport,
        private val book: Book,
        seed: Map<String, String>,
    ) {
        val runtime = linkedMapOf<String, String>().apply { putAll(seed) }
        val request = support.buildBookVariables(book).toMutableMap().apply { putAll(runtime) }

        fun apply(variables: Map<String, String>, replace: Boolean = false) {
            if (variables.isEmpty() && !replace) return
            if (replace) {
                runtime.keys.forEach { request.remove(it) }
                runtime.clear()
                request.putAll(support.buildBookVariables(book))
            }
            runtime.putAll(variables)
            request.putAll(variables)
        }

        fun applyPageWrites(writes: Map<String, String?>) {
            val merged = runtime.toMutableMap()
            for ((key, value) in writes) {
                if (value == null) merged.remove(key) else merged[key] = value
            }
            apply(merged, replace = true)
        }
    }

    private class PageRequestFailure(val failure: Throwable) : Exception(failure)
}
