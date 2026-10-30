@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.libarchive.legado_archive_file_path
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.CPointer
import kotlinx.cinterop.get

internal data class NativeBookFileArchiveHeader(val path: String, val size: Long, val directory: Boolean)

internal fun nativeBookFileArchiveFormat(format: String): Int = when (format) {
    "7z" -> 1
    "rar" -> 2
    "zip" -> 3
    else -> error("Only ZIP, RAR and 7z book archives are supported")
}

internal fun requireNativeBookFileArchiveSignature(
    source: LocalBookByteSource,
    size: Long,
    format: Int,
    checkCancelled: () -> Unit,
) {
    checkCancelled()
    require(size in 1L..BookFileArchiveLimits.ARCHIVE_BYTES && source.size == size) {
        "Archive source is empty, changed, or exceeds 16 GiB"
    }
    val signature = ByteArray(minOf(8L, size).toInt())
    var filled = 0
    while (filled < signature.size) {
        checkCancelled()
        val requested = signature.size - filled
        val bytes = source.read(filled.toLong(), requested)
        checkCancelled()
        require(source.size == size && bytes.isNotEmpty() && bytes.size <= requested) {
            "Archive signature is truncated or the source length changed"
        }
        bytes.copyInto(signature, destinationOffset = filled)
        filled += bytes.size
    }
    fun startsWith(vararg expected: Int): Boolean = signature.size >= expected.size &&
        expected.indices.all { (signature[it].toInt() and 255) == expected[it] }

    val matches = when (format) {
        1 -> startsWith(0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c)
        2 -> startsWith(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00) ||
            startsWith(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00)
        // Empty ZIP/ZIP64 are valid signatures; the engine validates their complete structure.
        3 -> startsWith(0x50, 0x4b, 0x03, 0x04) || startsWith(0x50, 0x4b, 0x05, 0x06) ||
            startsWith(0x50, 0x4b, 0x06, 0x06)
        else -> false
    }
    require(matches) { "Archive signature does not match its declared format" }
}

internal fun nativeBookFileArchivePath(entry: COpaquePointer): String {
    val path = nativeBookFileArchiveUtf8(legado_archive_file_path(entry), BookFileArchiveLimits.PATH_BYTES)
    return requireBookFileArchivePath(path)
}

private fun nativeBookFileArchiveUtf8(pointer: CPointer<ByteVar>?, maximumBytes: Int): String {
    require(pointer != null) { "Archive pathname cannot be read as UTF-8" }
    var length = 0
    while (true) {
        val byte = pointer[length]
        if (byte == 0.toByte()) break
        require(length < maximumBytes) { "Archive pathname exceeds 1024 UTF-8 bytes" }
        length++
    }
    val bytes = ByteArray(length) { pointer[it] }
    return try {
        bytes.decodeToString(throwOnInvalidSequence = true)
    } catch (_: kotlin.text.CharacterCodingException) {
        error("Archive pathname is not valid UTF-8")
    }
}
