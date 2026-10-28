@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import io.legado.kmp.shared.domain.localbook.LocalBookByteSource
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import platform.Foundation.*
import platform.posix.EINTR
import platform.posix.O_CLOEXEC
import platform.posix.O_NONBLOCK
import platform.posix.O_RDONLY
import platform.posix.S_IFMT
import platform.posix.S_IFREG
import platform.posix.errno
import platform.posix.fstat
import platform.posix.pread
import platform.posix.stat
import platform.posix.close as posixClose
import platform.posix.open as posixOpen

/**
 * iOS implementation of FileAccess using NSFileManager
 */
actual class FileAccess {

    @Throws(Exception::class)
    actual fun openRead(path: String): LocalBookByteSource {
        require('\u0000' !in path) { "File path must not contain NUL" }
        var resolvedPath = path
        var descriptor = openReadDescriptor(resolvedPath)
        if (descriptor < 0) {
            val openError = errno
            resolvedPath = reboundSandboxPath(path)
                ?: throw localBookFileError("open", path, openError)
            descriptor = openReadDescriptor(resolvedPath)
            if (descriptor < 0) {
                throw localBookFileError("open", resolvedPath, errno)
            }
        }

        return try {
            val size = memScoped {
                val info = alloc<stat>()
                while (fstat(descriptor, info.ptr) != 0) {
                    val statError = errno
                    if (statError != EINTR) {
                        throw localBookFileError("fstat", resolvedPath, statError)
                    }
                }
                check((info.st_mode.toInt() and S_IFMT.toInt()) == S_IFREG.toInt()) {
                    "Local book byte source requires a regular file: $resolvedPath"
                }
                check(info.st_size >= 0L) { "Invalid file size: $resolvedPath" }
                info.st_size
            }
            PosixLocalBookByteSource(descriptor, size, resolvedPath)
        } catch (failure: Throwable) {
            try {
                closeReadDescriptor(descriptor, resolvedPath)
            } catch (closeFailure: Throwable) {
                failure.addSuppressed(closeFailure)
            }
            throw failure
        }
    }

    actual suspend fun read(path: String): ByteArray {
        val data = NSData.dataWithContentsOfFile(path)
            ?: reboundSandboxPath(path)?.let { NSData.dataWithContentsOfFile(it) }
            ?: error("Failed to read file: $path")

        return data.toByteArray()
    }

    actual suspend fun write(path: String, data: ByteArray): Boolean {
        return data.toNSData().writeToFile(path, true)
    }

    actual suspend fun exists(path: String): Boolean {
        return NSFileManager.defaultManager.fileExistsAtPath(path)
            || reboundSandboxPath(path)?.let { NSFileManager.defaultManager.fileExistsAtPath(it) } == true
    }

    actual suspend fun delete(path: String): Boolean {
        return runCatching {
            val resolved = if (NSFileManager.defaultManager.fileExistsAtPath(path)) path else reboundSandboxPath(path) ?: path
            NSFileManager.defaultManager.removeItemAtPath(resolved, null)
        }.getOrDefault(false)
    }

    actual suspend fun getSize(path: String): Long {
        val attrs = NSFileManager.defaultManager.attributesOfItemAtPath(path, null)
            ?: reboundSandboxPath(path)?.let { NSFileManager.defaultManager.attributesOfItemAtPath(it, null) }
            ?: return 0L
        return (attrs[NSFileSize] as? NSNumber)?.longValue ?: 0L
    }

    actual suspend fun lastModified(path: String): Long? {
        val attrs = NSFileManager.defaultManager.attributesOfItemAtPath(path, null)
            ?: reboundSandboxPath(path)?.let { NSFileManager.defaultManager.attributesOfItemAtPath(it, null) }
            ?: return null
        return (attrs[NSFileModificationDate] as? NSDate)?.timeIntervalSince1970?.times(1000.0)?.toLong()
    }

    actual suspend fun listFiles(path: String): List<String> {
        val contents = NSFileManager.defaultManager.contentsOfDirectoryAtPath(path, null)
            ?: return emptyList()
        return (contents as List<*>).mapNotNull { it as? String }
    }

    actual suspend fun createDirectory(path: String): Boolean {
        if (exists(path)) return true
        return runCatching {
            NSFileManager.defaultManager.createDirectoryAtPath(path, true, null, null)
        }.getOrDefault(false)
    }

    actual suspend fun move(fromPath: String, toPath: String): Boolean {
        val manager = NSFileManager.defaultManager
        if (!manager.fileExistsAtPath(fromPath) || manager.fileExistsAtPath(toPath)) return false
        return manager.moveItemAtPath(fromPath, toPath, null)
    }
}

