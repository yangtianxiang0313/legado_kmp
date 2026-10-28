package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource

/**
 * Use case for getting chapter list from web sources
 */
class GetChapterListUseCase(
    private val repository: WebBookRepository
) {
    /**
     * Get chapter list for a book
     *
     * @param source Book source
     * @param book Book to get chapters for
     * @return Result containing list of chapters
     */
    suspend operator fun invoke(
        source: BookSource,
        book: Book
    ): Result<List<BookChapter>> {
        return repository.getChapterList(source, book)
    }
}
