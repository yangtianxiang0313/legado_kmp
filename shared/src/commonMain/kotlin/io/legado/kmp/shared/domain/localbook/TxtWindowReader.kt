package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.platform.TextCodec

internal class TxtWindowReader(
    private val source: LocalBookByteSource,
    charsetName: String,
    private val bufferSize: Int,
    private val checkActive: () -> Unit
) {
    private val prefix = readExact(0, minOf(source.size, 4).toInt())
    private val decodingCharset = when (charsetName.uppercase()) {
        "UTF-16", "UTF16" -> if (prefix.size >= 2 && prefix[0] == 0xfe.toByte() && prefix[1] == 0xff.toByte()) {
            "UTF-16BE"
        } else {
            "UTF-16LE"
        }
        else -> charsetName
    }
    val startOffset: Long = if (TextCodec.hasUtf8Bom(prefix)) 3 else 0
    val size: Long get() = source.size

    fun window(start: Long, end: Long = size, preferLineBreak: Boolean = false): Window {
        require(start >= 0 && start < end && end <= size) { "Invalid TXT byte window $start..$end" }
        // Four bytes of lookahead keep the requested window on a complete character boundary.
        val count = minOf(bufferSize.coerceAtLeast(8).toLong() + 4, end - start).toInt()
        val bytes = readExact(start, count)
        val support = TxtByteSupport(bytes, decodingCharset, isDocumentStart = start == 0L)
        val localEnd = support.windowEnd(0, bufferSize, preferLineBreak = preferLineBreak)
        val block = support.decode(0, localEnd)
        checkActive()
        return Window(start, start + localEnd, support, block)
    }

    private fun readExact(offset: Long, length: Int): ByteArray {
        checkActive()
        val first = source.read(offset, length)
        checkActive()
        check(first.size <= length) { "TXT byte source exceeded requested length" }
        if (first.size == length) return first
        val result = ByteArray(length)
        first.copyInto(result)
        var copied = first.size
        while (copied < length) {
            checkActive()
            val part = source.read(offset + copied, length - copied)
            checkActive()
            check(part.isNotEmpty() && part.size <= length - copied) { "TXT file changed or ended at byte ${offset + copied}" }
            part.copyInto(result, copied)
            copied += part.size
        }
        return result
    }

    inner class Window(
        val start: Long,
        val end: Long,
        private val support: TxtByteSupport,
        private val block: TxtByteSupport.Block
    ) {
        val content: String get() = block.content

        fun byteOffset(index: Int): Long? = block.byteOffset(index)?.let { start + it }

        fun firstLineBreak(offset: Long, minimum: Long): Long? =
            support.firstLineBreak((offset - start).toInt(), (minimum - start).toInt(), (end - start).toInt())
                ?.let { start + it }

        fun decode(offset: Long, limit: Long): String {
            checkActive()
            return support.decode((offset - start).toInt(), (limit - start).toInt()).content
        }
    }
}
