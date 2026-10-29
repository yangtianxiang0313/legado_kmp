package io.legado.kmp.shared.facade

import io.legado.kmp.shared.platform.ConsumerConcurrencyPolicy
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Each consumer handles source-local failures; parent cancellation stops the entire worker pool. */
internal suspend fun <T> forEachSourceWithWorkers(
    work: List<T>,
    configuredConcurrency: Int,
    action: suspend (T) -> Unit,
) = coroutineScope {
    val workMutex = Mutex()
    var nextIndex = 0
    // Allocate only logical in-flight workers, never a suspended coroutine for every source.
    repeat(ConsumerConcurrencyPolicy.workerCount(configuredConcurrency, work.size)) {
        launch {
            while (true) {
                coroutineContext.ensureActive()
                val item = workMutex.withLock {
                    if (nextIndex >= work.size) return@launch
                    work[nextIndex++]
                }
                action(item)
            }
        }
    }
}
