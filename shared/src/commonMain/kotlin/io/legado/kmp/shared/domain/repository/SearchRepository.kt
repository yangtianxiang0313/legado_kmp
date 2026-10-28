package io.legado.kmp.shared.domain.repository

import app.cash.sqldelight.coroutines.asFlow
import app.cash.sqldelight.coroutines.mapToList
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.model.SearchBook
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

/**
 * Repository for managing persisted search book results.
 */
interface SearchRepository {

    /**
     * Observe the current search results as a Flow
     *
     * @return Flow emitting list of search books
     */
    fun observeSearchResults(): Flow<List<SearchBook>>

    /**
     * Get the current search results (one-time)
     *
     * @return List of current search books
     */
    suspend fun getSearchResults(): List<SearchBook>

    /**
     * Set search results (replace current results)
     *
     * @param books List of search books
     */
    suspend fun setSearchResults(books: List<SearchBook>)

    /**
     * Add a single search result
     *
     * @param book The search book to add
     */
    suspend fun addSearchResult(book: SearchBook)

    /**
     * Add multiple search results
     *
     * @param books List of search books to add
     */
    suspend fun addSearchResults(books: List<SearchBook>)

    /**
     * Clear all search results
     */
    suspend fun clearSearchResults()

    /**
     * Get the number of search results
     *
     * @return The count of search results
     */
    suspend fun getResultCount(): Int

    /**
     * Check if there are any search results
     *
     * @return True if there are results
     */
    suspend fun hasResults(): Boolean

    /**
     * Get a search result by book URL
     *
     * @param bookUrl The book URL
     * @return The search book if found, null otherwise
     */
    suspend fun getByBookUrl(bookUrl: String): SearchBook?

    /**
     * Remove a search result by book URL
     *
     * @param bookUrl The book URL
     */
    suspend fun removeByBookUrl(bookUrl: String)

    /**
     * Get search results filtered by origin
     *
     * @param origin The book source URL
     * @return List of search books from the specified origin
     */
    suspend fun getByOrigin(origin: String): List<SearchBook>

    suspend fun getFirstByNameAuthor(name: String, author: String): SearchBook?

    suspend fun changeSourceByGroup(
        name: String,
        author: String,
        sourceGroup: String
    ): List<SearchBook>

    suspend fun changeSourceSearch(
        name: String,
        author: String,
        key: String,
        sourceGroup: String
    ): List<SearchBook>

    suspend fun getEnabledHasCover(name: String, author: String): List<SearchBook>

    suspend fun clear(name: String, author: String)

    suspend fun clearExpired(time: Long)

    /**
     * Sort search results by a comparator
     *
     * @param comparator The comparator to use
     */
    suspend fun sortResults(comparator: Comparator<SearchBook>)

    /**
     * Filter search results
     *
     * @param predicate The filter predicate
     */
    suspend fun filterResults(predicate: (SearchBook) -> Boolean)
}

/**
 * SQLDelight-backed implementation of SearchRepository
 */
