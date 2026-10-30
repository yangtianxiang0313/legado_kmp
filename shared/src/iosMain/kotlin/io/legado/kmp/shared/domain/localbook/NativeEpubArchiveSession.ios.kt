@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.libarchive.legado_epub_close
import io.legado.kmp.shared.libarchive.legado_epub_enable
import io.legado.kmp.shared.libarchive.legado_epub_encrypted
import io.legado.kmp.shared.libarchive.legado_epub_entry_encrypted
import io.legado.kmp.shared.libarchive.legado_epub_format_name
import io.legado.kmp.shared.libarchive.legado_epub_free
import io.legado.kmp.shared.libarchive.legado_epub_kind
import io.legado.kmp.shared.libarchive.legado_epub_matches
import io.legado.kmp.shared.libarchive.legado_epub_new
import io.legado.kmp.shared.libarchive.legado_epub_next
import io.legado.kmp.shared.libarchive.legado_epub_open
import io.legado.kmp.shared.libarchive.legado_epub_path
import io.legado.kmp.shared.libarchive.legado_epub_position
import io.legado.kmp.shared.libarchive.legado_epub_read
import io.legado.kmp.shared.libarchive.legado_epub_size
import io.legado.kmp.shared.libarchive.legado_epub_size_known
import io.legado.kmp.shared.libarchive.legado_epub_skip
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.COpaquePointerVar
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.StableRef
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value

internal fun openNativeEpubArchiveSession(
    source: LocalBookByteSource,
    size: Long,
    checkCancelled: () -> Unit,
): NativeEpubArchiveSession {
    checkCancelled()
    require(size in 1L..EpubArchiveReadLimits.ARCHIVE_BYTES && source.size == size) {
        "EPUB source is empty, changed, or exceeds 16 GiB"
    }
    val input = NativeEpubArchiveInput(source, size)
    var reference: StableRef<NativeEpubArchiveInput>? = null
    var handle: COpaquePointer? = null
    try {
        val stableReference = StableRef.create(input)
        reference = stableReference
        val openedHandle = legado_epub_new() ?: error("Cannot create EPUB archive reader")
        handle = openedHandle
        val session = NativeEpubArchiveSession(openedHandle, input, stableReference)
        session.operation(checkCancelled) {
            input.check()
            val enabled = legado_epub_enable(openedHandle)
            input.check()
            require(enabled == 0) { "Cannot enable the seekable ZIP reader" }
            val opened = legado_epub_open(
                openedHandle, stableReference.asCPointer(), nativeEpubReadCallback, nativeEpubSkipCallback, nativeEpubSeekCallback,
            )
            input.check()
            require(opened == 0) { "EPUB archive is damaged, encrypted, split, or unsupported" }
        }
        return session
    } catch (error: Throwable) {
        releaseNativeEpubArchiveSession(handle, reference, input, error)
        throw error
    }
}

private fun releaseNativeEpubArchiveSession(
    handle: COpaquePointer?,
    reference: StableRef<NativeEpubArchiveInput>?,
    input: NativeEpubArchiveInput,
    primary: Throwable? = null,
) {
    var failure = primary
    fun record(error: Throwable) {
        val original = failure
        if (original == null) failure = error else if (original !== error) original.addSuppressed(error)
    }
    // Both native operations may still access callback state, even when opening failed.
    try {
        if (handle != null) {
            try {
                if (legado_epub_close(handle) != 0) record(IllegalStateException("Closing EPUB archive failed"))
            } catch (error: Throwable) {
                record(error)
            } finally {
                try {
                    if (legado_epub_free(handle) != 0) record(IllegalStateException("Freeing EPUB archive failed"))
                } catch (error: Throwable) {
                    record(error)
                }
            }
        }
        input.callbackFailure()?.let(::record)
    } finally {
        input.endOperation()
        try {
            reference?.dispose()
        } finally {
            input.releaseBuffer()
        }
    }
    if (primary == null) failure?.let { throw it }
}

