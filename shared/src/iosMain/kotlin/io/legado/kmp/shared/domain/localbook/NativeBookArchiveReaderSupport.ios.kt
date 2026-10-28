@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.libarchive.legado_archive_close
import io.legado.kmp.shared.libarchive.legado_archive_enable
import io.legado.kmp.shared.libarchive.legado_archive_encrypted
import io.legado.kmp.shared.libarchive.legado_archive_entry_encrypted
import io.legado.kmp.shared.libarchive.legado_archive_free
import io.legado.kmp.shared.libarchive.legado_archive_kind
import io.legado.kmp.shared.libarchive.legado_archive_matches
import io.legado.kmp.shared.libarchive.legado_archive_new
import io.legado.kmp.shared.libarchive.legado_archive_next
import io.legado.kmp.shared.libarchive.legado_archive_open
import io.legado.kmp.shared.libarchive.legado_archive_path
import io.legado.kmp.shared.libarchive.legado_archive_read
import io.legado.kmp.shared.libarchive.legado_archive_size
import io.legado.kmp.shared.libarchive.legado_archive_size_known
import io.legado.kmp.shared.libarchive.legado_archive_skip
import kotlin.text.CharacterCodingException
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.COpaquePointerVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.convert
import kotlinx.cinterop.get
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value

internal data class NativeBookArchiveReaderHeader(val path: String, val size: Long, val directory: Boolean)

internal fun <T> withNativeBookArchiveReader(
    bytes: ByteArray,
    format: Int,
    checkCancelled: () -> Unit,
    action: (NativeBookArchiveReaderSession) -> T,
): T {
    checkCancelled()
    require(bytes.isNotEmpty() && bytes.size <= BookArchiveLimits.ARCHIVE_BYTES) {
        "压缩包为空或超过 128 MiB"
    }
    requireNativeBookArchiveReaderSignature(bytes, format)
    return bytes.usePinned { pinned ->
        val handle = legado_archive_new() ?: error("无法创建压缩包读取器")
        var failure: Throwable? = null
        try {
            checkCancelled()
            require(legado_archive_enable(handle, format) == 0) { "系统无法启用此压缩包格式" }
            checkCancelled()
            require(legado_archive_open(handle, pinned.addressOf(0), bytes.size.convert()) == 0) {
                "无法打开压缩包，文件可能已损坏、加密或格式不受支持"
            }
            checkCancelled()
            action(NativeBookArchiveReaderSession(handle, format, checkCancelled)).also { checkCancelled() }
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            // Keep the input pinned until both native cleanup operations finish, even on cancellation.
            val closeStatus = legado_archive_close(handle)
            val freeStatus = legado_archive_free(handle)
            if (closeStatus != 0 || freeStatus != 0) {
                val cleanupFailure = IllegalStateException("关闭或释放压缩包失败")
                val original = failure
                if (original == null) throw cleanupFailure
                original.addSuppressed(cleanupFailure)
            }
        }
    }
}

private fun requireNativeBookArchiveReaderSignature(bytes: ByteArray, format: Int) {
    fun startsWith(signature: IntArray): Boolean = bytes.size >= signature.size &&
        signature.indices.all { (bytes[it].toInt() and 255) == signature[it] }

    val matches = when (format) {
        1 -> startsWith(intArrayOf(0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c))
        2 -> startsWith(intArrayOf(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x00)) ||
            startsWith(intArrayOf(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00))
        else -> false
    }
    require(matches) { "压缩包签名与声明格式不一致，或文件已损坏" }
}

