package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.ParsedPdfBook
import io.legado.kmp.shared.domain.localbook.PdfBookParser
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

class ParsePdfLocalFileUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val pdfBookParser: PdfBookParser
) {
    suspend operator fun invoke(book: Book): ParsedPdfBook {
        return pdfBookParser.parse(localBookFileResolver.resolve(book))
    }
}

class LoadPdfLocalChapterContentUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val pdfBookParser: PdfBookParser
) {
    suspend operator fun invoke(book: Book, chapter: BookChapter): String {
        return pdfBookParser.readContent(localBookFileResolver.resolve(book), chapter)
    }
}

class RenderPdfLocalPageImageUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val pdfBookParser: PdfBookParser
) {
    suspend operator fun invoke(book: Book, pageIndex: Int): ByteArray? {
        return pdfBookParser.renderPageImage(localBookFileResolver.resolve(book), pageIndex)
    }
}
