package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook

/**
 * Use case for exploring/discovering books from web sources
 */
class ExploreBooksUseCase(
    private val repository: WebBookRepository
) {
    /**
     * Explore books from a source
     *
     * @param source Book source to explore
     * @param exploreUrl URL to explore
     * @param page Page number
     * @return Result containing list of discovered books
     */
    suspend operator fun invoke(
        source: BookSource,
        exploreUrl: String,
        page: Int = 1
    ): Result<List<SearchBook>> {
        return repository.exploreBook(source, exploreUrl, page)
    }
}