/** Cancellation runs between C calls; native decoding and allocations within one call are not bounded here. */
internal class NativeBookArchiveReaderSession(
    private val handle: COpaquePointer,
    private val format: Int,
    private val checkCancelled: () -> Unit,
) {
    private var currentEntry: COpaquePointer? = null

    fun next(): NativeBookArchiveReaderHeader? = memScoped {
        val entry = alloc<COpaquePointerVar>()
        entry.value = null
        currentEntry = null
        checkCancelled()
        val status = legado_archive_next(handle, entry.ptr)
        checkCancelled()
        require(status == 0 || status == 1) { "读取压缩包文件头失败，文件可能已损坏或加密" }
        checkContainer()
        if (status == 1) return@memScoped null
        val pointer = entry.value ?: error("压缩包文件头缺失")
        currentEntry = pointer
        header(pointer)
    }

    fun skip() {
        checkCancelled()
        require(legado_archive_skip(handle) == 0) { "跳过压缩包条目失败，文件可能已损坏" }
        checkCancelled()
        checkContainer()
    }

    fun recheck(expected: NativeBookArchiveReaderHeader) {
        checkCancelled()
        checkContainer()
        val pointer = currentEntry ?: error("压缩包文件头缺失")
        require(header(pointer) == expected) { "压缩包条目元数据发生变化" }
    }

    fun read(expected: NativeBookArchiveReaderHeader): ByteArray {
        recheck(expected)
        require(!expected.directory) { "不能将压缩包目录作为书籍读取" }
        val output = ByteArray(expected.size.toInt())
        val chunk = ByteArray(32 * 1024)
        var written = 0L
        chunk.usePinned { pinned ->
            while (true) {
                // An extra one-byte probe reaches the selected entry's EOF/CRC without reading another header.
                val requested = minOf(chunk.size.toLong(), (expected.size - written).coerceAtLeast(1L)).toInt()
                checkCancelled()
                val count = legado_archive_read(handle, pinned.addressOf(0), requested.convert())
                checkCancelled()
                require(count >= 0L && count <= requested.toLong()) {
                    "压缩包条目解压或完整性校验失败"
                }
                if (count == 0L) {
                    require(written == expected.size) { "压缩包条目实际长度与声明值不一致" }
                    break
                }
                require(count <= expected.size - written &&
                    count <= BookArchiveLimits.ENTRY_BYTES.toLong() - written) {
                    "压缩包条目实际长度超过声明值或 64 MiB 限制"
                }
                chunk.copyInto(output, destinationOffset = written.toInt(), endIndex = count.toInt())
                written += count
            }
        }
        recheck(expected)
        return output
    }

    private fun checkContainer() {
        require(legado_archive_matches(handle, format) != 0) { "压缩包实际格式与声明格式不一致" }
        require(legado_archive_encrypted(handle) == 0) { "不支持加密压缩包" }
    }

    private fun header(entry: COpaquePointer): NativeBookArchiveReaderHeader {
        require(legado_archive_entry_encrypted(entry) == 0) { "不支持压缩包中的加密条目" }
        val kind = legado_archive_kind(entry)
        require(kind == 1 || kind == 2) { "压缩包不允许符号链接、硬链接或特殊文件" }
        require(legado_archive_size_known(entry) != 0) { "压缩包条目缺少声明长度" }
        val size = legado_archive_size(entry)
        require(size in 0L..BookArchiveLimits.ENTRY_BYTES.toLong()) {
            "压缩包条目声明长度无效或超过 64 MiB"
        }
        val path = path(entry)
        val directory = kind == 2
        require(directory || !path.endsWith('/')) { "压缩包条目类型与目录路径不一致" }
        require(!directory || size == 0L) { "压缩包目录不允许包含文件数据" }
        return NativeBookArchiveReaderHeader(path, size, directory)
    }

    private fun path(entry: COpaquePointer): String {
        val pointer = legado_archive_path(entry) ?: error("压缩包文件名无法按 UTF-8 读取")
        val bytes = ByteArray(1024)
        var length = 0
        while (true) {
            val byte = pointer[length]
            if (byte == 0.toByte()) break
            require(length < bytes.size) { "压缩包路径超过 1024 字节" }
            bytes[length++] = byte
        }
        val path = try {
            bytes.decodeToString(endIndex = length, throwOnInvalidSequence = true)
        } catch (_: CharacterCodingException) {
            error("压缩包文件名不是有效的 UTF-8")
        }
        try {
            BookArchiveZipReader.validatePath(path)
        } catch (_: IllegalArgumentException) {
            // The shared validator includes untrusted paths in some messages; do not propagate them.
            error("压缩包路径无效")
        }
        return path
    }
}

internal class NativeBookArchiveReaderPaths {
    private data class Node(val path: String, val directory: Boolean)

    private val explicitPaths = mutableSetOf<String>()
    private val nodes = mutableMapOf<String, Node>()

    fun add(header: NativeBookArchiveReaderHeader) {
        val path = header.path.removeSuffix("/")
        require(explicitPaths.add(path.lowercase())) { "压缩包包含重名或大小写冲突的路径" }
        val parts = path.split('/')
        var prefix = ""
        parts.forEachIndexed { index, part ->
            prefix = if (prefix.isEmpty()) part else "$prefix/$part"
            val directory = index < parts.lastIndex || header.directory
            val key = prefix.lowercase()
            val previous = nodes[key]
            require(previous == null || (previous.path == prefix && previous.directory && directory)) {
                "压缩包路径存在大小写或文件与目录冲突"
            }
            nodes[key] = Node(prefix, directory)
        }
    }
}
