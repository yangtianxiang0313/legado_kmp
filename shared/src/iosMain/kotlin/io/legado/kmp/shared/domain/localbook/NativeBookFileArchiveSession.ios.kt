@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.libarchive.legado_archive_file_close
import io.legado.kmp.shared.libarchive.legado_archive_file_enable
import io.legado.kmp.shared.libarchive.legado_archive_file_encrypted
import io.legado.kmp.shared.libarchive.legado_archive_file_entry_encrypted
import io.legado.kmp.shared.libarchive.legado_archive_file_free
import io.legado.kmp.shared.libarchive.legado_archive_file_kind
import io.legado.kmp.shared.libarchive.legado_archive_file_matches
import io.legado.kmp.shared.libarchive.legado_archive_file_new
import io.legado.kmp.shared.libarchive.legado_archive_file_next
import io.legado.kmp.shared.libarchive.legado_archive_file_open_callbacks
import io.legado.kmp.shared.libarchive.legado_archive_file_read
import io.legado.kmp.shared.libarchive.legado_archive_file_size
import io.legado.kmp.shared.libarchive.legado_archive_file_size_known
import io.legado.kmp.shared.libarchive.legado_archive_file_skip
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.COpaquePointerVar
import kotlinx.cinterop.StableRef
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value

/** Every invocation owns a fresh session and releases it before returning or throwing. */
internal fun <T> withNativeBookFileArchiveSession(
    source: LocalBookByteSource,
    size: Long,
    format: Int,
    checkCancelled: () -> Unit,
    action: (NativeBookFileArchiveSession) -> T,
): T {
    requireNativeBookFileArchiveSignature(source, size, format, checkCancelled)
    val input = NativeBookFileArchiveInput(source, size, checkCancelled)
    var reference: StableRef<NativeBookFileArchiveInput>? = null
    var handle: COpaquePointer? = null
    var failure: Throwable? = null
    try {
        val stableReference = StableRef.create(input)
        reference = stableReference
        val openedHandle = legado_archive_file_new() ?: error("Cannot create archive file reader")
        handle = openedHandle
        input.check()
        val enabled = legado_archive_file_enable(openedHandle, format)
        input.check()
        require(enabled == 0) { "Cannot enable the declared archive format" }
        val opened = legado_archive_file_open_callbacks(
            openedHandle, stableReference.asCPointer(), nativeBookFileReadCallback,
            nativeBookFileSkipCallback, nativeBookFileSeekCallback,
        )
        input.check()
        require(opened == 0) { "Archive is damaged, encrypted, split, or unsupported" }
        return action(NativeBookFileArchiveSession(openedHandle, input, format)).also { input.check() }
    } catch (error: Throwable) {
        failure = error
        throw error
    } finally {
        releaseNativeBookFileArchiveSession(handle, reference, input, failure)
    }
}

private fun releaseNativeBookFileArchiveSession(
    handle: COpaquePointer?,
    reference: StableRef<NativeBookFileArchiveInput>?,
    input: NativeBookFileArchiveInput,
    primary: Throwable?,
) {
    var failure = primary
    fun record(error: Throwable) {
        val original = failure
        if (original == null) failure = error else if (original !== error) original.addSuppressed(error)
    }
    // Native close/free may still access callbacks, including after a failed open.
    try {
        if (handle != null) {
            try {
                if (legado_archive_file_close(handle) != 0) record(IllegalStateException("Closing archive failed"))
            } catch (error: Throwable) {
                record(error)
            } finally {
                try {
                    if (legado_archive_file_free(handle) != 0) record(IllegalStateException("Freeing archive failed"))
                } catch (error: Throwable) {
                    record(error)
                }
            }
        }
        input.callbackFailure()?.let(::record)
    } finally {
        try {
            reference?.dispose()
        } catch (error: Throwable) {
            record(error)
        } finally {
            try {
                input.release()
            } catch (error: Throwable) {
                record(error)
            }
        }
    }
    if (primary == null) failure?.let { throw it }
}

