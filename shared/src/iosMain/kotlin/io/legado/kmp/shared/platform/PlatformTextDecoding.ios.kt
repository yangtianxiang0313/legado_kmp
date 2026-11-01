package io.legado.kmp.shared.platform

internal fun decodePlatformText(bytes: ByteArray, charsetName: String): String {
    // Share the write-side allowlist, not its BOM/output-endianness policy.
    // Android lookup trims ASCII control/space characters; keep write-side rejection unchanged.
    val name = charsetName.trim { it <= ' ' }
    val encoding = textEncodingForWrite(name)
    return when (encoding) {
        TextWriteEncoding.UTF8 -> decodePlatformUtf8(bytes)
        TextWriteEncoding.UTF16 -> decodePlatformUtf16(
            bytes, littleEndian = false, consumeBom = true,
            fixedBomOrder = name.equals("UnicodeBig", ignoreCase = true),
        )
        TextWriteEncoding.UTF16BE -> decodePlatformUtf16(bytes, littleEndian = false)
        TextWriteEncoding.UTF16LE -> decodePlatformUtf16(bytes, littleEndian = true)
        TextWriteEncoding.UTF16LE_BOM -> decodePlatformUtf16(
            bytes, littleEndian = true, consumeBom = true, fixedBomOrder = true,
        )
        TextWriteEncoding.UTF32 -> decodePlatformUtf32(bytes, littleEndian = false, consumeBom = true)
        TextWriteEncoding.UTF32BE -> decodePlatformUtf32(bytes, littleEndian = false)
        TextWriteEncoding.UTF32LE -> decodePlatformUtf32(bytes, littleEndian = true)
        TextWriteEncoding.ASCII -> decodePlatformSingleByte(bytes, ascii = true)
        TextWriteEncoding.LATIN1 -> decodePlatformSingleByte(bytes)
        TextWriteEncoding.WINDOWS_1252 -> decodePlatformSingleByte(bytes, windows1252 = true)
        else -> decodePlatformLegacyText(bytes, requireNotNull(encoding.legacyCharset))
    }
}

private fun decodePlatformSingleByte(
    bytes: ByteArray,
    ascii: Boolean = false,
    windows1252: Boolean = false,
): String = buildString(bytes.size) {
    for (byte in bytes) {
        val value = byte.toInt() and 0xff
        append(
            when {
                ascii && value > 0x7f -> '\ufffd'
                windows1252 && value in 0x80..0x9f -> WINDOWS_1252_DECODE_C1[value - 0x80]
                else -> value.toChar()
            },
        )
    }
}

private val WINDOWS_1252_DECODE_C1 = charArrayOf(
    '\u20ac', '\u0081', '\u201a', '\u0192', '\u201e', '\u2026', '\u2020', '\u2021',
    '\u02c6', '\u2030', '\u0160', '\u2039', '\u0152', '\u008d', '\u017d', '\u008f',
    '\u0090', '\u2018', '\u2019', '\u201c', '\u201d', '\u2022', '\u2013', '\u2014',
    '\u02dc', '\u2122', '\u0161', '\u203a', '\u0153', '\u009d', '\u017e', '\u0178',
)

private fun decodePlatformUtf8(bytes: ByteArray): String = buildString(bytes.size) {
    var index = 0
    while (index < bytes.size) {
        val lead = bytes.unsignedByte(index++)
        if (lead < 0x80) {
            append(lead.toChar())
            continue
        }
        val length = when (lead) {
            in 0xc2..0xdf -> 2
            in 0xe0..0xef -> 3
            in 0xf0..0xf4 -> 4
            else -> {
                append('\ufffd')
                continue
            }
        }
        var codePoint = lead and (0x7f shr length)
        var consumed = 1
        while (consumed < length && index < bytes.size) {
            val next = bytes.unsignedByte(index)
            val valid = if (consumed != 1) next in 0x80..0xbf else when (lead) {
                0xe0 -> next in 0xa0..0xbf
                0xed -> next in 0x80..0x9f
                0xf0 -> next in 0x90..0xbf
                0xf4 -> next in 0x80..0x8f
                else -> next in 0x80..0xbf
            }
            if (!valid) break
            codePoint = (codePoint shl 6) or (next and 0x3f)
            index++
            consumed++
        }
        // Consume the maximal valid prefix only; the next starter is still input.
        if (consumed == length) appendDecodedScalar(codePoint) else append('\ufffd')
    }
}

