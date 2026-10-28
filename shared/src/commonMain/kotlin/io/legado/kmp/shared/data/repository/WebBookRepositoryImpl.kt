package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.domain.webBook.BookChapterList
import io.legado.kmp.shared.domain.webBook.BookContent
import io.legado.kmp.shared.domain.webBook.BookInfo
import io.legado.kmp.shared.domain.webBook.BookList
import io.legado.kmp.shared.domain.webBook.BookSourceDebugRawBucket
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.domain.webBook.ChapterContent
import io.legado.kmp.shared.domain.webBook.displayName
import io.legado.kmp.shared.domain.webBook.resolveLegacyAbsoluteUrl
import io.legado.kmp.shared.domain.webBook.rethrowIfSharedCapability
import io.legado.kmp.shared.domain.webBook.webBookParseFailure
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.WebBookChapterList
import io.legado.kmp.shared.domain.repository.WebBookChapterContent
import io.legado.kmp.shared.exception.ContentEmptyException
import io.legado.kmp.shared.exception.TocEmptyException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourceType
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.serializeVariableMap
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.AnalyzeUrlLegacyContext
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.network.SourceRequestResult
import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore

/**
 * WebBook repository implementation
 * Handles network book operations: search, explore, book info, chapters, content
 *
 * Uses AnalyzeRule for rule-based parsing with BookSource rules
 */
