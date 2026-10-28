package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.coroutineContext
import kotlin.time.TimeSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

internal class ReaderReadTimeSupport(
    private val getBookUseCase: GetBookUseCase,
    private val readRecordRepository: ReadRecordRepository,
    private val preferencesStore: AppPreferencesStore,
) {
    private data class Session(
        val bookUrl: String,
        val checkpoint: TimeSource.Monotonic.ValueTimeMark,
        val enabled: Boolean,
        val token: Any,
        val observer: Job,
    )

    private data class Increment(
        val bookUrl: String,
        val elapsedMillis: Long,
        val lastRead: Long,
    )

    private data class State(
        val session: Session? = null,
        val pending: List<Increment> = emptyList(),
    )

    private val state = MutableStateFlow(State())
    private val writeMutex = Mutex()
    private val observationScope = CoroutineScope(Dispatchers.Unconfined)

    fun beginReadSession(bookUrl: String) {
        if (bookUrl.isBlank()) return
        while (true) {
            val previous = state.value
            if (previous.session?.bookUrl == bookUrl) return
            val token = Any()
            val observer = observationScope.launch(start = CoroutineStart.LAZY) {
                preferencesStore.runtimeConfig.map { it.enableReadRecord }.distinctUntilChanged().collect { enabled ->
                    state.update { current ->
                        val session = current.session
                        if (session == null || session.token !== token || session.enabled == enabled) current
                        else current.copy(session = session.copy(checkpoint = TimeSource.Monotonic.markNow(), enabled = enabled))
                    }
                }
            }
            val session = Session(bookUrl, TimeSource.Monotonic.markNow(), isEnabled(), token, observer)
            if (state.compareAndSet(previous, previous.copy(session = session))) {
                previous.session?.observer?.cancel()
                observer.start()
                return
            }
            observer.cancel()
        }
    }

    suspend fun updateReadTime(bookUrl: String) {
        if (checkpoint(bookUrl, end = false)) drainPending()
    }

    suspend fun endReadSession(bookUrl: String) {
        // Stop before waiting for either the write mutex or the book lookup.
        if (checkpoint(bookUrl, end = true)) drainPending()
    }

    suspend fun endActiveSession() {
        if (checkpoint(bookUrl = null, end = true)) drainPending()
    }

    suspend fun prepareRecord(book: Book) {
        if (isEnabled()) readRecordRepository.ensureLocalRecord(book.name, currentTimeMillis())
    }

    private fun checkpoint(bookUrl: String?, end: Boolean): Boolean {
        while (true) {
            val previous = state.value
            val session = previous.session
            if (session == null || (bookUrl != null && session.bookUrl != bookUrl)) {
                return previous.pending.any { bookUrl == null || it.bookUrl == bookUrl }
            }
            val now = TimeSource.Monotonic.markNow()
            val enabled = isEnabled()
            val elapsed = (now - session.checkpoint).inWholeMilliseconds.coerceAtLeast(0L)
            val increment = if (session.enabled && enabled && elapsed > 0L) {
                Increment(session.bookUrl, elapsed, currentTimeMillis().coerceAtLeast(0L))
            } else {
                null
            }
            val next = previous.copy(
                session = if (end) null else session.copy(checkpoint = now, enabled = enabled),
                pending = if (increment == null) previous.pending else previous.pending + increment,
            )
            if (state.compareAndSet(previous, next)) {
                if (end) session.observer.cancel()
                return next.pending.isNotEmpty()
            }
        }
    }

    private suspend fun drainPending() = writeMutex.withLock {
        while (true) {
            val increment = state.value.pending.firstOrNull() ?: break
            coroutineContext.ensureActive()
            val book = if (isEnabled()) getBookUseCase.get(increment.bookUrl) else null
            coroutineContext.ensureActive()
            if (book != null && isEnabled()) {
                readRecordRepository.addReadTime(book.name, increment.elapsedMillis, increment.lastRead)
            }
            // No suspension after a successful write: a retry must not count this slice twice.
            state.update { it.copy(pending = it.pending.drop(1)) }
        }
    }

    private fun isEnabled(): Boolean = preferencesStore.runtimeConfig.value.enableReadRecord
}
