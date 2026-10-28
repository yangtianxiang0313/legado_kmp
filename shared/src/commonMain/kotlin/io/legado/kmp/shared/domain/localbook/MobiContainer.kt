package io.legado.kmp.shared.domain.localbook

internal data class MobiMetadata(
    val title: String,
    val authors: List<String> = emptyList(),
    val description: String = "",
    val subjects: List<String> = emptyList(),
)

internal data class MobiHeader(
    val isMobi: Boolean,
    val compression: Int,
    val textLength: Int,
    val textRecordCount: Int,
    val recordSize: Int,
    val encoding: MobiTextEncoding,
    val trailingFlags: Int,
    val ncxRecord: Int?,
    val metadata: MobiMetadata,
    val recordIndex: Int = 0,
    val version: Int = 0,
    val huffRecord: Int? = null,
    val huffCount: Int = 0,
    val resourceRecord: Int? = null,
    val coverRecord: Int? = null,
    val coverResourceIndex: Int? = null,
    val hybridRecord: Int? = null,
    val kf8: MobiKf8Header? = null,
)

/** PDB offsets and MOBI/EXTH fields follow Android MobiReader and PDBFile. */
internal class MobiRecordReader(private val source: LocalBookByteSource) {
    private val offsets: LongArray
    private val pdbName: ByteArray
    private val isMobiDatabase: Boolean
    val recordCount: Int get() = offsets.size

    init {
        require(source.size in 78L..MAX_FILE_BYTES) { "MOBI 文件无效或超过 128 MiB 限制" }
        val header = readExact(0L, 78)
        require(header.mobiU16(32) and 1 == 0) { "不支持 Palm 资源数据库格式" }
        require(header.mobiU32(72) == 0L) { "不支持包含多段记录表的 Palm 数据库" }
        val type = header.mobiAscii(60, 4)
        val creator = header.mobiAscii(64, 4)
        isMobiDatabase = type == "BOOK" && creator == "MOBI"
        require(isMobiDatabase || (type == "TEXt" && creator == "REAd")) {
            "文件不是 PalmDOC/MOBI 数据库"
        }
        pdbName = header.copyOfRange(0, 32)
        val count = header.mobiU16(76)
        require(count >= 2) { "MOBI 记录表为空" }
        val tableEnd = 78L + count.toLong() * 8
        require(tableEnd <= source.size) { "MOBI 记录表被截断" }
        val table = readExact(78L, count * 8)
        offsets = LongArray(count) { index -> table.mobiU32(index * 8) }
        var previous = tableEnd - 1
        offsets.forEach { offset ->
            require(offset > previous && offset < source.size) { "MOBI 记录偏移越界或顺序无效" }
            previous = offset
        }
    }

    fun record(index: Int, maxBytes: Int = MAX_RECORD_BYTES): ByteArray {
        require(index in offsets.indices) { "MOBI 记录索引越界：$index" }
        val start = offsets[index]
        val length = (offsets.getOrNull(index + 1) ?: source.size) - start
        require(length in 1L..maxBytes.toLong()) { "MOBI 记录过大或为空：$index" }
        return readExact(start, length.toInt())
    }

    fun readHeader(): MobiHeader {
        val primary = readHeaderAt(0)
        val boundary = primary.hybridRecord ?: return primary
        require(primary.kf8 == null && boundary > primary.textRecordCount) { "MOBI 混合版本边界无效" }
        val secondary = readHeaderAt(boundary)
        require(secondary.kf8 != null && secondary.hybridRecord == null) { "MOBI 混合版本缺少有效 KF8 文件头" }
        // Hybrid resource offsets belong to the original MOBI header, not the KF8 text record base.
        val resources = primary.resourceRecord ?: secondary.resourceRecord
        val coverIndex = secondary.coverResourceIndex ?: primary.coverResourceIndex
        val cover = if (resources != null && coverIndex != null) {
            (resources.toLong() + coverIndex).also {
                require(it < recordCount) { "MOBI 混合版本封面记录越界" }
            }.toInt()
        } else null
        return secondary.copy(
            resourceRecord = resources,
            coverRecord = cover,
            coverResourceIndex = coverIndex,
        )
    }

