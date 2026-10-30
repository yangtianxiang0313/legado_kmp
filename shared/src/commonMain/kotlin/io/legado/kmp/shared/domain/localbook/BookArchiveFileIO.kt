package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.platform.FileAccess
import okio.Buffer
import okio.HashingSink
import okio.blackholeSink

internal data class BookArchiveFileDigest(val size: Long, val sha256: String)

private const val BOOK_ARCHIVE_FILE_CHUNK_BYTES = 64 * 1024

/** Synchronous; callers run on Default. Owns and closes the source it opens. */
internal fun hashBookArchiveFile(
    files: FileAccess,
    path: String,
    maximumBytes: Long,
    checkCancelled: () -> Unit,
): BookArchiveFileDigest {
    require(maximumBytes >= 0L) { "Archive file byte limit must not be negative" }
    checkCancelled()
    return withBookArchiveInput(files, path) { source ->
        hashBookArchiveSource(source, maximumBytes, checkCancelled)
    }
}

/**
 * Scans from offset zero without closing or changing ownership of [source].
 * Synchronous; the caller keeps the same source open for subsequent parsing.
 * Uses its captured length; a source that bounds reads to that length hides appends.
 */
internal fun hashBookArchiveSource(
    source: LocalBookByteSource,
    maximumBytes: Long,
    checkCancelled: () -> Unit,
): BookArchiveFileDigest = scanBookArchiveSource(source, maximumBytes, checkCancelled) { }

/**
 * Synchronous; callers run on Default. Verifies the actual output before returning
 * ownership of the staged file. Every failure, including cancellation/close, aborts it.
 */
internal fun copyBookArchiveFile(
    files: FileAccess,
    sourcePath: String,
    targetPath: String,
    maximumBytes: Long,
    checkCancelled: () -> Unit,
): BookArchiveFileDigest {
    require(maximumBytes >= 0L) { "Archive file byte limit must not be negative" }
    checkCancelled()
    var output: BookArchiveFileOutput? = null
    try {
        val sourceDigest = withBookArchiveInput(files, sourcePath) { source ->
            checkedBookArchiveSourceSize(source, maximumBytes)
            checkCancelled()
            val destination = BookArchiveFileOutput(targetPath, maximumBytes)
            output = destination
            scanBookArchiveSource(source, maximumBytes, checkCancelled, destination::write)
        }
        checkCancelled()
        val destination = checkNotNull(output)
        val targetDigest = hashBookArchiveFile(files, targetPath, maximumBytes, checkCancelled)
        check(targetDigest == sourceDigest) { "Copied archive file does not match its source: $targetPath" }
        checkCancelled()
        destination.finish()
        checkCancelled()
        return targetDigest
    } catch (failure: Throwable) {
        try {
            output?.abort()
        } catch (cleanupFailure: Throwable) {
            if (cleanupFailure !== failure) failure.addSuppressed(cleanupFailure)
        }
        throw failure
    }
}

private fun scanBookArchiveSource(
    source: LocalBookByteSource,
    maximumBytes: Long,
    checkCancelled: () -> Unit,
    consume: (ByteArray) -> Unit,
): BookArchiveFileDigest {
    checkCancelled()
    val size = checkedBookArchiveSourceSize(source, maximumBytes)
    val hashingSink = HashingSink.sha256(blackholeSink())
    return withBookArchiveCleanup(hashingSink::close) {
        val buffer = Buffer()
        var offset = 0L
        while (offset < size) {
            checkCancelled()
            val count = minOf(BOOK_ARCHIVE_FILE_CHUNK_BYTES.toLong(), size - offset).toInt()
            val bytes = source.read(offset, count)
            checkCancelled()
            check(bytes.isNotEmpty() && bytes.size <= count) {
                "Archive file premature EOF or out-of-bounds read at $offset: requested $count, got ${bytes.size}"
            }
            consume(bytes)
            buffer.write(bytes)
            hashingSink.write(buffer, bytes.size.toLong())
            offset += bytes.size.toLong()
            checkCancelled()
        }
        check(offset == size) { "Archive file does not match its captured size: expected $size, got $offset" }
        checkCancelled()
        // The source contract permits this EOF probe. Bounded sources may hide appends.
        check(source.read(size, 1).isEmpty()) { "Archive file exceeds its initial size" }
        checkCancelled()
        BookArchiveFileDigest(offset, hashingSink.hash.hex())
    }
}

private fun checkedBookArchiveSourceSize(source: LocalBookByteSource, maximumBytes: Long): Long {
    require(maximumBytes >= 0L) { "Archive file byte limit must not be negative" }
    val size = source.size
    require(size >= 0L && size <= maximumBytes) {
        "Archive file size is outside the byte limit: $size (maximum=$maximumBytes)"
    }
    return size
}

private inline fun <T> withBookArchiveInput(
    files: FileAccess,
    path: String,
    block: (LocalBookByteSource) -> T,
): T {
    val source = files.openRead(path)
    return withBookArchiveCleanup(source::closeSource) { block(source) }
}

private inline fun <T> withBookArchiveCleanup(close: () -> Unit, block: () -> T): T {
    var primaryFailure: Throwable? = null
    try {
        return block()
    } catch (failure: Throwable) {
        primaryFailure = failure
        throw failure
    } finally {
        val primary = primaryFailure
        if (primary == null) {
            close()
        } else {
            try {
                close()
            } catch (closeFailure: Throwable) {
                if (closeFailure !== primary) primary.addSuppressed(closeFailure)
            }
        }
    }
}