internal class NativeBookFileArchiveSession(
    private val handle: COpaquePointer,
    private val input: NativeBookFileArchiveInput,
    private val format: Int,
) {
    private var currentEntry: COpaquePointer? = null
    private val chunk = ByteArray(BookFileArchiveLimits.READ_BYTES)

    fun next(): NativeBookFileArchiveHeader? = memScoped {
        val entry = alloc<COpaquePointerVar>()
        entry.value = null
        currentEntry = null
        input.check()
        val status = legado_archive_file_next(handle, entry.ptr)
        input.check()
        require(status == 0 || status == 1) { "Archive header is damaged, encrypted, or unsupported" }
        checkContainer()
        if (status == 1) return@memScoped null
        val pointer = entry.value ?: error("Missing archive entry header")
        currentEntry = pointer
        header(pointer)
    }

    /** Indexing/skipping is not a CRC check. Full validation uses [consume] instead. */
    fun skip(expected: NativeBookFileArchiveHeader) {
        recheck(expected)
        val status = legado_archive_file_skip(handle)
        input.check()
        require(status == 0) { "Cannot skip archive entry" }
        recheck(expected)
    }

    /** Null [write] discards data with the same bounded buffer and EOF/CRC checks. */
    fun consume(expected: NativeBookFileArchiveHeader, write: ((ByteArray) -> Unit)?): Long {
        recheck(expected)
        var written = 0L
        chunk.usePinned { pinned ->
            while (true) {
                // A final probe must reach EOF/CRC, even for an empty or exact-buffer-sized entry.
                val requested = minOf(chunk.size.toLong(), (expected.size - written).coerceAtLeast(1L)).toInt()
                input.check()
                val count = legado_archive_file_read(handle, pinned.addressOf(0), requested.convert())
                input.check()
                require(count in 0L..requested.toLong()) { "Archive decompression or integrity check failed" }
                if (count == 0L) {
                    require(written == expected.size) { "Archive entry is shorter than its declared size" }
                    break
                }
                require(count <= expected.size - written && count <= BookFileArchiveLimits.ENTRY_BYTES - written) {
                    "Archive entry exceeds its declared size or 2 GiB limit"
                }
                if (write != null) {
                    // Consumers may retain a chunk: never expose the reused native output buffer.
                    write(chunk.copyOf(count.toInt()))
                    input.check()
                }
                written += count
            }
        }
        recheck(expected)
        return written
    }

    private fun recheck(expected: NativeBookFileArchiveHeader) {
        input.check()
        checkContainer()
        val entry = currentEntry ?: error("Missing archive entry header")
        require(header(entry) == expected) { "Archive entry metadata changed after indexing" }
    }

    private fun checkContainer() {
        require(legado_archive_file_matches(handle, format) != 0) { "Archive type does not match its declared format" }
        require(legado_archive_file_encrypted(handle) == 0) { "Encrypted archives are unsupported" }
    }

    private fun header(entry: COpaquePointer): NativeBookFileArchiveHeader {
        require(legado_archive_file_entry_encrypted(entry) == 0) { "Encrypted archive entries are unsupported" }
        val kind = legado_archive_file_kind(entry)
        require(kind == 1 || kind == 2) { "Archive links and special files are unsupported" }
        require(legado_archive_file_size_known(entry) != 0) { "Archive entry has no declared size" }
        val size = legado_archive_file_size(entry)
        require(size in 0L..BookFileArchiveLimits.ENTRY_BYTES) { "Archive entry size is invalid or exceeds 2 GiB" }
        val directory = kind == 2
        require(!directory || size == 0L) { "Archive directory contains file data" }
        val path = nativeBookFileArchivePath(entry)
        require(directory || !path.endsWith('/')) { "Archive file has a directory path" }
        return NativeBookFileArchiveHeader(path, size, directory)
    }
}
