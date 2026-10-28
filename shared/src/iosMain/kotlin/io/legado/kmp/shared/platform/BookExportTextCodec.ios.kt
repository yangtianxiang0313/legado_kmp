@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.platform

import io.legado.kmp.shared.facade.BookExportFailure
import io.legado.kmp.shared.facade.requireBookExport
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.autoreleasepool
import kotlinx.cinterop.usePinned
import okio.Buffer
import platform.CoreFoundation.CFStringConvertEncodingToNSStringEncoding
import platform.CoreFoundation.CFStringConvertNSStringEncodingToEncoding
import platform.CoreFoundation.CFStringIsEncodingAvailable
import platform.CoreFoundation.kCFStringEncodingBig5
import platform.CoreFoundation.kCFStringEncodingDOSChineseSimplif
import platform.CoreFoundation.kCFStringEncodingEUC_CN
import platform.CoreFoundation.kCFStringEncodingEUC_JP
import platform.CoreFoundation.kCFStringEncodingGB_18030_2000
import platform.CoreFoundation.kCFStringEncodingShiftJIS
import platform.Foundation.NSASCIIStringEncoding
import platform.Foundation.NSISOLatin1StringEncoding
import platform.Foundation.NSString
import platform.Foundation.NSStringEncoding
import platform.Foundation.NSUTF16BigEndianStringEncoding
import platform.Foundation.NSUTF16LittleEndianStringEncoding
import platform.Foundation.NSUTF8StringEncoding
import platform.Foundation.create
import platform.Foundation.dataUsingEncoding
import platform.Foundation.getBytes

private const val EXPORT_TEXT_BLOCK_UNITS = 16 * 1024

internal actual fun validateBookExportCharset(charset: String) {
    exportNSStringEncoding(bookExportCharset(charset))
}

internal actual fun encodeBookExportText(text: String, charset: String, checkActive: () -> Unit): ByteArray {
    checkActive()
    val selected = bookExportCharset(charset)
    val encoding = exportNSStringEncoding(selected)
    requireBookExportTextInput(text, checkActive)
    val output = Buffer()
    try {
        // All supported legacy encodings are stateless. Explicit-endian UTF-16 avoids per-block BOMs.
        if (selected == BookExportCharset.UTF16) output.writeByte(0xFE).writeByte(0xFF)
        var start = 0
        while (start < text.length) {
            checkActive()
            var end = minOf(start + EXPORT_TEXT_BLOCK_UNITS, text.length)
            if (end < text.length && text[end - 1].isHighSurrogate()) end--
            appendExportTextBlock(text.substring(start, end), encoding, selected, output, checkActive)
            start = end
        }
        checkActive()
        requireBookExport(output.size <= BOOK_EXPORT_TEXT_BYTES, "导出文本输出超过 128 MiB 限制")
        // Only the final bounded ByteArray allocation/copy is monolithic, checked before and after.
        return output.readByteArray().also { checkActive() }
    } finally {
        output.clear()
    }
}

@Suppress("CAST_NEVER_SUCCEEDS")
private fun appendExportTextBlock(
    text: String,
    encoding: NSStringEncoding,
    charset: BookExportCharset,
    output: Buffer,
    checkActive: () -> Unit,
) = autoreleasepool {
    checkActive()
    // A block has at most 16 Ki UTF-16 units; every supported encoding uses at most four bytes/unit.
    val data = (text as NSString).dataUsingEncoding(encoding, false)
    checkActive()
    if (data == null) throw BookExportFailure("导出正文包含所选字符集无法无损表示的字符")
    requireBookExport(data.length <= (EXPORT_TEXT_BLOCK_UNITS * 4).toULong(), "导出字符编码块超过大小限制")
    requireBookExport(data.length <= (BOOK_EXPORT_TEXT_BYTES - output.size).toULong(), "导出文本输出超过 128 MiB 限制")
    requireBookExport(data.length > 0uL, "导出字符编码未产生有效数据")
    if (charset != BookExportCharset.UTF8 && charset != BookExportCharset.UTF16 &&
        charset != BookExportCharset.UTF16LE && charset != BookExportCharset.UTF16BE) {
        // Some legacy tables have non-bijective mappings or discard default-ignorable characters.
        val decoded = NSString.create(data, encoding)?.toString()
        checkActive()
        requireBookExport(decoded == text, "导出正文包含所选字符集无法无损表示的字符")
    }
    val bytes = ByteArray(data.length.toInt())
    bytes.usePinned { pinned -> data.getBytes(pinned.addressOf(0), data.length) }
    checkActive()
    output.write(bytes)
    checkActive()
}

private fun exportNSStringEncoding(charset: BookExportCharset): NSStringEncoding {
    val encoding = when (charset) {
        BookExportCharset.UTF8 -> NSUTF8StringEncoding
        BookExportCharset.UTF16, BookExportCharset.UTF16BE -> NSUTF16BigEndianStringEncoding
        BookExportCharset.UTF16LE -> NSUTF16LittleEndianStringEncoding
        BookExportCharset.ASCII -> NSASCIIStringEncoding
        BookExportCharset.LATIN1 -> NSISOLatin1StringEncoding
        BookExportCharset.GB18030 -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000.toUInt())
        // Use the system's implemented CP936 and EUC-CN tables, not the broader GB18030 table.
        BookExportCharset.GBK -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSChineseSimplif.toUInt())
        BookExportCharset.GB2312 -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_CN.toUInt())
        BookExportCharset.BIG5 -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingBig5.toUInt())
        BookExportCharset.SHIFT_JIS -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingShiftJIS.toUInt())
        BookExportCharset.EUC_JP -> CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingEUC_JP.toUInt())
    }
    requireBookExport(CFStringIsEncodingAvailable(CFStringConvertNSStringEncodingToEncoding(encoding)),
        "当前系统不支持所选导出字符集")
    return encoding
}
