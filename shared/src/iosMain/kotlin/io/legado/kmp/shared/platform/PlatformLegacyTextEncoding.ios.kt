@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.autoreleasepool
import kotlinx.cinterop.usePinned
import okio.Buffer
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.CFStringIsEncodingAvailable
import platform.CoreFoundation.kCFStringEncodingDOSChineseSimplif
import platform.CoreFoundation.kCFStringEncodingDOSChineseTrad
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.CoreFoundation.kCFStringEncodingShiftJIS
import platform.Foundation.NSString
import platform.Foundation.NSStringEncoding
import platform.Foundation.create
import platform.Foundation.dataUsingEncoding
import platform.Foundation.getBytes

internal enum class PlatformLegacyCharset(
    val cfEncoding: UInt? = null,
    val iconvName: String? = null,
    val replacement: ByteArray = byteArrayOf(0x3f),
) {
    ASCII,
    LATIN1,
    WINDOWS_1252(replacement = byteArrayOf(0x1a)),
    GBK(kCFStringEncodingDOSChineseSimplif.toUInt()),
    GB18030(kCFStringEncodingGB_18030_2000.toUInt(), replacement = byteArrayOf(0x1a)),
    BIG5(kCFStringEncodingDOSChineseTrad.toUInt()),
    SHIFT_JIS(kCFStringEncodingShiftJIS.toUInt(), replacement = byteArrayOf(0xfc.toByte(), 0xfc.toByte())),
    // iconv supplies JIS X 0212 mappings missing from Foundation; reverse conversion rejects approximations.
    EUC_JP(iconvName = "EUC-JP", replacement = byteArrayOf(0xf4.toByte(), 0xfe.toByte())),
}

internal fun encodePlatformLegacyText(
    text: String, charset: PlatformLegacyCharset, stringFastPaths: Boolean = true,
): ByteArray {
    // Android's Shift_JIS converter returns only the first replacement byte for a lone high surrogate input.
    if (stringFastPaths && charset == PlatformLegacyCharset.SHIFT_JIS && text.length == 1 && text[0].isHighSurrogate()) {
        return byteArrayOf(0xfc.toByte())
    }
    if (stringFastPaths && (charset == PlatformLegacyCharset.ASCII || charset == PlatformLegacyCharset.LATIN1)) {
        val limit = if (charset == PlatformLegacyCharset.ASCII) 0x7f else 0xff
        // Android's String.getBytes fast paths replace each UTF-16 unit, including both halves of a valid pair.
        return ByteArray(text.length) { index ->
            val unit = text[index].code
            (if (unit <= limit) unit else 0x3f).toByte()
        }
    }
    val iconvName = charset.iconvName?.also {
        require(platformSupportsTextCharset(it)) { "Unsupported charset: $it" }
    }
    val encoding = charset.cfEncoding?.let {
        require(CFStringIsEncodingAvailable(it)) { "Unsupported charset: $charset" }
        CFStringConvertEncodingToNSStringEncoding(it)
    }
    val output = Buffer()
    try {
        // A sentinel distinguishes malformed UTF-16 from a literal '?' or U+FFFD before selecting replacement bytes.
        forEachPlatformTextScalar(text, -1) { codePoint ->
            when {
                codePoint < 0 -> output.write(charset.replacement)
                // Every supported legacy charset is ASCII-compatible.
                codePoint <= 0x7f -> output.writeByte(codePoint)
                charset == PlatformLegacyCharset.ASCII -> output.writeByte(0x3f)
                charset == PlatformLegacyCharset.LATIN1 -> output.writeByte(if (codePoint <= 0xff) codePoint else 0x3f)
                charset == PlatformLegacyCharset.WINDOWS_1252 -> output.writeByte(windows1252Byte(codePoint))
                // Android's GBK/GB2312 aliases use CP936's single-byte Euro, unlike desktop JDK GBK.
                charset == PlatformLegacyCharset.GBK && codePoint == 0x20ac -> output.writeByte(0x80)
                // Android Big5 follows CP950, including its Euro extension absent from Apple's table.
                charset == PlatformLegacyCharset.BIG5 && codePoint == 0x20ac -> output.writeByte(0xa3).writeByte(0xe1)
                codePoint == 0x2014 && charset.isJis -> output.write(charset.replacement)
                codePoint == 0x2015 && charset.isJis -> {
                    if (charset == PlatformLegacyCharset.SHIFT_JIS) output.writeByte(0x81).writeByte(0x5c)
                    else output.writeByte(0xa1).writeByte(0xbd)
                }
                else -> {
                    val bytes = if (iconvName != null) iconvScalarBytes(codePoint, charset, iconvName)
                        else foundationScalarBytes(codePoint, charset, requireNotNull(encoding))
                    output.write(bytes ?: charset.replacement)
                }
            }
        }
        return output.readByteArray()
    } finally {
        output.clear()
    }
}

