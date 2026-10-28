package io.legado.kmp.shared.domain.localbook

import okio.Buffer
import okio.Inflater
import okio.InflaterSource

/**
 * Uses BackupZipReader's bounded directory/header/CRC algorithm, retaining full entry paths
 * instead of backup-only basename flattening. Untrusted entry paths are never extraction paths.
 */
internal class BookArchiveZipReader(
    private val bytes: ByteArray,
    private val checkCancelled: () -> Unit,
) {
    internal data class Entry(
        val path: String,
        val size: Int,
        val packed: Int,
        val crc: Long,
        val method: Int,
        val flags: Int,
        val offset: Int,
        val dataStart: Int,
    )

    private val entries = linkedMapOf<String, Entry>()

    init {
        checkCancelled()
        require(bytes.size in 22..MAX_ARCHIVE_BYTES) { "ZIP 为空、损坏或超过 128 MiB" }
        val end = (bytes.size - 22 downTo (bytes.size - 65557).coerceAtLeast(0)).firstOrNull {
            if (it and 1023 == 0) checkCancelled()
            int(it) == 0x06054b50 && it + 22 + short(it + 20) == bytes.size
        } ?: error("ZIP 中央目录损坏")
        require(short(end + 4) == 0 && short(end + 6) == 0 && short(end + 8) == short(end + 10)) {
            "不支持分卷 ZIP"
        }
        val count = short(end + 10)
        require(count != 65535 && count <= MAX_ENTRIES) { "不支持 ZIP64 或超过 4096 项的 ZIP" }
        val directoryStart = int(end + 16)
        val directorySize = int(end + 12)
        require(directoryStart >= 0 && directorySize >= 0 && directoryStart.toLong() + directorySize == end.toLong()) {
            "ZIP 中央目录偏移无效"
        }
        var cursor = directoryStart
        var declaredSize = 0L
        val names = mutableSetOf<String>()
        val ranges = mutableListOf<LongRange>()
        repeat(count) {
            checkCancelled()
            require(cursor.toLong() + 46 <= end && int(cursor) == 0x02014b50) { "ZIP 文件目录损坏" }
            val flags = short(cursor + 8)
            require(flags and 0x080e.inv() == 0) { "不支持加密 ZIP 或此 ZIP 文件标志" }
            require(short(cursor + 34) == 0) { "不支持分卷 ZIP" }
            val nameLength = short(cursor + 28)
            val next = cursor.toLong() + 46 + nameLength + short(cursor + 30) + short(cursor + 32)
            require(next <= end) { "ZIP 文件名损坏" }
            val name = bytes.copyOfRange(cursor + 46, cursor + 46 + nameLength)
                .decodeToString(throwOnInvalidSequence = true)
            validatePath(name)
            require(names.add(name.removeSuffix("/").lowercase())) { "ZIP 包含重名或大小写冲突的路径：$name" }
            val unixType = (int(cursor + 38) ushr 16) and 0xf000
            require(unixType == 0 || unixType == 0x8000 || unixType == 0x4000) { "ZIP 不允许符号链接或特殊文件：$name" }
            val packed = int(cursor + 20)
            val size = int(cursor + 24)
            val offset = int(cursor + 42)
            val crc = uint(cursor + 16)
            val method = short(cursor + 10)
            require(packed >= 0 && size >= 0 && offset >= 0) { "不支持 ZIP64" }
            require(method == 0 || method == 8) { "仅支持 Stored/Deflate ZIP" }
            require(size <= MAX_ENTRY_BYTES) { "ZIP 单文件超过 64 MiB：$name" }
            declaredSize += size
            require(declaredSize <= MAX_TOTAL_BYTES) { "ZIP 解压总量超过 256 MiB" }
            require(offset.toLong() + 30 <= directoryStart && int(offset) == 0x04034b50) { "ZIP 文件头偏移无效：$name" }
            require(short(offset + 6) == flags && short(offset + 8) == method) { "ZIP 文件头与目录不一致：$name" }
            val localNameLength = short(offset + 26)
            val start = offset.toLong() + 30 + localNameLength + short(offset + 28)
            require(start <= directoryStart && start + packed <= directoryStart) { "ZIP 文件数据越界：$name" }
            val localName = bytes.copyOfRange(offset + 30, offset + 30 + localNameLength)
                .decodeToString(throwOnInvalidSequence = true)
            require(localName == name) { "ZIP 文件名与目录不一致：$name" }
            if (flags and 8 == 0) {
                require(int(offset + 18) == packed && int(offset + 22) == size && uint(offset + 14) == crc) {
                    "ZIP 文件长度或校验信息不一致：$name"
                }
            }
            require(method != 0 || packed == size) { "ZIP 未压缩文件长度无效：$name" }
            var dataEnd = start + packed
            if (flags and 8 != 0) {
                require(dataEnd + 12 <= directoryStart) { "ZIP 数据描述符缺失：$name" }
                val descriptor = dataEnd.toInt() + if (int(dataEnd.toInt()) == 0x08074b50) 4 else 0
                require(descriptor.toLong() + 12 <= directoryStart && uint(descriptor) == crc &&
                    int(descriptor + 4) == packed && int(descriptor + 8) == size) { "ZIP 数据描述符无效：$name" }
                dataEnd = descriptor.toLong() + 12
            }
            ranges += offset.toLong() until dataEnd
            if (name.endsWith('/')) {
                require(size == 0) { "ZIP 目录包含文件数据：$name" }
            } else {
                require(unixType != 0x4000) { "ZIP 目录类型无效：$name" }
                entries[name] = Entry(name, size, packed, crc, method, flags, offset, start.toInt())
            }
            cursor = next.toInt()
        }
        require(cursor == end) { "ZIP 中央目录长度无效" }
        ranges.sortedBy { it.first }.zipWithNext().forEach { (left, right) ->
            require(left.last < right.first) { "ZIP 文件数据存在重叠" }
        }
    }

    fun entries(): List<Entry> = entries.values.toList()

    fun read(path: String): ByteArray {
        checkCancelled()
        val entry = entries[path] ?: error("ZIP 中不存在选中的书籍：$path")
        val compressed = Buffer().write(bytes, entry.dataStart, entry.packed)
        val output = Buffer()
        if (entry.method == 0) {
            output.writeAll(compressed)
        } else {
            val source = InflaterSource(compressed, Inflater(true))
            try {
                while (source.read(output, 8192) != -1L) {
                    checkCancelled()
                    require(output.size <= entry.size.toLong()) { "ZIP 实际解压长度超过声明值：$path" }
                }
            } finally {
                source.close()
            }
        }
        checkCancelled()
        require(output.size == entry.size.toLong()) { "ZIP 解压长度异常：$path" }
        return output.readByteArray().also {
            require(crc32(it) == entry.crc) { "ZIP CRC 校验失败：$path" }
        }
    }

    private fun crc32(data: ByteArray): Long {
        var crc = -1
        data.forEachIndexed { index, byte ->
            if (index and 65535 == 0) checkCancelled()
            crc = (crc ushr 8) xor CRC_TABLE[(crc xor byte.toInt()) and 255]
        }
        return crc.inv().toLong() and 0xffffffffL
    }

    private fun short(offset: Int): Int {
        require(offset >= 0 && offset.toLong() + 2 <= bytes.size) { "ZIP 数据截断" }
        return (bytes[offset].toInt() and 255) or ((bytes[offset + 1].toInt() and 255) shl 8)
    }

    private fun int(offset: Int): Int = short(offset) or (short(offset + 2) shl 16)
    private fun uint(offset: Int): Long = int(offset).toLong() and 0xffffffffL

    companion object {
        const val MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
        const val MAX_ENTRY_BYTES = 64 * 1024 * 1024
        const val MAX_TOTAL_BYTES = 256 * 1024 * 1024
        private const val MAX_ENTRIES = 4096
        private val CRC_TABLE = IntArray(256) { value ->
            var crc = value
            repeat(8) { crc = (crc ushr 1) xor (if (crc and 1 != 0) 0xedb88320.toInt() else 0) }
            crc
        }

        fun validatePath(path: String) {
            require(path.isNotEmpty() && path.encodeToByteArray().size <= 1024 &&
                path.none { it.code < 32 || it.code == 127 || it in "\\:" }) { "ZIP 路径无效" }
            val parts = path.removeSuffix("/").split('/')
            require(parts.size <= 32 && parts.none {
                it.isEmpty() || it == "." || it == ".." || it.endsWith(' ') || it.endsWith('.')
            }) { "ZIP 不允许绝对路径、目录跳转或含糊路径：$path" }
        }
    }
}
