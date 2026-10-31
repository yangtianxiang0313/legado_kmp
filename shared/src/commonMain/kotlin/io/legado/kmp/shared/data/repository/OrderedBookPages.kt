package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.platform.ConsumerConcurrencyPolicy
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive

/** Keep at most one configured window live, including completed pages awaiting their predecessor. */
internal suspend fun <T, R> orderedBookPages(
    work: List<T>,
    concurrency: Int,
    action: suspend (T) -> R,
): List<R> = coroutineScope {
    val width = ConsumerConcurrencyPolicy.workerCount(concurrency, work.size)
    val result = ArrayList<R>(work.size)
    if (width <= 1) {
        for (item in work) {
            coroutineContext.ensureActive()
            result.add(action(item))
        }
    } else {
        val pending = ArrayDeque<Deferred<R>>(width)
        var next = 0
        repeat(width) {
            val item = work[next++]
            pending.addLast(async { action(item) })
        }
        while (pending.isNotEmpty()) {
            coroutineContext.ensureActive()
            result.add(pending.removeFirst().await())
            if (next < work.size) {
                val item = work[next++]
                pending.addLast(async { action(item) })
            }
        }
    }
    coroutineContext.ensureActive()
    result
}
