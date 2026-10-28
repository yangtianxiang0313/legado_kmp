package io.legado.kmp.shared.domain.localbook

internal data class MobiTocEntry(val offset: Int, val title: String, val hasChildren: Boolean)

/** Bounded common implementation of Android MobiBook's INDX/TAGX/CNCX reader. */
internal class MobiNcxIndex(
    private val records: MobiRecordReader,
    private val textEncoding: MobiTextEncoding,
    private val checkActive: () -> Unit,
) {
    fun read(index: Int): List<MobiTocEntry> {
        val data = MobiIndexReader(records, textEncoding, checkActive).read(index)
        require(data.entries.isNotEmpty()) { "MOBI NCX 目录为空" }
        val traversal = MobiNcxTraversal(data.entries, checkActive)
        return traversal.order.map { index ->
            checkActive()
            val entry = data.entries[index]
            val offset = entry.values[1]?.firstOrNull()
                ?: throw IllegalArgumentException("MOBI NCX 缺少章节正文偏移")
            val stringOffset = entry.values[3]?.firstOrNull()
                ?: throw IllegalArgumentException("MOBI NCX 缺少章节标题索引")
            val title = data.strings[stringOffset]?.let(MobiHtmlSupport::metadataText)
                ?.takeIf { it.isNotBlank() }
                ?: throw IllegalArgumentException("MOBI NCX 章节标题索引不存在或为空")
            MobiTocEntry(offset, title, traversal.hasChildren(index))
        }
    }
}

internal data class MobiIndexEntry(val label: String, val values: Map<Int, List<Int>>)
internal data class MobiIndexData(val entries: List<MobiIndexEntry>, val strings: Map<Int, String>)