    private fun readHeaderAt(recordIndex: Int): MobiHeader {
        val first = record(recordIndex, MAX_HEADER_BYTES)
        require(first.size >= 16) { "PalmDOC 文件头被截断" }
        val encryption = first.mobiU16(12)
        require(encryption == 0) { "不支持受 DRM/加密保护的 PalmDOC/MOBI（加密类型 $encryption）" }
        val compression = first.mobiU16(0)
        when (compression) {
            1, 2, 17480 -> Unit
            else -> throw UnsupportedOperationException("不支持的 PalmDOC/MOBI 压缩类型：$compression")
        }
        val textLength = first.mobiU32(4).mobiInt("正文长度")
        val textCount = first.mobiU16(8)
        val recordSize = first.mobiU16(10)
        require(textLength in 1..MAX_TEXT_BYTES) { "MOBI 正文为空或超过 64 MiB 限制" }
        require(textCount in 1 until recordCount - recordIndex && recordSize > 0) { "MOBI 正文记录数或记录大小无效" }
        require(textLength.toLong() <= textCount.toLong() * maxOf(4096, recordSize)) {
            "MOBI 声明的正文长度超出记录容量"
        }

        val hasMobiHeader = first.size >= 24 && first.mobiAscii(16, 4) == "MOBI"
        require(!isMobiDatabase || hasMobiHeader) { "MOBI 文件缺少 MOBI 文件头" }
        if (!hasMobiHeader) return MobiHeader(
            isMobi = false,
            compression = compression,
            textLength = textLength,
            textRecordCount = textCount,
            recordSize = recordSize,
            encoding = MobiTextEncoding.WINDOWS_1252,
            trailingFlags = 0,
            ncxRecord = null,
            metadata = MobiMetadata(MobiTextEncoding.WINDOWS_1252.decode(pdbName, metadata = true)),
            recordIndex = recordIndex,
        )

        val headerLength = first.mobiU32(20).mobiInt("文件头长度")
        require(headerLength >= 24 && headerLength <= first.size - 16) { "MOBI 文件头长度无效" }
        val headerEnd = 16 + headerLength
        fun optional(offset: Int): Long? = if (offset + 4 <= headerEnd) first.mobiU32(offset) else null
        val version = first.mobiU32(36).mobiInt("格式版本")
        require(version in 1..8) { "不支持的 MOBI 版本：$version" }
        val encoding = when (val codepage = first.mobiU32(28)) {
            65001L -> MobiTextEncoding.UTF8
            1252L -> MobiTextEncoding.WINDOWS_1252
            else -> throw UnsupportedOperationException("不支持的 MOBI 文本编码：$codepage")
        }
        val drmCount = optional(172) ?: 0L
        require(drmCount == 0L || drmCount == 0xffffffffL) { "不支持带 DRM 数据的 MOBI" }
        val titleOffset = optional(84)?.mobiInt("标题偏移")
        val titleLength = optional(88)?.mobiInt("标题长度")
        val title = if (titleOffset != null && titleLength != null && titleLength > 0) {
            require(titleOffset >= 16 && titleLength <= MAX_METADATA_TEXT_BYTES &&
                titleOffset.toLong() + titleLength <= first.size) { "MOBI 标题范围无效" }
            encoding.decode(first, titleOffset, titleOffset + titleLength, metadata = true)
        } else encoding.decode(pdbName, metadata = true)
        val exthFlag = optional(128) ?: 0L
        val exth = if (exthFlag and 0x40L != 0L) readExth(first, headerEnd, encoding) else emptyMap()
        fun index(value: Long?, name: String, relative: Boolean = true): Int? {
            if (value == null || value == 0xffffffffL) return null
            val absolute = value + if (relative) recordIndex else 0
            require(absolute in 0 until recordCount.toLong()) { "MOBI $name 记录索引无效" }
            return absolute.toInt()
        }
        fun exthNumber(id: Int, name: String): Int? {
            val values = exth[id].orEmpty()
            require(values.size <= 1) { "MOBI $name 字段重复" }
            val data = values.firstOrNull() ?: return null
            require(data.size == 4) { "MOBI $name 字段长度无效" }
            val offset = data.mobiU32(0)
            return if (offset == 0xffffffffL) null else offset.mobiInt(name)
        }
        val ncx = index(optional(244), "目录")
        require(ncx == null || ncx in (recordIndex + textCount + 1) until recordCount) { "MOBI 目录记录索引无效" }
        val huff = if (compression == 17480) index(optional(112), "HUFF") else null
        val huffCount = if (compression == 17480) optional(116)?.mobiInt("HUFF 记录数") ?: 0 else 0
        if (compression == 17480) require(huff != null && huff > recordIndex + textCount &&
            huffCount >= 2 && huffCount.toLong() <= recordCount.toLong() - huff) { "MOBI HUFF/CDIC 记录范围无效" }
        // ResourceStart is an absolute PDB index, also in a hybrid book (Android MobiReader).
        val resources = index(optional(108), "资源", relative = false)
        val coverIndex = exthNumber(201, "封面") ?: exthNumber(202, "缩略图")
        val cover = resources?.let { base -> coverIndex?.let { index(base.toLong() + it, "封面", relative = false) } }
        val flowCount = if (version == 8) optional(196)?.mobiInt("FDST 数量") ?: 0 else 0
        val kf8 = if (version == 8) MobiKf8Header(
            // Single-flow KF8 files may retain the legacy first/last text pair at this offset.
            fdst = if (flowCount > 1) index(optional(192), "FDST") else null,
            numFdst = flowCount,
            frag = requireNotNull(index(optional(248), "片段索引")) { "KF8 缺少片段索引" },
            skel = requireNotNull(index(optional(252), "骨架索引")) { "KF8 缺少骨架索引" },
            guide = index(optional(260), "导航"),
        ) else null
        fun strings(id: Int): List<String> = exth[id].orEmpty().map {
            encoding.decode(it, metadata = true).let(MobiHtmlSupport::metadataText)
        }.filter { it.isNotBlank() }
        return MobiHeader(
            isMobi = true,
            compression = compression,
            textLength = textLength,
            textRecordCount = textCount,
            recordSize = recordSize,
            encoding = encoding,
            trailingFlags = if (headerEnd >= 244) first.mobiU16(242) else 0,
            ncxRecord = ncx,
            metadata = MobiMetadata(
                title = strings(503).firstOrNull() ?: MobiHtmlSupport.metadataText(title),
                authors = strings(100),
                description = strings(103).firstOrNull().orEmpty(),
                subjects = strings(105),
            ),
            recordIndex = recordIndex,
            version = version,
            huffRecord = huff,
            huffCount = huffCount,
            resourceRecord = resources,
            coverRecord = cover,
            coverResourceIndex = coverIndex,
            hybridRecord = index(exthNumber(121, "混合边界")?.toLong(), "混合边界", relative = false),
            kf8 = kf8,
        )
    }

