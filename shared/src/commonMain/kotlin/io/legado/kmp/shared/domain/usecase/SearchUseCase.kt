package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.SearchRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.compareTo
import io.legado.kmp.shared.model.isSameBook
import kotlinx.coroutines.flow.Flow

/**
 * Use case for managing search results
 */
class SearchUseCase(
    private val repository: SearchRepository
) {
    /**
     * Observe search results as a Flow
     *
     * @return Flow emitting list of search books
     */
    operator fun invoke(): Flow<List<SearchBook>> {
        return repository.observeSearchResults()
    }

    /**
     * Get current search results (one-time)
     *
     * @return List of search books
     */
    suspend fun getResults(): List<SearchBook> {
        return repository.getSearchResults()
    }

    /**
     * Set search results (replace current)
     *
     * @param books List of search books
     */
    suspend fun setResults(books: List<SearchBook>) {
        repository.setSearchResults(books)
    }

    /**
     * Add a single search result
     *
     * @param book The search book to add
     */
    suspend fun addResult(book: SearchBook) {
        repository.addSearchResult(book)
    }

    /**
     * Add multiple search results
     *
     * @param books List of search books to add
     */
    suspend fun addResults(books: List<SearchBook>) {
        repository.addSearchResults(books)
    }

    /**
     * Clear all search results
     */
    suspend fun clear() {
        repository.clearSearchResults()
    }

    /**
     * Get the count of search results
     *
     * @return Number of results
     */
    suspend fun count(): Int {
        return repository.getResultCount()
    }

    /**
     * Check if there are any results
     *
     * @return True if there are results
     */
    suspend fun hasResults(): Boolean {
        return repository.hasResults()
    }

    /**
     * Get a result by book URL
     *
     * @param bookUrl The book URL
     * @return The search book if found, null otherwise
     */
    suspend fun getByBookUrl(bookUrl: String): SearchBook? {
        return repository.getByBookUrl(bookUrl)
    }

    /**
     * Remove a result by book URL
     *
     * @param bookUrl The book URL
     */
    suspend fun removeByBookUrl(bookUrl: String) {
        repository.removeByBookUrl(bookUrl)
    }

    /**
     * Get results filtered by origin
     *
     * @param origin The book source URL
     * @return List of search books from the origin
     */
    suspend fun getByOrigin(origin: String): List<SearchBook> {
        return repository.getByOrigin(origin)
    }

    /**
     * Sort results by origin order
     */
    suspend fun sortByOriginOrder() {
        repository.sortResults { a: SearchBook, b: SearchBook -> b.compareTo(a) }
    }

    /**
     * Sort results by name
     */
    suspend fun sortByName() {
        repository.sortResults { a, b -> a.name.compareTo(b.name) }
    }

    /**
     * Filter results to only valid books
     */
    suspend fun filterValid() {
        repository.filterResults { it.isValid }
    }

    /**
     * Filter results by origin
     *
     * @param origin The origin to filter by
     */
    suspend fun filterByOrigin(origin: String) {
        repository.filterResults { it.origin == origin }
    }

    /**
     * Deduplicate results by book URL
     */
    suspend fun deduplicate() {
        val results = repository.getSearchResults()
        val seen = mutableSetOf<String>()
        val unique = results.filterNot { seen.add(it.bookUrl) }
        if (unique.size < results.size) {
            repository.setSearchResults(unique)
        }
    }
}

/**
 * Use case for converting search results to books
 */
class ConvertSearchToBooksUseCase {
    /**
     * Convert a single search book to a book
     *
     * @param searchBook The search book to convert
     * @return The converted Book
     */
    operator fun invoke(searchBook: SearchBook) = searchBook.toBook()

    /**
     * Convert multiple search books to books
     *
     * @param searchBooks List of search books to convert
     * @return List of converted Books
     */
    suspend operator fun invoke(searchBooks: List<SearchBook>): List<Book> {
        return searchBooks.map { it.toBook() }
    }
}

/**
 * Use case for managing search state
 */
class SearchStateUseCase(
    private val repository: SearchRepository
) {
    /**
     * Check if a book is in search results
     *
     * @param bookUrl The book URL to check
     * @return True if the book is in results
     */
    suspend fun contains(bookUrl: String): Boolean {
        return repository.getByBookUrl(bookUrl) != null
    }

    /**
     * Check if search results are empty
     *
     * @return True if no results
     */
    suspend fun isEmpty(): Boolean {
        return repository.getResultCount() == 0
    }

    /**
     * Get the first search result
     *
     * @return The first search book, or null if empty
     */
    suspend fun first(): SearchBook? {
        return repository.getSearchResults().firstOrNull()
    }

    /**
     * Get search results grouped by origin
     *
     * @return Map of origin to list of search books
     */
    suspend fun groupByOrigin(): Map<String, List<SearchBook>> {
        return repository.getSearchResults().groupBy { it.origin }
    }

    /**
     * Get unique origins from search results
     *
     * @return Set of origin URLs
     */
    suspend fun getOrigins(): Set<String> {
        return repository.getSearchResults().map { it.origin }.toSet()
    }
}
