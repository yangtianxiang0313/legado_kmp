@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import cnames.structs.archive
import io.legado.kmp.shared.libarchive.legado_archive_file_callback_error
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.COpaquePointerVar
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.allocArray
import kotlinx.cinterop.asStableRef
import kotlinx.cinterop.convert
import kotlinx.cinterop.free
import kotlinx.cinterop.nativeHeap
import kotlinx.cinterop.pointed
import kotlinx.cinterop.staticCFunction
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.posix.SEEK_CUR
import platform.posix.SEEK_END
import platform.posix.SEEK_SET
import platform.posix.memcpy

/** Owns one callback buffer, but never owns or closes the underlying source. */
internal class NativeBookFileArchiveInput(
    private val source: LocalBookByteSource,
    val size: Long,
    checkCancelled: () -> Unit,
) {
    private var buffer: CPointer<ByteVar>? = nativeHeap.allocArray<ByteVar>(BookFileArchiveLimits.READ_BYTES)
    private var cancellationCheck: (() -> Unit)? = checkCancelled
    private var cursor = 0L
    private var failure: Throwable? = null

    fun check() {
        failure?.let { throw it }
        checkNotNull(buffer) { "Archive callback input is closed" }
        checkNotNull(cancellationCheck) { "Archive callback input is closed" }.invoke()
        require(source.size == size) { "Archive source length changed" }
    }

    fun failed(error: Throwable) {
        if (failure == null) failure = error
    }

    fun callbackFailure(): Throwable? = failure

    fun read(output: CPointer<COpaquePointerVar>?): Long {
        require(output != null) { "Missing archive read buffer" }
        output.pointed.value = null
        check()
        require(cursor in 0L..size) { "Archive read offset is out of bounds" }
        if (cursor == size) return 0L
        val requested = minOf(BookFileArchiveLimits.READ_BYTES.toLong(), size - cursor).toInt()
        val bytes = source.read(cursor, requested)
        check()
        require(bytes.isNotEmpty() && bytes.size <= requested) {
            "Archive source returned a truncated or oversized read"
        }
        val destination = checkNotNull(buffer) { "Archive callback input is closed" }
        bytes.usePinned { pinned -> memcpy(destination, pinned.addressOf(0), bytes.size.convert()) }
        cursor += bytes.size.toLong()
        output.pointed.value = destination
        return bytes.size.toLong()
    }

    fun skip(requested: Long): Long {
        check()
        require(requested >= 0L && cursor in 0L..size) { "Invalid archive skip" }
        val count = minOf(requested, size - cursor)
        cursor += count
        check()
        return count
    }

    fun seek(offset: Long, whence: Int): Long {
        check()
        require(cursor in 0L..size) { "Archive seek offset is out of bounds" }
        val base = when (whence) {
            SEEK_SET -> 0L
            SEEK_CUR -> cursor
            SEEK_END -> size
            else -> error("Invalid archive seek origin")
        }
        // Bounds-check before addition, without negating an untrusted Long.MIN_VALUE.
        require(offset >= -base && offset <= size - base) { "Archive seek is out of bounds" }
        cursor = base + offset
        check()
        return cursor
    }

    fun release() {
        val previous = buffer
        buffer = null
        cancellationCheck = null
        failure = null
        if (previous != null) nativeHeap.free(previous)
    }
}

internal val nativeBookFileReadCallback = staticCFunction {
        handle: CPointer<archive>?, client: COpaquePointer?, output: CPointer<COpaquePointerVar>? ->
    var input: NativeBookFileArchiveInput? = null
    try {
        input = requireNotNull(client).asStableRef<NativeBookFileArchiveInput>().get()
        input.read(output)
    } catch (error: Throwable) {
        input?.failed(error)
        if (handle != null) legado_archive_file_callback_error(handle)
        -1L
    }
}

internal val nativeBookFileSkipCallback = staticCFunction {
        handle: CPointer<archive>?, client: COpaquePointer?, requested: Long ->
    var input: NativeBookFileArchiveInput? = null
    try {
        input = requireNotNull(client).asStableRef<NativeBookFileArchiveInput>().get()
        input.skip(requested)
    } catch (error: Throwable) {
        input?.failed(error)
        if (handle != null) legado_archive_file_callback_error(handle)
        -1L
    }
}

internal val nativeBookFileSeekCallback = staticCFunction {
        handle: CPointer<archive>?, client: COpaquePointer?, offset: Long, whence: Int ->
    var input: NativeBookFileArchiveInput? = null
    try {
        input = requireNotNull(client).asStableRef<NativeBookFileArchiveInput>().get()
        input.seek(offset, whence)
    } catch (error: Throwable) {
        input?.failed(error)
        if (handle != null) legado_archive_file_callback_error(handle)
        -30L
    }
}