/** Shared INDX/TAGX/CNCX decoding for legacy NCX and KF8 structural indices. */
internal class MobiIndexReader(
    private val records: MobiRecordReader,
    private val textEncoding: MobiTextEncoding,
    private val checkActive: () -> Unit,
) {
    // One KF8 reader shares this budget across SKEL, FRAG, NCX and guide.
    private var recordBytes = 0
    private var labelBytes = 0
    private var stringBytes = 0
    private var valueCount = 0
    private var entryCount = 0

    fun read(index: Int): MobiIndexData {
        checkActive()
        val metaRecord = readRecord(index)
        val meta = readHeader(metaRecord)
        require(meta.count in 0..MAX_INDEX_RECORDS && meta.cncxCount in 0..MAX_CNCX_RECORDS) {
            "MOBI INDX 索引记录数无效"
        }
        require(index.toLong() + meta.count + meta.cncxCount < records.recordCount) {
            "MOBI INDX 索引引用越界"
        }
        val tags = readTagx(metaRecord, meta.length)
        val strings = readCncx(index + meta.count + 1, meta.cncxCount, meta.encoding)
        val result = mutableListOf<MobiIndexEntry>()
        for (recordIndex in 1..meta.count) {
            checkActive()
            val data = readRecord(index + recordIndex)
            val header = readHeader(data)
            require(header.count in 0..MAX_TOC_ENTRIES && result.size <= MAX_TOC_ENTRIES - header.count) {
                "MOBI INDX 超过 $MAX_TOC_ENTRIES 项限制"
            }
            require(entryCount <= MAX_INDEX_ENTRIES - header.count) { "MOBI INDX 条目总数超过限制" }
            entryCount += header.count
            require(header.idxt >= header.length && header.idxt <= data.size - 4 &&
                data.mobiAscii(header.idxt, 4) == "IDXT") { "MOBI IDXT 索引无效" }
            data.mobiRange(header.idxt + 4, header.count * 2)
            val offsets = IntArray(header.count) { data.mobiU16(header.idxt + 4 + it * 2) }
            var previous = header.length - 1
            offsets.forEach { offset ->
                require(offset > previous && offset < header.idxt) { "MOBI INDX 条目偏移无效" }
                previous = offset
            }
            offsets.forEachIndexed { entryIndex, start ->
                checkActive()
                val end = offsets.getOrNull(entryIndex + 1) ?: header.idxt
                val labelLength = data.mobiU8(start)
                require(labelLength <= end - start - 1 && labelBytes <= MAX_LABEL_TOTAL_BYTES - labelLength) {
                    "MOBI INDX 标签范围无效或总长度超过限制"
                }
                labelBytes += labelLength
                val values = readEntry(data, start, end, tags)
                val count = values.values.sumOf { it.size }
                require(valueCount <= MAX_INDEX_VALUES - count) { "MOBI INDX 标签值总数超过限制" }
                valueCount += count
                result.add(MobiIndexEntry(meta.encoding.decode(data, start + 1, start + 1 + labelLength), values))
            }
        }
        return MobiIndexData(result, strings)
    }

    private fun readRecord(index: Int, limit: Int = MAX_INDEX_RECORD_BYTES): ByteArray {
        require(recordBytes < MAX_INDEX_TOTAL_BYTES) { "MOBI INDX 记录总大小超过限制" }
        val data = records.record(index, minOf(limit, MAX_INDEX_TOTAL_BYTES - recordBytes))
        recordBytes += data.size
        return data
    }

    private fun readHeader(data: ByteArray): MobiIndexHeader {
        data.mobiRange(0, 56)
        require(data.mobiAscii(0, 4) == "INDX") { "MOBI INDX 文件头无效" }
        val length = data.mobiU32(4).mobiInt("INDX 文件头长度")
        require(length in 56..data.size) { "MOBI INDX 文件头被截断" }
        val encoding = when (val value = data.mobiU32(28)) {
            65001L -> MobiTextEncoding.UTF8
            1252L -> MobiTextEncoding.WINDOWS_1252
            0L, 0xffffffffL -> textEncoding
            else -> throw UnsupportedOperationException("不支持的 MOBI INDX 编码：$value")
        }
        val idxt = data.mobiU32(20)
        return MobiIndexHeader(
            length,
            if (idxt == 0xffffffffL) -1 else idxt.mobiInt("IDXT 偏移"),
            data.mobiU32(24).mobiInt("INDX 条目数"),
            data.mobiU32(52).mobiInt("CNCX 记录数"),
            encoding,
        )
    }

    private fun readTagx(data: ByteArray, offset: Int): MobiTagTable {
        data.mobiRange(offset, 12)
        require(data.mobiAscii(offset, 4) == "TAGX") { "MOBI INDX 缺少 TAGX 标签表" }
        val length = data.mobiU32(offset + 4).mobiInt("TAGX 长度")
        require(length >= 12 && (length - 12) % 4 == 0 && length <= data.size - offset) {
            "MOBI TAGX 标签表长度无效"
        }
        val controlBytes = data.mobiU32(offset + 8).mobiInt("TAGX 控制字节数")
        require(controlBytes in 1..32 && (length - 12) / 4 in 1..MAX_TAGS) {
            "MOBI TAGX 标签数量或控制字节数无效"
        }
        val tags = (0 until (length - 12) / 4).map { index ->
            val cursor = offset + 12 + index * 4
            val tag = MobiIndexTag(
                id = data.mobiU8(cursor),
                valueCount = data.mobiU8(cursor + 1),
                bitmask = data.mobiU8(cursor + 2),
                endsControl = data.mobiU8(cursor + 3) == 1,
            )
            require(data.mobiU8(cursor + 3) in 0..1) { "MOBI TAGX 控制标志无效" }
            require(tag.endsControl || (tag.bitmask > 0 && tag.valueCount in 1..16)) {
                "MOBI TAGX 标签描述无效"
            }
            if (!tag.endsControl) {
                val mask = tag.bitmask ushr tag.bitmask.countTrailingZeroBits()
                require(mask and (mask + 1) == 0) { "MOBI TAGX 掩码不连续" }
            }
            tag
        }
        require(tags.count { it.endsControl } <= controlBytes) { "MOBI TAGX 控制字节索引越界" }
        return MobiTagTable(controlBytes, tags)
    }

    private fun readEntry(data: ByteArray, start: Int, end: Int, table: MobiTagTable): Map<Int, List<Int>> {
        require(start < end) { "MOBI INDX 条目为空" }
        val labelLength = data.mobiU8(start)
        val controlsStart = start + 1 + labelLength
        require(controlsStart <= end - table.controlBytes) { "MOBI INDX 条目控制字节被截断" }
        val cursor = MobiVarIntCursor(data, controlsStart + table.controlBytes, end)
        var controlIndex = 0
        val pending = mutableListOf<MobiPendingTag>()
        table.tags.forEach { tag ->
            if (tag.endsControl) {
                controlIndex++
            } else {
                require(controlIndex < table.controlBytes) { "MOBI TAGX 控制字节索引越界" }
                val value = data.mobiU8(controlsStart + controlIndex) and tag.bitmask
                when {
                    value == 0 -> Unit
                    value == tag.bitmask && tag.bitmask.countOneBits() > 1 -> {
                        pending.add(MobiPendingTag(tag, null, cursor.read()))
                    }
                    else -> {
                        val count = value ushr tag.bitmask.countTrailingZeroBits()
                        require(count <= MAX_TAG_VALUES / tag.valueCount) { "MOBI INDX 标签值数量过大" }
                        pending.add(MobiPendingTag(tag, count * tag.valueCount, null))
                    }
                }
            }
        }
        val result = mutableMapOf<Int, List<Int>>()
        pending.forEach { descriptor ->
            checkActive()
            val values = mutableListOf<Int>()
            if (descriptor.count != null) {
                repeat(descriptor.count) { values.add(cursor.read()) }
            } else {
                val size = checkNotNull(descriptor.bytes)
                require(size <= end - cursor.position) { "MOBI INDX 标签数据被截断" }
                val target = cursor.position + size
                while (cursor.position < target) {
                    require(values.size < MAX_TAG_VALUES) { "MOBI INDX 标签值数量过大" }
                    values.add(cursor.read(target))
                }
                require(values.size % descriptor.tag.valueCount == 0) { "MOBI INDX 标签值分组无效" }
            }
            // Android stores TAGX entries in SparseArray.put: a repeated tag replaces the old group.
            result[descriptor.tag.id] = values
        }
        return result
    }

    private fun readCncx(start: Int, count: Int, encoding: MobiTextEncoding): Map<Int, String> {
        val result = mutableMapOf<Int, String>()
        repeat(count) { index ->
            checkActive()
            val data = readRecord(start + index, 0x10000)
            val cursor = MobiVarIntCursor(data, 0, data.size)
            var lastNonzero = data.lastIndex
            while (lastNonzero >= 0 && data[lastNonzero] == 0.toByte()) {
                if (lastNonzero and 0x3fff == 0) checkActive()
                lastNonzero--
            }
            while (cursor.position < data.size) {
                checkActive()
                if (cursor.position > lastNonzero) break
                val offset = cursor.position
                val length = cursor.read()
                require(length <= MAX_LABEL_BYTES && length <= data.size - cursor.position) {
                    "MOBI CNCX 标题长度无效"
                }
                require(result.size < MAX_TOC_ENTRIES && stringBytes <= MAX_LABEL_TOTAL_BYTES - length) {
                    "MOBI CNCX 标题表超过限制"
                }
                result[index * 0x10000 + offset] = encoding.decode(data, cursor.position, cursor.position + length)
                cursor.position += length
                stringBytes += length
            }
        }
        return result
    }

    private companion object {
        const val MAX_INDEX_RECORD_BYTES = 4 * 1024 * 1024
        const val MAX_INDEX_TOTAL_BYTES = 24 * 1024 * 1024
        const val MAX_INDEX_VALUES = 1_000_000
        const val MAX_INDEX_ENTRIES = 150000
        const val MAX_INDEX_RECORDS = 1024
        const val MAX_CNCX_RECORDS = 128
        const val MAX_TAGS = 64
        const val MAX_TAG_VALUES = 4096
        const val MAX_LABEL_BYTES = 16 * 1024
        const val MAX_LABEL_TOTAL_BYTES = 8 * 1024 * 1024
        const val MAX_TOC_ENTRIES = 50000
    }
}

private data class MobiIndexHeader(
    val length: Int,
    val idxt: Int,
    val count: Int,
    val cncxCount: Int,
    val encoding: MobiTextEncoding,
)

private data class MobiIndexTag(val id: Int, val valueCount: Int, val bitmask: Int, val endsControl: Boolean)
private data class MobiTagTable(val controlBytes: Int, val tags: List<MobiIndexTag>)
private data class MobiPendingTag(val tag: MobiIndexTag, val count: Int?, val bytes: Int?)

private class MobiVarIntCursor(private val data: ByteArray, var position: Int, private val end: Int) {
    fun read(limit: Int = end): Int {
        var value = 0L
        repeat(5) {
            require(position < minOf(end, limit)) { "MOBI 变长整数被截断" }
            val byte = data.mobiU8(position++)
            value = (value shl 7) or (byte and 0x7f).toLong()
            require(value <= Int.MAX_VALUE) { "MOBI 变长整数超出范围" }
            if (byte and 0x80 != 0) return value.toInt()
        }
        throw IllegalArgumentException("MOBI 变长整数过长")
    }
}
