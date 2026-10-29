package io.legado.kmp.shared.facade

import io.legado.kmp.shared.network.ConcurrentRateLimiter
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException

/**
 * Owns one prepared HTTP intent and its shared rate limit across platform retries/redirects.
 * Always finish in platform cleanup, even when request() never returns or the platform is cancelled.
 * No HTTP transfer, body read, file publication, or platform-specific bridge runs here.
 */
class WebBookFileTransferSession internal constructor(
    prepare: suspend () -> WebBookFilePreparedDownload,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val ready = CompletableDeferred<WebBookFileRequest>()
    private val receivedHeaders = CompletableDeferred<Unit>()
    private val closed = CompletableDeferred<Unit>()
    private val job = scope.launch(start = CoroutineStart.LAZY) {
        try {
            recoverWebBookFile("beginDownload") {
                val prepared = prepare()
                // Keep acquisition, publication and release in this job, never in request()'s caller.
                prepared.limiter.withLimit {
                    currentCoroutineContext().ensureActive()
                    prepared.revalidate()
                    currentCoroutineContext().ensureActive()
                    ready.complete(prepared.request)
                    receivedHeaders.await()
                }
            }
        } catch (_: CancellationException) {
            throw sessionCancellation()
        } catch (error: Throwable) {
            // Never forward raw source/script exceptions to a coroutine exception handler or logger.
            ready.completeExceptionally(webBookFileCallbackError(error))
        }
    }

    init {
        // Also completes waiters when cancellation prevents the coroutine body from starting.
        job.invokeOnCompletion { cause ->
            if (cause != null || closed.isCompleted) {
                ready.cancel(sessionCancellation())
            } else if (!ready.isCompleted) {
                ready.completeExceptionally(RecoverableSharedException(
                    "WebBookFileFacade.beginDownload", "文件下载准备未完成，请重试",
                ))
            }
            scope.cancel()
        }
        job.start()
    }

    /** Repeated calls await the same preparation; cancelling a waiter cancels the session as well. */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun request(): WebBookFileRequest = try {
        currentCoroutineContext().ensureActive()
        if (closed.isCompleted) throw sessionCancellation()
        val request = ready.await()
        currentCoroutineContext().ensureActive()
        if (closed.isCompleted) throw sessionCancellation()
        request
    } catch (_: CancellationException) {
        cancel()
        throw sessionCancellation()
    }

    /** Call after successful final headers, before reading the body; not for redirects or retries. */
    fun headersReceived() {
        if (ready.isCompleted && !ready.isCancelled) receivedHeaders.complete(Unit)
    }

    /** Non-blocking. finish() must still be awaited to observe actual Kotlin cleanup. */
    fun cancel() {
        closed.complete(Unit)
        ready.cancel(sessionCancellation())
        job.cancel(sessionCancellation())
    }

    /** Idempotent, non-throwing cleanup, including when the platform's calling task is cancelled. */
    suspend fun finish() {
        withContext(NonCancellable) {
            cancel()
            job.join()
        }
    }

    override fun toString(): String = "WebBookFileTransferSession(redacted)"

    private fun sessionCancellation(): CancellationException =
        CancellationException("File download session cancelled")
}

internal class WebBookFilePreparedDownload(
    val request: WebBookFileRequest,
    val limiter: ConcurrentRateLimiter,
    val revalidate: suspend () -> Unit,
) {
    override fun toString(): String = "WebBookFilePreparedDownload(redacted)"
}
