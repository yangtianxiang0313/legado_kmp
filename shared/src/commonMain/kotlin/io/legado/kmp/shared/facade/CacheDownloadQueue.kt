package io.legado.kmp.shared.facade

import io.legado.kmp.shared.platform.ConsumerConcurrencyPolicy
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class CacheDownloadQueue {
    private data class State(
        val pending: Int = 0,
        val active: Int = 0,
        val stopped: Boolean = false,
        val loading: Boolean = false,
    )

    private val lock = Mutex()
    private val pending = linkedSetOf<Int>()
    private val active = mutableSetOf<Int>()
    private val state = MutableStateFlow(State())
    val pendingCount: Int get() = state.value.pending
    val activeCount: Int get() = state.value.active
    val isLoading: Boolean get() = state.value.loading
    val isRunning: Boolean get() = state.value.let { it.pending > 0 || it.active > 0 || it.loading }
    val isStopped: Boolean get() = state.value.stopped || !isRunning

    fun setLoading() = lock.withCacheState { state.value = state.value.copy(loading = true) }

    fun add(start: Int, end: Int) = lock.withCacheState {
        for (index in start..end) {
            if (index !in active) pending.add(index)
        }
        publish(stopped = false, loading = false)
    }

    // Claim before the first suspension, including database and cache lookups.
    fun claimNext(): Int? = lock.withCacheState {
        if (state.value.stopped) return@withCacheState null
        val index = pending.firstOrNull() ?: return@withCacheState null
        pending.remove(index)
        active.add(index)
        publish()
        index
    }

    fun claim(index: Int): Boolean = lock.withCacheState {
        if (!active.add(index)) return@withCacheState false
        pending.remove(index)
        publish()
        true
    }

    fun finish(index: Int, retry: Boolean = false) = lock.withCacheState {
        if (!active.remove(index)) return@withCacheState
        if (retry && !state.value.stopped) pending.add(index)
        publish()
    }

    fun stop() = lock.withCacheState {
        pending.clear()
        publish(stopped = true, loading = false)
    }

    private fun publish(stopped: Boolean = state.value.stopped, loading: Boolean = state.value.loading) {
        state.value = State(pending.size, active.size, stopped, loading)
    }

    suspend fun awaitPending(working: StateFlow<Boolean>): Boolean = combine(state, working) { queue, enabled ->
        when {
            queue.stopped || (queue.pending == 0 && queue.active == 0 && !queue.loading) -> false
            enabled && queue.pending > 0 -> true
            else -> null
        }
    }.filterNotNull().first()
}

// These synchronous sections only mutate in-memory state; never perform I/O or callbacks here.
internal fun <T> Mutex.withCacheState(block: () -> T): T = runBlocking {
    this@withCacheState.withLock { block() }
}

internal class CacheDownloadLimiter {
    private data class State(val limit: Int = 3, val active: Int = 0)
    private val state = MutableStateFlow(State())

    class Permit internal constructor(private val limiter: CacheDownloadLimiter) {
        private val released = MutableStateFlow(false)

        fun release() {
            if (released.compareAndSet(false, true)) {
                limiter.state.update { it.copy(active = it.active - 1) }
            }
        }
    }

    fun configure(limit: Int) = state.update {
        it.copy(limit = ConsumerConcurrencyPolicy.configuredLimit(limit))
    }

    // Only book dispatchers wait here; a chapter task is created after admission.
    suspend fun acquire(): Permit {
        while (true) {
            coroutineContext.ensureActive()
            val available = state.first { it.active < it.limit }
            coroutineContext.ensureActive()
            if (state.compareAndSet(available, available.copy(active = available.active + 1))) {
                return Permit(this)
            }
        }
    }
}
