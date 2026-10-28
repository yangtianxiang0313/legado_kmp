package io.legado.kmp.shared.facade

import okio.Buffer
import okio.utf8Size

/** Stored ZIP, with the same UTF-8/CRC32 contract as DirectLinkUploadZip; no ZIP64 or paths. */
internal class BackupZipWriter {
    private data class Entry(val name: ByteArray, val size: Int, val crc: Int, val offset: Int)

    private val output = Buffer()
    private val entries = linkedMapOf<String, Entry>()
    private var centralBytes = 0L
    private var finished = false

    fun text(name: String, text: String) {
        require(text.utf8Size() <= MAX_ENTRY_BYTES) { "备份单文件超过 64 MB" }
        add(name, text.encodeToByteArray())
    }

    private fun add(name: String, data: ByteArray) {
        check(!finished) { "备份 ZIP 已结束" }
        require(entries.size < MAX_ENTRIES && name !in entries) { "备份 ZIP 文件过多或重名" }
        require(name.isNotEmpty() && name.length <= 255 && name.all {
            it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '.' || it == '_' || it == '-'
        } && name != "." && name != "..") { "备份文件名无效" }
        val encoded = name.encodeToByteArray()
        val nextCentral = centralBytes + 46L + encoded.size
        require(output.size + 30L + encoded.size + data.size + nextCentral + 22L <= MAX_ARCHIVE_BYTES) {
            "备份 ZIP 超过 128 MB，请减少备份数据"
        }
        var crc = -1
        data.forEach { crc = (crc ushr 8) xor CRC_TABLE[(crc xor it.toInt()) and 255] }
        crc = crc.inv()
        val entry = Entry(encoded, data.size, crc, output.size.toInt())
        // A valid, deterministic DOS date (1980-01-01), UTF-8 names, method 0, no data descriptor.
        output.writeIntLe(0x04034b50).writeShortLe(20).writeShortLe(0x0800)
            .writeShortLe(0).writeShortLe(0).writeShortLe(33).writeIntLe(crc)
            .writeIntLe(data.size).writeIntLe(data.size).writeShortLe(encoded.size).writeShortLe(0)
            .write(encoded).write(data)
        entries[name] = entry
        centralBytes = nextCentral
    }

    fun finish(): ByteArray {
        check(!finished) { "备份 ZIP 已结束" }
        finished = true
        val start = output.size.toInt()
        entries.values.forEach { entry ->
            output.writeIntLe(0x02014b50).writeShortLe(20).writeShortLe(20).writeShortLe(0x0800)
                .writeShortLe(0).writeShortLe(0).writeShortLe(33).writeIntLe(entry.crc)
                .writeIntLe(entry.size).writeIntLe(entry.size).writeShortLe(entry.name.size)
                .writeShortLe(0).writeShortLe(0).writeShortLe(0).writeShortLe(0)
                .writeIntLe(0).writeIntLe(entry.offset).write(entry.name)
        }
        val size = output.size.toInt() - start
        output.writeIntLe(0x06054b50).writeShortLe(0).writeShortLe(0)
            .writeShortLe(entries.size).writeShortLe(entries.size)
            .writeIntLe(size).writeIntLe(start).writeShortLe(0)
        return output.readByteArray()
    }

    fun clear() {
        output.clear()
        entries.clear()
        finished = true
    }

    companion object {
        const val MAX_ENTRY_BYTES = 64 * 1024 * 1024
        const val MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
        private const val MAX_ENTRIES = 64
        private val CRC_TABLE = IntArray(256) { value ->
            var crc = value
            repeat(8) { crc = (crc ushr 1) xor (if (crc and 1 != 0) 0xedb88320.toInt() else 0) }
            crc
        }
    }
}
