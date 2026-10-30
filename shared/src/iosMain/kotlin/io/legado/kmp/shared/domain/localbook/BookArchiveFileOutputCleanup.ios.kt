@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import platform.Foundation.NSUUID
import platform.posix.AT_REMOVEDIR
import platform.posix.AT_SYMLINK_NOFOLLOW
import platform.posix.EEXIST
import platform.posix.EINTR
import platform.posix.ENOENT
import platform.posix.O_CLOEXEC
import platform.posix.O_DIRECTORY
import platform.posix.O_NOFOLLOW
import platform.posix.O_NONBLOCK
import platform.posix.O_RDONLY
import platform.posix.RENAME_EXCL
import platform.posix.S_IFDIR
import platform.posix.S_IFMT
import platform.posix.S_IFREG
import platform.posix.S_IRUSR
import platform.posix.S_IWUSR
import platform.posix.S_IXUSR
import platform.posix.errno
import platform.posix.fstat
import platform.posix.fstatat
import platform.posix.mkdirat
import platform.posix.openat
import platform.posix.renameatx_np
import platform.posix.stat
import platform.posix.unlinkat
import platform.posix.close as posixClose
import platform.posix.open as posixOpen

/** Birth time and generation also guard against inode reuse after finish closes fd. */
internal data class BookArchiveOutputIdentity(
    val device: Long,
    val inode: ULong,
    val generation: UInt,
    val birthSeconds: Long,
    val birthNanoseconds: Long,
)

internal data class BookArchiveOutputStat(
    val identity: BookArchiveOutputIdentity,
    val size: Long,
    val links: Long,
    val regular: Boolean,
    val directory: Boolean,
)

private const val BOOK_ARCHIVE_QUARANTINED_ENTRY = "output"
private val bookArchiveOutputDirectoryFlags = O_RDONLY or O_DIRECTORY or O_CLOEXEC or O_NOFOLLOW or O_NONBLOCK

internal fun openBookArchiveOutputDirectory(path: String): Int {
    while (true) {
        val opened = posixOpen(path, bookArchiveOutputDirectoryFlags)
        if (opened >= 0 || errno != EINTR) return opened
    }
}

internal fun statBookArchiveOutput(descriptor: Int, path: String): BookArchiveOutputStat = memScoped {
    val info = alloc<stat>()
    while (fstat(descriptor, info.ptr) != 0) {
        val statError = errno
        if (statError != EINTR) throw bookArchiveOutputError("fstat", path, statError)
    }
    info.bookArchiveSnapshot()
}

internal fun statBookArchiveOutputEntry(directory: Int, name: String, path: String): BookArchiveOutputStat? = memScoped {
    val info = alloc<stat>()
    while (fstatat(directory, name, info.ptr, AT_SYMLINK_NOFOLLOW) != 0) {
        val statError = errno
        if (statError == ENOENT) return@memScoped null
        if (statError != EINTR) throw bookArchiveOutputError("fstatat", path, statError)
    }
    info.bookArchiveSnapshot()
}

private fun stat.bookArchiveSnapshot(): BookArchiveOutputStat {
    val kind = st_mode.toInt() and S_IFMT.toInt()
    return BookArchiveOutputStat(
        identity = BookArchiveOutputIdentity(
            st_dev.toLong(), st_ino.toULong(), st_gen.toUInt(),
            st_birthtimespec.tv_sec.toLong(), st_birthtimespec.tv_nsec.toLong(),
        ),
        size = st_size,
        links = st_nlink.toLong(),
        regular = kind == S_IFREG.toInt(),
        directory = kind == S_IFDIR.toInt(),
    )
}

internal fun closeBookArchiveOutputDescriptor(descriptor: Int, path: String) {
    if (posixClose(descriptor) != 0) {
        val closeError = errno
        // Darwin consumes fd even on EINTR; retrying can close an unrelated reused fd.
        if (closeError != EINTR) throw bookArchiveOutputError("close", path, closeError)
    }
}

internal fun bookArchiveOutputError(operation: String, path: String, errorCode: Int): IllegalStateException =
    IllegalStateException("Failed to $operation archive output: $path (errno=$errorCode)")

internal fun collectBookArchiveOutputFailure(primary: Throwable?, block: () -> Unit): Throwable? {
    try {
        block()
    } catch (failure: Throwable) {
        if (primary == null) return failure
        if (primary !== failure) primary.addSuppressed(failure)
    }
    return primary
}