private fun decodePlatformUtf16(
    bytes: ByteArray,
    littleEndian: Boolean,
    consumeBom: Boolean = false,
    fixedBomOrder: Boolean = false,
): String = buildString(bytes.size / 2) {
    // The API 36 BOM-sensitive converter buffers its first byte without flushing it as an error.
    if (consumeBom && bytes.size == 1) return@buildString
    var little = littleEndian
    var index = 0
    if (consumeBom && bytes.size >= 2) {
        val first = bytes.readTextUnit(0, 2, little)
        when (first) {
            0xfeff -> index = 2
            0xfffe -> {
                index = 2
                if (fixedBomOrder) append('\ufffd') else little = !little
            }
        }
    }
    while (bytes.size - index >= 2) {
        val unit = bytes.readTextUnit(index, 2, little)
        index += 2
        when (unit) {
            in 0xd800..0xdbff -> {
                if (bytes.size - index >= 2) {
                    val trail = bytes.readTextUnit(index, 2, little)
                    if (trail in 0xdc00..0xdfff) {
                        append(unit.toChar())
                        append(trail.toChar())
                        index += 2
                    } else {
                        append('\ufffd')
                    }
                } else {
                    // An unfinished surrogate pair, including a partial trail, is one truncated sequence.
                    append('\ufffd')
                    index = bytes.size
                }
            }
            in 0xdc00..0xdfff -> append('\ufffd')
            else -> append(unit.toChar())
        }
    }
    if (index < bytes.size) append('\ufffd')
}

private fun decodePlatformUtf32(
    bytes: ByteArray,
    littleEndian: Boolean,
    consumeBom: Boolean = false,
): String = buildString(bytes.size / 4) {
    // An incomplete initial BOM candidate remains buffered, unlike a truncated UTF-32 code unit.
    if (consumeBom && bytes.isPartialUtf32Bom()) return@buildString
    var little = littleEndian
    var index = 0
    if (consumeBom && bytes.size >= 4) {
        when (bytes.readTextUnit(0, 4, little)) {
            0x0000feff -> index = 4
            0xfffe0000.toInt() -> {
                index = 4
                little = !little
            }
        }
    }
    // ICU's BOM-sensitive UTF-32 defaults to BE when reading, even on a LE writer platform.
    while (bytes.size - index >= 4) {
        val codePoint = bytes.readTextUnit(index, 4, little)
        index += 4
        if (codePoint in 0..0x10ffff && codePoint !in 0xd800..0xdfff) {
            appendDecodedScalar(codePoint)
        } else {
            append('\ufffd')
        }
    }
    if (index < bytes.size) append('\ufffd')
}

private fun ByteArray.isPartialUtf32Bom(): Boolean {
    if (isEmpty() || size >= 4) return false
    val bigEndianBom = intArrayOf(0x00, 0x00, 0xfe, 0xff)
    val littleEndianBom = intArrayOf(0xff, 0xfe, 0x00, 0x00)
    return indices.all { unsignedByte(it) == bigEndianBom[it] } ||
        indices.all { unsignedByte(it) == littleEndianBom[it] }
}

private fun ByteArray.unsignedByte(index: Int): Int = this[index].toInt() and 0xff

private fun ByteArray.readTextUnit(index: Int, width: Int, littleEndian: Boolean): Int {
    var result = 0
    for (offset in 0 until width) {
        val byteIndex = index + if (littleEndian) width - 1 - offset else offset
        result = (result shl 8) or unsignedByte(byteIndex)
    }
    return result
}

private fun StringBuilder.appendDecodedScalar(codePoint: Int) {
    if (codePoint <= 0xffff) {
        append(codePoint.toChar())
    } else {
        append((0xd800 + ((codePoint - 0x10000) ushr 10)).toChar())
        append((0xdc00 + ((codePoint - 0x10000) and 0x3ff)).toChar())
    }
}
