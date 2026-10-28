package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.domain.runtime.SourceCheckBackend
import io.legado.kmp.shared.domain.runtime.withSourceCheckResult
import io.legado.kmp.shared.domain.webBook.BookSourceDebugRawBucket
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookSourceUseCase
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

data class BookSourceDebugStep(
    val stage: String,
    val status: String,
    val message: String,
    val detail: String? = null,
    val durationMs: Long = 0L,
)

data class BookSourceDebugRawResponse(
    val stage: String,
    val length: Int,
    val preview: String,
)

data class BookSourceDebugLogLine(
    val state: Int,
    val message: String,
    val elapsedMs: Long = 0L,
)

data class BookSourceDebugRawPages(
    val search: String? = null,
    val detail: String? = null,
    val toc: String? = null,
    val content: String? = null,
)

data class BookSourceDebugReport(
    val sourceUrl: String,
    val sourceName: String,
    val keyword: String,
    val success: Boolean,
    val steps: List<BookSourceDebugStep>,
    val logs: List<BookSourceDebugLogLine>,
    val rawPages: BookSourceDebugRawPages,
    val rawResponses: List<BookSourceDebugRawResponse>,
)

data class BookSourceCheckReport(
    val sourceUrl: String,
    val sourceName: String,
    val success: Boolean,
    val invalidGroups: List<String>,
    val failureMessage: String? = null,
    val respondTimeMs: Long = 0L,
    val persisted: Boolean = false,
    val updatedSource: BookSource? = null,
)

