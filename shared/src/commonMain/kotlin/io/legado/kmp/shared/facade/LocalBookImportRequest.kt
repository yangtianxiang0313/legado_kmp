package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

data class LocalBookImportRequestResult(
    val book: Book?,
    val errorCode: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

/** The caller must register cancellation before starting, and await the terminal callback before cleanup. */
class LocalBookImportRequest internal constructor(private val job: Job) {
    fun start() {
        job.start()
    }

    fun cancel() {
        job.cancel()
    }

    internal companion object {
        fun create(
            performImport: suspend () -> Book,
            onResult: (LocalBookImportRequestResult) -> Unit,
        ): LocalBookImportRequest {
            val scope = CoroutineScope(Dispatchers.Default)
            var result: LocalBookImportRequestResult? = null
            val job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    val book = performImport()
                    // A committed book owns its file even if cancellation arrived during the atomic write.
                    result = LocalBookImportRequestResult(book, null, null, isCancelled = false)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    findFacadeRequestCancellation(error)?.let { throw it }
                    result = failure(error)
                }
            }
            job.invokeOnCompletion { cause ->
                val terminal = result?.takeIf { it.book != null } ?: when {
                    job.isCancelled || findFacadeRequestCancellation(cause) != null ->
                        LocalBookImportRequestResult(null, null, null, isCancelled = true)
                    cause != null -> failure(cause)
                    else -> result ?: failure(IllegalStateException("Local import completed without a result"))
                }
                scope.cancel()
                try {
                    onResult(terminal)
                } catch (error: Throwable) {
                    if (findFacadeRequestCancellation(error) == null) {
                        CrashCollector.record("BookshelfFacade", "importLocalBookRequest.onResult", error = error)
                    }
                }
            }
            return LocalBookImportRequest(job)
        }

        private fun failure(error: Throwable): LocalBookImportRequestResult {
            val failure = error.asRecoverableSharedException("BookshelfFacade.importLocalBook")
            return LocalBookImportRequestResult(null, failure.code, failure.message, isCancelled = false)
        }
    }
}
