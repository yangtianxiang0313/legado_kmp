package io.legado.kmp.shared.facade

import io.legado.kmp.shared.image.ImageDiskCache
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.cancellation.CancellationException

/** File existence and readable dimensions alone do not establish a usable cached image. */
internal suspend fun ImageDiskCache.readValidatedImage(bookFolder: String, src: String): ByteArray? {
    val bytes = getImage(bookFolder, src) ?: return null
    currentCoroutineContext().ensureActive()
    try {
        validateCacheImage(bytes)
        return bytes
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        deleteImage(bookFolder, src)
        return null
    }
}

/** Callers publish to memory only after this returns the exact, fully validated persisted bytes. */
internal suspend fun ImageDiskCache.writeValidatedImage(bookFolder: String, src: String, bytes: ByteArray): ByteArray {
    validateCacheImage(bytes)
    currentCoroutineContext().ensureActive()
    val previous = readValidatedImage(bookFolder, src)
    try {
        writeImage(bookFolder, src, bytes)
        currentCoroutineContext().ensureActive()
        val persisted = getImage(bookFolder, src)
        currentCoroutineContext().ensureActive()
        check(persisted != null && persisted.contentEquals(bytes)) { "Image cache write could not be read back completely" }
        return persisted
    } catch (error: Exception) {
        withContext(NonCancellable) {
            try {
                if (previous == null) {
                    deleteImage(bookFolder, src)
                } else {
                    writeImage(bookFolder, src, previous)
                    val restored = getImage(bookFolder, src)
                    if (restored == null || !restored.contentEquals(previous)) deleteImage(bookFolder, src)
                }
            } catch (restoreError: Exception) {
                CrashCollector.record("ValidatedImageCache", "restoreAfterFailedWrite", error = restoreError)
                try {
                    deleteImage(bookFolder, src)
                } catch (cleanupError: Exception) {
                    CrashCollector.record("ValidatedImageCache", "removeAfterFailedWrite", error = cleanupError)
                }
            }
        }
        throw error
    }
}
