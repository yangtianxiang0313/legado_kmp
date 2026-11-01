package io.legado.kmp.shared.platform

import okio.Buffer

actual object TextCodec {
    private val utf8Bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())

    actual fun decode(bytes: ByteArray, charsetName: String): String {
        return decodePlatformText(bytes, charsetName)
    }

    actual fun encode(text: String, charsetName: String): ByteArray {
        val encoding = textEncodingForWrite(charsetName)
        if (encoding.unicodeBytes != 0) return encodeUnicodeText(text, encoding)
        if (encoding == TextWriteEncoding.UTF8) return encodeAndroidUtf8(text)
        return encodePlatformLegacyText(text, requireNotNull(encoding.legacyCharset))
    }

    actual fun detectCharset(sample: ByteArray): String {
        return EncodingDetector().detect(sample)
    }

    actual fun hasUtf8Bom(bytes: ByteArray): Boolean {
        return bytes.size >= 3 &&
            bytes[0] == utf8Bom[0] &&
            bytes[1] == utf8Bom[1] &&
            bytes[2] == utf8Bom[2]
    }
}

internal actual fun encodeCharsetWriterText(text: String, charsetName: String): ByteArray {
    val encoding = textEncodingForWrite(charsetName)
    return when {
        encoding.unicodeBytes != 0 -> encodeUnicodeText(text, encoding, stringFastPaths = false)
        encoding == TextWriteEncoding.UTF8 -> encodeAndroidUtf8(text)
        else -> encodePlatformLegacyText(text, requireNotNull(encoding.legacyCharset), stringFastPaths = false)
    }
}

internal enum class TextWriteEncoding(
    val unicodeBytes: Int = 0,
    val littleEndian: Boolean = false,
    val bom: Boolean = false,
    val legacyCharset: PlatformLegacyCharset? = null,
) {
    UTF8,
    UTF16(unicodeBytes = 2, bom = true),
    UTF16BE(unicodeBytes = 2),
    UTF16LE(unicodeBytes = 2, littleEndian = true),
    UTF16LE_BOM(unicodeBytes = 2, littleEndian = true, bom = true),
    UTF32(unicodeBytes = 4, littleEndian = true, bom = true),
    UTF32BE(unicodeBytes = 4),
    UTF32LE(unicodeBytes = 4, littleEndian = true),
    ASCII(legacyCharset = PlatformLegacyCharset.ASCII),
    LATIN1(legacyCharset = PlatformLegacyCharset.LATIN1),
    GBK(legacyCharset = PlatformLegacyCharset.GBK),
    GB18030(legacyCharset = PlatformLegacyCharset.GB18030),
    BIG5(legacyCharset = PlatformLegacyCharset.BIG5),
    SHIFT_JIS(legacyCharset = PlatformLegacyCharset.SHIFT_JIS),
    EUC_JP(legacyCharset = PlatformLegacyCharset.EUC_JP),
    WINDOWS_1252(legacyCharset = PlatformLegacyCharset.WINDOWS_1252),
}

