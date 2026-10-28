package io.legado.kmp.shared.domain.localbook

/** HUFF lookup and padded bit windows ported from Android HuffcdicDecompressor (5f5d31404). */
internal class MobiHuffCdicDecoder(
    records: MobiRecordReader,
    huffRecord: Int,
    huffCount: Int,
    private val checkActive: () -> Unit,
) {
    private val table1: LongArray
    private val mincodeTable = LongArray(33)
    private val maxcodeTable = LongArray(33)
    private val dictionary: MobiCdicDictionary

    init {
        checkActive()
        require(huffRecord in 0 until records.recordCount && huffCount >= 2 &&
            huffCount <= records.recordCount - huffRecord) {
            "MOBI HUFF/CDIC 记录范围无效"
        }
        val huff = records.record(huffRecord, MAX_DICTIONARY_RECORD_BYTES)
        checkActive()
        huff.mobiRange(0, 16)
        require(huff.mobiAscii(0, 4) == "HUFF") { "MOBI HUFF 记录标识无效" }
        val offset1 = huff.mobiU32(8).mobiInt("HUFF 前缀表偏移")
        val offset2 = huff.mobiU32(12).mobiInt("HUFF 码表偏移")
        require(offset1 >= 16 && offset2 >= 16) { "MOBI HUFF 码表与文件头重叠" }
        huff.mobiRange(offset1, 256 * 4)
        huff.mobiRange(offset2, 32 * 8)
        table1 = LongArray(256) { index ->
            if (index and 0x3f == 0) checkActive()
            huff.mobiU32(offset1 + index * 4).also { value ->
                require(value and 0x1fL != 0L) { "MOBI HUFF 前缀码长度为零" }
            }
        }
        for (length in 1..32) {
            val offset = offset2 + (length - 1) * 8
            val mincode = huff.mobiU32(offset)
            val maxcode = huff.mobiU32(offset + 4)
            mincodeTable[length] = mincode shl (32 - length)
            maxcodeTable[length] = ((maxcode + 1) shl (32 - length)) - 1
        }
        dictionary = MobiCdicDictionary(records, huffRecord + 1, huffCount - 1, checkActive)
    }

    fun decompress(data: ByteArray, end: Int, limit: Int): ByteArray {
        checkActive()
        require(end in 0..data.size && end <= MAX_COMPRESSED_RECORD_BYTES) {
            "MOBI HUFF 压缩记录范围无效或过大"
        }
        require(limit in 1..MAX_RECORD_OUTPUT_BYTES) { "MOBI HUFF 解压上限无效" }
        return decode(data, end, limit, 0, DecodeBudget(checkActive))
    }

    private fun decode(
        data: ByteArray,
        end: Int,
        limit: Int,
        depth: Int,
        budget: DecodeBudget,
    ): ByteArray {
        val output = ByteArray(limit)
        var written = 0
        var bitsleft = end.toLong() * 8
        var position = 0
        var window = readWindow(data, position, end)
        var bitcount = 32

        while (bitsleft > 0) {
            budget.step()
            if (bitcount <= 0) {
                position += 4
                require(position < end) { "MOBI HUFF 位窗口越界" }
                window = readWindow(data, position, end)
                bitcount += 32
            }

            val code = (window ushr bitcount) and UINT32_MASK
            val prefix = table1[(code ushr 24).toInt()]
            var codelen = (prefix and 0x1fL).toInt()
            var maxcode = (((prefix ushr 8) + 1) shl (32 - codelen)) - 1

            if (prefix and 0x80L == 0L) {
                while (codelen <= 32 && code < mincodeTable[codelen]) codelen++
                require(codelen in 1..32) { "MOBI HUFF 位流没有匹配的码长" }
                maxcode = maxcodeTable[codelen]
                require(mincodeTable[codelen] in 0L..UINT32_MASK &&
                    maxcode >= mincodeTable[codelen]) {
                    "MOBI HUFF 码表范围无效"
                }
            }

            // Android discards the final incomplete code after zero-padding its bit window.
            bitsleft -= codelen
            if (bitsleft < 0) break
            bitcount -= codelen
            require(maxcode in 0L..UINT32_MASK && code <= maxcode) { "MOBI HUFF 码值越界" }
            val index = (maxcode - code) ushr (32 - codelen)
            require(index < dictionary.size.toLong()) { "MOBI HUFF 词条索引越界：$index" }

            val phrase = dictionary.resolve(index.toInt(), limit - written, depth) { compressed, remaining, nextDepth ->
                decode(compressed, compressed.size, remaining, nextDepth, budget)
            }
            require(phrase.size <= limit - written) { "MOBI HUFF 解压结果超过记录大小限制" }
            phrase.copyInto(output, written)
            written += phrase.size
        }
        checkActive()
        return output.copyOf(written)
    }

    private fun readWindow(data: ByteArray, offset: Int, end: Int): Long {
        require(offset in 0..end) { "MOBI HUFF 位窗口偏移无效" }
        var value = 0L
        repeat(8) { index ->
            value = value shl 8
            if (index < end - offset) value = value or data.mobiU8(offset + index).toLong()
        }
        return value
    }

    private class DecodeBudget(private val checkActive: () -> Unit) {
        private var steps = 0

        fun step() {
            if (steps and 0x3ff == 0) checkActive()
            require(steps < MAX_DECODE_STEPS) { "MOBI HUFF/CDIC 展开步骤超过限制" }
            steps++
        }
    }

    private companion object {
        const val UINT32_MASK = 0xffffffffL
        const val MAX_DICTIONARY_RECORD_BYTES = 16 * 1024 * 1024
        const val MAX_RECORD_OUTPUT_BYTES = 64 * 1024
        const val MAX_COMPRESSED_RECORD_BYTES = 2 * MAX_RECORD_OUTPUT_BYTES + 1024
        const val MAX_DECODE_STEPS = 4 * 1024 * 1024
    }
}