internal class NativeEpubArchiveSession(
    private val handle: COpaquePointer,
    private val input: NativeEpubArchiveInput,
    private val reference: StableRef<NativeEpubArchiveInput>,
) {
    private var closed = false
    private var currentEntry: COpaquePointer? = null
    private var headerPosition = 0L

    fun <T> operation(checkCancelled: () -> Unit, action: () -> T): T {
        check(!closed) { "EPUB archive reader is closed" }
        input.beginOperation(checkCancelled)
        try {
            input.check()
            return action().also { input.check() }
        } finally {
            // The retained native session never retains a completed operation's Job/context.
            input.endOperation()
        }
    }

    fun next(): NativeEpubArchiveHeader? = memScoped {
        val entry = alloc<COpaquePointerVar>()
        entry.value = null
        currentEntry = null
        input.check()
        val status = legado_epub_next(handle, entry.ptr)
        input.check()
        require(status == 0 || status == 1) { "EPUB file header is damaged or unsupported" }
        checkContainer()
        if (status == 1) return@memScoped null
        currentEntry = entry.value ?: error("Missing EPUB file header")
        headerPosition = legado_epub_position(handle)
        require(headerPosition in 0L..input.size) { "EPUB file header is outside the source" }
        header(currentEntry!!)
    }

    fun skip(expected: NativeEpubArchiveHeader) {
        input.check()
        val status = legado_epub_skip(handle)
        input.check()
        require(status == 0) { "Cannot skip EPUB entry metadata" }
        recheck(expected)
    }

    fun read(expected: NativeEpubArchiveHeader, maximumBytes: Int): ByteArray {
        recheck(expected)
        require(!expected.directory && maximumBytes >= 0 && expected.size <= maximumBytes.toLong()) {
            "EPUB resource exceeds its read limit or is a directory"
        }
        val output = ByteArray(expected.size.toInt())
        val chunk = ByteArray(minOf(EpubArchiveReadLimits.READ_BYTES.toLong(), expected.size.coerceAtLeast(1L)).toInt())
        var written = 0L
        chunk.usePinned { pinned ->
            while (true) {
                // Probe once beyond the declared size to reach native EOF/CRC, never another entry.
                val requested = minOf(chunk.size.toLong(), (expected.size - written).coerceAtLeast(1L)).toInt()
                input.check()
                val count = legado_epub_read(handle, pinned.addressOf(0), requested.convert())
                input.check()
                require(count in 0L..requested.toLong()) { "EPUB resource decompression or CRC check failed" }
                if (count == 0L) {
                    require(written == expected.size) { "EPUB resource is shorter than declared" }
                    break
                }
                require(count <= expected.size - written && count <= maximumBytes.toLong() - written) {
                    "EPUB resource exceeds its declared size or read limit"
                }
                chunk.copyInto(output, destinationOffset = written.toInt(), endIndex = count.toInt())
                written += count
            }
        }
        recheck(expected)
        return output
    }

    fun close(primary: Throwable? = null) {
        if (closed) return
        closed = true
        currentEntry = null
        releaseNativeEpubArchiveSession(handle, reference, input, primary)
    }

    private fun recheck(expected: NativeEpubArchiveHeader) {
        input.check()
        checkContainer()
        val entry = currentEntry ?: error("Missing EPUB file header")
        require(header(entry) == expected) { "EPUB entry metadata changed after indexing" }
    }

    private fun checkContainer() {
        require(legado_epub_matches(handle) != 0) { "EPUB source is not a seekable ZIP archive" }
        require(legado_epub_encrypted(handle) == 0) { "Encrypted EPUB archives are unsupported" }
    }

    private fun header(entry: COpaquePointer): NativeEpubArchiveHeader {
        require(legado_epub_entry_encrypted(entry) == 0) { "Encrypted EPUB resources are unsupported" }
        val kind = legado_epub_kind(entry)
        require(kind == 1 || kind == 2) { "EPUB links and special files are unsupported" }
        require(legado_epub_size_known(entry) != 0) { "EPUB entry has no declared size" }
        val size = legado_epub_size(entry)
        require(size in 0L..EpubArchiveReadLimits.DECLARED_BYTES) { "Invalid EPUB entry size" }
        val directory = kind == 2
        require(!directory || size == 0L) { "EPUB directory contains file data" }
        val path = requireNativeEpubArchivePath(readNativeEpubString(legado_epub_path(entry), 1024))
        require(directory || !path.endsWith('/')) { "EPUB file has a directory path" }
        val formatName = readNativeEpubString(legado_epub_format_name(handle), 128)
        require(formatName.startsWith("ZIP ") &&
            (formatName.endsWith("(uncompressed)") || formatName.endsWith("(deflation)"))) {
            "Only Stored/Deflate EPUB resources are supported"
        }
        return NativeEpubArchiveHeader(path, size, directory, formatName, headerPosition)
    }
}

private fun readNativeEpubString(pointer: CPointer<ByteVar>?, maximumBytes: Int): String {
    require(pointer != null) { "Missing EPUB UTF-8 metadata" }
    var length = 0
    while (true) {
        val byte = pointer[length]
        if (byte == 0.toByte()) break
        require(length < maximumBytes) { "EPUB metadata string is too long" }
        length++
    }
    val bytes = ByteArray(length) { pointer[it] }
    return try {
        bytes.decodeToString(endIndex = length, throwOnInvalidSequence = true)
    } catch (_: kotlin.text.CharacterCodingException) {
        error("EPUB metadata is not valid UTF-8")
    }
}