class WebBookRepositoryImpl(
    private val requestExecutor: SourceRequestExecutor,
    private val headerResolver: SourceHeaderResolver,
    private val sourceStateStore: SourceStateStore,
    private val jsExecutor: JsExecutor = JsExecutor.Default,
    private val chapterRepository: BookChapterRepository? = null,
    private val sourceJsRuntime: SourceJsRuntime? = null
) : WebBookRepository {

    override suspend fun searchBook(
        source: BookSource,
        keyword: String,
        page: Int?,
        filter: ((name: String, author: String) -> Boolean)?,
        shouldBreak: ((size: Int) -> Boolean)?,
        debugSink: BookSourceDebugSink?,
    ): Result<List<SearchBook>> {
        return try {
            val searchUrl = source.searchUrl
            if (searchUrl.isNullOrBlank()) {
                return Result.failure(Exception("Search URL is empty"))
            }

            val requestPage = page ?: 1
            val requestVariables = linkedMapOf<String, Any?>(
                "key" to keyword,
                "searchKey" to keyword,
                "page" to requestPage,
                "searchPage" to requestPage
            )
            val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
            applySourceVariables(analyzeUrl, source)
            analyzeUrl.set("key", keyword)
            analyzeUrl.set("searchKey", keyword)
            analyzeUrl.set("page", requestPage)
            analyzeUrl.set("searchPage", requestPage)

            val builtRequest = analyzeUrl.build(searchUrl, source.bookSourceUrl)
            requestVariables.putAll(analyzeUrl.getWrittenVariables())
            val result = requestExecutor.executeText(
                request = builtRequest,
                source = source,
                defaultHeaders = buildHeaders(source, requestVariables, builtRequest),
                ruleData = requestVariables
            )

            result.fold(
                onSuccess = { response ->
                    debugSink?.raw(BookSourceDebugRawBucket.SEARCH, response.bodyText)
                    val books = BookList.analyzeBookList(
                        bookSource = source,
                        baseUrl = response.finalUrl.ifBlank { builtRequest.url },
                        body = response.bodyText,
                        isSearch = true,
                        initialVariables = requestVariables,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime,
                        filter = filter,
                        shouldBreak = shouldBreak,
                        debugSink = debugSink
                    )
                    Result.success(books)
                },
                onFailure = { error ->
                    Result.failure(error)
                }
            )
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            Result.failure(
                webBookParseFailure(
                    stage = "repository.search",
                    source = source,
                    baseUrl = source.bookSourceUrl,
                    detail = "search request or parsing failed for keyword=$keyword page=${page ?: 1}",
                    cause = e
                )
            )
        }
    }

    override suspend fun exploreBook(
        source: BookSource,
        exploreUrl: String,
        page: Int?,
        debugSink: BookSourceDebugSink?,
    ): Result<List<SearchBook>> {
        return try {
            val requestVariables = linkedMapOf<String, Any?>("page" to page).apply {
                if (page != null) put("searchPage", page)
            }
            val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
            applySourceVariables(analyzeUrl, source)
            page?.let { analyzeUrl.set("page", it) }
            page?.let { analyzeUrl.set("searchPage", it) }

            val builtRequest = analyzeUrl.build(exploreUrl, source.bookSourceUrl)
            requestVariables.putAll(analyzeUrl.getWrittenVariables())
            val result = requestExecutor.executeText(
                request = builtRequest,
                source = source,
                defaultHeaders = buildHeaders(source, requestVariables, builtRequest),
                ruleData = requestVariables
            )

            result.fold(
                onSuccess = { response ->
                    debugSink?.raw(BookSourceDebugRawBucket.SEARCH, response.bodyText)
                    val books = BookList.analyzeBookList(
                        bookSource = source,
                        baseUrl = response.finalUrl.ifBlank { builtRequest.url },
                        body = response.bodyText,
                        isSearch = false,
                        initialVariables = requestVariables,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime,
                        debugSink = debugSink
                    )
                    Result.success(books)
                },
                onFailure = { error ->
                    Result.failure(error)
                }
            )
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            Result.failure(
                webBookParseFailure(
                    stage = "repository.explore",
                    source = source,
                    baseUrl = exploreUrl,
                    detail = "explore request or parsing failed",
                    cause = e
                )
            )
        }
    }

    override suspend fun getBookInfo(
        source: BookSource,
        bookUrl: String,
        debugSink: BookSourceDebugSink?,
    ): Result<Book> {
        return try {
            val requestVariables = linkedMapOf<String, Any?>(
                "bookUrl" to bookUrl
            )
            val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
            applySourceVariables(analyzeUrl, source)
            val request = analyzeUrl.build(bookUrl, source.bookSourceUrl)
            requestVariables.putAll(analyzeUrl.getWrittenVariables())
            val result = requestExecutor.executeText(
                request = request,
                source = source,
                defaultHeaders = buildHeaders(source, requestVariables, request),
                ruleData = requestVariables
            )

            result.fold(
                onSuccess = { response ->
                    debugSink?.raw(BookSourceDebugRawBucket.DETAIL, response.bodyText)
                    val initialBook = Book(
                        bookUrl = bookUrl,
                        origin = source.bookSourceUrl,
                        originName = source.bookSourceName,
                        type = when (source.bookSourceType) {
                            BookSourceType.FILE -> BookType.TEXT or BookType.WEB_FILE
                            BookSourceType.IMAGE -> BookType.IMAGE
                            BookSourceType.AUDIO -> BookType.AUDIO
                            else -> BookType.TEXT
                        }
                    ).withRequestVariables(analyzeUrl.getWrittenVariables())

                    // Check for redirect and log debug info
                    checkRedirect(source, response, request.url)

                    val updatedBook = BookInfo.getBookInfo(
                        bookSource = source,
                        book = initialBook,
                        baseUrl = bookUrl,
                        body = response.bodyText,
                        redirectUrl = response.finalUrl.ifBlank { request.url },
                        canReName = true,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime,
                        debugSink = debugSink
                    )

                    Result.success(updatedBook)
                },
                onFailure = { error ->
                    Result.failure(error)
                }
            )
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            Result.failure(
                webBookParseFailure(
                    stage = "repository.detail",
                    source = source,
                    baseUrl = bookUrl,
                    detail = "book detail request or parsing failed",
                    cause = e
                )
            )
        }
    }

    /**
     * Get book info with infoHtml short-circuit support.
     *
     * Aligned with legado WebBook.getBookInfoAwait():
     * When book.infoHtml is not empty, parse it directly without network request.
     */
    override suspend fun getBookInfo(
        source: BookSource,
        book: Book,
        canReName: Boolean,
        debugSink: BookSourceDebugSink?,
    ): Result<Book> {
        return try {
            if (!book.infoHtml.isNullOrEmpty()) {
                debugSink?.raw(BookSourceDebugRawBucket.DETAIL, book.infoHtml.orEmpty())
                // Short-circuit: use cached infoHtml from search results
                val updatedBook = BookInfo.getBookInfo(
                    bookSource = source,
                    book = book,
                    baseUrl = book.bookUrl,
                    body = book.infoHtml.orEmpty(),
                    redirectUrl = book.bookUrl,
                    canReName = canReName,
                    sourceStateStore = sourceStateStore,
                    jsExecutor = jsExecutor,
                    connectGateway = requestExecutor,
                    headerResolver = headerResolver,
                    sourceJsRuntime = sourceJsRuntime,
                    debugSink = debugSink
                )
                return Result.success(updatedBook)
            }

            // No cached infoHtml, fetch from network
            val requestVariables = buildBookVariables(book).toMutableMap().apply { putAll(book.variableMap) }
            val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
            applySourceVariables(analyzeUrl, source)
            analyzeUrl.setVariables(requestVariables)
            val request = analyzeUrl.build(book.bookUrl, source.bookSourceUrl)
            requestVariables.putAll(analyzeUrl.getWrittenVariables())
            val result = requestExecutor.executeText(
                request = request,
                source = source,
                defaultHeaders = buildHeaders(source, requestVariables, request),
                ruleData = requestVariables
            )

            result.fold(
                onSuccess = { response ->
                    debugSink?.raw(BookSourceDebugRawBucket.DETAIL, response.bodyText)
                    checkRedirect(source, response, request.url)

                    val updatedBook = BookInfo.getBookInfo(
                        bookSource = source,
                        book = book.withRequestVariables(analyzeUrl.getWrittenVariables()),
                        baseUrl = book.bookUrl,
                        body = response.bodyText,
                        redirectUrl = response.finalUrl.ifBlank { request.url },
                        canReName = canReName,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime,
                        debugSink = debugSink
                    )

                    Result.success(updatedBook)
                },
                onFailure = { error ->
                    Result.failure(error)
                }
            )
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            Result.failure(
                webBookParseFailure(
                    stage = "repository.detail",
                    source = source,
                    baseUrl = book.bookUrl,
                    detail = "book detail request or parsing failed",
                    cause = e
                )
            )
        }
    }

    override suspend fun getChapterList(
        source: BookSource,
        book: Book,
        debugSink: BookSourceDebugSink?,
    ): Result<List<BookChapter>> = getChapterListWithBook(source, book, debugSink).map { it.chapters }

    override suspend fun getChapterListWithBook(
        source: BookSource,
        book: Book,
        debugSink: BookSourceDebugSink?,
    ): Result<WebBookChapterList> {
        return try {
            val tocUrl = book.tocUrl.ifEmpty { book.bookUrl }
            val tocRuntimeVariables = linkedMapOf<String, String>().apply {
                putAll(book.variableMap)
            }
            val requestVariables = buildBookVariables(book).toMutableMap().apply {
                putAll(tocRuntimeVariables)
            }
            val parsedPages = mutableListOf<BookChapterList.ParsedChapterPage>()

            fun applyTocVariables(variables: Map<String, String>, replace: Boolean = false) {
                if (variables.isEmpty() && !replace) return
                if (replace) {
                    tocRuntimeVariables.keys.forEach { requestVariables.remove(it) }
                    tocRuntimeVariables.clear()
                    requestVariables.putAll(buildBookVariables(book))
                }
                tocRuntimeVariables.putAll(variables)
                requestVariables.putAll(variables)
            }

            suspend fun loadChapterPage(
                requestUrl: String,
                getNextUrls: Boolean,
                debugLog: Boolean,
                requestBaseUrl: String = ""
            ): Result<BookChapterList.ParsedChapterPage> {
                debugSink?.log(message = "︾加载目录页:$requestUrl")
                val analyzeUrl = createAnalyzeUrl(source, ruleData = requestVariables)
                applySourceVariables(analyzeUrl, source)
                analyzeUrl.setVariables(requestVariables)
                val request = analyzeUrl.build(requestUrl, requestBaseUrl)
                applyTocVariables(analyzeUrl.getWrittenVariables())
                return requestExecutor.executeText(
                    request = request,
                    source = source,
                    defaultHeaders = buildHeaders(source, requestVariables, request),
                    ruleData = requestVariables
                ).map { response ->
                    debugSink?.raw(BookSourceDebugRawBucket.TOC, response.bodyText)
                    BookChapterList.parseChapterPage(
                        bookSource = source,
                        book = book.withRequestVariables(tocRuntimeVariables, replace = true),
                        baseUrl = requestUrl,
                        redirectUrl = response.finalUrl.ifBlank { request.url },
                        body = response.bodyText,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime,
                        getNextUrls = getNextUrls,
                        runtimeVariables = tocRuntimeVariables,
                        debugSink = debugSink,
                        debugLog = debugLog
                    )
                }
            }

            if (book.bookUrl == tocUrl && !book.tocHtml.isNullOrEmpty()) {
                debugSink?.raw(BookSourceDebugRawBucket.TOC, book.tocHtml.orEmpty())
                parsedPages += BookChapterList.parseChapterPage(
                    bookSource = source,
                    book = book.withRequestVariables(tocRuntimeVariables, replace = true),
                    baseUrl = tocUrl,
                    redirectUrl = tocUrl,
                    body = book.tocHtml.orEmpty(),
                    sourceStateStore = sourceStateStore,
                    jsExecutor = jsExecutor,
                    connectGateway = requestExecutor,
                    headerResolver = headerResolver,
                    sourceJsRuntime = sourceJsRuntime,
                    getNextUrls = true,
                    runtimeVariables = tocRuntimeVariables,
                    debugSink = debugSink,
                    debugLog = true
                ).also { applyTocVariables(it.variables, replace = true) }
            } else {
                loadChapterPage(
                    tocUrl,
                    getNextUrls = true,
                    debugLog = true,
                    requestBaseUrl = book.bookUrl
                ).fold(
                    onSuccess = {
                        parsedPages += it
                        applyTocVariables(it.variables, replace = true)
                    },
                    onFailure = { return Result.failure(it) }
                )
            }

            val visitedNextUrls = linkedSetOf<String>()
            val firstPage = parsedPages.first()
            when (firstPage.nextUrls.size) {
                0 -> Unit
                1 -> {
                    var nextUrl = firstPage.nextUrls.first()
                    while (nextUrl.isNotBlank() && visitedNextUrls.add(nextUrl)) {
                        loadChapterPage(nextUrl, getNextUrls = true, debugLog = false).fold(
                            onSuccess = {
                                parsedPages += it
                                applyTocVariables(it.variables, replace = true)
                                nextUrl = it.nextUrls.firstOrNull().orEmpty()
                            },
                            onFailure = { return Result.failure(it) }
                        )
                    }
                }

                else -> {
                    for (nextUrl in firstPage.nextUrls) {
                        if (!visitedNextUrls.add(nextUrl)) continue
                        loadChapterPage(nextUrl, getNextUrls = false, debugLog = false).fold(
                            onSuccess = {
                                parsedPages += it
                                applyTocVariables(it.variables, replace = true)
                            },
                            onFailure = { return Result.failure(it) }
                        )
                    }
                }
            }

            val chapters = BookChapterList.finalizeChapterList(
                chapters = parsedPages.flatMap { it.chapters },
                reverse = firstPage.reverse,
                reverseToc = book.config.reverseToc,
                formatJs = firstPage.formatJs,
                jsExecutor = jsExecutor,
                sourceStateStore = sourceStateStore,
                sourceKey = source.bookSourceUrl
            )
            debugSink?.log(message = "◇目录页数:${parsedPages.size}")
            debugSink?.log(message = "◇目录总数:${chapters.size}")
            Result.success(WebBookChapterList(book.withRequestVariables(tocRuntimeVariables, replace = true), chapters))
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            if (e is TocEmptyException) {
                return Result.failure(e)
            }
            Result.failure(
                webBookParseFailure(
                    stage = "repository.toc",
                    source = source,
                    baseUrl = book.tocUrl.ifEmpty { book.bookUrl },
                    detail = "chapter list request or parsing failed for ${source.displayName()}",
                    cause = e
                )
            )
        }
    }

    override suspend fun getChapterContent(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
        needSave: Boolean,
        debugSink: BookSourceDebugSink?,
        nextChapterUrl: String?,
    ): Result<String> = getChapterContentWithChapter(
        source, book, chapter, needSave, debugSink, nextChapterUrl,
    ).map { it.content }

    override suspend fun getChapterContentWithChapter(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
        needSave: Boolean,
        debugSink: BookSourceDebugSink?,
        nextChapterUrl: String?,
    ): Result<WebBookChapterContent> {
        return try {
            // W07: needSave parameter controls whether the caller should persist the content.
            // In the KMP architecture, persistence is handled by ChapterContentRepository
            // at the Facade layer (ReaderFacade.loadChapter / MangaReaderFacade.download).
            // When needSave=false, the caller should use the content without caching it.
            // This pass-through design aligns with legado WebBook.getContentAwait(needSave).

            // Legacy short-circuit: empty content rule returns chapter URL
            if (source.ruleContent?.content.isNullOrEmpty()) {
                return Result.success(WebBookChapterContent(chapter, chapter.url))
            }
            // Legacy short-circuit: isVolume chapters with url starting with title
            // return tag (updateTime) or empty string, no network request needed
            if (chapter.isVolume && chapter.url.startsWith(chapter.title)) {
                return Result.success(WebBookChapterContent(chapter, chapter.tag.orEmpty()))
            }

            val chapterBoundaryUrl = nextChapterUrl ?: chapterRepository
                ?.getChapter(book.bookUrl, chapter.index + 1)
                ?.url
                ?: chapterRepository?.getChapter(book.bookUrl, 0)?.url

            val requestVariables = linkedMapOf<String, Any?>().apply {
                putAll(buildBookVariables(book))
                putAll(buildChapterVariables(chapter))
            }
            val contentRuntimeVariables = linkedMapOf<String, String>().apply {
                putAll(book.variableMap)
                putAll(chapter.variableMap)
            }
            requestVariables.putAll(contentRuntimeVariables)
            val visitedUrls = linkedSetOf<String>()
            val contentParts = mutableListOf<String>()
            var updatedChapter = chapter
            val firstPageBaseUrl = chapter.getAbsoluteURL()
            var firstPageRedirectUrl = firstPageBaseUrl

            // Aligned with legado WebBook.getContentAwait():
            // webJs and sourceRegex from ContentRule are passed as fallbacks
            // to getStrResponseAwait (webView rendering parameters).
            val contentWebJs = source.ruleContent?.webJs
            val contentSourceRegex = source.ruleContent?.sourceRegex

            fun applyContentVariables(variables: Map<String, String>) {
                val changedVariables = variables.filter { (key, value) ->
                    contentRuntimeVariables[key] != value
                }
                if (changedVariables.isEmpty()) return
                contentRuntimeVariables.putAll(changedVariables)
                val mergedChapterVariables = updatedChapter.variableMap + changedVariables
                updatedChapter = updatedChapter.copy(
                    variable = serializeVariableMap(mergedChapterVariables).takeIf { it.isNotEmpty() }
                )
                requestVariables.putAll(buildChapterVariables(updatedChapter))
                requestVariables.putAll(changedVariables)
            }

            suspend fun loadContentPage(
                requestUrl: String,
                getNextPageUrls: Boolean,
                requestBaseUrl: String = ""
            ): Result<ChapterContent> {
                debugSink?.log(message = "︾加载正文页:$requestUrl")
                val analyzeUrl = createAnalyzeUrl(
                    source = source,
                    ruleData = requestVariables,
                    chapter = updatedChapter
                )
                applySourceVariables(analyzeUrl, source)
                analyzeUrl.setVariables(requestVariables)
                val builtRequest = analyzeUrl.build(requestUrl, requestBaseUrl)
                applyContentVariables(analyzeUrl.getWrittenVariables())
                val mergedWebJs = builtRequest.webJs.takeUnless { it.isNullOrBlank() } ?: contentWebJs
                val mergedSourceRegex = builtRequest.sourceRegex.takeUnless { it.isNullOrBlank() } ?: contentSourceRegex
                val usesContentWebViewFallback =
                    (builtRequest.webJs.isNullOrBlank() && !contentWebJs.isNullOrBlank()) ||
                        (builtRequest.sourceRegex.isNullOrBlank() && !contentSourceRegex.isNullOrBlank())
                // Merge contentRule's webJs/sourceRegex as fallback (URL option takes precedence)
                val request = builtRequest.copy(
                    useWebView = builtRequest.useWebView || usesContentWebViewFallback,
                    webJs = mergedWebJs,
                    sourceRegex = mergedSourceRegex
                )
                return requestExecutor.executeText(
                    request = request,
                    source = source,
                    defaultHeaders = buildHeaders(source, requestVariables, request, updatedChapter),
                    ruleData = requestVariables,
                    chapter = updatedChapter
                ).map { response ->
                    debugSink?.raw(BookSourceDebugRawBucket.CONTENT, response.bodyText)
                    val redirectUrl = response.finalUrl.ifBlank { request.url }
                    // Keep raw URL options distinct for same-URL POST pages with different bodies.
                    visitedUrls += requestUrl
                    visitedUrls += redirectUrl
                    if (contentParts.isEmpty()) {
                        firstPageRedirectUrl = redirectUrl
                    }
                    BookContent.getContent(
                        bookSource = source,
                        book = book,
                        chapter = updatedChapter,
                        baseUrl = requestUrl,
                        redirectUrl = redirectUrl,
                        body = response.bodyText,
                        nextChapterUrl = chapterBoundaryUrl,
                        getNextPageUrls = getNextPageUrls,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime,
                        runtimeVariables = contentRuntimeVariables,
                        debugSink = debugSink
                    )
                }
            }

            loadContentPage(
                firstPageBaseUrl,
                getNextPageUrls = true,
                requestBaseUrl = book.tocUrl
            ).fold(
                onSuccess = { firstPage ->
                    applyContentVariables(firstPage.variables)
                    firstPage.title
                        ?.takeIf { it != updatedChapter.title }
                        ?.let { newTitle ->
                            updatedChapter = updatedChapter.copy(title = newTitle)
                            chapterRepository?.update(updatedChapter)
                            requestVariables.putAll(buildChapterVariables(updatedChapter))
                        }
                    contentParts += firstPage.content
                    debugSink?.log(
                        message = "◇正文分页:1 长度:${firstPage.content.length} 下一页:${firstPage.nextUrls.size}"
                    )
                    if (firstPage.nextUrls.size == 1) {
                        var nextUrl = firstPage.nextUrls.first()
                        val redirectBase = firstPageRedirectUrl
                        var pageIndex = 1
                        while (nextUrl.isNotBlank() && visitedUrls.add(nextUrl)) {
                            // Legacy boundary check: stop if next content page URL
                            // resolves to the same as nextChapterUrl (prevents reading
                            // into the next chapter)
                            if (!chapterBoundaryUrl.isNullOrEmpty()) {
                                val resolvedNext = resolveLegacyAbsoluteUrl(redirectBase, nextUrl)
                                val resolvedChapter = resolveLegacyAbsoluteUrl(redirectBase, chapterBoundaryUrl)
                                if (resolvedNext == resolvedChapter) break
                            }
                            loadContentPage(nextUrl, getNextPageUrls = true).fold(
                                onSuccess = { page ->
                                    applyContentVariables(page.variables)
                                    contentParts += page.content
                                    pageIndex += 1
                                    debugSink?.log(
                                        message = "◇正文分页:${pageIndex} 长度:${page.content.length} 下一页:${page.nextUrls.size}"
                                    )
                                    nextUrl = page.nextUrls.firstOrNull().orEmpty()
                                },
                                onFailure = { return Result.failure(it) }
                            )
                        }
                    } else {
                        for (nextUrl in firstPage.nextUrls) {
                            if (!visitedUrls.add(nextUrl)) continue
                            loadContentPage(nextUrl, getNextPageUrls = false).fold(
                                onSuccess = { page ->
                                    applyContentVariables(page.variables)
                                    contentParts += page.content
                                    debugSink?.log(
                                        message = "◇正文分页:${contentParts.size} 长度:${page.content.length} 下一页:${page.nextUrls.size}"
                                    )
                                },
                                onFailure = { return Result.failure(it) }
                            )
                        }
                    }
                },
                onFailure = { return Result.failure(it) }
            )
            var content = contentParts.joinToString("\n")
            // Legado applies replaceRegex after joining all content pages, so cross-page
            // patterns work and one-shot replacements are not consumed per page.
            source.ruleContent?.replaceRegex
                ?.takeIf { it.isNotBlank() }
                ?.let { replaceRegex ->
                    debugSink?.log(message = "┌应用正文替换规则")
                    val beforeLength = content.length
                    content = BookContent.applyJoinedReplaceRegex(
                        replaceRegex = replaceRegex,
                        content = content,
                        bookSource = source,
                        book = book,
                        chapter = updatedChapter,
                        baseUrl = firstPageBaseUrl,
                        redirectUrl = firstPageRedirectUrl,
                        nextChapterUrl = chapterBoundaryUrl,
                        sourceStateStore = sourceStateStore,
                        jsExecutor = jsExecutor,
                        connectGateway = requestExecutor,
                        headerResolver = headerResolver,
                        sourceJsRuntime = sourceJsRuntime
                    )
                    debugSink?.log(message = "└正文长度:${beforeLength}->${content.length}")
                }
            if (!updatedChapter.isVolume && content.isBlank()) {
                throw ContentEmptyException(
                    webBookParseFailure(
                        stage = "content.empty",
                        source = source,
                        baseUrl = firstPageRedirectUrl,
                        detail = "parsed content is empty"
                    ).message
                )
            }
            if (
                updatedChapter.title != chapter.title ||
                updatedChapter.url != chapter.url ||
                updatedChapter.baseUrl != chapter.baseUrl ||
                updatedChapter.variable != chapter.variable
            ) {
                chapterRepository?.update(updatedChapter)
            }
            debugSink?.log(message = "◇本章总页数:${contentParts.size}")
            debugSink?.log(message = "◇正文总长度:${content.length}")
            Result.success(WebBookChapterContent(updatedChapter, content))
        } catch (e: Exception) {
            e.rethrowIfSharedCapability()
            if (e is ContentEmptyException) {
                return Result.failure(e)
            }
            Result.failure(
                webBookParseFailure(
                    stage = "repository.content",
                    source = source,
                    baseUrl = chapter.getAbsoluteURL(),
                    detail = "chapter content request or parsing failed for ${chapter.title}",
                    cause = e
                )
            )
        }
    }

    /**
     * Build HTTP headers from book source configuration
     */
    private suspend fun buildHeaders(
        source: BookSource,
        requestVariables: Map<String, Any?>,
        request: io.legado.kmp.shared.network.BuiltUrl,
        chapter: BookChapter? = null,
    ): Map<String, String> = requestExecutor.resolveSourceHeaders(
        source = source, request = request, includeLoginHeader = true, ruleData = requestVariables, chapter = chapter,
    )

    private fun Book.withRequestVariables(variables: Map<String, String>, replace: Boolean = false): Book {
        if (variables.isEmpty() && !replace) return this
        val current = variableMap
        val merged = if (replace) variables else current + variables
        if (merged == current) return this
        return copy(variable = serializeVariableMap(merged)).also {
            it.infoHtml = infoHtml
            it.tocHtml = tocHtml
            it.downloadUrls = downloadUrls
        }
    }

    private suspend fun applySourceVariables(
        analyzeUrl: AnalyzeUrl,
        source: BookSource
    ) {
        sourceStateStore.getSourceVariableMap(source.bookSourceUrl).forEach { (key, value) ->
            analyzeUrl.setString(key, value)
        }
    }

    private fun createAnalyzeUrl(
        source: BookSource,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null
    ): AnalyzeUrl {
        return AnalyzeUrl(
            jsExecutor = jsExecutor,
            legacyContext = AnalyzeUrlLegacyContext(
                source = source,
                sourceStateStore = sourceStateStore,
                gateway = requestExecutor,
                sourceJsRuntime = sourceJsRuntime,
                ruleData = ruleData,
                chapter = chapter
            )
        )
    }

    private fun buildBookVariables(book: Book): Map<String, Any?> {
        return linkedMapOf(
            "book" to mapOf(
                "bookUrl" to book.bookUrl,
                "tocUrl" to book.tocUrl,
                "origin" to book.origin,
                "originName" to book.originName,
                "name" to book.name,
                "author" to book.author,
                "kind" to book.kind,
                "intro" to book.intro,
                "coverUrl" to book.displayCoverUrl,
                "latestChapterTitle" to book.latestChapterTitle,
                "totalChapterNum" to book.totalChapterNum,
                "variable" to book.variableMap
            ),
            "bookUrl" to book.bookUrl,
            "bookName" to book.name,
            "bookCoverUrl" to book.displayCoverUrl,
            "bookTotalChapterNum" to book.totalChapterNum,
            "author" to book.author
        )
    }

    private fun buildChapterVariables(chapter: BookChapter): Map<String, Any?> {
        return linkedMapOf(
            "chapter" to mapOf(
                "url" to chapter.url,
                "title" to chapter.title,
                "bookUrl" to chapter.bookUrl,
                "index" to chapter.index,
                "baseUrl" to chapter.baseUrl,
                "variable" to chapter.variableMap
            ),
            "chapterUrl" to chapter.url,
            "title" to chapter.title,
            "chapterIndex" to chapter.index
        )
    }

    /**
     * Check for HTTP redirect and log debug info.
     *
     * Aligned with legado WebBook.checkRedirect():
     * Detects when the response URL differs from the request URL (indicating redirect)
     * and outputs debug logging.
     *
     * @param source Book source (for log tagging)
     * @param response The response to check
     * @param requestUrl The original request URL for comparison
     */
    private fun checkRedirect(
        source: BookSource,
        response: SourceRequestResult,
        requestUrl: String = ""
    ) {
        val finalUrl = response.finalUrl
        if (requestUrl.isNotBlank() && finalUrl.isNotBlank() && requestUrl != finalUrl) {
            println("Debug[${source.bookSourceUrl}]: redirect detected -> $finalUrl")
        }
    }
}
