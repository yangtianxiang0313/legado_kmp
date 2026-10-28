package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/**
 * Use case for searching books across web sources
 */
class SearchWebBooksUseCase(
    private val repository: WebBookRepository
) {
    /**
     * Search books from a single source
     *
     * @param source Book source to search
     * @param keyword Search keyword
     * @param page Page number
     * @return Result containing list of search books
     */
    suspend fun searchFromSource(
        source: BookSource,
        keyword: String,
        page: Int = 1
    ): Result<List<SearchBook>> {
        return repository.searchBook(source, keyword, page)
    }

    /**
     * Search books from multiple sources
     *
     * @param sources List of book sources to search
     * @param keyword Search keyword
     * @param page Page number
     * @return List of results from all sources
     */
    suspend fun searchFromSources(
        sources: List<BookSource>,
        keyword: String,
        page: Int = 1
    ): List<Result<List<SearchBook>>> {
        return sources.map { source ->
            try {
                repository.searchBook(source, keyword, page)
            } catch (e: Exception) {
                Result.failure(e)
            }
        }
    }

    /**
     * Search books from multiple sources and aggregate results
     *
     * @param sources List of book sources to search
     * @param keyword Search keyword
     * @param page Page number
     * @return Aggregated list of all search books
     */
    suspend fun searchAndAggregate(
        sources: List<BookSource>,
        keyword: String,
        page: Int = 1
    ): List<SearchBook> {
        val results = searchFromSources(sources, keyword, page)
        val books = mutableListOf<SearchBook>()

        results.forEach { result ->
            result.getOrNull()?.let { bookList ->
                books.addAll(bookList)
            }
        }

        return books
    }

    /**
     * 精准搜索：在单个书源中搜索，按书名+作者精确匹配。
     * 对应 legado WebBook.preciseSearchAwait 语义：
     * - 使用 name 作为搜索关键词
     * - 在搜索结果中按 name + author 精确过滤
     * - 找到第一个匹配结果即返回对应 Book
     *
     * @param source Book source to search
     * @param name Exact book name to match
     * @param author Exact author to match
     * @return Result containing the matched Book, or failure if not found
     */
    suspend fun preciseSearchAwait(
        source: BookSource,
        name: String,
        author: String,
    ): Result<Book> {
        return kotlin.runCatching {
            coroutineContext.ensureActive()
            // Use filter + shouldBreak to match legacy WebBook.preciseSearchAwait:
            // filter by exact name+author, break as soon as one match is found
            val results = repository.searchBook(
                source = source,
                keyword = name,
                page = 1,
                filter = { fName, fAuthor -> fName == name && fAuthor == author },
                shouldBreak = { it > 0 }
            ).getOrThrow()
            val matched = results.firstOrNull()
                ?: throw IllegalStateException("未搜索到 $name($author) 书籍")
            coroutineContext.ensureActive()
            matched.toBook()
        }
    }
}