private class PosixLocalBookByteSource(
    private var descriptor: Int,
    override val size: Long,
    private val path: String
) : LocalBookByteSource {
    private val lock = NSLock()

    override fun read(offset: Long, length: Int): ByteArray {
        require(offset >= 0L) { "Byte offset must not be negative: $offset" }
        require(length >= 0) { "Byte length must not be negative: $length" }
        lock.lock()
        try {
            check(descriptor >= 0) { "Local book byte source is closed" }
            if (length == 0 || offset >= size) return ByteArray(0)

            val count = minOf(length.toLong(), size - offset).toInt()
            val bytes = ByteArray(count)
            var bytesRead = 0
            bytes.usePinned { pinned ->
                while (bytesRead < count) {
                    val result = pread(
                        descriptor,
                        pinned.addressOf(bytesRead),
                        (count - bytesRead).toULong(),
                        offset + bytesRead.toLong()
                    )
                    when {
                        result > 0L -> bytesRead += result.toInt()
                        result == 0L -> break
                        else -> {
                            val readError = errno
                            if (readError != EINTR) {
                                throw localBookFileError("pread", path, readError)
                            }
                        }
                    }
                }
            }
            return if (bytesRead == count) bytes else bytes.copyOf(bytesRead)
        } finally {
            lock.unlock()
        }
    }

    override fun closeSource() {
        lock.lock()
        try {
            if (descriptor < 0) return
            val closingDescriptor = descriptor
            descriptor = -1
            closeReadDescriptor(closingDescriptor, path)
        } finally {
            lock.unlock()
        }
    }
}

private fun openReadDescriptor(path: String): Int {
    while (true) {
        // Nonblocking open avoids hanging on a FIFO before fstat rejects it.
        val descriptor = posixOpen(path, O_RDONLY or O_CLOEXEC or O_NONBLOCK)
        if (descriptor >= 0 || errno != EINTR) return descriptor
    }
}

private fun closeReadDescriptor(descriptor: Int, path: String) {
    if (posixClose(descriptor) != 0) {
        val closeError = errno
        // Darwin releases the descriptor on EINTR; retrying could close a reused fd.
        if (closeError != EINTR) throw localBookFileError("close", path, closeError)
    }
}

private fun localBookFileError(operation: String, path: String, errorCode: Int): IllegalStateException {
    return IllegalStateException("Failed to $operation local book file: $path (errno=$errorCode)")
}

internal fun reboundSandboxPath(path: String): String? {
    if ("/Containers/Data/Application/" !in path) return null
    val localBooksMarker = "/Library/Application Support/LocalBooks/"
    val isInternalBook = localBooksMarker in path
    val marker = if (isInternalBook) "/Library/Application Support/" else "/Documents/"
    val markerIndex = path.indexOf(marker)
    if (markerIndex < 0) return null
    val relativePath = path.substring(markerIndex + marker.length).takeIf { it.isNotBlank() } ?: return null
    if (relativePath.split('/').any { it == "." || it == ".." }) return null
    val directoryUrl = NSFileManager.defaultManager.URLForDirectory(
        directory = if (isInternalBook) NSApplicationSupportDirectory else NSDocumentDirectory,
        inDomain = NSUserDomainMask,
        appropriateForURL = null,
        create = false,
        error = null
    ) ?: return null
    val directoryPath = directoryUrl.path ?: return null
    return "$directoryPath/$relativePath"
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

private fun ByteArray.toNSData(): NSData {
    if (isEmpty()) return NSData()
    return usePinned { pinned ->
        NSData.create(bytes = pinned.addressOf(0), length = size.toULong())
    }
}