class SearchRepositoryImpl(
    private val database: LegadoDatabase
) : SearchRepository {

    override fun observeSearchResults(): Flow<List<SearchBook>> {
        return database.searchBookQueries
            .selectAll()
            .asFlow()
            .mapToList(Dispatchers.Default)
            .map { books -> books.map(::mapFromDb) }
    }

    override suspend fun getSearchResults(): List<SearchBook> {
        return database.searchBookQueries.selectAll().executeAsList().map(::mapFromDb)
    }

    override suspend fun setSearchResults(books: List<SearchBook>) {
        replaceAll(books)
    }

    override suspend fun addSearchResult(book: SearchBook) {
        upsert(book)
    }

    override suspend fun addSearchResults(books: List<SearchBook>) {
        for (book in books) {
            upsert(book)
        }
    }

    override suspend fun clearSearchResults() {
        database.searchBookQueries.deleteAll()
    }

    override suspend fun getResultCount(): Int {
        return database.searchBookQueries.countAll().executeAsOne().toInt()
    }

    override suspend fun hasResults(): Boolean {
        return getResultCount() > 0
    }

    override suspend fun getByBookUrl(bookUrl: String): SearchBook? {
        return database.searchBookQueries.selectByBookUrl(bookUrl).executeAsOneOrNull()?.let(::mapFromDb)
    }

    override suspend fun removeByBookUrl(bookUrl: String) {
        database.searchBookQueries.deleteByBookUrl(bookUrl)
    }

    override suspend fun getByOrigin(origin: String): List<SearchBook> {
        return database.searchBookQueries.selectByOrigin(origin).executeAsList().map(::mapFromDb)
    }

    override suspend fun getFirstByNameAuthor(name: String, author: String): SearchBook? {
        return database.searchBookQueries
            .selectFirstByNameAuthor(name, author)
            .executeAsOneOrNull()
            ?.let(::mapFromDb)
    }

    override suspend fun changeSourceByGroup(
        name: String,
        author: String,
        sourceGroup: String
    ): List<SearchBook> {
        return database.searchBookQueries
            .changeSourceByGroup(name, author, sourceGroup)
            .executeAsList()
            .map(::mapFromChangeSourceByGroup)
    }

    override suspend fun changeSourceSearch(
        name: String,
        author: String,
        key: String,
        sourceGroup: String
    ): List<SearchBook> {
        return database.searchBookQueries
            .changeSourceSearch(name, author, sourceGroup, key, key)
            .executeAsList()
            .map(::mapFromChangeSourceSearch)
    }

    override suspend fun getEnabledHasCover(name: String, author: String): List<SearchBook> {
        return database.searchBookQueries
            .selectEnabledHasCover(name, author)
            .executeAsList()
            .map(::mapFromEnabledHasCover)
    }

    override suspend fun clear(name: String, author: String) {
        database.searchBookQueries.deleteByNameAuthor(name, author)
    }

    override suspend fun clearExpired(time: Long) {
        database.searchBookQueries.deleteExpired(time)
    }

    override suspend fun sortResults(comparator: Comparator<SearchBook>) {
        replaceAll(getSearchResults().sortedWith(comparator))
    }

    override suspend fun filterResults(predicate: (SearchBook) -> Boolean) {
        replaceAll(getSearchResults().filter(predicate))
    }

    private suspend fun replaceAll(books: List<SearchBook>) {
        database.searchBookQueries.deleteAll()
        val now = io.legado.kmp.shared.util.currentTimeMillis()
        books.forEachIndexed { index, book ->
            upsert(book.copy(time = if (book.time > 0) book.time else now - index))
        }
    }

    private suspend fun upsert(book: SearchBook) {
        database.searchBookQueries.insert(
            book_url = book.bookUrl,
            origin = book.origin,
            origin_name = book.originName,
            type = book.type.toLong(),
            name = book.name,
            author = book.author,
            kind = book.kind,
            cover_url = book.coverUrl,
            intro = book.intro,
            word_count = book.wordCount,
            latest_chapter_title = book.latestChapterTitle,
            toc_url = book.tocUrl,
            time = book.time,
            variable = book.variable,
            origin_order = book.originOrder.toLong(),
            chapter_word_count_text = book.chapterWordCountText,
            chapter_word_count = book.chapterWordCount.toLong(),
            respond_time = book.respondTime.toLong()
        )
    }

    private fun mapFromDb(book: io.legado.kmp.data.database.schema.Search_books): SearchBook {
        return SearchBook(
            bookUrl = book.book_url,
            origin = book.origin,
            originName = book.origin_name,
            type = book.type.toInt(),
            name = book.name,
            author = book.author,
            kind = book.kind,
            coverUrl = book.cover_url,
            intro = book.intro,
            wordCount = book.word_count,
            latestChapterTitle = book.latest_chapter_title,
            tocUrl = book.toc_url,
            time = book.time,
            variable = book.variable,
            originOrder = book.origin_order.toInt(),
            chapterWordCountText = book.chapter_word_count_text,
            chapterWordCount = book.chapter_word_count.toInt(),
            respondTime = book.respond_time.toInt()
        )
    }

    private fun mapFromChangeSourceByGroup(book: io.legado.kmp.data.database.schema.ChangeSourceByGroup): SearchBook {
        return mapJoinedFields(
            bookUrl = book.book_url,
            origin = book.origin,
            originName = book.origin_name,
            type = book.type,
            name = book.name,
            author = book.author,
            kind = book.kind,
            coverUrl = book.cover_url,
            intro = book.intro,
            wordCount = book.word_count,
            latestChapterTitle = book.latest_chapter_title,
            tocUrl = book.toc_url,
            time = book.time,
            variable = book.variable,
            originOrder = book.origin_order,
            chapterWordCountText = book.chapter_word_count_text,
            chapterWordCount = book.chapter_word_count,
            respondTime = book.respond_time
        )
    }

    private fun mapFromChangeSourceSearch(book: io.legado.kmp.data.database.schema.ChangeSourceSearch): SearchBook {
        return mapJoinedFields(
            bookUrl = book.book_url,
            origin = book.origin,
            originName = book.origin_name,
            type = book.type,
            name = book.name,
            author = book.author,
            kind = book.kind,
            coverUrl = book.cover_url,
            intro = book.intro,
            wordCount = book.word_count,
            latestChapterTitle = book.latest_chapter_title,
            tocUrl = book.toc_url,
            time = book.time,
            variable = book.variable,
            originOrder = book.origin_order,
            chapterWordCountText = book.chapter_word_count_text,
            chapterWordCount = book.chapter_word_count,
            respondTime = book.respond_time
        )
    }

    private fun mapFromEnabledHasCover(book: io.legado.kmp.data.database.schema.SelectEnabledHasCover): SearchBook {
        return mapJoinedFields(
            bookUrl = book.book_url,
            origin = book.origin,
            originName = book.origin_name,
            type = book.type,
            name = book.name,
            author = book.author,
            kind = book.kind,
            coverUrl = book.cover_url,
            intro = book.intro,
            wordCount = book.word_count,
            latestChapterTitle = book.latest_chapter_title,
            tocUrl = book.toc_url,
            time = book.time,
            variable = book.variable,
            originOrder = book.origin_order,
            chapterWordCountText = book.chapter_word_count_text,
            chapterWordCount = book.chapter_word_count,
            respondTime = book.respond_time
        )
    }

    private fun mapJoinedFields(
        bookUrl: String,
        origin: String,
        originName: String,
        type: Long,
        name: String,
        author: String,
        kind: String?,
        coverUrl: String?,
        intro: String?,
        wordCount: String?,
        latestChapterTitle: String?,
        tocUrl: String,
        time: Long,
        variable: String?,
        originOrder: Long,
        chapterWordCountText: String?,
        chapterWordCount: Long,
        respondTime: Long
    ): SearchBook {
        return SearchBook(
            bookUrl = bookUrl,
            origin = origin,
            originName = originName,
            type = type.toInt(),
            name = name,
            author = author,
            kind = kind,
            coverUrl = coverUrl,
            intro = intro,
            wordCount = wordCount,
            latestChapterTitle = latestChapterTitle,
            tocUrl = tocUrl,
            time = time,
            variable = variable,
            originOrder = originOrder.toInt(),
            chapterWordCountText = chapterWordCountText,
            chapterWordCount = chapterWordCount.toInt(),
            respondTime = respondTime.toInt()
        )
    }
}
