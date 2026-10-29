package io.legado.kmp.shared.facade

import okio.Buffer
import okio.Inflater
import okio.InflaterSource

/** In-memory ZIP reader: never extracts untrusted paths onto the file system. */
internal class BackupZipReader(
    private val bytes: ByteArray,
    private val limits: Limits? = null,
    private val checkActive: () -> Unit = {},
) {
    internal data class Limits(
        val maxArchiveBytes: Int,
        val maxEntries: Int,
        val maxEntryBytes: Int,
        val maxTotalBytes: Int,
        val validateName: (String) -> Unit,
    )

    private data class Entry(val method: Int, val packed: Int, val size: Int, val crc: Long, val offset: Int, val flags: Int)
    private val entries = linkedMapOf<String, Entry>()
    private var extractedSize = 0L
    private val directoryOffset: Int

    init {
        checkActive()
        require(bytes.size <= MAX_ARCHIVE_BYTES) { "备份 ZIP 超过 128 MB" }
        limits?.let { require(bytes.size <= it.maxArchiveBytes) { "ZIP 超过允许大小" } }
        val end = (bytes.size - 22 downTo (bytes.size - 65557).coerceAtLeast(0)).firstOrNull {
            if (it % CHECK_INTERVAL == 0) checkActive()
            int(it) == 0x06054b50 && it + 22 + short(it + 20) == bytes.size
        } ?: error("备份 ZIP 目录损坏")
        checkActive()
        require(short(end + 4) == 0 && short(end + 6) == 0 && short(end + 8) == short(end + 10)) {
            "不支持分卷备份 ZIP"
        }
        val count = short(end + 10)
        require(count != 65535) { "不支持 ZIP64 备份" }
        limits?.let { require(count <= it.maxEntries) { "ZIP 文件数量超过上限" } }
        var cursor = int(end + 16)
        directoryOffset = cursor
        require(cursor >= 0 && cursor.toLong() + int(end + 12) == end.toLong()) { "备份 ZIP 目录偏移无效" }
        var declaredSize = 0L
        repeat(count) {
            checkActive()
            require(cursor >= 0 && cursor.toLong() + 46 <= end && int(cursor) == 0x02014b50) { "备份 ZIP 文件目录损坏" }
            val flags = short(cursor + 8)
            require(flags and 1 == 0) { "不支持加密 ZIP 容器，请先解压再导入" }
            val nameLength = short(cursor + 28)
            val next = cursor.toLong() + 46 + nameLength + short(cursor + 30) + short(cursor + 32)
            require(next <= end) { "备份 ZIP 文件名损坏" }
            val fullName = bytes.copyOfRange(cursor + 46, cursor + 46 + nameLength)
                .decodeToString(throwOnInvalidSequence = limits != null)
            limits?.validateName?.invoke(fullName)
            checkActive()
            if (!fullName.endsWith('/')) {
                val name = fullName.replace('\\', '/').substringAfterLast('/')
                require(name !in entries) { "备份 ZIP 包含重名文件：$name" }
                val entry = Entry(short(cursor + 10), int(cursor + 20), int(cursor + 24), uint(cursor + 16), int(cursor + 42), flags)
                require(entry.packed >= 0 && entry.size >= 0 && entry.offset >= 0) { "不支持 ZIP64 备份" }
                limits?.let {
                    require(entry.method == 0 || entry.method == 8) { "不支持的 ZIP 压缩方式：${entry.method}" }
                    require(entry.size <= it.maxEntryBytes) { "ZIP 单文件超过上限：$name" }
                    declaredSize += entry.size
                    require(declaredSize <= it.maxTotalBytes) { "ZIP 解压内容超过上限" }
                    dataStart(name, entry)
                }
                entries[name] = entry
            }
            cursor = next.toInt()
        }
        require(cursor == end) { "备份 ZIP 目录长度无效" }
        checkActive()
    }

    fun names(): Set<String> {
        checkActive()
        return entries.keys
    }

    fun text(name: String): String? {
        val data = raw(name) ?: return null
        checkActive()
        val text = data.decodeToString(throwOnInvalidSequence = true)
        checkActive()
        return text
    }

    fun raw(name: String, maxBytes: Int = MAX_ENTRY_BYTES): ByteArray? {
        checkActive()
        val entry = entries[name] ?: return null
        require(entry.size <= MAX_ENTRY_BYTES) { "备份文件过大：$name" }
        require(entry.size <= maxBytes) { "ZIP 单文件超过读取上限：$name" }
        extractedSize += entry.size
        require(extractedSize <= 256 * 1024 * 1024) { "备份解压内容超过 256 MB" }
        limits?.let { require(extractedSize <= it.maxTotalBytes) { "ZIP 解压内容超过上限" } }
        val start = dataStart(name, entry)
        val end = start + entry.packed
        require(start >= 0 && end <= bytes.size && end >= start) { "备份 ZIP 文件数据损坏：$name" }
        val compressed = bytes.copyOfRange(start.toInt(), end.toInt())
        checkActive()
        val result = when (entry.method) {
            0 -> compressed
            8 -> {
                val source = InflaterSource(Buffer().write(compressed), Inflater(true))
                val buffer = Buffer()
                try {
                    while (true) {
                        checkActive()
                        val read = source.read(buffer, CHECK_INTERVAL.toLong())
                        checkActive()
                        if (read == -1L) break
                        require(buffer.size <= entry.size.toLong() && buffer.size <= MAX_ENTRY_BYTES &&
                            (limits == null || buffer.size <= limits.maxEntryBytes)) { "备份 ZIP 解压长度异常：$name" }
                    }
                    buffer.readByteArray().also { checkActive() }
                } finally { source.close() }
            }
            else -> error("不支持的 ZIP 压缩方式：${entry.method}")
        }
        checkActive()
        require(result.size == entry.size && crc32(result) == entry.crc) { "备份 ZIP 校验失败：$name" }
        checkActive()
        return result
    }

    private fun dataStart(name: String, entry: Entry): Long {
        checkActive()
        val local = entry.offset
        limits?.let { require(local.toLong() + 30 <= directoryOffset) { "ZIP 文件头偏移无效：$name" } }
        require(int(local) == 0x04034b50 && short(local + 8) == entry.method) { "备份 ZIP 文件头无效：$name" }
        val nameLength = short(local + 26)
        val start = local.toLong() + 30 + nameLength + short(local + 28)
        limits?.let {
            require(short(local + 6) == entry.flags && entry.flags and 0x080e.inv() == 0) { "ZIP 文件标志无效：$name" }
            require(start <= directoryOffset && start + entry.packed <= directoryOffset) { "ZIP 文件数据越界：$name" }
            val localName = bytes.copyOfRange(local + 30, local + 30 + nameLength)
                .decodeToString(throwOnInvalidSequence = true)
            it.validateName(localName)
            checkActive()
            require(localName == name) { "ZIP 文件名与目录不一致：$name" }
            if (entry.flags and 8 == 0) {
                require(int(local + 18) == entry.packed && int(local + 22) == entry.size && uint(local + 14) == entry.crc) {
                    "ZIP 文件头与目录不一致：$name"
                }
            }
            require(entry.method != 0 || entry.packed == entry.size) { "ZIP 未压缩文件长度无效：$name" }
        }
        checkActive()
        return start
    }

    private fun short(offset: Int): Int {
        require(offset >= 0 && offset.toLong() + 2 <= bytes.size) { "备份 ZIP 数据截断" }
        return (bytes[offset].toInt() and 255) or ((bytes[offset + 1].toInt() and 255) shl 8)
    }
    private fun int(offset: Int): Int = short(offset) or (short(offset + 2) shl 16)
    private fun uint(offset: Int): Long = int(offset).toLong() and 0xffffffffL

    private fun crc32(data: ByteArray): Long {
        var crc = -1
        var offset = 0
        while (offset < data.size) {
            checkActive()
            val end = (offset + CHECK_INTERVAL).coerceAtMost(data.size)
            while (offset < end) {
                crc = (crc ushr 8) xor CRC_TABLE[(crc xor data[offset].toInt()) and 255]
                offset++
            }
        }
        checkActive()
        return crc.inv().toLong() and 0xffffffffL
    }

    private companion object {
        val CRC_TABLE = IntArray(256) { value ->
            var crc = value
            repeat(8) { crc = (crc ushr 1) xor (if (crc and 1 != 0) 0xedb88320.toInt() else 0) }
            crc
        }
        const val MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
        const val MAX_ENTRY_BYTES = 64 * 1024 * 1024
        const val CHECK_INTERVAL = 8192
    }
}
