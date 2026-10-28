package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.BookArchiveZipReader
import io.legado.kmp.shared.model.BookChapter
import okio.Buffer

internal data class EpubChapterEntry(
    val chapter: BookChapter,
    val fileName: String,
    val content: String,
)

internal data class ZipEntryData(
    val path: String,
    val data: ByteArray,
)

internal fun epubContainerXml(): String =
    """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

internal fun buildStoredZip(entries: List<ZipEntryData>, checkActive: () -> Unit = {}): ByteArray {
    checkActive()
    require(entries.size < 0xffff) { "导出 ZIP 条目数达到 ZIP32 上限" }
    val paths = mutableSetOf<String>()
    var localBytes = 0L
    var centralBytes = 0L
    entries.forEach { entry ->
        checkActive()
        validateExportArchivePath(entry.path)
        require(paths.add(entry.path.lowercase())) { "导出 ZIP 条目重名：${entry.path}" }
        val nameSize = entry.path.encodeToByteArray().size
        require(nameSize <= 0xffff && entry.data.size <= MAX_EXPORT_ENTRY_BYTES) { "导出 ZIP 文件名过长或条目超过 64 MiB" }
        localBytes += 30L + nameSize + entry.data.size
        centralBytes += 46L + nameSize
        require(localBytes < 0xffffffffL && centralBytes < 0xffffffffL &&
            localBytes + centralBytes + 22 <= MAX_EXPORT_ARCHIVE_BYTES) { "导出 ZIP 超过 128 MiB 或 ZIP32 上限" }
        if (entry.path == "mimetype") require(entry.data.contentEquals("application/epub+zip".encodeToByteArray())) {
            "EPUB mimetype 内容无效"
        }
    }
    // Other callers also use this writer; only EPUB archives contain this reserved entry.
    val ordered = entries.firstOrNull { it.path == "mimetype" }?.let { mime ->
        listOf(mime) + entries.filterNot { it.path == "mimetype" }
    } ?: entries
    val output = Buffer()
    val centralDirectory = Buffer()
    try {
        for (entry in ordered) {
            checkActive()
            val offset = output.size
            val name = entry.path.encodeToByteArray()
            val crc = crc32(entry.data, checkActive)
            output.writeIntLe(0x04034b50)
            output.writeShortLe(20)
            output.writeShortLe(0x0800)
            output.writeShortLe(0)
            output.writeShortLe(0)
            output.writeShortLe(33)
            output.writeIntLe(crc.toInt())
            output.writeIntLe(entry.data.size)
            output.writeIntLe(entry.data.size)
            output.writeShortLe(name.size)
            output.writeShortLe(0)
            output.write(name)
            var written = 0
            while (written < entry.data.size) {
                checkActive()
                val count = minOf(64 * 1024, entry.data.size - written)
                output.write(entry.data, written, count)
                written += count
            }

            centralDirectory.writeIntLe(0x02014b50)
            centralDirectory.writeShortLe(20)
            centralDirectory.writeShortLe(20)
            centralDirectory.writeShortLe(0x0800)
            centralDirectory.writeShortLe(0)
            centralDirectory.writeShortLe(0)
            centralDirectory.writeShortLe(33)
            centralDirectory.writeIntLe(crc.toInt())
            centralDirectory.writeIntLe(entry.data.size)
            centralDirectory.writeIntLe(entry.data.size)
            centralDirectory.writeShortLe(name.size)
            centralDirectory.writeShortLe(0)
            centralDirectory.writeShortLe(0)
            centralDirectory.writeShortLe(0)
            centralDirectory.writeShortLe(0)
            centralDirectory.writeIntLe(0)
            centralDirectory.writeIntLe(offset.toInt())
            centralDirectory.write(name)
        }
        val centralOffset = output.size
        val centralSize = centralDirectory.size
        checkActive()
        output.write(centralDirectory, centralSize)
        output.writeIntLe(0x06054b50)
        output.writeShortLe(0)
        output.writeShortLe(0)
        output.writeShortLe(entries.size)
        output.writeShortLe(entries.size)
        output.writeIntLe(centralSize.toInt())
        output.writeIntLe(centralOffset.toInt())
        output.writeShortLe(0)
        checkActive()
        return output.readByteArray()
    } finally {
        output.clear()
        centralDirectory.clear()
    }
}

private const val MAX_EXPORT_ENTRY_BYTES = 64 * 1024 * 1024
private const val MAX_EXPORT_ARCHIVE_BYTES = 128L * 1024 * 1024

internal fun validateExportArchivePath(path: String) {
    BookArchiveZipReader.validatePath(path)
    require(!path.endsWith('/') && path.none { it.isISOControl() }) { "导出 ZIP 路径不是安全文件路径" }
    path.encodeToByteArray(throwOnInvalidSequence = true)
}

private val exportCrcTable = IntArray(256) { value ->
    var crc = value
    repeat(8) { crc = (crc ushr 1) xor (if (crc and 1 != 0) 0xedb88320.toInt() else 0) }
    crc
}

private fun crc32(data: ByteArray, checkActive: () -> Unit): Long {
    var crc = -1
    data.forEachIndexed { index, byte ->
        if (index and 0xffff == 0) checkActive()
        crc = (crc ushr 8) xor exportCrcTable[(crc xor byte.toInt()) and 0xff]
    }
    return crc.inv().toLong() and 0xffffffffL
}

internal fun String.sanitizedExportFileName(): String {
    val cleaned = map { char ->
        if (char in setOf('/', '\\', ':', '*', '?', '"', '<', '>', '|')) '_' else char
    }.joinToString("").trim()
    return cleaned.ifBlank { "chapter" }
}

internal val cacheExportImageSrcRegex = Regex("""<img[^>]+src=["']([^"']+)["'][^>]*>""", RegexOption.IGNORE_CASE)

internal fun String.imageExtensionFromUrl(): String {
    val path = substringBefore('?').substringBefore('#')
    val extension = path.substringAfterLast('.', "")
        .lowercase()
        .takeIf { it.matches(Regex("[a-z0-9]{2,5}")) }
    return when (extension) {
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "svg" -> extension
        else -> "jpg"
    }
}

internal fun String.cacheExportParentPath(): String? {
    val index = maxOf(lastIndexOf('/'), lastIndexOf('\\'))
    if (index <= 0) return null
    return substring(0, index)
}
