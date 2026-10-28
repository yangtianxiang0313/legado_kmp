package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.ParsedUmdBook
import io.legado.kmp.shared.domain.localbook.UmdBookParser
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

class ParseUmdLocalFileUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val umdBookParser: UmdBookParser
) {
    suspend operator fun invoke(book: Book): ParsedUmdBook {
        val resolved = localBookFileResolver.read(book)
        return umdBookParser.parse(resolved.book, resolved.bytes)
    }
}

class LoadUmdLocalChapterContentUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val umdBookParser: UmdBookParser
) {
    suspend operator fun invoke(book: Book, chapter: BookChapter): String {
        val resolved = localBookFileResolver.read(book)
        return umdBookParser.readContent(resolved.bytes, chapter)
    }
}
