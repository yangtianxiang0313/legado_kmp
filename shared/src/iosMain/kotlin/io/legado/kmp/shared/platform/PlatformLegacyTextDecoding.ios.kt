@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.COpaquePointer
import kotlinx.cinterop.CPointerVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.autoreleasepool
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.CFStringIsEncodingAvailable
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.Foundation.NSData
import platform.Foundation.NSString
import platform.Foundation.NSStringEncoding
import platform.Foundation.create
import platform.iconv.iconv
import platform.iconv.iconv_close
import platform.iconv.iconv_open
import platform.posix.EILSEQ
import platform.posix.EINVAL
import platform.posix.errno
import platform.posix.size_tVar

internal fun decodePlatformLegacyText(bytes: ByteArray, charset: PlatformLegacyCharset): String {
    require(charset == PlatformLegacyCharset.GBK || charset == PlatformLegacyCharset.GB18030 ||
        charset == PlatformLegacyCharset.BIG5 || charset == PlatformLegacyCharset.SHIFT_JIS ||
        charset == PlatformLegacyCharset.EUC_JP) { "Not a multibyte text charset: $charset" }
    val decoder = LegacyTextUnitDecoder(charset)
    try {
        return buildString(bytes.size) {
            var index = 0
            while (index < bytes.size) {
                val single = legacySingleByteUnit(bytes.legacyByte(index), charset)
                if (single != null) {
                    append(single.toChar())
                    index++
                    continue
                }
                // Positive sizes are complete units; negative sizes are malformed prefixes to replace.
                // Conversion errors cannot consume a following character or choose resynchronization.
                val length = legacyTextUnitLength(bytes, index, charset)
                if (length < 0) {
                    append('\ufffd')
                    index -= length
                } else {
                    append(decoder.decode(bytes, index, length))
                    index += length
                }
            }
        }
    } finally {
        decoder.close()
    }
}

private fun legacySingleByteUnit(value: Int, charset: PlatformLegacyCharset): Int? {
    if (value < 0x80) {
        // ICU ibm-943_P15A rotates these controls; all other supported tables preserve ASCII.
        return if (charset != PlatformLegacyCharset.SHIFT_JIS) value else when (value) {
            0x1a -> 0x1c
            0x1c -> 0x7f
            0x7f -> 0x1a
            else -> value
        }
    }
    return when (charset) {
        PlatformLegacyCharset.GBK -> when (value) {
            0x80 -> 0x20ac
            0xff -> 0xf8f5
            else -> null
        }
        PlatformLegacyCharset.GB18030 -> when (value) {
            0x80 -> 0x20ac
            0xff -> 0xfffd
            else -> null
        }
        PlatformLegacyCharset.BIG5 -> when (value) {
            0x80 -> 0x0080
            0xff -> 0xf8f8
            else -> null
        }
        PlatformLegacyCharset.SHIFT_JIS -> when (value) {
            in 0xa1..0xdf -> 0xff61 + value - 0xa1
            0x80, 0xa0, in 0xfd..0xff -> 0xfffd
            else -> null
        }
        PlatformLegacyCharset.EUC_JP -> when (value) {
            in 0x80..0x8d, in 0x90..0x9f -> value
            0xa0, 0xff -> 0xfffd
            else -> null
        }
        else -> null
    }
}

private fun legacyTextUnitLength(bytes: ByteArray, index: Int, charset: PlatformLegacyCharset): Int {
    val remaining = bytes.size - index
    fun byte(offset: Int): Int = if (offset < remaining) bytes.legacyByte(index + offset) else -1
    val lead = byte(0)
    val second = byte(1)
    return when (charset) {
        PlatformLegacyCharset.GBK -> if (lead in 0x81..0xfe && second.isGbkTrail()) 2 else -1
        PlatformLegacyCharset.GB18030 -> when {
            lead !in 0x81..0xfe -> -1
            second.isGbkTrail() -> 2
            second == 0xff -> -2
            second !in 0x30..0x39 -> -1
            remaining == 2 -> -2
            byte(2) !in 0x81..0xfe -> -1
            remaining == 3 -> -3
            byte(3) in 0x30..0x39 -> 4
            // Replay the digit and following bytes if this is not a complete four-byte prefix.
            else -> -1
        }
        PlatformLegacyCharset.BIG5 -> when {
            lead !in 0x81..0xfe -> -1
            second in 0x40..0x7e || second in 0xa1..0xfe -> 2
            second in 0x80..0xa0 -> -2
            else -> -1
        }
        PlatformLegacyCharset.SHIFT_JIS -> if ((lead in 0x81..0x9f || lead in 0xe0..0xfc) &&
            second in 0x40..0xfc && second != 0x7f) 2 else -1
        PlatformLegacyCharset.EUC_JP -> when {
            lead == 0x8f -> when {
                second !in 0xa1..0xfe -> -1
                remaining == 2 -> -2
                byte(2) in 0xa1..0xfe -> 3
                byte(2) == 0xa0 || byte(2) == 0xff -> -3
                else -> -1
            }
            lead == 0x8e && second in 0xa1..0xdf -> 2
            lead == 0x8e && second in 0xa0..0xff -> -2
            lead in 0xa1..0xfe && second in 0xa1..0xfe -> 2
            lead in 0xa1..0xfe && (second == 0xa0 || second == 0xff) -> -2
            else -> -1
        }
        else -> -1
    }
}

private fun Int.isGbkTrail(): Boolean = this in 0x40..0xfe && this != 0x7f

private fun ByteArray.legacyByte(index: Int): Int = this[index].toInt() and 0xff

