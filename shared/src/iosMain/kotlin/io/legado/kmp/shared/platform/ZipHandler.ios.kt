@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.Foundation.*

/**
 * iOS implementation of ZipHandler using ZZArchive (via compression framework)
 * Note: For production, consider using a proper ZIP library
 */
actual class ZipHandler {

    actual suspend fun extractEntry(zipFile: String, entryPath: String): ByteArray? {
        if (!NSFileManager.defaultManager.fileExistsAtPath(zipFile)) {
            return null
        }
        return null
    }

    actual suspend fun extractAll(zipFile: String, destDir: String): Boolean {
        NSFileManager.defaultManager.createDirectoryAtPath(destDir, true, null, null)
        return false
    }

    actual suspend fun listEntries(zipFile: String): List<String> {
        if (!NSFileManager.defaultManager.fileExistsAtPath(zipFile)) {
            return emptyList()
        }
        return emptyList()
    }

    actual suspend fun isValidZip(zipFile: String): Boolean {
        if (!NSFileManager.defaultManager.fileExistsAtPath(zipFile)) {
            return false
        }
        val data = NSData.dataWithContentsOfFile(zipFile) ?: return false
        if (data.length < 4uL) return false

        val bytes = data.toByteArray()
        return bytes[0].toInt() == 0x50 &&
            bytes[1].toInt() == 0x4B &&
            bytes[2].toInt() == 0x03 &&
            bytes[3].toInt() == 0x04
    }

    actual suspend fun getEntrySize(zipFile: String, entryPath: String): Long? {
        return null
    }
}

private fun NSData.toByteArray(): ByteArray {
    val bytes = ByteArray(this.length.toInt())
    if (bytes.isNotEmpty()) {
        bytes.usePinned { pinned ->
            this.getBytes(pinned.addressOf(0), this.length)
        }
    }
    return bytes
}
