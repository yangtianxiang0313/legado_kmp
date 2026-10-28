package io.legado.kmp.shared.domain.localbook

import okio.Buffer
import okio.IOException
import okio.Inflater
import okio.InflaterSource
import okio.Source
import okio.Timeout

internal fun inflateUmdZlib(
    payload: UmdBinaryReader,
    maxOutputBytes: Int,
    checkActive: () -> Unit,
): ByteArray {
    checkActive()
    require(payload.size in 6..UmdLimits.MAX_BLOCK_BYTES) { "UMD 正文压缩块为空、损坏或超过 8 MiB" }
    require(maxOutputBytes >= 0) { "UMD 实际正文超过声明长度" }
    val cmf = payload.bytes[payload.start].toInt() and 255
    val flags = payload.bytes[payload.start + 1].toInt() and 255
    require(cmf and 15 == 8 && cmf ushr 4 <= 7 && ((cmf shl 8) + flags) % 31 == 0) {
        "UMD 正文不是有效 zlib 数据，不支持加密正文"
    }
    if (flags and 32 != 0) throw UnsupportedOperationException("UMD 不支持需要外部字典的压缩正文")
    val input = UmdCompressedSource(payload, checkActive)
    val output = Buffer()
    val source = InflaterSource(input, Inflater(false))
    try {
        while (true) {
            checkActive()
            val read = source.read(output, minOf(8192L, maxOutputBytes.toLong() - output.size + 1))
            require(output.size <= maxOutputBytes.toLong()) { "UMD 解压正文超过声明长度或 8 MiB 块限额" }
            if (read == -1L) break
            require(read > 0) { "UMD 正文解压未取得进展" }
        }
        require(input.exhausted) { "UMD zlib 压缩块尾部存在多余数据" }
        require(!input.readPastEnd) { "UMD zlib 正文截断，尚未完成压缩流或校验尾" }
        checkActive()
        payload.skipRemaining()
        return output.readByteArray()
    } catch (error: IOException) {
        throw IllegalArgumentException("UMD zlib 正文损坏、截断或校验失败", error)
    } finally {
        source.close()
    }
}

private class UmdCompressedSource(
    private val payload: UmdBinaryReader,
    private val checkActive: () -> Unit,
) : Source {
    private var position = payload.start
    val exhausted: Boolean get() = position == payload.end
    var readPastEnd: Boolean = false
        private set

    override fun read(sink: Buffer, byteCount: Long): Long {
        require(byteCount >= 0)
        checkActive()
        if (byteCount == 0L) return 0
        if (exhausted) {
            // Native Okio can report EOF without a complete zlib stream; do not accept that as success.
            readPastEnd = true
            return -1
        }
        // Feed the final eight bytes individually so inflater read-ahead cannot hide a trailing stream.
        val bulkRemaining = payload.end - position - 8
        val count = minOf(byteCount, 8192L, if (bulkRemaining > 0) bulkRemaining.toLong() else 1L).toInt()
        sink.write(payload.bytes, position, count)
        position += count
        return count.toLong()
    }

    override fun timeout(): Timeout = Timeout.NONE

    override fun close() = Unit
}