private val PlatformLegacyCharset.isJis: Boolean
    get() = this == PlatformLegacyCharset.SHIFT_JIS || this == PlatformLegacyCharset.EUC_JP

private fun windows1252Byte(codePoint: Int): Int {
    if (codePoint in 0xa0..0xff) return codePoint
    val index = WINDOWS_1252_C1.indexOf(codePoint)
    return if (index >= 0) 0x80 + index else 0x1a
}

// The five undefined bytes must not become encodable C1 controls (or U+FFFD).
private val WINDOWS_1252_C1 = intArrayOf(
    0x20ac, -1, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
    0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, -1, 0x017d, -1,
    -1, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
    0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, -1, 0x017e, 0x0178,
)

private fun iconvScalarBytes(
    codePoint: Int,
    charset: PlatformLegacyCharset,
    target: String,
): ByteArray? {
    val utf8 = Buffer().writeUtf8CodePoint(codePoint).readByteArray()
    return try {
        val bytes = convertPlatformTextBytes(utf8, "UTF-8", target, null, true)
        if (!charset.acceptsScalarBytes(bytes)) return null
        val decoded = convertPlatformTextBytes(bytes, target, "UTF-8", null, false)
        // Android rejects JIS Roman aliases and punctuation folds; do not use desktop JDK c2b-only mappings.
        bytes.takeIf { decoded.contentEquals(utf8) }
    } catch (_: IllegalArgumentException) {
        null
    }
}

@Suppress("CAST_NEVER_SUCCEEDS")
private fun foundationScalarBytes(
    codePoint: Int,
    charset: PlatformLegacyCharset,
    encoding: NSStringEncoding,
): ByteArray? = autoreleasepool {
    val scalar = if (codePoint <= 0xffff) codePoint.toChar().toString() else buildString(2) {
        append((0xd800 + ((codePoint - 0x10000) ushr 10)).toChar())
        append((0xdc00 + ((codePoint - 0x10000) and 0x3ff)).toChar())
    }
    val data = (scalar as NSString).dataUsingEncoding(encoding, false) ?: return@autoreleasepool null
    if (data.length == 0uL || data.length > 4uL) return@autoreleasepool null
    // The Android reference rejects these tables' compatibility folds and non-roundtrip substitutions.
    if (NSString.create(data, encoding)?.toString() != scalar) return@autoreleasepool null
    val bytes = ByteArray(data.length.toInt())
    bytes.usePinned { pinned -> data.getBytes(pinned.addressOf(0), data.length) }
    bytes.takeIf { charset.acceptsScalarBytes(it) }
}

private fun PlatformLegacyCharset.acceptsScalarBytes(bytes: ByteArray): Boolean {
    fun byte(index: Int): Int = bytes[index].toInt() and 0xff
    return when (this) {
        PlatformLegacyCharset.GBK -> bytes.size == 2 &&
            byte(0) in 0x81..0xfe && byte(1) in 0x40..0xfe && byte(1) != 0x7f
        PlatformLegacyCharset.GB18030 -> when (bytes.size) {
            2 -> byte(0) in 0x81..0xfe && byte(1) in 0x40..0xfe && byte(1) != 0x7f
            4 -> byte(0) in 0x81..0xfe && byte(1) in 0x30..0x39 &&
                byte(2) in 0x81..0xfe && byte(3) in 0x30..0x39
            else -> false
        }
        PlatformLegacyCharset.BIG5 -> bytes.size == 2 && byte(0) in 0xa1..0xf9 &&
            (byte(1) in 0x40..0x7e || byte(1) in 0xa1..0xfe)
        PlatformLegacyCharset.SHIFT_JIS -> when (bytes.size) {
            1 -> byte(0) in 0xa1..0xdf
            2 -> (byte(0) in 0x81..0x9f || byte(0) in 0xe0..0xef) &&
                byte(1) in 0x40..0xfc && byte(1) != 0x7f
            else -> false
        }
        PlatformLegacyCharset.EUC_JP -> when (bytes.size) {
            2 -> (byte(0) == 0x8e && byte(1) in 0xa1..0xdf) ||
                (byte(0) in 0xa1..0xfe && byte(1) in 0xa1..0xfe)
            3 -> byte(0) == 0x8f && byte(1) in 0xa1..0xfe && byte(2) in 0xa1..0xfe
            else -> false
        }
        else -> false
    }
}
