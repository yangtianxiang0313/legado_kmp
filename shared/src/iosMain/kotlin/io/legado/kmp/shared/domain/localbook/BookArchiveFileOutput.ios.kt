@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.posix.EINTR
import platform.posix.ELOOP
import platform.posix.ENOENT
import platform.posix.ENOTDIR
import platform.posix.O_CLOEXEC
import platform.posix.O_CREAT
import platform.posix.O_EXCL
import platform.posix.O_NOFOLLOW
import platform.posix.O_NONBLOCK
import platform.posix.O_WRONLY
import platform.posix.S_IRUSR
import platform.posix.S_IWUSR
import platform.posix.errno
import platform.posix.fsync
import platform.posix.openat
import platform.posix.write as posixWrite

private const val BOOK_ARCHIVE_OUTPUT_WRITE_BYTES = 1024 * 1024

internal actual class BookArchiveFileOutput actual constructor(
    private val path: String,
    private val maximumBytes: Long,
) {
    private enum class State { OPEN, FINISHED, ABORTED }

    private val parentPath: String
    private val fileName: String
    private var directoryDescriptor = -1
    private var descriptor = -1
    private var directoryIdentity: BookArchiveOutputIdentity? = null
    private var identity: BookArchiveOutputIdentity? = null
    private var writtenBytes = 0L
    private var state = State.OPEN
    private var terminalFailure: Throwable? = null

    init {
        require(maximumBytes >= 0L) { "Archive output byte limit must not be negative" }
        require(path.startsWith('/') && '\u0000' !in path) { "Archive output requires an absolute app-owned path" }
        require(path.substring(1).split('/').all { it.isNotEmpty() && it != "." && it != ".." }) {
            "Archive output path must name a file without relative components"
        }
        parentPath = path.substringBeforeLast('/').ifEmpty { "/" }
        fileName = path.substringAfterLast('/')
        try {
            directoryDescriptor = openBookArchiveOutputDirectory(parentPath)
            if (directoryDescriptor < 0) throw bookArchiveOutputError("open parent", parentPath, errno)
            directoryIdentity = statBookArchiveOutput(directoryDescriptor, parentPath).identity
            descriptor = createDescriptor()
            val created = statBookArchiveOutput(descriptor, path)
            identity = created.identity
            check(created.regular && created.links == 1L && created.size == 0L) {
                "Archive output requires a new, exclusive regular file: $path"
            }
            verifyOutput()
        } catch (failure: Throwable) {
            fail(failure)
        }
    }

    actual fun write(bytes: ByteArray) {
        requireOpen()
        try {
            require(bytes.size.toLong() <= maximumBytes - writtenBytes) {
                "Archive output exceeds its byte limit: $path (maximum=$maximumBytes)"
            }
            bytes.usePinned { pinned ->
                var offset = 0
                while (offset < bytes.size) {
                    val count = minOf(BOOK_ARCHIVE_OUTPUT_WRITE_BYTES, bytes.size - offset)
                    val result = posixWrite(descriptor, pinned.addressOf(offset), count.toULong())
                    when {
                        result > 0L -> {
                            check(result <= count.toLong()) { "Invalid archive output write count: $result" }
                            offset += result.toInt()
                            writtenBytes += result
                        }
                        result == 0L -> error("Archive output write made no progress: $path")
                        else -> {
                            val writeError = errno
                            if (writeError != EINTR) throw bookArchiveOutputError("write", path, writeError)
                        }
                    }
                }
            }
        } catch (failure: Throwable) {
            fail(failure)
        }
    }

    actual fun finish() {
        if (state == State.FINISHED) return
        requireOpen()
        try {
            verifyOutput()
            while (fsync(descriptor) != 0) {
                val syncError = errno
                if (syncError != EINTR) throw bookArchiveOutputError("fsync", path, syncError)
            }
            verifyOutput()
            closeFileDescriptor()
            closeDirectoryDescriptor()
            state = State.FINISHED
        } catch (failure: Throwable) {
            fail(failure)
        }
    }

    actual fun abort() {
        if (state == State.ABORTED) return
        state = State.ABORTED
        var cleanupFailure: Throwable? = null
        cleanupFailure = collectBookArchiveOutputFailure(cleanupFailure) {
            if (identity == null && descriptor >= 0) {
                identity = statBookArchiveOutput(descriptor, path).identity
            }
            val ownedIdentity = identity
            if (ownedIdentity != null && reopenCleanupDirectory()) {
                discardBookArchiveOutput(directoryDescriptor, fileName, ownedIdentity, path)
            }
        }
        // Keep the file open through identity-checked removal to prevent inode reuse.
        cleanupFailure = collectBookArchiveOutputFailure(cleanupFailure, ::closeFileDescriptor)
        cleanupFailure = collectBookArchiveOutputFailure(cleanupFailure, ::closeDirectoryDescriptor)
        cleanupFailure?.let { throw it }
    }

    private fun createDescriptor(): Int {
        val flags = O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or O_NOFOLLOW or O_NONBLOCK
        val mode = S_IRUSR.toInt() or S_IWUSR.toInt()
        while (true) {
            val opened = openat(directoryDescriptor, fileName, flags, mode)
            if (opened >= 0) return opened
            val openError = errno
            if (openError != EINTR) throw bookArchiveOutputError("create exclusive output", path, openError)
        }
    }

    private fun verifyOutput() {
        val opened = statBookArchiveOutput(descriptor, path)
        check(opened.identity == identity && opened.regular && opened.links == 1L && opened.size == writtenBytes) {
            "Archive output changed while writing: $path"
        }
        val named = statBookArchiveOutputEntry(directoryDescriptor, fileName, path)
        check(named?.identity == identity && named?.regular == true) { "Archive output path was replaced: $path" }
    }

    private fun reopenCleanupDirectory(): Boolean {
        if (directoryDescriptor >= 0) return true
        val reopened = openBookArchiveOutputDirectory(parentPath)
        if (reopened < 0) {
            val openError = errno
            if (openError == ENOENT || openError == ENOTDIR || openError == ELOOP) return false
            throw bookArchiveOutputError("reopen parent for abort", parentPath, openError)
        }
        directoryDescriptor = reopened
        return statBookArchiveOutput(reopened, parentPath).identity == directoryIdentity
    }

    private fun closeFileDescriptor() {
        val closing = descriptor
        descriptor = -1
        if (closing >= 0) closeBookArchiveOutputDescriptor(closing, path)
    }

    private fun closeDirectoryDescriptor() {
        val closing = directoryDescriptor
        directoryDescriptor = -1
        if (closing >= 0) closeBookArchiveOutputDescriptor(closing, parentPath)
    }

    private fun requireOpen() {
        terminalFailure?.let { throw it }
        check(state == State.OPEN) { "Archive output is closed: $path" }
    }

    private fun fail(failure: Throwable): Nothing {
        terminalFailure = failure
        try {
            abort()
        } catch (cleanupFailure: Throwable) {
            if (cleanupFailure !== failure) failure.addSuppressed(cleanupFailure)
        }
        throw failure
    }
}