    private fun readExth(
        record: ByteArray,
        offset: Int,
        encoding: MobiTextEncoding,
    ): Map<Int, List<ByteArray>> {
        record.mobiRange(offset, 12)
        require(record.mobiAscii(offset, 4) == "EXTH") { "MOBI EXTH 文件头无效" }
        val length = record.mobiU32(offset + 4).mobiInt("EXTH 长度")
        require(length >= 12 && length <= record.size - offset) { "MOBI EXTH 范围无效" }
        val count = record.mobiU32(offset + 8).mobiInt("EXTH 记录数")
        require(count <= (length - 12) / 8) { "MOBI EXTH 记录数无效" }
        val result = mutableMapOf<Int, MutableList<ByteArray>>()
        var cursor = offset + 12
        repeat(count) {
            require(cursor <= offset + length - 8) { "MOBI EXTH 记录被截断" }
            val type = record.mobiU32(cursor).mobiInt("EXTH 类型")
            val size = record.mobiU32(cursor + 4).mobiInt("EXTH 记录长度")
            require(size >= 8 && size <= offset + length - cursor) { "MOBI EXTH 记录长度无效" }
            if (type in METADATA_RECORDS) {
                require(size - 8 <= MAX_METADATA_TEXT_BYTES) { "MOBI 元数据字段过长" }
                val data = record.copyOfRange(cursor + 8, cursor + size)
                if (type !in setOf(121, 201, 202)) encoding.decode(data, metadata = true)
                result.getOrPut(type) { mutableListOf() }.add(data)
            }
            cursor += size
        }
        return result
    }

    private fun readExact(offset: Long, length: Int): ByteArray {
        require(offset >= 0L && length >= 0 && offset <= source.size - length) { "MOBI 读取范围越界" }
        val result = ByteArray(length)
        var read = 0
        while (read < length) {
            val bytes = source.read(offset + read, minOf(length - read, 64 * 1024))
            require(bytes.isNotEmpty() && bytes.size <= length - read) { "MOBI 文件读取不完整" }
            bytes.copyInto(result, read)
            read += bytes.size
        }
        return result
    }

    private companion object {
        const val MAX_FILE_BYTES = 128L * 1024 * 1024
        const val MAX_HEADER_BYTES = 2 * 1024 * 1024
        const val MAX_RECORD_BYTES = 16 * 1024 * 1024
        const val MAX_METADATA_TEXT_BYTES = 64 * 1024
        val METADATA_RECORDS = setOf(100, 103, 105, 121, 201, 202, 503)
    }
}

internal const val MAX_TEXT_BYTES = 64 * 1024 * 1024

internal fun ByteArray.mobiRange(offset: Int, length: Int) {
    require(offset >= 0 && length >= 0 && offset <= size - length) { "MOBI 数据字段被截断" }
}

internal fun ByteArray.mobiU8(offset: Int): Int {
    mobiRange(offset, 1)
    return this[offset].toInt() and 0xff
}

internal fun ByteArray.mobiU16(offset: Int): Int = (mobiU8(offset) shl 8) or mobiU8(offset + 1)

internal fun ByteArray.mobiU32(offset: Int): Long = (mobiU16(offset).toLong() shl 16) or mobiU16(offset + 2).toLong()

internal fun ByteArray.mobiAscii(offset: Int, length: Int): String {
    mobiRange(offset, length)
    return buildString(length) { for (index in offset until offset + length) append(mobiU8(index).toChar()) }
}

internal fun Long.mobiInt(field: String): Int {
    require(this in 0..Int.MAX_VALUE.toLong()) { "MOBI $field 超出范围" }
    return toInt()
}
