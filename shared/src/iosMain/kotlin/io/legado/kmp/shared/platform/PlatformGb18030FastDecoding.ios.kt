@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.autoreleasepool
import kotlinx.cinterop.usePinned
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.CFStringIsEncodingAvailable
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.Foundation.NSData
import platform.Foundation.NSString
import platform.Foundation.create

/** The same Foundation table as the unit decoder, restricted to its unambiguous stateless runs. */
internal fun decodePlatformGb18030Fast(bytes: ByteArray): String? {
    if (bytes.isEmpty()) return ""
    var index = 0
    while (index < bytes.size) {
        val first = bytes[index].toInt() and 0xff
        if (first < 0x80) {
            index++
        } else {
            if (first !in 0x81..0xfe || index + 1 >= bytes.size) return null
            val second = bytes[index + 1].toInt() and 0xff
            // Euro's single-byte alias, four-byte units and malformed recovery keep the unit path.
            if (second !in 0x40..0xfe || second == 0x7f) return null
            index += 2
        }
    }
    return autoreleasepool {
        val encoding = kCFStringEncodingGB_18030_2000.toUInt()
        require(CFStringIsEncodingAvailable(encoding)) { "Unsupported charset: GB18030" }
        val data = bytes.usePinned { pinned ->
            NSData.create(bytes = pinned.addressOf(0), length = bytes.size.toULong())
        }
        NSString.create(data, CFStringConvertEncodingToNSStringEncoding(encoding))?.toString()
    }
}
