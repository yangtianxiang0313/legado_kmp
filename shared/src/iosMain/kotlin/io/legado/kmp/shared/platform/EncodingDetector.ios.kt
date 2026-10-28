@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.kCFStringEncodingBig5
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.Foundation.*

/**
 * iOS implementation of EncodingDetector using NSStringEncoding
 */
actual class EncodingDetector {

    actual fun detect(bytes: ByteArray): String {
        return detectWithConfidence(bytes).first
    }

    actual fun detectWithConfidence(bytes: ByteArray, hint: String?): Pair<String, Float> {
        val nsData = bytes.toNSData()

        detectUtf16AsciiPrefix(bytes, nsData)?.let { return it to 0.90f }

        // Try UTF-8 first
        if (isValidUtf8(bytes) && 0.toByte() !in bytes) {
            return "UTF-8" to 0.95f
        }

        // Use NSString encoding detection
        val encoding = NSString.stringEncodingForData(
            data = nsData,
            encodingOptions = null,
            convertedString = null,
            usedLossyConversion = null
        )

        val gbkEncoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000.toUInt())
        val big5Encoding = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5.toUInt())

        val encodingName = when (encoding.toUInt()) {
            NSUTF8StringEncoding.toUInt() -> "UTF-8"
            NSUTF16StringEncoding.toUInt() -> "UTF-16"
            NSUTF16BigEndianStringEncoding.toUInt() -> "UTF-16BE"
            NSUTF16LittleEndianStringEncoding.toUInt() -> "UTF-16LE"
            NSASCIIStringEncoding.toUInt() -> "ASCII"
            NSISOLatin1StringEncoding.toUInt() -> "ISO-8859-1"
            NSUTF32StringEncoding.toUInt() -> "UTF-32"
            NSUTF32BigEndianStringEncoding.toUInt() -> "UTF-32BE"
            NSUTF32LittleEndianStringEncoding.toUInt() -> "UTF-32LE"
            gbkEncoding.toUInt() -> "GBK"
            big5Encoding.toUInt() -> "BIG5"
            else -> {
                // If NSString detection failed, try GBK as fallback for non-UTF8 CJK content
                if (NSString.create(nsData, gbkEncoding) != null) {
                    return "GBK" to 0.70f
                }
                "UTF-8"
            }
        }

        return encodingName to 0.85f
    }

    actual fun isValidUtf8(bytes: ByteArray): Boolean {
        return NSString.create(bytes.toNSData(), NSUTF8StringEncoding) != null
    }
}

private fun detectUtf16AsciiPrefix(bytes: ByteArray, data: NSData): String? {
    if (bytes.size < 8 || bytes.size % 2 != 0) return null
    var littleEndianRun = 0
    var bigEndianRun = 0
    val limit = minOf(bytes.size, 256)
    var offset = 0
    while (offset + 1 < limit) {
        val first = bytes[offset].toInt() and 0xff
        val second = bytes[offset + 1].toInt() and 0xff
        littleEndianRun = if (second == 0 && first.isTextAscii()) littleEndianRun + 1 else 0
        bigEndianRun = if (first == 0 && second.isTextAscii()) bigEndianRun + 1 else 0
        // Require a code-unit-aligned ASCII run, then let Foundation validate the entire bounded sample.
        if (littleEndianRun >= 4 && NSString.create(data, NSUTF16LittleEndianStringEncoding) != null) return "UTF-16LE"
        if (bigEndianRun >= 4 && NSString.create(data, NSUTF16BigEndianStringEncoding) != null) return "UTF-16BE"
        offset += 2
    }
    return null
}

private fun Int.isTextAscii(): Boolean = this in 0x20..0x7e || this == 9 || this == 10 || this == 13

private fun ByteArray.toNSData(): NSData {
    if (isEmpty()) return NSData()
    return usePinned { pinned ->
        NSData.create(bytes = pinned.addressOf(0), length = size.toULong())
    }
}
