package io.legado.kmp.shared.domain.localbook

/** CDIC offsets, length flags and lazy phrase expansion follow Android CDICData/HuffcdicDecompressor. */
internal class MobiCdicDictionary(
    records: MobiRecordReader,
    firstRecord: Int,
    recordCount: Int,
    private val checkActive: () -> Unit,
) {
    private class Entry(val data: ByteArray, val decompressed: Boolean) {
        var cached: ByteArray? = null
        var expanding = false
    }

    private val entries = ArrayList<Entry>()
    private var cachedBytes = 0
    val size: Int get() = entries.size

    init {
        require(firstRecord in 0 until records.recordCount && recordCount > 0 &&
            recordCount <= records.recordCount - firstRecord) {
            "MOBI CDIC 记录范围无效"
        }
        var declaredEntries = -1
        var declaredCodeLength = -1
        var storedBytes = 0
        var recordBytes = 0
        repeat(recordCount) { recordIndex ->
            checkActive()
            val record = records.record(firstRecord + recordIndex, MAX_RECORD_BYTES)
            checkActive()
            require(record.size <= MAX_DICTIONARY_RECORD_BYTES - recordBytes) {
                "MOBI CDIC 记录总量超过 32 MiB 限制"
            }
            recordBytes += record.size
            record.mobiRange(0, 16)
            require(record.mobiAscii(0, 4) == "CDIC") { "MOBI CDIC 记录标识无效" }
            val length = record.mobiU32(4).mobiInt("CDIC 文件头长度")
            val count = record.mobiU32(8).mobiInt("CDIC 词条总数")
            val codeLength = record.mobiU32(12).mobiInt("CDIC 码长")
            require(length in 16..record.size && count in 1..MAX_ENTRIES && codeLength in 0..31) {
                "MOBI CDIC 文件头、词条数量或码长无效"
            }
            if (declaredEntries < 0) {
                declaredEntries = count
                declaredCodeLength = codeLength
            } else {
                require(count == declaredEntries && codeLength == declaredCodeLength) {
                    "MOBI CDIC 词条总数或码长不一致"
                }
            }

            val entryCount = minOf(1L shl codeLength, (count - entries.size).toLong()).toInt()
            require(entryCount >= 0) { "MOBI CDIC 词条数量溢出" }
            val tableBytes = entryCount * 2
            record.mobiRange(length, tableBytes)
            repeat(entryCount) { index ->
                if (index and 0xff == 0) checkActive()
                val relativeOffset = record.mobiU16(length + index * 2)
                require(relativeOffset >= tableBytes && relativeOffset <= record.size - length - 2) {
                    "MOBI CDIC 词条偏移越界或与偏移表重叠"
                }
                val offset = length + relativeOffset
                val flags = record.mobiU16(offset)
                val dataLength = flags and 0x7fff
                record.mobiRange(offset + 2, dataLength)
                require(dataLength <= MAX_STORED_BYTES - storedBytes) {
                    "MOBI CDIC 词条数据超过 16 MiB 限制"
                }
                storedBytes += dataLength
                entries.add(Entry(record.copyOfRange(offset + 2, offset + 2 + dataLength), flags and 0x8000 != 0))
            }
        }
        require(entries.size == declaredEntries) { "MOBI CDIC 词典词条被截断" }
        checkActive()
    }

    fun resolve(
        index: Int,
        limit: Int,
        depth: Int,
        expand: (ByteArray, Int, Int) -> ByteArray,
    ): ByteArray {
        require(index in entries.indices && limit >= 0) { "MOBI CDIC 词条索引或输出上限无效" }
        val entry = entries[index]
        val resolved = if (entry.decompressed) entry.data else entry.cached
        if (resolved != null) {
            require(resolved.size <= limit) { "MOBI CDIC 词条展开超过记录大小限制" }
            return resolved
        }
        require(!entry.expanding) { "MOBI CDIC 词条存在递归环：$index" }
        require(depth < MAX_EXPANSION_DEPTH) { "MOBI CDIC 词条递归超过 64 层限制" }
        checkActive()
        entry.expanding = true
        try {
            val decoded = expand(entry.data, limit, depth + 1)
            require(decoded.size <= limit) { "MOBI CDIC 词条展开超过记录大小限制" }
            if (decoded.size <= MAX_CACHE_BYTES - cachedBytes) {
                entry.cached = decoded
                cachedBytes += decoded.size
            }
            return decoded
        } finally {
            entry.expanding = false
        }
    }

    private companion object {
        const val MAX_RECORD_BYTES = 16 * 1024 * 1024
        const val MAX_DICTIONARY_RECORD_BYTES = 32 * 1024 * 1024
        const val MAX_STORED_BYTES = 16 * 1024 * 1024
        const val MAX_CACHE_BYTES = 8 * 1024 * 1024
        const val MAX_ENTRIES = 256 * 1024
        const val MAX_EXPANSION_DEPTH = 64
    }
}
