package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.network.SourceRequestExecutor
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

/** Common preparation only. The platform owns download, response validation, storage, and import. */
class WebBookFileFacade(
    private val details: BookDetailFacade,
    private val sources: BookSourceRepository,
    private val executor: SourceRequestExecutor,
    private val cookies: CookieRepository,
    state: SourceStateStore,
    jsExecutor: JsExecutor,
    headerResolver: SourceHeaderResolver,
    runtime: SourceJsRuntime,
) {
    private val preparationMutex = Mutex()
    private val issuedOptions = WebBookFileIssuedOptions()
    private val detailLoader = WebBookFileDetailLoader(executor, state, jsExecutor, headerResolver, runtime)

    companion object {
        @Throws(RecoverableSharedException::class)
        fun create(): WebBookFileFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            WebBookFileFacade(koin.get(), koin.get(), koin.get(), koin.get(), koin.get(), koin.get(), koin.get(), koin.get())
        } catch (_: Exception) {
            throw RecoverableSharedException("WebBookFileFacade.create", "文件书源服务不可用，请重试")
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareFiles(bookUrl: String): List<WebBookFileOption> = recoverWebBookFile("prepareFiles") {
        preparationMutex.withLock {
            requireWebBookFileRule(bookUrl)
            issuedOptions.remove(bookUrl)
            val initialBook = requireBook(bookUrl)
            val initialBookSnapshot = webBookFileBookSnapshot(initialBook)
            val source = requireSource(initialBook)
            val snapshot = webBookFileSourceSnapshot(source)
            // downloadUrls is transient. Refresh detail only, without persisting or loading a TOC.
            // Avoid the detail facade's raw crash log and the repository's raw redirect log.
            val book = if (initialBook.downloadUrls.isNullOrEmpty()) {
                detailLoader.refreshInfo(source, initialBook)
            } else initialBook
            requireWebBookFile(book.bookUrl == initialBook.bookUrl && book.origin == initialBook.origin && !book.isLocal,
                "bookChanged", "书籍或书源已变化，请刷新文件列表")
            val downloadRules = book.downloadUrls.orEmpty()
            requireWebBookFile(downloadRules.size <= WebBookFileLimits.OPTIONS, "optionsTooLarge", "文件下载选项数量超过限制")
            val rules = downloadRules.toList()
            var bytes = 0
            var inlineBytes = 0
            val options = mutableListOf<WebBookFileOption>()
            for (rule in rules) {
                currentCoroutineContext().ensureActive()
                if (isWebBookFileInlineRule(rule)) {
                    webBookFileInlineHeader(rule)
                    if (options.any { sameWebBookFileRule(it.urlRule, rule) }) continue
                    requireWebBookFile(rule.length <= WebBookFileLimits.INLINE_CACHE_BYTES - inlineBytes,
                        "inlineTooLarge", "DataURL 选项总大小超过 96 MiB 限制")
                    validateWebBookFileInline(rule)
                    inlineBytes += rule.length
                } else {
                    requireWebBookFileRule(rule)
                    bytes += webBookFileBoundedByteSize(rule, WebBookFileLimits.RULE_BYTES)!!
                    requireWebBookFile(bytes <= WebBookFileLimits.OPTIONS_BYTES, "optionsTooLarge", "文件下载选项总大小超过限制")
                    if (options.any { sameWebBookFileRule(it.urlRule, rule) }) continue
                }
                options.add(webBookFileOption(book, rule))
            }
            val currentBook = requireBook(bookUrl)
            requireWebBookFile(currentBook.origin == book.origin &&
                (currentBook.variable == initialBook.variable || currentBook.variable == book.variable) &&
                webBookFileBookSnapshot(currentBook.copy(variable = initialBook.variable)) == initialBookSnapshot &&
                webBookFileSourceSnapshot(requireSource(currentBook)) == snapshot,
                "bookChanged", "书籍或书源配置已变化，请刷新文件列表")
            requireCurrentOptions(currentBook, options)
            currentCoroutineContext().ensureActive()
            val immutableOptions = options.toList()
            issuedOptions.put(bookUrl, WebBookFileIssued(book.copy(), currentBook.variable, snapshot,
                immutableOptions, webBookFileBookSnapshot(currentBook)))
            immutableOptions
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareDownload(bookUrl: String, urlRule: String): WebBookFileRequest = recoverWebBookFile("prepareDownload") {
        preparationMutex.withLock {
            requireWebBookFileRule(bookUrl)
            requireWebBookFile(!isWebBookFileInlineRule(urlRule),
                "inlineRequiresPreparation", "DataURL 文件请使用内联文件准备接口")
            requireWebBookFileRule(urlRule)
            val issued = issuedOptions.get(bookUrl)
            val option = issued?.options?.firstOrNull { it.urlRule == urlRule }
            requireWebBookFile(issued != null && option != null, "optionExpired", "文件选项已失效，请刷新列表后重新选择")
            val currentBook = requireBook(bookUrl)
            val source = requireSource(currentBook)
            requireIssuedBook(currentBook, source, issued!!)
            val book = issued.book
            val ruleData = webBookFileRuleData(book)
            // Exactly one AnalyzeUrl build for this user intent; no re-fetch or signed-URL comparison.
            val context = executor.prepareFileRequest(urlRule, source, book.bookUrl, ruleData)
            currentCoroutineContext().ensureActive()
            requireWebBookFile(!isWebBookFileInlineRule(context.requestConfig.url),
                "inlineRequiresPreparation", "HTTP 规则不能下载 DataURL，请刷新为静态内联文件选项")
            val latestBook = requireBook(bookUrl)
            requireIssuedBook(latestBook, requireSource(latestBook), issued)
            prepareWebBookFileHttp(context, source, book, option!!)
        }
    }

    /** Static DataURL only: no AnalyzeUrl, source JS, headers, cookies, or HTTP request. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareInlineDownload(bookUrl: String, urlRule: String): WebBookFileInlineData =
        recoverWebBookFile("prepareInlineDownload") {
            preparationMutex.withLock {
                requireWebBookFileRule(bookUrl)
                webBookFileInlineHeader(urlRule)
                val issued = issuedOptions.get(bookUrl)
                val option = issued?.options?.firstOrNull { it.isInlineData && sameWebBookFileRule(it.urlRule, urlRule) }
                requireWebBookFile(issued != null && option != null,
                    "optionExpired", "文件选项已失效，请刷新列表后重新选择")
                val currentBook = requireBook(bookUrl)
                requireIssuedBook(currentBook, requireSource(currentBook), issued!!)
                val data = prepareWebBookFileInline(option!!)
                currentCoroutineContext().ensureActive()
                val latestBook = requireBook(bookUrl)
                requireIssuedBook(latestBook, requireSource(latestBook), issued)
                data
            }
        }

    /**
     * targetUrl must be absolute. After every hop, the loader must retain the new URL and returned
     * headers in its request copy; clear explicitCookie on an origin change, keeping headerOriginUrl.
     * The loader handles 301/302/303 method/body changes, a hop limit, and an overall deadline.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareRedirect(request: WebBookFileRequest, targetUrl: String): Map<String, String> =
        recoverWebBookFile("prepareRedirect") { prepareWebBookFileRedirect(cookies, request, targetUrl) }

    /**
     * Call for each actual response BEFORE preparing its redirect, including the final response.
     * Pass the current hop's request and all raw Set-Cookie fields, not the final URL of an automatic
     * redirect chain. enabledCookieJar controls persistence, not URL-scoped session-cookie updates.
     * This does not run loginCheckJs, retry the response, validate file bytes, or import a book.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun recordResponseCookies(request: WebBookFileRequest, responseUrl: String, setCookieHeaders: List<String>) {
        recoverWebBookFile("recordResponseCookies") { recordWebBookFileCookies(cookies, request, responseUrl, setCookieHeaders) }
    }

    fun prepareFilesRequest(bookUrl: String, onResult: (WebBookFileOptionsResult) -> Unit): FlowSubscription =
        CancellableFacadeRequest.start(
            prepare = { WebBookFileOptionsResult(options = prepareFiles(bookUrl)) },
            cancelledResult = WebBookFileOptionsResult(isCancelled = true),
            failureResult = { error -> webBookFileCallbackError(error).let {
                WebBookFileOptionsResult(errorCode = it.code, errorMessage = it.message)
            } },
            onResult = { deliverWebBookFileResult(it, onResult) },
            facade = "WebBookFileFacade",
            callbackMethod = "prepareFilesRequest.onResult",
            missingResultMessage = "File options unavailable",
        )

    fun prepareDownloadRequest(bookUrl: String, urlRule: String, onResult: (WebBookFileRequestResult) -> Unit): FlowSubscription =
        CancellableFacadeRequest.start(
            prepare = { WebBookFileRequestResult(request = prepareDownload(bookUrl, urlRule)) },
            cancelledResult = WebBookFileRequestResult(isCancelled = true),
            failureResult = { error -> webBookFileCallbackError(error).let {
                WebBookFileRequestResult(errorCode = it.code, errorMessage = it.message)
            } },
            onResult = { deliverWebBookFileResult(it, onResult) },
            facade = "WebBookFileFacade",
            callbackMethod = "prepareDownloadRequest.onResult",
            missingResultMessage = "File download intent unavailable",
        )

    fun prepareInlineDownloadRequest(bookUrl: String, urlRule: String, onResult: (WebBookFileInlineResult) -> Unit): FlowSubscription =
        CancellableFacadeRequest.start(
            prepare = { WebBookFileInlineResult(data = prepareInlineDownload(bookUrl, urlRule)) },
            cancelledResult = WebBookFileInlineResult(isCancelled = true),
            failureResult = { error -> webBookFileCallbackError(error).let {
                WebBookFileInlineResult(errorCode = it.code, errorMessage = it.message)
            } },
            onResult = { deliverWebBookFileResult(it, onResult) },
            facade = "WebBookFileFacade",
            callbackMethod = "prepareInlineDownloadRequest.onResult",
            missingResultMessage = "Inline file intent unavailable",
        )

    private suspend fun requireBook(bookUrl: String): Book {
        val book = details.resolveBook(bookUrl)
        requireWebBookFile(book != null && !book.isLocal && book.bookUrl == bookUrl,
            "bookUnavailable", "书籍不存在或已不再属于在线文件书源")
        return book!!
    }

    private suspend fun requireSource(book: Book): BookSource {
        requireWebBookFile(webBookFileBounded(book.origin, WebBookFileLimits.URL_BYTES), "invalidSource", "文件书源标识超过大小限制")
        val source = sources.getBookSource(book.origin)
        requireWebBookFile(source != null && source.isFile && source.bookSourceUrl == book.origin,
            "sourceUnavailable", "文件书源不存在或类型已变化")
        return source!!
    }

    private suspend fun requireIssuedBook(book: Book, source: BookSource, issued: WebBookFileIssued) {
        requireWebBookFile(book.bookUrl == issued.book.bookUrl && book.origin == issued.book.origin &&
            book.variable == issued.baselineVariable && webBookFileBookSnapshot(book) == issued.baselineBookSnapshot &&
            webBookFileSourceSnapshot(source) == issued.sourceSnapshot,
            "bookChanged", "书籍或书源配置已变化，请刷新文件列表")
        requireCurrentOptions(book, issued.options)
    }

    private suspend fun requireCurrentOptions(book: Book, options: List<WebBookFileOption>) {
        val rules = book.downloadUrls ?: return
        requireWebBookFile(rules.size <= WebBookFileLimits.OPTIONS &&
            rules.all { rule -> options.any { sameWebBookFileRule(it.urlRule, rule) } } &&
            options.all { option -> rules.any { sameWebBookFileRule(option.urlRule, it) } },
            "bookChanged", "书籍文件选项已变化，请刷新文件列表")
    }
}
