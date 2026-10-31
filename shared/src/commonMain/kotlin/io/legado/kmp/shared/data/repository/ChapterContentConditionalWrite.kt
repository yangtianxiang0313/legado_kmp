package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.platform.FileAccess
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/** The caller must hold the real cache root's [ChapterCacheLocks] lease throughout this call. */
internal suspend fun FileAccess.writeChapterContentIfUnchanged(
    directory: String,
    path: String,
    expectedContent: String?,
    content: String,
): Boolean {
    if (content.isEmpty()) return false
    currentCoroutineContext().ensureActive()
    val previousBytes = readChapterBytesOrNull(path)
    val previousContent = previousBytes?.decodeToString()?.takeIf { it.isNotEmpty() }
    currentCoroutineContext().ensureActive()
    if (previousContent != expectedContent) return false

    val directoryReady = createDirectory(directory)
    currentCoroutineContext().ensureActive()
    if (!directoryReady) return false
    val replacementBytes = content.encodeToByteArray()
    currentCoroutineContext().ensureActive()

    var writeFailure: Throwable? = null
    val saved = try {
        val accepted = write(path, replacementBytes)
        currentCoroutineContext().ensureActive()
        val verified = accepted && read(path).contentEquals(replacementBytes)
        currentCoroutineContext().ensureActive()
        verified
    } catch (failure: Throwable) {
        writeFailure = failure
        false
    }
    if (saved) return true

    val failure = writeFailure ?: IllegalStateException("Failed to write and verify chapter content: $path")
    try {
        withContext(NonCancellable) {
            restoreChapterBytes(path, previousBytes)
        }
    } catch (restoreFailure: Throwable) {
        failure.addSuppressed(restoreFailure)
        throw failure
    }
    if (writeFailure != null) throw failure
    currentCoroutineContext().ensureActive()
    return false
}

private suspend fun FileAccess.readChapterBytesOrNull(path: String): ByteArray? {
    return if (exists(path)) read(path) else null
}

private suspend fun FileAccess.restoreChapterBytes(path: String, previousBytes: ByteArray?) {
    val current = runCatching { readChapterBytesOrNull(path) }
    if (current.isSuccess && sameChapterBytes(current.getOrThrow(), previousBytes)) return

    val restore = runCatching {
        if (previousBytes == null) delete(path) else write(path, previousBytes)
    }
    // A rejected or throwing atomic write can still have left the exact old bytes intact.
    val restored = runCatching { readChapterBytesOrNull(path) }
    if (restored.isSuccess && sameChapterBytes(restored.getOrThrow(), previousBytes)) return

    val failure = IllegalStateException("Failed to restore previous chapter content bytes: $path")
    restore.exceptionOrNull()?.let { failure.addSuppressed(it) }
    restored.exceptionOrNull()?.let { failure.addSuppressed(it) }

    // Never delete an unreadable file that might still contain the good original bytes.
    // If no file existed before, any remaining file belongs to the failed write.
    if (previousBytes == null || (restored.isSuccess && restored.getOrThrow() != null)) {
        try {
            if (exists(path)) check(delete(path)) { "Failed to remove invalid chapter content: $path" }
            check(!exists(path)) { "Invalid chapter content remains after cleanup: $path" }
        } catch (cleanupFailure: Throwable) {
            failure.addSuppressed(cleanupFailure)
        }
    }
    throw failure
}

private fun sameChapterBytes(first: ByteArray?, second: ByteArray?): Boolean {
    return if (first == null) second == null else second != null && first.contentEquals(second)
}
