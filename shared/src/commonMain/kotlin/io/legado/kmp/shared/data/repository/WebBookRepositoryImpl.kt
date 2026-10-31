package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.domain.webBook.BookChapterList
import io.legado.kmp.shared.domain.webBook.BookContent
import io.legado.kmp.shared.domain.webBook.BookInfo
import io.legado.kmp.shared.domain.webBook.BookList
import io.legado.kmp.shared.domain.webBook.BookSourceDebugRawBucket
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.domain.webBook.ChapterContent
import io.legado.kmp.shared.domain.webBook.rethrowIfSharedCapability
import io.legado.kmp.shared.domain.webBook.webBookParseFailure
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.WebBookChapterList
import io.legado.kmp.shared.domain.repository.WebBookChapterContent
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourceType
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.network.SourceRequestResult
import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlinx.coroutines.flow.first

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
    private val sourceJsRuntime: SourceJsRuntime? = null,
    private val preferencesStore: AppPreferencesStore? = null,
) : WebBookRepository {
    private val requestSupport = WebBookRequestSupport(
        requestExecutor, headerResolver, sourceStateStore, jsExecutor, sourceJsRuntime,
    )
    private val tocLoader = WebBookTocLoader(requestSupport)
    private val contentLoader = WebBookContentLoader(requestSupport, chapterRepository)

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
    ): Result<WebBookChapterList> = tocLoader.load(source, book, debugSink, paginationConcurrency())

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
    ): Result<WebBookChapterContent> = contentLoader.load(
        source, book, chapter, needSave, debugSink, nextChapterUrl, paginationConcurrency(),
    )

    private suspend fun paginationConcurrency(): Int =
        preferencesStore?.runtimeConfig?.first()?.threadCount ?: AppRuntimeConfig().threadCount

    private suspend fun buildHeaders(
        source: BookSource,
        requestVariables: Map<String, Any?>,
        request: io.legado.kmp.shared.network.BuiltUrl,
        chapter: BookChapter? = null,
    ): Map<String, String> = requestSupport.buildHeaders(source, requestVariables, request, chapter)

    private fun Book.withRequestVariables(variables: Map<String, String>, replace: Boolean = false): Book =
        requestSupport.withRequestVariables(this, variables, replace)

    private suspend fun applySourceVariables(analyzeUrl: AnalyzeUrl, source: BookSource) =
        requestSupport.applySourceVariables(analyzeUrl, source)

    private fun createAnalyzeUrl(
        source: BookSource,
        ruleData: Map<String, Any?> = emptyMap(),
        chapter: BookChapter? = null,
    ): AnalyzeUrl = requestSupport.createAnalyzeUrl(source, ruleData, chapter)

    private fun buildBookVariables(book: Book): Map<String, Any?> = requestSupport.buildBookVariables(book)

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
