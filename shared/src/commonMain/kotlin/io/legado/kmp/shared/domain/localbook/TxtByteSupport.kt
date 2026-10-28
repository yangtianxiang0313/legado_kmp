package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.platform.TextCodec
import kotlin.math.min

internal class TxtByteSupport(
    private val bytes: ByteArray,
    charsetName: String,
    private val isDocumentStart: Boolean = true
) {
    private enum class Encoding {
        UTF8, UTF16_LE, UTF16_BE, GB18030, BIG5, SHIFT_JIS, EUC_JP, SINGLE_BYTE
    }

    private val encoding = when (charsetName.uppercase()) {
        "UTF-16", "UTF16" -> if (hasBom(0xfe, 0xff)) Encoding.UTF16_BE else Encoding.UTF16_LE
        "UTF-16LE", "UTF16LE" -> Encoding.UTF16_LE
        "UTF-16BE", "UTF16BE" -> Encoding.UTF16_BE
        "GBK", "GB2312", "GB18030", "GB_18030" -> Encoding.GB18030
        "BIG5", "BIG-5" -> Encoding.BIG5
        "SHIFT_JIS", "SHIFT-JIS", "SJIS" -> Encoding.SHIFT_JIS
        "EUC-JP", "EUCJP" -> Encoding.EUC_JP
        "ASCII", "ISO-8859-1", "ISO8859-1", "LATIN1" -> Encoding.SINGLE_BYTE
        else -> Encoding.UTF8
    }
    // Decode every UTF-16 slice with a fixed byte order; generic UTF-16 loses its BOM after the first window.
    private val decodingCharset = when (encoding) {
        Encoding.UTF16_LE -> "UTF-16LE"
        Encoding.UTF16_BE -> "UTF-16BE"
        else -> charsetName
    }
    private val utf16BomSize = when (encoding) {
        Encoding.UTF16_LE -> if (isDocumentStart && hasBom(0xff, 0xfe)) 2 else 0
        Encoding.UTF16_BE -> if (isDocumentStart && hasBom(0xfe, 0xff)) 2 else 0
        else -> 0
    }

    val startOffset: Int = if (isDocumentStart && TextCodec.hasUtf8Bom(bytes)) 3 else 0

    fun windowEnd(start: Int, maxBytes: Int, end: Int = bytes.size, preferLineBreak: Boolean = false): Int {
        // Even tiny caller-supplied windows must fit a BOM and a complete supplementary character.
        val limit = start + min(maxBytes.coerceAtLeast(8), end - start)
        var offset = start
        var lastLineEnd = start
        while (offset < limit) {
            val next = nextCharacterEnd(offset, end)
            if (next > limit) break
            if (isLineBreak(offset)) lastLineEnd = next
            offset = next
        }
        check(offset > start) { "TXT window did not advance at byte $start" }
        return if (preferLineBreak && offset < end && lastLineEnd > start) lastLineEnd else offset
    }

    fun firstLineBreak(start: Int, minimum: Int, end: Int): Int? {
        var offset = start
        while (offset < end) {
            if (offset >= minimum && isLineBreak(offset)) return offset
            offset = nextCharacterEnd(offset, end)
        }
        return null
    }

    fun decode(start: Int, end: Int): Block {
        val textStart = textStart(start)
        val from = textStart.coerceAtMost(end)
        var content = TextCodec.decode(bytes.copyOfRange(from, end), decodingCharset)
        // Foundation consumes a leading encoding marker on every slice, even inside the document.
        if (!isDocumentStart || from > 0) {
            val markerWidth = when (encoding) {
                Encoding.UTF8 -> 3
                Encoding.UTF16_LE, Encoding.UTF16_BE -> 2
                else -> 0
            }
            var markers = 0
            var cursor = from
            while (markerWidth > 0 && cursor + markerWidth <= end && isBomAt(cursor)) {
                markers++
                cursor += markerWidth
            }
            val retained = content.takeWhile { it == '\ufeff' }.length
            if (markers > retained) content = "\ufeff".repeat(markers - retained) + content
        }
        return Block(start, end, content)
    }

    inner class Block(val start: Int, val end: Int, val content: String) {
        private var byteCursor = textStart(start)
        private var textCursor = 0

        // Match indexes count UTF-16 code units; offsets must refer to the original bytes, not re-encoded text.
        fun byteOffset(index: Int): Int? {
            if (index !in 0..content.length) return null
            if (index == 0) return start
            if (index < textCursor) {
                byteCursor = textStart(start)
                textCursor = 0
            }
            while (byteCursor < end && textCursor < index) {
                val next = nextCharacterEnd(byteCursor, end)
                val units = when (encoding) {
                    Encoding.UTF8 -> if (next - byteCursor == 4) 2 else 1
                    Encoding.UTF16_LE, Encoding.UTF16_BE -> (next - byteCursor) / 2
                    Encoding.GB18030 -> if (next - byteCursor == 4 && unsigned(byteCursor) >= 0x90) 2 else 1
                    else -> 1
                }
                if (textCursor + units > index) return null
                byteCursor = next
                textCursor += units
            }
            return byteCursor.takeIf { textCursor == index }
        }
    }

    private fun textStart(start: Int): Int = if (start == 0) utf16BomSize else start

    private fun isLineBreak(offset: Int): Boolean = when (encoding) {
        Encoding.UTF16_LE, Encoding.UTF16_BE -> codeUnit(offset) == 0x000a
        else -> unsigned(offset) == 0x0a
    }

    private fun nextCharacterEnd(offset: Int, end: Int): Int {
        // Reject malformed/truncated input rather than letting a codec fallback change the byte-to-text mapping.
        val first = unsigned(offset)
        fun requireBytes(count: Int) {
            require(end - offset >= count) { "Incomplete $decodingCharset character at TXT byte $offset" }
        }
        fun requireByte(index: Int, range: IntRange) {
            require(unsigned(offset + index) in range) { "Invalid $decodingCharset character at TXT byte $offset" }
        }
        val size = when (encoding) {
            Encoding.UTF8 -> when (first) {
                in 0x00..0x7f -> 1
                in 0xc2..0xdf -> {
                    requireBytes(2)
                    requireByte(1, 0x80..0xbf)
                    2
                }
                in 0xe0..0xef -> {
                    requireBytes(3)
                    requireByte(1, when (first) {
                        0xe0 -> 0xa0..0xbf
                        0xed -> 0x80..0x9f
                        else -> 0x80..0xbf
                    })
                    requireByte(2, 0x80..0xbf)
                    3
                }
                in 0xf0..0xf4 -> {
                    requireBytes(4)
                    requireByte(1, when (first) {
                        0xf0 -> 0x90..0xbf
                        0xf4 -> 0x80..0x8f
                        else -> 0x80..0xbf
                    })
                    requireByte(2, 0x80..0xbf)
                    requireByte(3, 0x80..0xbf)
                    4
                }
                else -> throw IllegalArgumentException("Invalid UTF-8 character at TXT byte $offset")
            }
            Encoding.UTF16_LE, Encoding.UTF16_BE -> {
                requireBytes(2)
                when (codeUnit(offset)) {
                    in 0xd800..0xdbff -> {
                        requireBytes(4)
                        require(codeUnit(offset + 2) in 0xdc00..0xdfff) {
                            "Invalid UTF-16 surrogate at TXT byte $offset"
                        }
                        4
                    }
                    in 0xdc00..0xdfff -> throw IllegalArgumentException("Unpaired UTF-16 surrogate at TXT byte $offset")
                    else -> 2
                }
            }
            Encoding.GB18030 -> if (first <= 0x80) {
                1
            } else {
                require(first in 0x81..0xfe) { "Invalid GB18030 character at TXT byte $offset" }
                requireBytes(2)
                if (unsigned(offset + 1) in 0x30..0x39) {
                    requireBytes(4)
                    requireByte(2, 0x81..0xfe)
                    requireByte(3, 0x30..0x39)
                    val pointer = (((first - 0x81) * 10 + unsigned(offset + 1) - 0x30) * 126 +
                        unsigned(offset + 2) - 0x81) * 10 + unsigned(offset + 3) - 0x30
                    require(pointer in 0..39419 || pointer in 189000..1237575) {
                        "Unmapped GB18030 character at TXT byte $offset"
                    }
                    4
                } else {
                    require(unsigned(offset + 1) in 0x40..0xfe && unsigned(offset + 1) != 0x7f) {
                        "Invalid GB18030 character at TXT byte $offset"
                    }
                    2
                }
            }
            Encoding.BIG5 -> if (first <= 0x7f) {
                1
            } else {
                require(first in 0x81..0xfe) { "Invalid Big5 character at TXT byte $offset" }
                requireBytes(2)
                require(unsigned(offset + 1) in 0x40..0x7e || unsigned(offset + 1) in 0xa1..0xfe) {
                    "Invalid Big5 character at TXT byte $offset"
                }
                2
            }
            Encoding.SHIFT_JIS -> if (first <= 0x7f || first in 0xa1..0xdf) {
                1
            } else {
                require(first in 0x81..0x9f || first in 0xe0..0xfc) { "Invalid Shift-JIS character at TXT byte $offset" }
                requireBytes(2)
                require(unsigned(offset + 1) in 0x40..0xfc && unsigned(offset + 1) != 0x7f) {
                    "Invalid Shift-JIS character at TXT byte $offset"
                }
                2
            }
            Encoding.EUC_JP -> when (first) {
                in 0x00..0x7f -> 1
                0x8e -> {
                    requireBytes(2)
                    requireByte(1, 0xa1..0xdf)
                    2
                }
                0x8f -> {
                    requireBytes(3)
                    requireByte(1, 0xa1..0xfe)
                    requireByte(2, 0xa1..0xfe)
                    3
                }
                in 0xa1..0xfe -> {
                    requireBytes(2)
                    requireByte(1, 0xa1..0xfe)
                    2
                }
                else -> throw IllegalArgumentException("Invalid EUC-JP character at TXT byte $offset")
            }
            Encoding.SINGLE_BYTE -> 1
        }
        return offset + size
    }

    private fun unsigned(offset: Int): Int = bytes[offset].toInt() and 0xff

    private fun codeUnit(offset: Int): Int = if (encoding == Encoding.UTF16_BE) {
        (unsigned(offset) shl 8) or unsigned(offset + 1)
    } else {
        unsigned(offset) or (unsigned(offset + 1) shl 8)
    }

    private fun hasBom(first: Int, second: Int): Boolean =
        bytes.size >= 2 && unsigned(0) == first && unsigned(1) == second

    private fun isBomAt(offset: Int): Boolean = when (encoding) {
        Encoding.UTF8 -> unsigned(offset) == 0xef && unsigned(offset + 1) == 0xbb && unsigned(offset + 2) == 0xbf
        Encoding.UTF16_LE -> unsigned(offset) == 0xff && unsigned(offset + 1) == 0xfe
        Encoding.UTF16_BE -> unsigned(offset) == 0xfe && unsigned(offset + 1) == 0xff
        else -> false
    }
}
