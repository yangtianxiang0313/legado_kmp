package io.legado.kmp.shared.domain.localbook

/** All record numbers are absolute PDB indices, including in hybrid MOBI files. */
internal data class MobiKf8Header(
    val fdst: Int?,
    val numFdst: Int,
    val frag: Int,
    val skel: Int,
    val guide: Int? = null,
)

/** An auxiliary FDST flow. Index zero is the main stream, returned as document.text. */
internal data class MobiKf8Flow(val index: Int, val bytes: ByteArray)

internal data class MobiKf8Document(
    val text: ByteArray,
    val sections: List<MobiTextSection>,
    val flows: List<MobiKf8Flow>,
    // Preserve the decoded guide without inventing an HTML/NCX interpretation for it.
    val guide: MobiIndexData? = null,
)

/** Rebuilds Android KF8Book's SKEL/FRAG layout before exposing reader byte ranges. */
internal class MobiKf8Reader(
    private val records: MobiRecordReader,
    private val header: MobiHeader,
    private val checkActive: () -> Unit,
) {
    fun read(rawText: ByteArray): MobiKf8Document {
        checkActive()
        val kf8 = requireNotNull(header.kf8) { "MOBI 缺少 KF8 文件头" }
        require(rawText.isNotEmpty() && rawText.size <= MAX_TEXT_BYTES && rawText.size == header.textLength) {
            "KF8 解压正文长度无效或超过限制"
        }
        require(header.recordIndex >= 0 && header.textRecordCount > 0 &&
            header.recordIndex.toLong() + header.textRecordCount < records.recordCount) {
            "KF8 正文记录范围无效"
        }
        val indexRecords = listOfNotNull(kf8.fdst, kf8.frag, kf8.skel, kf8.guide, header.ncxRecord)
        indexRecords.forEach(::requireIndexRecord)
        require(indexRecords.distinct().size == indexRecords.size) { "KF8 结构索引互相重叠" }

        val flows = readFlowRanges(rawText.size, kf8)
        val indices = MobiIndexReader(records, header.encoding, checkActive)
        val skeletons = indices.read(kf8.skel)
        val fragments = indices.read(kf8.frag)
        val rebuilt = MobiKf8Reconstructor(rawText, header.encoding, checkActive).rebuild(
            flows.first().start,
            flows.first().end,
            skeletons,
            fragments,
        )
        // Auxiliary flows can contain non-HTML data; validate only reconstructed reading text.
        header.encoding.validate(rebuilt.text, checkActive)
        val navigation = header.ncxRecord?.let { index ->
            readNavigation(indices.read(index), rebuilt)
        } ?: rebuilt.parts.map { MobiTocEntry(it.start, "", false) }
        val sections = MobiHtmlSupport.sections(rebuilt.text, header.encoding, true, navigation, checkActive)
        require(sections.any { !it.isVolume && it.end > it.start }) { "KF8 重建后的正文为空" }
        val auxiliary = flows.drop(1).mapIndexed { index, range ->
            checkActive()
            val bytes = ByteArray(range.end - range.start)
            copyBytes(rawText, bytes, range.start, range.end)
            MobiKf8Flow(index + 1, bytes)
        }
        val guide = kf8.guide?.let(indices::read)
        checkActive()
        return MobiKf8Document(rebuilt.text, sections, auxiliary, guide)
    }

    private fun requireIndexRecord(index: Int) {
        require(index.toLong() > header.recordIndex.toLong() + header.textRecordCount &&
            index < records.recordCount) { "KF8 结构索引引用越界：$index" }
    }

    private fun readFlowRanges(textSize: Int, kf8: MobiKf8Header): List<MobiKf8FlowRange> {
        require(kf8.numFdst in 0..MAX_FLOWS) { "KF8 FDST 流数量超过限制" }
        val record = kf8.fdst ?: run {
            require(kf8.numFdst <= 1) { "KF8 多流正文缺少 FDST" }
            return listOf(MobiKf8FlowRange(0, textSize))
        }
        checkActive()
        val data = records.record(record, 12 + MAX_FLOWS * 8)
        data.mobiRange(0, 12)
        require(data.mobiAscii(0, 4) == "FDST" && data.mobiU32(4) == 12L) { "KF8 FDST 文件头无效" }
        val count = data.mobiU32(8).mobiInt("FDST 流数量")
        require(count in 1..MAX_FLOWS && count == kf8.numFdst) { "KF8 FDST 流数量与文件头不一致" }
        data.mobiRange(12, count * 8)
        var previousEnd = 0
        return (0 until count).map { index ->
            checkActive()
            val start = data.mobiU32(12 + index * 8).mobiInt("FDST 流起点")
            val end = data.mobiU32(16 + index * 8).mobiInt("FDST 流终点")
            require(start >= previousEnd && end >= start && end <= textSize &&
                (index != 0 || (start == 0 && end > start))) { "KF8 FDST 流范围越界或重叠" }
            previousEnd = end
            MobiKf8FlowRange(start, end)
        }
    }

    private fun readNavigation(data: MobiIndexData, rebuilt: MobiKf8Rebuilt): List<MobiTocEntry> {
        require(data.entries.isNotEmpty()) { "KF8 NCX 目录为空" }
        validateHierarchy(data.entries)
        val traversal = MobiNcxTraversal(data.entries, checkActive)
        return traversal.order.map { index ->
            checkActive()
            val entry = data.entries[index]
            val position = entry.values[6]
            require(position != null && position.size == 2) { "KF8 NCX 缺少有效的 fid/off 位置" }
            val offset = rebuilt.positions.resolve(position[0], position[1])
            require(offset in rebuilt.text.indices && header.encoding.isBoundary(rebuilt.text, offset)) {
                "KF8 NCX 章节位置越界或落在多字节字符中间"
            }
            val label = entry.values[3]?.singleOrNull()
                ?: throw IllegalArgumentException("KF8 NCX 标题索引无效")
            val title = data.strings[label]?.let(MobiHtmlSupport::metadataText)?.takeIf { it.isNotBlank() }
                ?: throw IllegalArgumentException("KF8 NCX 标题索引不存在或为空")
            MobiTocEntry(offset, title, traversal.hasChildren(index))
        }
    }

    private fun validateHierarchy(entries: List<MobiIndexEntry>) {
        val parents = IntArray(entries.size) { -1 }
        entries.forEachIndexed { index, entry ->
            checkActive()
            for (tag in 21..23) {
                val values = entry.values[tag] ?: continue
                require(values.size == 1 && values[0] in entries.indices && values[0] != index) {
                    "KF8 NCX 层级引用无效"
                }
                if (tag == 21) parents[index] = values[0]
            }
            val first = entry.values[22]?.singleOrNull()
            val last = entry.values[23]?.singleOrNull()
            require((first == null && last == null) || (first != null && last != null && first <= last)) {
                "KF8 NCX 子目录范围无效"
            }
        }
        val states = ByteArray(entries.size)
        for (index in entries.indices) {
            checkActive()
            var cursor = index
            while (cursor >= 0 && states[cursor] == 0.toByte()) {
                checkActive()
                states[cursor] = 1
                cursor = parents[cursor]
            }
            require(cursor < 0 || states[cursor] != 1.toByte()) { "KF8 NCX 父目录引用成环" }
            cursor = index
            while (cursor >= 0 && states[cursor] == 1.toByte()) {
                checkActive()
                states[cursor] = 2
                cursor = parents[cursor]
            }
        }
    }

    private fun copyBytes(source: ByteArray, target: ByteArray, start: Int, end: Int) {
        var cursor = start
        while (cursor < end) {
            checkActive()
            val next = minOf(end, cursor + 64 * 1024)
            source.copyInto(target, cursor - start, cursor, next)
            cursor = next
        }
    }

    private companion object {
        const val MAX_FLOWS = 4096
    }
}

private data class MobiKf8FlowRange(val start: Int, val end: Int)
