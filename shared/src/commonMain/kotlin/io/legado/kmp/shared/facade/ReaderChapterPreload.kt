package io.legado.kmp.shared.facade

import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withContext

/** Owns only the existing loader's prefetch Job; it never loads a display payload or saves progress. */
internal class ReaderChapterPreload(private val loader: ReaderChapterLoader) {
    private data class Request(
        val bookUrl: String,
        val index: Int,
        val count: Int,
        val includeCurrent: Boolean,
        val job: Deferred<Unit>,
        val settled: CompletableDeferred<Unit> = CompletableDeferred(),
    )
    private val current = MutableStateFlow<Request?>(null)

    fun cancel() {
        // Keep the identity until the owning run has finished cleaning its loading guards.
        current.value?.job?.cancel()
    }

    suspend fun run(bookUrl: String, index: Int, count: Int, includeCurrent: Boolean = false) = supervisorScope {
        val boundedCount = count.coerceIn(0, 9999).let { if (includeCurrent) it.coerceAtLeast(1) else it }
        if (boundedCount == 0) {
            val previous = current.value
            previous?.job?.cancel()
            withContext(NonCancellable) { previous?.settled?.await() }
            return@supervisorScope
        }
        while (true) {
            val previous = current.value
            if (previous != null && previous.bookUrl == bookUrl && previous.index == index &&
                previous.count == boundedCount && previous.includeCurrent == includeCurrent && previous.job.isActive
            ) {
                try {
                    previous.job.await()
                } catch (cancelled: CancellationException) {
                    previous.job.cancel()
                    throw cancelled
                } finally {
                    withContext(NonCancellable) { previous.settled.await() }
                }
                return@supervisorScope
            }
            val job = async(start = CoroutineStart.LAZY) {
                // Also wait for ancestors if an intermediate lazy window never started.
                previous?.settled?.await()
                loader.preloadAdjacentChapters(bookUrl, index, boundedCount, includeCurrent)
            }
            val request = Request(bookUrl, index, boundedCount, includeCurrent, job)
            if (!current.compareAndSet(previous, request)) {
                job.cancel()
                continue
            }
            previous?.job?.cancel()
            try {
                job.start()
                job.await()
            } finally {
                withContext(NonCancellable) {
                    job.cancelAndJoin()
                    previous?.settled?.await()
                    current.compareAndSet(request, null)
                    request.settled.complete(Unit)
                }
            }
            return@supervisorScope
        }
    }
}
