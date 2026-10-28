package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Ordinary mode keeps best-effort uploads, but a slow WebDAV never holds local page persistence. */
internal class ReaderProgressUploadQueue(
    private val preferences: AppPreferencesStore,
    private val settings: SettingsFacade,
) {
    private val lock = Mutex()
    private var pending: Book? = null
    private var worker: Job? = null
    private var workerToken: Any? = null

    suspend fun stage(book: Book) {
        if (book.isNotShelf) return
        val snapshot = book.copy(readConfig = book.readConfig?.copy())
        lock.withLock {
            pending = snapshot
            if (worker == null) startWorkerLocked()
        }
    }

    private fun startWorkerLocked() {
        // This scope exists only for this drain; a factory Reader never leaves an idle collector behind.
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val token = Any()
        workerToken = token
        worker = scope.launch(start = CoroutineStart.LAZY) {
            try {
                drain()
            } finally {
                try {
                    withContext(NonCancellable) {
                        lock.withLock {
                            if (workerToken === token) {
                                worker = null
                                workerToken = null
                                // A stage may have arrived while the cancelled upload was settling.
                                if (pending != null) startWorkerLocked()
                            }
                        }
                    }
                } finally {
                    scope.cancel()
                }
            }
        }
        worker?.start()
    }

    private suspend fun drain() {
        while (true) {
            delay(800)
            val latest = lock.withLock {
                pending.also { pending = null }
            } ?: return
            try {
                val config = preferences.runtimeConfig.first()
                // Plus compares at lifecycle boundaries, never blind PUT on each page.
                if (config.syncBookProgress && !config.syncBookProgressPlus && !latest.isNotShelf &&
                    !config.webDavAccount.isNullOrBlank() && !config.webDavPassword.isNullOrBlank()
                ) {
                    settings.uploadBookProgress(latest)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                CrashCollector.record("ReaderProgressUploadQueue", "upload", error = error)
            }
        }
    }
}
