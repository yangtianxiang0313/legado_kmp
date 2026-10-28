@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.platform.reboundSandboxPath
import kotlinx.cinterop.readBytes
import kotlinx.datetime.Clock
import platform.CoreGraphics.CGSizeMake
import platform.Foundation.NSData
import platform.Foundation.NSURL
import platform.Foundation.NSFileManager
import platform.PDFKit.PDFDocument
import platform.PDFKit.kPDFDisplayBoxMediaBox
import platform.UIKit.UIImagePNGRepresentation

class IosPdfBookParser : PdfBookParser {
    override suspend fun documentPath(book: Book): String {
        require('\u0000' !in book.bookUrl) { "Invalid PDF path" }
        val path = book.bookUrl
        return if (NSFileManager.defaultManager.fileExistsAtPath(path)) path
        else reboundSandboxPath(path) ?: path
    }

    override suspend fun parse(book: Book): ParsedPdfBook {
        val document = openDocument(book)
        val pageCount = document.pageCount().toInt()
        require(pageCount > 0) { "PDF has no pages" }

        val chapters = List(pageCount) { index ->
            BookChapter(
                bookUrl = book.bookUrl,
                index = index,
                title = "Page ${index + 1}",
                url = "pdf-page-${index + 1}",
            )
        }
        val currentTitle = chapters.getOrNull(book.durChapterIndex)?.title ?: chapters.firstOrNull()?.title
        return ParsedPdfBook(
            book = book.copy(
                totalChapterNum = chapters.size,
                latestChapterTitle = chapters.lastOrNull()?.title,
                latestChapterTime = Clock.System.now().toEpochMilliseconds(),
                durChapterTitle = currentTitle,
            ),
            chapters = chapters,
        )
    }

    override suspend fun readContent(book: Book, chapter: BookChapter): String {
        val document = openDocument(book)
        val page = document.pageAtIndex(chapter.index.toULong())
            ?: error("PDF page not found: ${chapter.index + 1}")
        return page.string.orEmpty()
    }

    override suspend fun renderPageImage(book: Book, pageIndex: Int): ByteArray? {
        val document = openDocument(book)
        val page = document.pageAtIndex(pageIndex.toULong()) ?: return null
        val image = page.thumbnailOfSize(
            size = CGSizeMake(width = 1080.0, height = 1440.0),
            forBox = kPDFDisplayBoxMediaBox,
        )
        return UIImagePNGRepresentation(image)?.toByteArray()
    }

    private suspend fun openDocument(book: Book): PDFDocument {
        val url = NSURL.fileURLWithPath(documentPath(book))
        val document = PDFDocument(uRL = url) ?: error("PDF 文件损坏或无法打开")
        require(!document.isLocked()) { "PDF 已加密，请先解锁文件后再导入" }
        return document
    }
}

private fun NSData.toByteArray(): ByteArray {
    if (length == 0UL) return ByteArray(0)
    return bytes?.readBytes(length.toInt()) ?: ByteArray(0)
}
