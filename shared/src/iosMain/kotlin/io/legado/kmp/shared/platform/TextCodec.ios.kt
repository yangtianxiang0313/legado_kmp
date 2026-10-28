@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.kCFStringEncodingBig5
import platform.CoreFoundation.kCFStringEncodingEUC_JP
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.CoreFoundation.kCFStringEncodingShiftJIS
import platform.Foundation.NSASCIIStringEncoding
import platform.Foundation.NSData
import platform.Foundation.NSISOLatin1StringEncoding
import platform.Foundation.NSString
import platform.Foundation.NSStringEncoding
import platform.Foundation.NSUTF16BigEndianStringEncoding
import platform.Foundation.NSUTF16LittleEndianStringEncoding
import platform.Foundation.NSUTF16StringEncoding
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.create
import platform.Foundation.dataUsingEncoding
import platform.Foundation.getBytes

actual object TextCodec {
    private val utf8Bom = byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())

    actual fun decode(bytes: ByteArray, charsetName: String): String {
        val data = bytes.toNSData()
        return NSString.create(data, encodingFor(charsetName))
            ?.toString()
            ?: NSString.create(data, NSUTF8StringEncoding)
                ?.toString()
            ?: NSString.create(data, NSISOLatin1StringEncoding)
                ?.toString()
            ?: bytes.decodeToString()
    }

    @Suppress("CAST_NEVER_SUCCEEDS")
    actual fun encode(text: String, charsetName: String): ByteArray {
        val encoding = encodingFor(charsetName)
        if (encoding == NSUTF8StringEncoding) {
            return text.encodeToByteArray()
        }
        val nsStr = text as NSString
        val data = nsStr.dataUsingEncoding(encoding, false)
        return data?.toByteArray() ?: text.encodeToByteArray()
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

    private fun encodingFor(charsetName: String): NSStringEncoding {
        return when (charsetName.uppercase()) {
            "UTF-8", "UTF8" -> NSUTF8StringEncoding
            "UTF-16", "UTF16" -> NSUTF16StringEncoding
            "UTF-16LE", "UTF16LE" -> NSUTF16LittleEndianStringEncoding
            "UTF-16BE", "UTF16BE" -> NSUTF16BigEndianStringEncoding
            "ASCII" -> NSASCIIStringEncoding
            "ISO-8859-1", "ISO8859-1", "LATIN1" -> NSISOLatin1StringEncoding
            "GBK", "GB2312", "GB18030", "GB_18030" ->
                CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000.toUInt())
            "BIG5", "BIG-5" ->
                CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5.toUInt())
            "SHIFT_JIS", "SHIFT-JIS", "SJIS" ->
                CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingShiftJIS.toUInt())
            "EUC-JP", "EUCJP" ->
                CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_JP.toUInt())
            else -> NSUTF8StringEncoding
        }
    }
}

private fun ByteArray.toNSData(): NSData {
    if (isEmpty()) return NSData()
    return usePinned { pinned ->
        NSData.create(bytes = pinned.addressOf(0), length = size.toULong())
    }
}

private fun NSData.toByteArray(): ByteArray {
    val bytes = ByteArray(length.toInt())
    if (bytes.isNotEmpty()) {
        bytes.usePinned { pinned ->
            getBytes(pinned.addressOf(0), length)
        }
    }
    return bytes
}
