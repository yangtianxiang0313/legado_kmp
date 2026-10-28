package io.legado.kmp.shared.facade

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

object FlowObserverDiagnostics {
    private val lock = Mutex()
    private val activeCounts = linkedMapOf<String, Int>()

    internal fun register(label: String) {
        runBlocking {
            lock.withLock {
                activeCounts[label] = (activeCounts[label] ?: 0) + 1
            }
        }
    }

    internal fun unregister(label: String) {
        runBlocking {
            lock.withLock {
                val current = activeCounts[label] ?: return@withLock
                if (current <= 1) {
                    activeCounts.remove(label)
                } else {
                    activeCounts[label] = current - 1
                }
            }
        }
    }

    fun activeCount(label: String? = null): Int {
        return runBlocking {
            lock.withLock {
                if (label == null) {
                    activeCounts.values.sum()
                } else {
                    activeCounts[label] ?: 0
                }
            }
        }
    }

    fun snapshot(): String {
        return runBlocking {
            lock.withLock {
                if (activeCounts.isEmpty()) {
                    "active=0"
                } else {
                    activeCounts.entries.joinToString(
                        prefix = "active=${activeCounts.values.sum()} [",
                        postfix = "]",
                    ) { "${it.key}=${it.value}" }
                }
            }
        }
    }
}

class FlowSubscription internal constructor(
    private val job: Job,
) {
    fun cancel() {
        job.cancel()
    }
}

internal fun <T> watchFlow(
    flow: Flow<T>,
    onEach: (T) -> Unit,
    label: String = "shared.flow",
): FlowSubscription {
    FlowObserverDiagnostics.register(label)
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    val job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
        flow.collect(onEach)
    }
    job.invokeOnCompletion {
        FlowObserverDiagnostics.unregister(label)
    }
    return FlowSubscription(job)
}
