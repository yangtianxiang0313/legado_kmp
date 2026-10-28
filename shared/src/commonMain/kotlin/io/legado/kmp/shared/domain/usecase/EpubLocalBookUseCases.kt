package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.localbook.EpubBookParser
import io.legado.kmp.shared.domain.localbook.LocalBookFileResolver
import io.legado.kmp.shared.domain.localbook.ParsedEpubBook
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

class ParseEpubLocalFileUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val epubBookParser: EpubBookParser
) {
    suspend operator fun invoke(book: Book): ParsedEpubBook {
        return epubBookParser.parse(localBookFileResolver.resolve(book))
    }
}

class LoadEpubLocalChapterContentUseCase(
    private val localBookFileResolver: LocalBookFileResolver,
    private val epubBookParser: EpubBookParser
) {
    suspend operator fun invoke(book: Book, chapter: BookChapter): String {
        return epubBookParser.readContent(localBookFileResolver.resolve(book), chapter)
    }
}
