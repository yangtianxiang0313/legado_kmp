package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.LocalBookFileBinding
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.LoadEpubLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadMobiLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadTxtLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadUmdLocalChapterContentUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.isTxtLocalBook
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

internal class ReaderContentSearchSource(
    private val chapterContentRepository: ChapterContentRepository,
    private val loadTxtLocalChapterContentUseCase: LoadTxtLocalChapterContentUseCase,
    private val loadEpubLocalChapterContentUseCase: LoadEpubLocalChapterContentUseCase,
    private val loadUmdLocalChapterContentUseCase: LoadUmdLocalChapterContentUseCase,
    private val loadMobiLocalChapterContentUseCase: LoadMobiLocalChapterContentUseCase,
) {
    suspend fun read(book: Book, chapter: BookChapter): String? {
        val context = coroutineContext
        context.ensureActive()
        val cached = chapterContentRepository.getContent(book, chapter)
        context.ensureActive()
        if (cached != null) return cached
        if (!book.isLocal) return null

        val extension = LocalBookFileBinding.format(book)
        context.ensureActive()
        // Keep persisted chapter boundaries intact; local resolvers own missing-file recovery.
        val content = when (extension) {
            "pdf" -> null
            "epub" -> loadEpubLocalChapterContentUseCase(book, chapter)
            "umd" -> loadUmdLocalChapterContentUseCase(book, chapter)
            "mobi", "azw", "azw3" -> loadMobiLocalChapterContentUseCase(book, chapter)
            else -> when {
                book.isTxtLocalBook -> loadTxtLocalChapterContentUseCase(book, chapter)
                book.isEpub -> loadEpubLocalChapterContentUseCase(book, chapter)
                else -> null
            }
        }
        context.ensureActive()
        return content
    }
}
