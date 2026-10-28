package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.platform.TextCodec

internal fun canonicalUmdCharset(name: String): String = when (name.trim().uppercase().replace('_', '-')) {
    "UTF-16", "UTF16", "UTF-16LE", "UTF16LE" -> "UTF-16LE"
    "UTF-16BE", "UTF16BE" -> "UTF-16BE"
    "UTF-8", "UTF8" -> "UTF-8"
    "GB18030", "GB-18030" -> "GB18030"
    "GBK" -> "GBK"
    "GB2312", "GB-2312" -> "GB2312"
    else -> throw UnsupportedOperationException("UMD 不支持此文本编码：$name")
}

internal data class UmdTextEncoding(val name: String, val bomBytes: Int)

internal fun umdTextEncoding(bytes: ByteArray, start: Int, end: Int, fallback: String): UmdTextEncoding {
    fun byte(index: Int) = bytes[start + index].toInt() and 255
    val size = end - start
    if (size >= 4 && ((byte(0) == 255 && byte(1) == 254 && byte(2) == 0 && byte(3) == 0) ||
        (byte(0) == 0 && byte(1) == 0 && byte(2) == 254 && byte(3) == 255))) {
        throw UnsupportedOperationException("UMD 不支持 UTF-32 编码")
    }
    return when {
        size >= 3 && byte(0) == 239 && byte(1) == 187 && byte(2) == 191 -> UmdTextEncoding("UTF-8", 3)
        size >= 2 && byte(0) == 255 && byte(1) == 254 -> UmdTextEncoding("UTF-16LE", 2)
        size >= 2 && byte(0) == 254 && byte(1) == 255 -> UmdTextEncoding("UTF-16BE", 2)
        else -> UmdTextEncoding(fallback, 0)
    }
}

internal fun decodeUmdText(
    bytes: ByteArray,
    start: Int,
    end: Int,
    charset: String,
    checkActive: () -> Unit,
    detectBom: Boolean = true,
): String {
    checkActive()
    require(start >= 0 && end >= start && end <= bytes.size) { "UMD 文本数据范围无效" }
    val encoding = if (detectBom) umdTextEncoding(bytes, start, end, charset) else UmdTextEncoding(charset, 0)
    val from = start + encoding.bomBytes
    val text = when (encoding.name) {
        "UTF-16LE", "UTF-16BE" -> decodeUmdUtf16(bytes, from, end, encoding.name == "UTF-16BE", checkActive)
        "UTF-8" -> {
            validateUmdUtf8(bytes, from, end, checkActive)
            bytes.decodeToString(startIndex = from, endIndex = end, throwOnInvalidSequence = true)
        }
        else -> decodeUmdGbText(bytes, from, end, encoding.name, checkActive)
    }
    checkActive()
    return text
}

private fun decodeUmdUtf16(
    bytes: ByteArray,
    start: Int,
    end: Int,
    bigEndian: Boolean,
    checkActive: () -> Unit,
): String {
    require((end - start) and 1 == 0) { "UMD UTF-16 文本或章节偏移不是偶数字节" }
    fun unit(offset: Int): Int {
        val first = bytes[offset].toInt() and 255
        val second = bytes[offset + 1].toInt() and 255
        return if (bigEndian) (first shl 8) or second else first or (second shl 8)
    }
    return buildString((end - start) / 2) {
        var offset = start
        var nextCheck = start
        while (offset < end) {
            if (offset >= nextCheck) {
                checkActive()
                nextCheck = offset + 8192
            }
            val char = unit(offset)
            when (char) {
                in 0xd800..0xdbff -> {
                    require(offset + 4 <= end && unit(offset + 2) in 0xdc00..0xdfff) {
                        "UMD UTF-16 代理对损坏或被章节偏移截断，偏移 $offset"
                    }
                    append(char.toChar())
                    append(unit(offset + 2).toChar())
                    offset += 4
                }
                in 0xdc00..0xdfff -> throw IllegalArgumentException("UMD UTF-16 包含孤立低代理项，偏移 $offset")
                else -> {
                    append(char.toChar())
                    offset += 2
                }
            }
        }
    }
}

private fun validateUmdUtf8(bytes: ByteArray, start: Int, end: Int, checkActive: () -> Unit) {
    var offset = start
    var nextCheck = start
    while (offset < end) {
        if (offset >= nextCheck) {
            checkActive()
            nextCheck = offset + 4096
        }
        val first = bytes[offset].toInt() and 255
        val count = when (first) {
            in 0..127 -> 1
            in 0xc2..0xdf -> 2
            in 0xe0..0xef -> 3
            in 0xf0..0xf4 -> 4
            else -> throw IllegalArgumentException("UMD UTF-8 字节无效，偏移 $offset")
        }
        require(end - offset >= count) { "UMD UTF-8 字符被截断，偏移 $offset" }
        for (index in 1 until count) {
            val range = when {
                index != 1 -> 0x80..0xbf
                first == 0xe0 -> 0xa0..0xbf
                first == 0xed -> 0x80..0x9f
                first == 0xf0 -> 0x90..0xbf
                first == 0xf4 -> 0x80..0x8f
                else -> 0x80..0xbf
            }
            require((bytes[offset + index].toInt() and 255) in range) { "UMD UTF-8 续字节无效，偏移 $offset" }
        }
        offset += count
    }
}

private fun decodeUmdGbText(
    bytes: ByteArray,
    start: Int,
    end: Int,
    charset: String,
    checkActive: () -> Unit,
): String {
    var offset = start
    var nextCheck = start
    fun byte(index: Int) = bytes[index].toInt() and 255
    while (offset < end) {
        if (offset >= nextCheck) {
            checkActive()
            nextCheck = offset + 4096
        }
        if (byte(offset) < 128) {
            offset++
            continue
        }
        require(offset + 1 < end) { "UMD $charset 字符被截断，偏移 $offset" }
        val first = byte(offset)
        val second = byte(offset + 1)
        val count = when {
            charset == "GB2312" -> {
                require(first in 0xa1..0xf7 && second in 0xa1..0xfe) { "UMD GB2312 字节无效，偏移 $offset" }
                2
            }
            charset == "GB18030" && second in 0x30..0x39 -> {
                require(end - offset >= 4 && first in 0x81..0xfe && byte(offset + 2) in 0x81..0xfe &&
                    byte(offset + 3) in 0x30..0x39) { "UMD GB18030 四字节字符无效，偏移 $offset" }
                4
            }
            else -> {
                require(first in 0x81..0xfe && second in 0x40..0xfe && second != 0x7f) {
                    "UMD $charset 字节无效，偏移 $offset"
                }
                2
            }
        }
        offset += count
    }
    checkActive()
    if (start == end) return ""
    val encoded = bytes.copyOfRange(start, end)
    val text = TextCodec.decode(encoded, charset)
    val roundTrip = TextCodec.encode(text, charset)
    require(roundTrip.size == encoded.size) { "UMD $charset 编码转换失败" }
    for (index in encoded.indices) {
        if (index and 65535 == 0) checkActive()
        require(roundTrip[index] == encoded[index]) { "UMD $charset 编码损坏或平台不支持该字符" }
    }
    return text
}