internal fun textEncodingForWrite(name: String): TextWriteEncoding {
    require(isPlatformCharsetName(name)) { "Illegal charset name: $name" }
    // Resolve only known aliases; never pass user-supplied iconv names/options through.
    return when (name.uppercase()) {
        "UTF-8", "UTF8", "UNICODE-1-1-UTF-8" -> TextWriteEncoding.UTF8
        "UTF-16", "UTF16", "UTF_16", "UNICODE", "UNICODEBIG" -> TextWriteEncoding.UTF16
        "UTF-16BE", "UTF16BE", "UTF_16BE", "X-UTF-16BE", "UNICODEBIGUNMARKED", "ISO-10646-UCS-2" ->
            TextWriteEncoding.UTF16BE
        "UTF-16LE", "UTF16LE", "UTF_16LE", "X-UTF-16LE", "UNICODELITTLEUNMARKED" -> TextWriteEncoding.UTF16LE
        "X-UTF-16LE-BOM", "UNICODELITTLE" -> TextWriteEncoding.UTF16LE_BOM
        "UTF-32", "UTF32", "UTF_32" -> TextWriteEncoding.UTF32
        "UTF-32BE", "UTF32BE", "UTF_32BE", "X-UTF-32BE" -> TextWriteEncoding.UTF32BE
        "UTF-32LE", "UTF32LE", "UTF_32LE", "X-UTF-32LE" -> TextWriteEncoding.UTF32LE
        "ASCII", "US-ASCII", "ISO-IR-6", "ANSI_X3.4-1986", "ISO_646.IRV:1991", "ISO646-US", "US",
        "IBM367", "CP367", "CSASCII", "DEFAULT", "646", "ISO_646.IRV:1983", "ANSI_X3.4-1968", "ASCII7" ->
            TextWriteEncoding.ASCII
        "ISO-8859-1", "ISO8859-1", "ISO_8859-1", "ISO8859_1", "ISO_8859_1", "8859_1", "ISO_8859-1:1987",
        "LATIN1", "L1", "ISO-IR-100", "IBM819", "IBM-819", "CP819", "CSISOLATIN1", "819" -> TextWriteEncoding.LATIN1
        "GBK", "CP936", "WINDOWS-936" -> TextWriteEncoding.GBK
        // Android's GB2312 name resolves to its GBK converter, not the desktop JDK EUC-CN table.
        "GB2312", "EUC-CN", "EUC_CN", "EUCCN", "X-EUC-CN", "GB2312-80", "GB2312-1980" ->
            TextWriteEncoding.GBK
        "GB18030", "GB_18030" -> TextWriteEncoding.GB18030
        "BIG5", "BIG-5", "CSBIG5" -> TextWriteEncoding.BIG5
        "SHIFT_JIS", "SHIFT-JIS", "SJIS", "MS_KANJI", "CSSHIFTJIS", "X-SJIS" -> TextWriteEncoding.SHIFT_JIS
        "EUC-JP", "EUCJP", "EUC_JP", "EUCJIS", "X-EUC-JP", "X-EUCJP", "CSEUCPKDFMTJAPANESE",
        "EXTENDED_UNIX_CODE_PACKED_FORMAT_FOR_JAPANESE" ->
            TextWriteEncoding.EUC_JP
        "WINDOWS-1252", "CP1252", "CP5348", "IBM-1252", "IBM1252" -> TextWriteEncoding.WINDOWS_1252
        else -> throw IllegalArgumentException("Unsupported charset: $name")
    }
}

internal inline fun forEachPlatformTextScalar(text: String, malformedReplacement: Int, write: (Int) -> Unit) {
    var index = 0
    while (index < text.length) {
        val char = text[index++]
        val codePoint = when {
            char.isHighSurrogate() && index < text.length && text[index].isLowSurrogate() ->
                0x10000 + ((char.code - 0xd800) shl 10) + (text[index++].code - 0xdc00)
            char.isSurrogate() -> malformedReplacement
            else -> char.code
        }
        write(codePoint)
    }
}

private fun encodeAndroidUtf8(text: String): ByteArray {
    val output = Buffer()
    try {
        // Android UTF-8 replaces each unpaired surrogate with '?', not Kotlin's U+FFFD.
        forEachPlatformTextScalar(text, 63) { output.writeUtf8CodePoint(it) }
        return output.readByteArray()
    } finally {
        output.clear()
    }
}

private fun encodeUnicodeText(text: String, encoding: TextWriteEncoding, stringFastPaths: Boolean = true): ByteArray {
    val output = Buffer()
    try {
        fun writeUnit(value: Int) {
            when {
                encoding.unicodeBytes == 4 && encoding.littleEndian -> output.writeIntLe(value)
                encoding.unicodeBytes == 4 -> output.writeInt(value)
                encoding.littleEndian -> output.writeShortLe(value)
                else -> output.writeShort(value)
            }
        }
        // The Android 36 arm64 reference uses BE+BOM for UTF-16 and LE+BOM for UTF-32.
        if (encoding.bom && text.isNotEmpty()) writeUnit(0xfeff)
        if (stringFastPaths && encoding == TextWriteEncoding.UTF16BE) {
            // Android's String.getBytes fast path preserves even unpaired UTF-16BE units.
            for (unit in text) writeUnit(unit.code)
        } else {
            forEachPlatformTextScalar(text, 0xfffd) { codePoint ->
                if (encoding.unicodeBytes == 2 && codePoint > 0xffff) {
                    writeUnit(0xd800 + ((codePoint - 0x10000) ushr 10))
                    writeUnit(0xdc00 + ((codePoint - 0x10000) and 0x3ff))
                } else {
                    writeUnit(codePoint)
                }
            }
        }
        return output.readByteArray()
    } finally {
        output.clear()
    }
}
