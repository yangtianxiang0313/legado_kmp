package io.legado.kmp.shared.facade

import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/**
 * One immutable credential/destination snapshot for a caller-driven, non-atomic export batch.
 * Upload sequentially, keep every terminal result, then close, including on conflict or cancellation.
 */
class BookExportCloudSession internal constructor(
    private val preferencesStore: AppPreferencesStore,
    private val config: CloudBackupConfiguration,
) {
    private class State(val closed: Boolean = false, val active: Job? = null)

    private val state = MutableStateFlow(State())
    private val store = BookExportCloudStore(config)

    /** Idempotent; cancels an in-flight transfer without claiming it was rolled back remotely. */
    fun close() {
        while (true) {
            val before = state.value
            if (before.closed) return
            if (!state.compareAndSet(before, State(closed = true, active = before.active))) continue
            before.active?.cancel(CancellationException("Book export cloud session closed"))
            store.close()
            return
        }
    }

    /** Cancellation is returned as a terminal value, including any already observed PUT status. */
    suspend fun upload(
        fileName: String,
        data: ByteArray,
        overwrite: Boolean = false,
    ): BookExportCloudUploadResult {
        val transfer = BookExportCloudTransfer()
        var active: Job? = null
        var failure: Throwable? = null
        try {
            withContext(Dispatchers.Default) {
                withTimeout(300_000L) {
                    val job = currentCoroutineContext().job
                    begin(job)
                    active = job
                    suspend fun check() {
                        if (!bookExportCloudMatches(config, preferencesStore.runtimeConfig.value)) {
                            transfer.configurationChanged = true
                        }
                        if (transfer.configurationChanged) {
                            throw BookExportCloudFailure(BookExportCloudMessage.CONFIGURATION_CHANGED)
                        }
                        if (state.value.closed) throw CancellationException("Book export cloud session closed")
                        currentCoroutineContext().ensureActive()
                    }
                    check()
                    val contentType = bookExportCloudContentType(fileName, data)
                    val bytes = data.copyOf()
                    check()
                    val configurationWatch = launch(start = CoroutineStart.UNDISPATCHED) {
                        preferencesStore.runtimeConfig.collect { current ->
                            if (!bookExportCloudMatches(config, current)) {
                                transfer.configurationChanged = true
                                job.cancel(CancellationException("Book export cloud configuration changed"))
                            }
                        }
                    }
                    try {
                        store.ensureDirectory(::check)
                        store.upload(fileName, bytes, contentType, overwrite, transfer, ::check)
                        check()
                    } finally {
                        configurationWatch.cancel()
                    }
                }
            }
        } catch (error: Throwable) {
            // Do not send transport exceptions, response bodies or filenames to CrashCollector.
            failure = error
        } finally {
            active?.let(::end)
        }
        val changed = transfer.configurationChanged ||
            !bookExportCloudMatches(config, preferencesStore.runtimeConfig.value)
        val cancellation = findFacadeRequestCancellation(failure)
        val cancelled = !currentCoroutineContext().isActive || state.value.closed ||
            (cancellation != null && cancellation !is TimeoutCancellationException && !changed)
        val message = when {
            changed -> BookExportCloudMessage.CONFIGURATION_CHANGED.text
            state.value.closed -> BookExportCloudMessage.CLOSED.text
            cancelled -> null
            cancellation is TimeoutCancellationException -> BookExportCloudMessage.TIMED_OUT.text
            failure is BookExportCloudFailure -> failure.reason.text
            failure != null -> BookExportCloudMessage.FAILED.text
            else -> null
        }
        return transfer.result(cancelled, message)
    }

    /** Same terminal semantics as upload, including late cancellation after the server accepted PUT. */
    fun uploadRequest(
        fileName: String,
        data: ByteArray,
        overwrite: Boolean = false,
        onResult: (BookExportCloudUploadResult) -> Unit,
    ): FlowSubscription {
        val observed = MutableStateFlow<BookExportCloudUploadResult?>(null)
        return CancellableFacadeRequest.start(
            prepare = { upload(fileName, data, overwrite).also { observed.value = it } },
            cancelledResult = BookExportCloudUploadResult(isCancelled = true),
            failureResult = { BookExportCloudUploadResult(errorMessage = BookExportCloudMessage.FAILED.text) },
            onResult = { fallback ->
                // The generic wrapper prefers cancellation; retain the actual transfer evidence first.
                val recorded = observed.value
                val retained = if (recorded != null && fallback.isCancelled) {
                    recorded.copy(isCancelled = true)
                } else recorded ?: fallback
                val result = if (!bookExportCloudMatches(config, preferencesStore.runtimeConfig.value)) {
                    retained.copy(errorMessage = BookExportCloudMessage.CONFIGURATION_CHANGED.text)
                } else retained
                try {
                    onResult(result)
                } catch (_: Throwable) {
                    // Foreign callback errors can contain credentials or book data too.
                }
            },
            facade = "BookExportCloudSession",
            callbackMethod = "uploadRequest.onResult",
            missingResultMessage = "Book export cloud result unavailable",
        )
    }

    private fun begin(job: Job) {
        while (true) {
            val before = state.value
            if (before.closed) throw BookExportCloudFailure(BookExportCloudMessage.CLOSED)
            if (before.active != null) throw BookExportCloudFailure(BookExportCloudMessage.BUSY)
            if (state.compareAndSet(before, State(active = job))) return
        }
    }

    private fun end(job: Job) {
        while (true) {
            val before = state.value
            if (before.active !== job) return
            if (state.compareAndSet(before, State(closed = before.closed))) return
        }
    }
}

/** A response is recorded before cancellation/configuration checks can hide its remote outcome. */
internal class BookExportCloudTransfer {
    private val dispatched = MutableStateFlow(false)
    private val status = MutableStateFlow<Int?>(null)
    private val changed = MutableStateFlow(false)

    var configurationChanged: Boolean
        get() = changed.value
        set(value) { if (value) changed.value = true }

    fun dispatch() { dispatched.value = true }
    fun receive(value: Int) { status.value = value }

    fun result(cancelled: Boolean, message: String?): BookExportCloudUploadResult {
        val code = status.value
        val success = code == 200 || code == 201 || code == 204
        val conflict = code == 412
        // A transport error after dispatch, 202/207 or even a server error cannot prove no write occurred.
        val possibleWrite = dispatched.value &&
            (code == null || code in 200..399 || code == 408 || code >= 500)
        return BookExportCloudUploadResult(
            success = success,
            conflict = conflict,
            isCancelled = cancelled,
            mayHaveUploaded = possibleWrite,
            errorMessage = message ?: when {
                conflict -> BookExportCloudMessage.CONFLICT.text
                success || cancelled -> null
                else -> BookExportCloudMessage.FAILED.text
            },
        )
    }
}
