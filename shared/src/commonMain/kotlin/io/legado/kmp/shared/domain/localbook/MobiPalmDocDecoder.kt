package io.legado.kmp.shared.domain.localbook

/** PalmDOC LZ77, Huff/CDIC and record trailers follow Android's MOBI decompressors. */
internal object MobiPalmDocDecoder {
    fun readText(records: MobiRecordReader, header: MobiHeader, checkActive: () -> Unit): ByteArray {
        checkActive()
        require(header.textLength in 1..MAX_TEXT_BYTES && header.recordSize in 1..0xffff) {
            "MOBI 正文长度或记录大小无效"
        }
        require(header.recordIndex in 0 until records.recordCount && header.textRecordCount > 0 &&
            header.textRecordCount < records.recordCount - header.recordIndex) {
            "MOBI 正文记录范围无效"
        }
        val recordLimit = maxOf(4096, header.recordSize)
        val huff = if (header.compression == 17480) {
            MobiHuffCdicDecoder(
                records,
                requireNotNull(header.huffRecord) { "MOBI 缺少 HUFF 记录索引" },
                header.huffCount,
                checkActive,
            )
        } else null
        val result = ByteArray(header.textLength)
        var written = 0
        repeat(header.textRecordCount) { index ->
            checkActive()
            val recordIndex = header.recordIndex + index + 1
            val compressed = records.record(recordIndex, 2 * recordLimit + 1024)
            val end = removeTrailers(compressed, header.trailingFlags)
            val text = when (header.compression) {
                1 -> {
                    require(end <= recordLimit) { "PalmDOC 未压缩记录超过声明大小" }
                    compressed.copyOfRange(0, end)
                }
                2 -> decompress(compressed, end, recordLimit, checkActive)
                17480 -> checkNotNull(huff).decompress(compressed, end, recordLimit)
                else -> error("不支持的 MOBI 压缩方式")
            }
            require(text.isNotEmpty()) { "MOBI 正文记录为空：$recordIndex" }
            val remaining = result.size - written
            require(remaining > 0) { "MOBI 正文记录数量与声明长度不符" }
            val count = minOf(remaining, text.size)
            text.copyInto(result, written, 0, count)
            written += count
            require(count == text.size || index == header.textRecordCount - 1) {
                "MOBI 正文长度在最后记录之前结束"
            }
        }
        require(written == result.size) { "MOBI 正文被截断，实际 $written 字节，声明 ${result.size} 字节" }
        return result
    }

    private fun decompress(data: ByteArray, end: Int, limit: Int, checkActive: () -> Unit): ByteArray {
        val output = ByteArray(limit)
        var input = 0
        var written = 0
        fun append(value: Byte) {
            require(written < limit) { "PalmDOC 解压结果超过记录大小限制" }
            output[written++] = value
        }
        while (input < end) {
            if (input and 0x3ff == 0) checkActive()
            val byte = data.mobiU8(input++)
            when (byte) {
                in 1..8 -> {
                    require(byte <= end - input) { "PalmDOC 字面量记录被截断" }
                    repeat(byte) { append(data[input++]) }
                }
                in 0..0x7f -> append(byte.toByte())
                in 0xc0..0xff -> {
                    append(0x20)
                    append((byte xor 0x80).toByte())
                }
                else -> {
                    require(input < end) { "PalmDOC 回溯引用被截断" }
                    val pair = (byte shl 8) or data.mobiU8(input++)
                    val distance = (pair shr 3) and 0x7ff
                    val count = (pair and 7) + 3
                    require(distance in 1..written) { "PalmDOC 回溯距离无效" }
                    repeat(count) { append(output[written - distance]) }
                }
            }
        }
        return output.copyOf(written)
    }

    private fun removeTrailers(data: ByteArray, flags: Int): Int {
        var end = data.size
        repeat((flags ushr 1).countOneBits()) {
            var cursor = end - 1
            var size = 0L
            var shift = 0
            var terminated = false
            while (cursor >= 0 && shift <= 28) {
                val byte = data.mobiU8(cursor--)
                size = size or ((byte and 0x7f).toLong() shl shift)
                shift += 7
                if (byte and 0x80 != 0) {
                    terminated = true
                    break
                }
            }
            val encodedSize = end - 1 - cursor
            require(terminated && size >= encodedSize && size <= end.toLong()) {
                "MOBI 尾部附加记录长度无效"
            }
            end -= size.toInt()
        }
        if (flags and 1 != 0) {
            require(end > 0) { "MOBI 多字节尾部记录被截断" }
            val size = (data.mobiU8(end - 1) and 3) + 1
            require(size <= end) { "MOBI 多字节尾部记录长度无效" }
            end -= size
        }
        require(end > 0) { "MOBI 正文记录仅含尾部附加数据" }
        return end
    }
}