class BookSourceDebugFacade(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val webBookRepository: WebBookRepository,
    private val saveBookSourceUseCase: SaveBookSourceUseCase,
    private val sourceCheckBackend: SourceCheckBackend,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
) {
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun debugSource(sourceUrl: String, keyword: String = ""): BookSourceDebugReport {
        return runRecoverable("BookSourceDebugFacade.debugSource") {
            runDebugSource(sourceUrl, keyword, onLog = null)
        }
    }

    /** Logs belong to this invocation and are delivered on its coroutine's thread. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun debugSourceWithLogs(
        sourceUrl: String,
        keyword: String,
        onLog: (BookSourceDebugLogLine) -> Unit,
    ): BookSourceDebugReport {
        return runRecoverable("BookSourceDebugFacade.debugSourceWithLogs") {
            runDebugSource(sourceUrl, keyword, onLog)
        }
    }

    /** Cancelling the subscription cancels the request; onResult(null, null) denotes cancellation. */
    fun debugSourceRequest(
        sourceUrl: String,
        keyword: String,
        onLog: (BookSourceDebugLogLine) -> Unit,
        onResult: (BookSourceDebugReport?, RecoverableSharedException?) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            BookSourceDebugRequestResult(debugSourceWithLogs(sourceUrl, keyword, onLog), null)
        },
        cancelledResult = BookSourceDebugRequestResult(null, null),
        failureResult = { error ->
            BookSourceDebugRequestResult(
                null,
                error.asRecoverableSharedException("BookSourceDebugFacade.debugSourceRequest"),
            )
        },
        onResult = { result -> onResult(result.report, result.error) },
        facade = "BookSourceDebugFacade",
        callbackMethod = "debugSourceRequest.onResult",
        missingResultMessage = "Book source debug request completed without a result",
    )

    private suspend fun runDebugSource(
        sourceUrl: String,
        keyword: String,
        onLog: ((BookSourceDebugLogLine) -> Unit)?,
    ): BookSourceDebugReport {
        try {
            coroutineContext.ensureActive()
            val source = getBookSourcesUseCase.getByUrl(sourceUrl.trim())
                ?: throw IllegalArgumentException("Book source not found: $sourceUrl")
            coroutineContext.ensureActive()
            val normalizedKeyword = keyword.trim().ifBlank { source.getCheckKeyword("我的") }
            val debugSink = BookSourceDebugCollector(coroutineContext, onLog)
            val query = BookSourceDebugQuerySupport(source, webBookRepository, fetchChapterListUseCase, debugSink)
            val success = query.run(normalizedKeyword)
            debugSink.ensureActive()
            return BookSourceDebugReport(
                sourceUrl = source.bookSourceUrl,
                sourceName = source.bookSourceName,
                keyword = normalizedKeyword,
                success = success,
                steps = query.steps,
                logs = debugSink.logs,
                rawPages = debugSink.rawPages(),
                rawResponses = debugSink.responses,
            )
        } catch (error: Throwable) {
            coroutineContext.ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            throw error
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun checkSource(sourceUrl: String, persist: Boolean = false): BookSourceCheckReport {
        return runRecoverable("BookSourceDebugFacade.checkSource") {
            val source = getBookSourcesUseCase.getByUrl(sourceUrl.trim())
                ?: throw IllegalArgumentException("Book source not found: $sourceUrl")
            val result = sourceCheckBackend.checkSource(source)
            val updatedSource = if (persist) {
                source.withSourceCheckResult(result).also { saveBookSourceUseCase(it) }
            } else {
                null
            }
            BookSourceCheckReport(
                sourceUrl = source.bookSourceUrl,
                sourceName = source.bookSourceName,
                success = result.invalidGroups.isEmpty(),
                invalidGroups = result.invalidGroups.toList(),
                failureMessage = result.failureMessage,
                respondTimeMs = result.respondTimeMs,
                persisted = persist,
                updatedSource = updatedSource,
            )
        }
    }
}

private data class BookSourceDebugRequestResult(
    val report: BookSourceDebugReport?,
    val error: RecoverableSharedException?,
)

private class BookSourceDebugCollector(
    private val context: CoroutineContext,
    private val onLog: ((BookSourceDebugLogLine) -> Unit)?,
) : BookSourceDebugSink {
    private val startTime = currentTimeMillis()
    private val mutableLogs = mutableListOf<BookSourceDebugLogLine>()
    private val mutableResponses = mutableListOf<BookSourceDebugRawResponse>()
    private var searchRaw: String? = null
    private var detailRaw: String? = null
    private var tocRaw: String? = null
    private var contentRaw: String? = null
    private var callbackCancellation: CancellationException? = null

    val logs: List<BookSourceDebugLogLine>
        get() = mutableLogs.toList()

    val responses: List<BookSourceDebugRawResponse>
        get() = mutableResponses.toList()

    fun ensureActive() {
        context.ensureActive()
        callbackCancellation?.let { throw it }
    }

    override fun log(state: Int, message: String, showTime: Boolean) {
        ensureActive()
        val elapsed = currentTimeMillis() - startTime
        val printedMessage = if (showTime) {
            "${elapsed.formatDebugTime()} $message"
        } else {
            message
        }
        val line = BookSourceDebugLogLine(
            state = state,
            message = printedMessage,
            elapsedMs = elapsed,
        )
        mutableLogs += line
        deliver(line)
        ensureActive()
    }

    private fun deliver(line: BookSourceDebugLogLine) {
        try {
            onLog?.invoke(line)
        } catch (error: Throwable) {
            findFacadeRequestCancellation(error)?.let {
                // Optional parser rules may catch exceptions; keep cancellation sticky for this invocation.
                callbackCancellation = it
                throw it
            }
            // A broken log consumer must not interrupt source parsing.
        }
    }

    fun rawPages(): BookSourceDebugRawPages {
        return BookSourceDebugRawPages(
            search = searchRaw,
            detail = detailRaw,
            toc = tocRaw,
            content = contentRaw,
        )
    }

    override fun raw(bucket: BookSourceDebugRawBucket, text: String) {
        ensureActive()
        when (bucket) {
            BookSourceDebugRawBucket.SEARCH -> searchRaw = searchRaw.appendRawPage(text)
            BookSourceDebugRawBucket.DETAIL -> detailRaw = detailRaw.appendRawPage(text)
            BookSourceDebugRawBucket.TOC -> tocRaw = tocRaw.appendRawPage(text)
            BookSourceDebugRawBucket.CONTENT -> contentRaw = contentRaw.appendRawPage(text)
        }
        mutableResponses += BookSourceDebugRawResponse(
            stage = bucket.displayName,
            length = text.length,
            preview = text.previewRawResponse()
        )
        // Android's states 10/20/30/40 update the raw-page menu, not visible log rows.
        val state = when (bucket) {
            BookSourceDebugRawBucket.SEARCH -> 10
            BookSourceDebugRawBucket.DETAIL -> 20
            BookSourceDebugRawBucket.TOC -> 30
            BookSourceDebugRawBucket.CONTENT -> 40
        }
        deliver(BookSourceDebugLogLine(state, text, currentTimeMillis() - startTime))
        ensureActive()
    }
}

private fun String?.appendRawPage(text: String): String {
    return if (isNullOrEmpty()) text else "$this\n\n----- next page -----\n\n$text"
}

private fun Long.formatDebugTime(): String {
    val minutes = this / 60_000
    val seconds = (this % 60_000) / 1_000
    val millis = this % 1_000
    return "[${minutes.padDebugNumber(2)}:${seconds.padDebugNumber(2)}.${millis.padDebugNumber(3)}]"
}

private fun Long.padDebugNumber(width: Int): String {
    val text = toString()
    return if (text.length >= width) text else "0".repeat(width - text.length) + text
}

private val BookSourceDebugRawBucket.displayName: String
    get() = when (this) {
        BookSourceDebugRawBucket.SEARCH -> "搜索原文"
        BookSourceDebugRawBucket.DETAIL -> "详情原文"
        BookSourceDebugRawBucket.TOC -> "目录原文"
        BookSourceDebugRawBucket.CONTENT -> "正文原文"
    }

private fun String.previewRawResponse(maxLength: Int = 4000): String {
    val normalized = replace("\r\n", "\n").replace('\r', '\n').trim()
    return if (normalized.length <= maxLength) normalized else normalized.take(maxLength) + "\n..."
}
