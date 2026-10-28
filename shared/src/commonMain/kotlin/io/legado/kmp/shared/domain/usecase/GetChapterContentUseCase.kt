package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource

/**
 * Use case for getting chapter content from web sources
 */
class GetChapterContentUseCase(
    private val repository: WebBookRepository
) {
    /**
     * Get content for a chapter
     *
     * @param source Book source
     * @param book Book containing the chapter
     * @param chapter Chapter to get content for
     * @return Result containing chapter content text
     */
    suspend operator fun invoke(
        source: BookSource,
        book: Book,
        chapter: BookChapter
    ): Result<String> {
        return repository.getChapterContent(source, book, chapter)
    }
}
