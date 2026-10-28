package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

data class ParsedPdfBook(
    val book: Book,
    val chapters: List<BookChapter>
)

interface PdfBookParser {
    suspend fun documentPath(book: Book): String = book.bookUrl

    suspend fun parse(book: Book): ParsedPdfBook

    suspend fun readContent(book: Book, chapter: BookChapter): String

    suspend fun renderPageImage(book: Book, pageIndex: Int): ByteArray?
}

class UnsupportedPdfBookParser : PdfBookParser {
    override suspend fun parse(book: Book): ParsedPdfBook {
        throw UnsupportedOperationException("PDF parsing is not implemented on this platform")
    }

    override suspend fun readContent(book: Book, chapter: BookChapter): String {
        throw UnsupportedOperationException("PDF content reading is not implemented on this platform")
    }

    override suspend fun renderPageImage(book: Book, pageIndex: Int): ByteArray? {
        throw UnsupportedOperationException("PDF page rendering is not implemented on this platform")
    }
}
