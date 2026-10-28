package io.legado.kmp.shared.platform

import io.legado.kmp.shared.facade.BookExportFailure
import io.legado.kmp.shared.facade.requireBookExport

/** Strict export-only encoding. Unknown charsets and unrepresentable text must fail, never fall back. */
internal expect fun validateBookExportCharset(charset: String)

/**
 * Input is bounded in both UTF-16 storage bytes and UTF-8 bytes; output is independently bounded.
 * Implementations check cancellation between bounded, complete-codepoint conversion blocks.
 * UTF-16 writes one big-endian BOM; explicit UTF-16LE/BE and UTF-8 write no BOM.
 */
internal expect fun encodeBookExportText(text: String, charset: String, checkActive: () -> Unit): ByteArray

internal const val BOOK_EXPORT_TEXT_BYTES = 128L * 1024 * 1024

internal enum class BookExportCharset {
    UTF8, UTF16, UTF16LE, UTF16BE, GB18030, GBK, GB2312, BIG5, SHIFT_JIS, EUC_JP, ASCII, LATIN1,
}

internal fun bookExportCharset(charset: String): BookExportCharset {
    requireBookExport(charset.length <= 64, "不支持的导出字符集")
    return when (charset.trim().uppercase().replace("-", "").replace("_", "")) {
        "UTF8" -> BookExportCharset.UTF8
        "UTF16" -> BookExportCharset.UTF16
        "UTF16LE" -> BookExportCharset.UTF16LE
        "UTF16BE" -> BookExportCharset.UTF16BE
        "GB18030" -> BookExportCharset.GB18030
        "GBK" -> BookExportCharset.GBK
        "GB2312" -> BookExportCharset.GB2312
        "BIG5" -> BookExportCharset.BIG5
        "SHIFTJIS", "SJIS" -> BookExportCharset.SHIFT_JIS
        "EUCJP" -> BookExportCharset.EUC_JP
        "ASCII", "USASCII" -> BookExportCharset.ASCII
        "ISO88591", "LATIN1" -> BookExportCharset.LATIN1
        else -> throw BookExportFailure("不支持的导出字符集")
    }
}

internal fun requireBookExportTextInput(text: String, checkActive: () -> Unit) {
    checkActive()
    requireBookExport(text.length.toLong() * 2 <= BOOK_EXPORT_TEXT_BYTES, "导出文本输入超过 128 MiB 限制")
    var bytes = 0L
    var index = 0
    var nextCheck = 0
    while (index < text.length) {
        if (index >= nextCheck) {
            checkActive()
            nextCheck = index + 4096
        }
        val char = text[index++]
        bytes += when {
            char.isHighSurrogate() -> {
                requireBookExport(index < text.length && text[index].isLowSurrogate(), "导出文本包含无效 Unicode 字符")
                index++
                4
            }
            char.isLowSurrogate() -> throw BookExportFailure("导出文本包含无效 Unicode 字符")
            char.code < 0x80 -> 1
            char.code < 0x800 -> 2
            else -> 3
        }
        requireBookExport(bytes <= BOOK_EXPORT_TEXT_BYTES, "导出文本输入超过 128 MiB 限制")
    }
    checkActive()
}
