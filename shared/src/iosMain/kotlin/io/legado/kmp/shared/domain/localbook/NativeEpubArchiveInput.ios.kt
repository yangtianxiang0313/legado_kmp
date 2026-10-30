@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import cnames.structs.archive
import io.legado.kmp.shared.libarchive.legado_epub_callback_error
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

/** One native operation borrows the source and its current caller's cancellation check. */
internal class NativeEpubArchiveInput(
    private val source: LocalBookByteSource,
    val size: Long,
) {
    val buffer: CPointer<ByteVar> = nativeHeap.allocArray<ByteVar>(EpubArchiveReadLimits.READ_BYTES)
    private var cursor = 0L
    private var failure: Throwable? = null
    private var checkCancelled: (() -> Unit)? = null

    fun beginOperation(cancellationCheck: () -> Unit) {
        kotlin.check(checkCancelled == null) { "EPUB native operation is already active" }
        checkCancelled = cancellationCheck
    }

    fun endOperation() { checkCancelled = null }

    fun check() {
        failure?.let { throw it }
        checkCancelled?.invoke()
        require(source.size == size) { "EPUB source length changed" }
    }

    fun failed(error: Throwable) {
        if (failure == null) failure = error
    }

    fun callbackFailure(): Throwable? = failure

    fun read(output: CPointer<COpaquePointerVar>?): Long {
        check()
        require(output != null) { "Missing EPUB read buffer" }
        output.pointed.value = null
        require(cursor in 0L..size) { "EPUB read offset is out of bounds" }
        if (cursor == size) return 0L
        val requested = minOf(EpubArchiveReadLimits.READ_BYTES.toLong(), size - cursor).toInt()
        val bytes = source.read(cursor, requested)
        check()
        require(bytes.isNotEmpty() && bytes.size <= requested) { "EPUB source returned a truncated or oversized read" }
        bytes.usePinned { pinned -> memcpy(buffer, pinned.addressOf(0), bytes.size.convert()) }
        cursor += bytes.size.toLong()
        output.pointed.value = buffer
        return bytes.size.toLong()
    }

    fun skip(requested: Long): Long {
        check()
        require(requested >= 0L && cursor in 0L..size) { "Invalid EPUB skip" }
        val count = minOf(requested, size - cursor)
        cursor += count
        return count
    }

    fun seek(offset: Long, whence: Int): Long {
        check()
        val base = when (whence) {
            SEEK_SET -> 0L
            SEEK_CUR -> cursor
            SEEK_END -> size
            else -> error("Invalid EPUB seek origin")
        }
        // Check the signed addition without negating Long.MIN_VALUE.
        require(offset >= -base && offset <= size - base) { "EPUB seek is out of bounds" }
        cursor = base + offset
        return cursor
    }

    fun releaseBuffer() { nativeHeap.free(buffer) }
}

internal val nativeEpubReadCallback = staticCFunction {
        handle: CPointer<archive>?, client: COpaquePointer?, output: CPointer<COpaquePointerVar>? ->
    var input: NativeEpubArchiveInput? = null
    try {
        input = requireNotNull(client).asStableRef<NativeEpubArchiveInput>().get()
        input.read(output)
    } catch (error: Throwable) {
        input?.failed(error)
        if (handle != null) legado_epub_callback_error(handle)
        -1L
    }
}

internal val nativeEpubSkipCallback = staticCFunction {
        handle: CPointer<archive>?, client: COpaquePointer?, requested: Long ->
    var input: NativeEpubArchiveInput? = null
    try {
        input = requireNotNull(client).asStableRef<NativeEpubArchiveInput>().get()
        input.skip(requested)
    } catch (error: Throwable) {
        input?.failed(error)
        if (handle != null) legado_epub_callback_error(handle)
        -1L
    }
}

internal val nativeEpubSeekCallback = staticCFunction {
        handle: CPointer<archive>?, client: COpaquePointer?, offset: Long, whence: Int ->
    var input: NativeEpubArchiveInput? = null
    try {
        input = requireNotNull(client).asStableRef<NativeEpubArchiveInput>().get()
        input.seek(offset, whence)
    } catch (error: Throwable) {
        input?.failed(error)
        if (handle != null) legado_epub_callback_error(handle)
        -30L
    }
}
