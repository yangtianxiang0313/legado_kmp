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
            val source = requireSource(initialBook)
            val snapshot = webBookFileSourceSnapshot(source)
            // downloadUrls is transient. Refresh detail only, without persisting or loading a TOC.
            // Avoid the detail facade's raw crash log and the repository's raw redirect log.
            val book = if (initialBook.downloadUrls.isNullOrEmpty()) {
                detailLoader.refreshInfo(source, initialBook)
            } else initialBook
            requireWebBookFile(book.bookUrl == initialBook.bookUrl && book.origin == initialBook.origin && !book.isLocal,
                "bookChanged", "书籍或书源已变化，请刷新文件列表")
            val rules = book.downloadUrls.orEmpty()
            requireWebBookFile(rules.size <= WebBookFileLimits.OPTIONS, "optionsTooLarge", "文件下载选项数量超过限制")
            var bytes = 0
            val options = rules.map { rule ->
                currentCoroutineContext().ensureActive()
                requireWebBookFileRule(rule)
                bytes += rule.encodeToByteArray().size
                requireWebBookFile(bytes <= WebBookFileLimits.OPTIONS_BYTES, "optionsTooLarge", "文件下载选项总大小超过限制")
                webBookFileOption(book, rule)
            }.distinctBy { it.urlRule }
            val currentBook = requireBook(bookUrl)
            requireWebBookFile(currentBook.origin == book.origin &&
                (currentBook.variable == initialBook.variable || currentBook.variable == book.variable) &&
                webBookFileSourceSnapshot(requireSource(currentBook)) == snapshot,
                "bookChanged", "书籍或书源配置已变化，请刷新文件列表")
            currentCoroutineContext().ensureActive()
            issuedOptions.put(bookUrl, WebBookFileIssued(book.copy(), currentBook.variable, snapshot, options))
            options
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun prepareDownload(bookUrl: String, urlRule: String): WebBookFileRequest = recoverWebBookFile("prepareDownload") {
        preparationMutex.withLock {
            requireWebBookFileRule(bookUrl)
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
            val latestBook = requireBook(bookUrl)
            requireIssuedBook(latestBook, requireSource(latestBook), issued)
            prepareWebBookFileHttp(context, source, book, option!!)
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

    private suspend fun requireBook(bookUrl: String): Book {
        val book = details.resolveBook(bookUrl)
        requireWebBookFile(book != null && !book.isLocal && book.bookUrl == bookUrl,
            "bookUnavailable", "书籍不存在或已不再属于在线文件书源")
        return book!!
    }

    private suspend fun requireSource(book: Book): BookSource {
        requireWebBookFile(webBookFileBounded(book.origin, WebBookFileLimits.URL_BYTES), "invalidSource", "文件书源标识超过大小限制")
        val source = sources.getBookSource(book.origin)
        requireWebBookFile(source != null && source.isFile, "sourceUnavailable", "文件书源不存在或类型已变化")
        return source!!
    }

    private fun requireIssuedBook(book: Book, source: BookSource, issued: WebBookFileIssued) {
        requireWebBookFile(book.bookUrl == issued.book.bookUrl && book.origin == issued.book.origin &&
            book.variable == issued.baselineVariable && webBookFileSourceSnapshot(source) == issued.sourceSnapshot,
            "bookChanged", "书籍或书源配置已变化，请刷新文件列表")
    }
}