internal fun discardBookArchiveOutput(
    directory: Int,
    name: String,
    identity: BookArchiveOutputIdentity,
    path: String,
) {
    val named = statBookArchiveOutputEntry(directory, name, path)
    if (named == null || named.identity != identity || !named.regular) return

    // Checking inode then unlinking the public name is not atomic. Isolate the
    // entry in a private directory, recheck it, and never unlink a replacement.
    val quarantineName = createBookArchiveQuarantine(directory, path)
    val quarantinePath = "${path.substringBeforeLast('/')}/$quarantineName"
    var quarantineDescriptor = -1
    var quarantineIdentity: BookArchiveOutputIdentity? = null
    var ownsQuarantineDescriptor = false
    var primaryFailure: Throwable? = null
    try {
        val createdDirectory = checkNotNull(statBookArchiveOutputEntry(directory, quarantineName, quarantinePath)) {
            "Archive cleanup directory disappeared: $quarantinePath"
        }
        check(createdDirectory.directory) { "Archive cleanup directory was replaced: $quarantinePath" }
        quarantineIdentity = createdDirectory.identity
        while (true) {
            quarantineDescriptor = openat(directory, quarantineName, bookArchiveOutputDirectoryFlags)
            if (quarantineDescriptor >= 0) break
            val openError = errno
            if (openError != EINTR) throw bookArchiveOutputError("open cleanup directory", quarantinePath, openError)
        }
        check(statBookArchiveOutput(quarantineDescriptor, quarantinePath).identity == quarantineIdentity) {
            "Archive cleanup directory was replaced: $quarantinePath"
        }
        ownsQuarantineDescriptor = true
        val current = statBookArchiveOutputEntry(directory, name, path)
        if (current == null || current.identity != identity || !current.regular) return
        if (renameatx_np(directory, name, quarantineDescriptor, BOOK_ARCHIVE_QUARANTINED_ENTRY, RENAME_EXCL.toUInt()) != 0) {
            val moveError = errno
            if (moveError == ENOENT) return
            throw bookArchiveOutputError("isolate output for abort", path, moveError)
        }
        val isolated = statBookArchiveOutputEntry(quarantineDescriptor, BOOK_ARCHIVE_QUARANTINED_ENTRY, quarantinePath)
        if (isolated != null && isolated.identity == identity && isolated.regular) {
            unlinkBookArchiveOutputEntry(quarantineDescriptor, BOOK_ARCHIVE_QUARANTINED_ENTRY, 0, quarantinePath)
        }
    } catch (failure: Throwable) {
        primaryFailure = failure
        throw failure
    } finally {
        var cleanupFailure: Throwable? = null
        if (ownsQuarantineDescriptor) {
            cleanupFailure = collectBookArchiveOutputFailure(cleanupFailure) {
                restoreBookArchiveQuarantine(quarantineDescriptor, directory, name, quarantinePath)
            }
        }
        cleanupFailure = collectBookArchiveOutputFailure(cleanupFailure) {
            val namedDirectory = statBookArchiveOutputEntry(directory, quarantineName, quarantinePath)
            if (quarantineIdentity != null && namedDirectory?.identity == quarantineIdentity && namedDirectory?.directory == true) {
                // rmdir cannot remove a preserved replacement if restoration failed.
                unlinkBookArchiveOutputEntry(directory, quarantineName, AT_REMOVEDIR, quarantinePath)
            }
        }
        if (quarantineDescriptor >= 0) {
            cleanupFailure = collectBookArchiveOutputFailure(cleanupFailure) {
                closeBookArchiveOutputDescriptor(quarantineDescriptor, quarantinePath)
            }
        }
        val cleanup = cleanupFailure
        if (cleanup != null) {
            val primary = primaryFailure
            if (primary == null) throw cleanup
            if (primary !== cleanup) primary.addSuppressed(cleanup)
        }
    }
}

private fun createBookArchiveQuarantine(directory: Int, path: String): String {
    val mode = S_IRUSR.toInt() or S_IWUSR.toInt() or S_IXUSR.toInt()
    repeat(8) {
        val name = ".book-archive-abort-${NSUUID().UUIDString}"
        while (true) {
            if (mkdirat(directory, name, mode.convert()) == 0) return name
            val createError = errno
            if (createError == EEXIST) break
            if (createError != EINTR) throw bookArchiveOutputError("create cleanup directory", path, createError)
        }
    }
    error("Failed to allocate a private archive cleanup directory: $path")
}

private fun restoreBookArchiveQuarantine(quarantine: Int, directory: Int, name: String, path: String) {
    while (statBookArchiveOutputEntry(quarantine, BOOK_ARCHIVE_QUARANTINED_ENTRY, path) != null) {
        if (renameatx_np(quarantine, BOOK_ARCHIVE_QUARANTINED_ENTRY, directory, name, RENAME_EXCL.toUInt()) == 0) return
        val restoreError = errno
        if (restoreError != EINTR) {
            throw bookArchiveOutputError("restore replaced output; preserved at $path/$BOOK_ARCHIVE_QUARANTINED_ENTRY", name, restoreError)
        }
    }
}

private fun unlinkBookArchiveOutputEntry(directory: Int, name: String, flags: Int, path: String) {
    while (unlinkat(directory, name, flags) != 0) {
        val unlinkError = errno
        if (unlinkError == ENOENT) return
        if (unlinkError != EINTR) throw bookArchiveOutputError("unlink owned output", path, unlinkError)
    }
}
