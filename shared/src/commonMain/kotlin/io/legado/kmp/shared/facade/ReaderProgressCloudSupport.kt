package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Serializes progress traffic without holding a database transaction over network I/O. */
internal class ReaderProgressCloudSupport(
    private val preferences: AppPreferencesStore,
    private val books: BookRepository?,
) {
    private val traffic = Mutex()
    private val transport = ReaderProgressWebDav()

    suspend fun read(name: String, author: String): BookProgress? = traffic.withLock {
        val endpoint = ReaderProgressWebDav.endpoint(preferences.runtimeConfig.first())
            ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV 未配置")
        val document = transport.read(endpoint, name, author)
        requireEndpoint(endpoint)
        document.progress
    }

    suspend fun upload(book: Book) = traffic.withLock {
        if (book.isNotShelf) return@withLock
        val current = currentBook(book) ?: return@withLock
        val endpoint = ReaderProgressWebDav.endpoint(preferences.runtimeConfig.first())
            ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV 未配置")
        currentCoroutineContext().ensureActive()
        transport.write(endpoint, BookProgress(current))
        requireEndpoint(endpoint)
    }

    suspend fun upload(progress: BookProgress) = traffic.withLock {
        val endpoint = ReaderProgressWebDav.endpoint(preferences.runtimeConfig.first())
            ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV 未配置")
        if (progress.durChapterIndex < 0 || progress.durChapterPos < 0 || progress.durChapterTime < 0) {
            throw RecoverableSharedException("PROGRESS_INVALID", "阅读进度无效")
        }
        transport.write(endpoint, progress)
        requireEndpoint(endpoint)
    }

    suspend fun sync(book: Book): SyncProgressResult = traffic.withLock {
        val config = preferences.runtimeConfig.first()
        if (!config.syncBookProgress || book.isNotShelf) return@withLock SyncProgressResult.Disabled
        val endpoint = ReaderProgressWebDav.endpoint(config)
            ?: throw RecoverableSharedException("WEBDAV_NOT_CONFIGURED", "WebDAV 未配置")
        val before = currentBook(book) ?: return@withLock SyncProgressResult.Disabled
        val document = transport.read(endpoint, before.name, before.author)
        requireEndpoint(endpoint)
        val latestConfig = preferences.runtimeConfig.first()
        if (!latestConfig.syncBookProgress || latestConfig.syncBookProgressPlus != config.syncBookProgressPlus) {
            throw kotlin.coroutines.cancellation.CancellationException("Progress synchronization settings changed")
        }
        val latest = currentBook(before) ?: return@withLock SyncProgressResult.Disabled
        val remote = document.progress
        if (remote != null && samePosition(latest, remote)) return@withLock SyncProgressResult.InSync
        val localChanged = !sameReaderProgressRevision(before, latest)
        if (remote != null && (isRemoteAhead(latest, remote) ||
                (config.syncBookProgressPlus && (remote.durChapterTime > latest.durChapterTime || localChanged)))
        ) {
            // Never apply a downloaded position here, even if the reader was idle when GET began.
            return@withLock SyncProgressResult.ServerAhead(remote)
        }
        // A rewind made during GET is a new local decision, not permission to overwrite either side.
        if (localChanged) {
            throw RecoverableSharedException("PROGRESS_LOCAL_CHANGED", "本地阅读进度已改变，请重新同步")
        }
        currentCoroutineContext().ensureActive()
        transport.write(endpoint, BookProgress(latest), document)
        requireEndpoint(endpoint)
        SyncProgressResult.LocalAhead
    }

    private suspend fun currentBook(expected: Book): Book? {
        val current = if (books != null) books.getBook(expected.bookUrl) else expected
        currentCoroutineContext().ensureActive()
        if (current == null || !sameReaderProgressIdentity(expected, current)) {
            throw kotlin.coroutines.cancellation.CancellationException("Progress book was removed or changed source")
        }
        return current.takeUnless { it.isNotShelf }
    }

    private suspend fun requireEndpoint(expected: ReaderProgressWebDav.Endpoint) {
        currentCoroutineContext().ensureActive()
        if (ReaderProgressWebDav.endpoint(preferences.runtimeConfig.first()) != expected) {
            throw kotlin.coroutines.cancellation.CancellationException("Progress WebDAV account changed")
        }
    }

    private fun samePosition(book: Book, progress: BookProgress): Boolean =
        book.durChapterIndex == progress.durChapterIndex && book.durChapterPos == progress.durChapterPos

    private fun isRemoteAhead(book: Book, progress: BookProgress): Boolean =
        progress.durChapterIndex > book.durChapterIndex ||
            (progress.durChapterIndex == book.durChapterIndex && progress.durChapterPos > book.durChapterPos)
}

internal fun sameReaderProgressIdentity(expected: Book, actual: Book): Boolean =
    expected.bookUrl == actual.bookUrl && expected.origin == actual.origin && expected.tocUrl == actual.tocUrl &&
        expected.config.reverseToc == actual.config.reverseToc && expected.name == actual.name && expected.author == actual.author

internal fun sameReaderProgressRevision(expected: Book, actual: Book): Boolean =
    sameReaderProgressIdentity(expected, actual) && expected.durChapterIndex == actual.durChapterIndex &&
        expected.durChapterPos == actual.durChapterPos && expected.durChapterTime == actual.durChapterTime &&
        expected.durChapterTitle == actual.durChapterTitle