private class LegacyTextUnitDecoder(private val charset: PlatformLegacyCharset) {
    private val converters = mutableMapOf<String, COpaquePointer>()
    private val cache = mutableMapOf<Long, String>()
    private val scratch = ByteArray(16)
    private val gb18030Encoding: NSStringEncoding? = if (
        charset == PlatformLegacyCharset.GBK || charset == PlatformLegacyCharset.GB18030
    ) {
        val encoding = kCFStringEncodingGB_18030_2000.toUInt()
        require(CFStringIsEncodingAvailable(encoding)) { "Unsupported charset: GB18030" }
        CFStringConvertEncodingToNSStringEncoding(encoding)
    } else {
        null
    }

    fun decode(bytes: ByteArray, index: Int, length: Int): String {
        var key = length.toLong()
        for (offset in 0 until length) key = (key shl 8) or bytes.legacyByte(index + offset).toLong()
        cache[key]?.let { return it }
        val value = when (charset) {
            PlatformLegacyCharset.GBK -> iconvUnit(bytes, index, length, "CP936")
                // Only a structurally valid GBK double-byte unit can use the shared GB18030 PUA table.
                ?: foundationUnit(bytes, index, length)
            PlatformLegacyCharset.GB18030 -> foundationUnit(bytes, index, length)
            PlatformLegacyCharset.BIG5 -> big5PrivateUseUnit(bytes.legacyByte(index), bytes.legacyByte(index + 1))
                ?.toChar()?.toString()
                ?: if (bytes.legacyByte(index) == 0xa3 && bytes.legacyByte(index + 1) == 0xe1) "\u20ac"
                else iconvUnit(bytes, index, length, "CP950")
            PlatformLegacyCharset.SHIFT_JIS -> iconvUnit(bytes, index, length, "CP932")
            PlatformLegacyCharset.EUC_JP -> iconvUnit(bytes, index, length, "EUC-JP")
                // CP51932 supplies the NEC/IBM extension rows, not EUC-JP-MS's unrelated PUA rows.
                ?: if (length == 2) iconvUnit(bytes, index, length, "CP51932") else null
            else -> null
        } ?: "\ufffd"
        val normalized = if (charset == PlatformLegacyCharset.SHIFT_JIS || charset == PlatformLegacyCharset.EUC_JP) {
            value.replace('\u2014', '\u2015')
        } else {
            value
        }
        // Keep repeated book characters cheap without growing a cache with the document's length.
        if (cache.size < 2048) cache[key] = normalized
        return normalized
    }

    private fun foundationUnit(bytes: ByteArray, index: Int, length: Int): String? = autoreleasepool {
        val encoding = requireNotNull(gb18030Encoding)
        val data = bytes.usePinned { pinned ->
            NSData.create(bytes = pinned.addressOf(index), length = length.toULong())
        }
        NSString.create(data, encoding)?.toString()?.takeIf { it.isNotEmpty() }
    }

    private fun iconvUnit(bytes: ByteArray, index: Int, length: Int, source: String): String? {
        // All names are internal constants. No user-supplied charset/options reach iconv.
        val converter = converters.getOrPut(source) {
            val opened = requireNotNull(iconv_open("UTF-8", source)) { "Unsupported charset: $source" }
            require(opened.rawValue.toLong() != -1L) { "Unsupported charset: $source" }
            opened
        }
        // Supported source encodings are stateless. Reset even after a failed/incomplete unit.
        iconv(converter, null, null, null, null)
        return bytes.usePinned { inputPin ->
            scratch.usePinned { outputPin ->
                memScoped {
                    val input = alloc<CPointerVar<ByteVar>>()
                    val inputLeft = alloc<size_tVar>()
                    val target = alloc<CPointerVar<ByteVar>>()
                    val targetLeft = alloc<size_tVar>()
                    input.value = inputPin.addressOf(index)
                    inputLeft.value = length.convert()
                    target.value = outputPin.addressOf(0)
                    targetLeft.value = scratch.size.convert()
                    val result = iconv(converter, input.ptr, inputLeft.ptr, target.ptr, targetLeft.ptr)
                    if (result.toLong() == -1L) {
                        val failure = errno
                        require(failure == EILSEQ || failure == EINVAL) {
                            "Charset unit decoding failed: $source ($failure)"
                        }
                        return@memScoped null
                    }
                    val written = scratch.size - targetLeft.value.toInt()
                    if (inputLeft.value != 0uL || written == 0) return@memScoped null
                    // This is converter-generated UTF-8, never a second interpretation of source bytes.
                    scratch.decodeToString(endIndex = written, throwOnInvalidSequence = true)
                }
            }
        }
    }

    fun close() {
        converters.values.forEach { iconv_close(it) }
        converters.clear()
        cache.clear()
    }
}

private fun big5PrivateUseUnit(lead: Int, trail: Int): Int? {
    val column = when (trail) {
        in 0x40..0x7e -> trail - 0x40
        in 0xa1..0xfe -> trail - 0xa1 + 63
        else -> return null
    }
    // Complete CP950 PUA runs from ICU windows-950-2000.ucm, 157 cells per Big5 row:
    // FA40-FEFE, 8E40-A0FE, 8140-8DFE, C6A1-C8FE. No HKSCS/Big5-2003 substitutions.
    return when {
        lead in 0xfa..0xfe -> 0xe000 + (lead - 0xfa) * 157 + column
        lead in 0x8e..0xa0 -> 0xe311 + (lead - 0x8e) * 157 + column
        lead in 0x81..0x8d -> 0xeeb8 + (lead - 0x81) * 157 + column
        (lead == 0xc6 && trail >= 0xa1) || lead in 0xc7..0xc8 ->
            0xf6b1 + (lead - 0xc6) * 157 + column - 63
        else -> null
    }
}
