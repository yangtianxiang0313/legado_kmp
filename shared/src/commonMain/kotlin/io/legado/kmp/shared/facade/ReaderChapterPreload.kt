package io.legado.kmp.shared.facade

import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.launch

/** Owns only the existing loader's prefetch Job; it never loads a display payload or saves progress. */
internal class ReaderChapterPreload(private val loader: ReaderChapterLoader) {
    private data class Request(val bookUrl: String, val index: Int, val count: Int, val job: Job)
    private val current = MutableStateFlow<Request?>(null)

    fun cancel() {
        current.getAndUpdate { null }?.job?.cancel()
    }

    suspend fun run(bookUrl: String, index: Int, count: Int) = coroutineScope {
        val boundedCount = count.coerceIn(0, 100)
        if (boundedCount == 0) {
            cancel()
            return@coroutineScope
        }
        while (true) {
            val previous = current.value
            if (previous != null && previous.bookUrl == bookUrl && previous.index == index &&
                previous.count == boundedCount && previous.job.isActive
            ) {
                previous.job.join()
                return@coroutineScope
            }
            val job = launch(start = CoroutineStart.LAZY) {
                // Let the prior window unwind its loading guards before reusing any index.
                previous?.job?.cancelAndJoin()
                loader.preloadAdjacentChapters(bookUrl, index, boundedCount)
            }
            val request = Request(bookUrl, index, boundedCount, job)
            if (!current.compareAndSet(previous, request)) {
                job.cancel()
                continue
            }
            previous?.job?.cancel()
            try {
                job.start()
                job.join()
            } finally {
                current.compareAndSet(request, null)
                job.cancel()
            }
            return@coroutineScope
        }
    }
}
