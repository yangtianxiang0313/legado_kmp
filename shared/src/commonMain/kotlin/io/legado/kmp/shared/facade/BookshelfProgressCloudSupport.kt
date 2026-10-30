package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.ReadingProgressImportGuard
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.withContext

/** Startup imports only an ahead position; it never uploads or confirms a remote rewind. */
internal class BookshelfProgressCloudSupport(
    private val preferences: AppPreferencesStore,
    private val books: BookRepository?,
) {
    suspend fun sync(): BookshelfProgressSyncResult {
        val config = preferences.runtimeConfig.value
        if (!config.syncBookProgress) return BookshelfProgressSyncResult(disabled = true)
        val endpoint = ReaderProgressWebDav.endpoint(config)
            ?: return BookshelfProgressSyncResult(disabled = true)
        val repository = books ?: return BookshelfProgressSyncResult()
        currentCoroutineContext().ensureActive()
        if (!operations.tryLock()) {
            throw RecoverableSharedException("PROGRESS_SYNC_BUSY", "另一项书架进度同步正在进行")
        }
        val transport = ReaderProgressWebDav()
        try {
            val snapshot = repository.getAllBooks().filterNot { it.isNotShelf }
            if (snapshot.isEmpty()) return BookshelfProgressSyncResult()
            val files = transport.list(endpoint)
            val context = currentCoroutineContext()
            fun checkCurrent() {
                context.ensureActive()
                val current = preferences.runtimeConfig.value
                if (!current.syncBookProgress || ReaderProgressWebDav.endpoint(current) != endpoint) {
                    throw CancellationException("Bookshelf progress account or settings changed")
                }
            }
            checkCurrent()
            var updated = 0
            var skipped = 0
            var failed = 0
            for (book in snapshot) {
                checkCurrent()
                val modified = files[ReaderProgressWebDav.progressFileName(book.name, book.author)]
                if (modified == null || modified <= book.syncTime) {
                    skipped++
                    continue
                }
                val progress = try {
                    transport.read(endpoint, book.name, book.author).progress
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Exception) {
                    findFacadeRequestCancellation(error)?.let { throw it }
                    checkCurrent()
                    // A bad document must not prevent later healthy books from synchronizing.
                    if ((error as? RecoverableSharedException)?.code == "WEBDAV_AUTH") throw error
                    failed++
                    continue
                }
                checkCurrent()
                if (progress == null || (progress.durChapterIndex < book.durChapterIndex ||
                        (progress.durChapterIndex == book.durChapterIndex && progress.durChapterPos <= book.durChapterPos))) {
                    skipped++
                    continue
                }
                val applied = withContext(ReadingProgressImportGuard(::checkCurrent)) {
                    repository.importReadingProgressIfUnchanged(book, progress, currentTimeMillis())
                }
                if (applied.persisted) updated++ else skipped++
            }
            return BookshelfProgressSyncResult(updated, skipped, failed)
        } catch (error: Exception) {
            findFacadeRequestCancellation(error)?.let { throw it }
            currentCoroutineContext().ensureActive()
            if (error is RecoverableSharedException) throw error
            throw RecoverableSharedException("PROGRESS_SYNC_FAILED", "书架云端进度同步失败，请检查 WebDAV 配置和网络")
        } finally {
            try {
                transport.close()
            } finally {
                operations.unlock()
            }
        }
    }

    private companion object {
        val operations = Mutex()
    }
}
