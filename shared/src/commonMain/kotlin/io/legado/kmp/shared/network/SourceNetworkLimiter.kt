package io.legado.kmp.shared.network

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** One gate per source, shared by text, resource and native file consumers. */
object SourceNetworkLimiter {
    private val mutex = Mutex()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private class Gate(var active: Int = 0, val changed: Channel<Unit> = Channel(Channel.CONFLATED))
    private val gates = mutableMapOf<String, Gate>()

    @Throws(Exception::class)
    suspend fun acquire(sourceUrl: String): SourceNetworkLease {
        val gate = mutex.withLock { gates.getOrPut(sourceUrl) { Gate() } }
        while (true) {
            val acquired = mutex.withLock {
                val limit = SourceNetworkPolicy.effective(sourceUrl).maxConcurrent ?: 6
                if (gate.active < limit) {
                    gate.active++
                    if (gate.active < limit) gate.changed.trySend(Unit)
                    true
                } else false
            }
            if (acquired) return SourceNetworkLease { scope.launch {
                mutex.withLock { gate.active--; gate.changed.trySend(Unit) }
            } }
            gate.changed.receive()
        }
    }

    internal suspend fun <T> withPermit(sourceUrl: String?, operation: suspend () -> T): T {
        if (sourceUrl.isNullOrBlank()) return operation()
        val lease = acquire(sourceUrl)
        return try { operation() } finally { lease.close() }
    }

    internal fun settingsChanged() { scope.launch { mutex.withLock { gates.values.forEach { it.changed.trySend(Unit) } } } }
}

class SourceNetworkLease internal constructor(private var release: (() -> Unit)?) {
    private val mutex = Mutex()
    fun close() {
        // All releases are serialized, including native cancellation and completion racing each other.
        CoroutineScope(Dispatchers.Default).launch { mutex.withLock {
            val action = release; release = null; action?.invoke()
        } }
    }
}
