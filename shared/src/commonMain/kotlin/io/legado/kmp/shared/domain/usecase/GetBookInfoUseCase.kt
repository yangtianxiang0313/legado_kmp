package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource

/**
 * Use case for getting book information from web sources
 */
class GetBookInfoUseCase(
    private val repository: WebBookRepository
) {
    /**
     * Get book information
     *
     * @param source Book source
     * @param bookUrl URL of the book detail page
     * @return Result containing Book with details
     */
    suspend operator fun invoke(
        source: BookSource,
        bookUrl: String
    ): Result<Book> {
        return repository.getBookInfo(source, bookUrl)
    }
}
