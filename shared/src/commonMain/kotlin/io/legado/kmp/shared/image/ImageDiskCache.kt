package io.legado.kmp.shared.image

import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.util.md5Hex
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlin.coroutines.cancellation.CancellationException

/**
 * Image disk cache interface mirroring legado BookHelp.getImage/writeImage/isImageExist.
 */
interface ImageDiskCache {
    /** Changed book folders, used to refresh offline-readable chapter indicators. */
    val changes: Flow<String> get() = emptyFlow()
    suspend fun isImageExist(bookFolderName: String, src: String): Boolean
    suspend fun getImage(bookFolderName: String, src: String): ByteArray?
    suspend fun writeImage(bookFolderName: String, src: String, data: ByteArray)
    fun getImagePath(bookFolderName: String, src: String): String
    suspend fun deleteImage(bookFolderName: String, src: String): Boolean
}

/**
 * File-system backed image disk cache.
 *
 * Uses the same MD5-based file naming strategy as legado:
 *   - Cache key = MD5(src).substring(0, 16) + "." + suffix
 *   - Path = <appFilesDir>/book_cache/<bookFolderName>/images/<cacheKey>
 *
 * File I/O is delegated to [FileAccess] (expect/actual per platform).
 */
class FileImageDiskCache(
    private val fileAccess: FileAccess,
    private val appFilesDirectory: AppFilesDirectory,
) : ImageDiskCache {
    private val updates = MutableSharedFlow<String>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val changes: Flow<String> = updates.asSharedFlow()
    companion object {
        private const val CACHE_DIR = "book_cache"
        private const val IMAGES_DIR = "images"
    }

    override suspend fun isImageExist(bookFolderName: String, src: String): Boolean {
        val path = imagePath(bookFolderName, src)
        return fileAccess.exists(path)
    }

    override suspend fun getImage(bookFolderName: String, src: String): ByteArray? {
        val path = imagePath(bookFolderName, src)
        if (!fileAccess.exists(path)) return null
        return try {
            fileAccess.read(path)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            null
        }
    }

    override suspend fun writeImage(bookFolderName: String, src: String, data: ByteArray) {
        val dirPath = imageDir(bookFolderName)
        fileAccess.createDirectory(dirPath)
        val path = imagePath(bookFolderName, src)
        check(fileAccess.write(path, data)) { "Failed to persist book image" }
        updates.tryEmit(bookFolderName)
    }

    override fun getImagePath(bookFolderName: String, src: String): String {
        return imagePath(bookFolderName, src)
    }

    override suspend fun deleteImage(bookFolderName: String, src: String): Boolean {
        val path = imagePath(bookFolderName, src)
        val removed = fileAccess.delete(path)
        if (removed) updates.tryEmit(bookFolderName)
        return removed
    }

    private fun imagePath(bookFolderName: String, src: String): String {
        val cacheKey = md5Encode16(src) + "." + getImageSuffix(src)
        val baseDir = appFilesDirectory.path()
        return "$baseDir/$CACHE_DIR/$bookFolderName/$IMAGES_DIR/$cacheKey"
    }

    private fun imageDir(bookFolderName: String): String {
        val baseDir = appFilesDirectory.path()
        return "$baseDir/$CACHE_DIR/$bookFolderName/$IMAGES_DIR"
    }
}

/**
 * Get first 16 chars of MD5 hash, matching legado MD5Utils.md5Encode16.
 */
internal fun md5Encode16(input: String): String {
    val full = input.md5Hex()
    // legado md5Encode16 returns chars 8..24 (16 chars from the middle)
    return full.substring(8, 24)
}

/**
 * Extract image suffix from URL, defaulting to "jpg".
 * Matches legado BookHelp.getImageSuffix / UrlUtil.getSuffix.
 */
internal fun getImageSuffix(src: String): String {
    val urlPath = src.substringBefore('?').substringBefore('#')
    val lastDot = urlPath.lastIndexOf('.')
    if (lastDot < 0) return "jpg"
    val suffix = urlPath.substring(lastDot + 1).lowercase()
    if (suffix.length > 5 || suffix.isEmpty()) return "jpg"
    return suffix
}
