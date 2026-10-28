package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ExploreBooksUseCase
import io.legado.kmp.shared.domain.usecase.DeleteSearchKeywordUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetExploreKindsUseCase
import io.legado.kmp.shared.domain.usecase.GetSearchKeywordsUseCase
import io.legado.kmp.shared.domain.usecase.SaveSearchKeywordUseCase
import io.legado.kmp.shared.domain.usecase.SearchUseCase
import io.legado.kmp.shared.domain.usecase.SearchWebBooksUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourcePart
import io.legado.kmp.shared.model.ExploreKind
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.SearchKeyword
import io.legado.kmp.shared.model.SearchScope
import io.legado.kmp.shared.model.SearchSessionState
import io.legado.kmp.shared.platform.SearchExecutionPolicy
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

class SearchFacade(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val searchWebBooksUseCase: SearchWebBooksUseCase,
    private val getExploreKindsUseCase: GetExploreKindsUseCase,
    private val exploreBooksUseCase: ExploreBooksUseCase,
    private val searchUseCase: SearchUseCase,
    private val getSearchKeywordsUseCase: GetSearchKeywordsUseCase,
    private val saveSearchKeywordUseCase: SaveSearchKeywordUseCase,
    private val deleteSearchKeywordUseCase: DeleteSearchKeywordUseCase,
    private val preferencesStore: AppPreferencesStore,
) {
    companion object {
        private const val PARTIAL_PUBLISH_INTERVAL_MS = 120L
        private const val SOURCE_SEARCH_TIMEOUT_MS = 30_000L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val session = MutableStateFlow(SearchSessionState())
    private var searchJob: Job? = null
    private val searchGeneration = MutableStateFlow(0L)
    private val searchStartMutex = Mutex()
    private var seenResultIds = emptySet<String>()
    private var pageRecovery: SearchPageRecovery? = null

    fun watchSourceParts(onUpdate: (List<BookSourcePart>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase.observeEnabledParts(), onUpdate, label = "SearchFacade.sourceParts")
    }

    fun watchEnabledSources(onUpdate: (List<BookSource>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase.observeEnabled(), onUpdate, label = "SearchFacade.enabledSources")
    }

    fun watchEnabledGroups(onUpdate: (List<String>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase.observeEnabledGroups(), onUpdate, label = "SearchFacade.enabledGroups")
    }

    fun watchExploreSourceParts(onUpdate: (List<BookSourcePart>) -> Unit): FlowSubscription {
        return watchFlow(getBookSourcesUseCase.observeEnabledExploreParts(), onUpdate, label = "SearchFacade.exploreSourceParts")
    }

    fun watchSearchSession(onUpdate: (SearchSessionState) -> Unit): FlowSubscription {
        return watchFlow(session, onUpdate, label = "SearchFacade.session")
    }

    fun watchSearchHistory(
        keyword: String,
        onUpdate: (List<SearchKeyword>) -> Unit,
    ): FlowSubscription {
        val normalizedKeyword = keyword.trim()
        val flow = if (normalizedKeyword.isBlank()) {
            getSearchKeywordsUseCase.byTime()
        } else {
            getSearchKeywordsUseCase.search(normalizedKeyword)
        }
        return watchFlow(flow, onUpdate, label = "SearchFacade.history")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun startSearch(searchScope: SearchScope, keyword: String, page: Int = 1) = runRecoverable("SearchFacade.startSearch") {
        beginSearch(searchScope, keyword, page)
    }

    private suspend fun beginSearch(searchScope: SearchScope, keyword: String, page: Int, recovery: SearchPageRecovery? = null) {
        val generation = searchGeneration.updateAndGet { it + 1 }
        searchStartMutex.withLock {
            if (isCurrentGeneration(generation)) {
                startSearchLocked(searchScope, keyword, page, generation, recovery)
            }
        }
    }

    private suspend fun startSearchLocked(
        searchScope: SearchScope,
        keyword: String,
        page: Int,
        generation: Long,
        recovery: SearchPageRecovery?,
    ) {
        val previous = searchJob
        searchJob = null
        previous?.cancelAndJoin()
        kotlin.coroutines.coroutineContext.ensureActive()
        if (!isCurrentGeneration(generation)) return
        if (recovery == null) pageRecovery = null
        val normalizedKeyword = keyword.trim()
        val requestedPage = page.coerceAtLeast(1)
        if (normalizedKeyword.isBlank()) {
            publishSession(
                SearchSessionState(
                    keyword = "",
                    scope = searchScope,
                    page = 0,
                    isRunning = false,
                    isPaused = false,
                    results = emptyList(),
                    hasMore = false,
                    sourceTotalCount = 0,
                    completedSourceCount = 0,
                    failedSourceCount = 0,
                    error = "请输入搜索关键词",
                )
            )
            searchUseCase.clear()
            return
        }

        if (recovery == null && page <= 1) saveSearchKeywordUseCase.recordUsage(normalizedKeyword)
        kotlin.coroutines.coroutineContext.ensureActive()
        if (!isCurrentGeneration(generation)) return
        val continuesSession =
            page > 1 &&
            session.value.keyword == normalizedKeyword &&
            session.value.scope == searchScope
        val seedResults = recovery?.seedResults ?: if (continuesSession) session.value.results else emptyList()
        val seedResultIds = recovery?.seedResultIds ?: if (continuesSession) seenResultIds else emptySet()
        val visibleResults = if (recovery != null) session.value.results else seedResults

        publishSession(
            SearchSessionState(
                keyword = normalizedKeyword,
                scope = searchScope,
                page = requestedPage,
                isRunning = true,
                isPaused = false,
                results = visibleResults,
                hasMore = false,
                sourceTotalCount = 0,
                completedSourceCount = 0,
                failedSourceCount = 0,
                error = null,
            )
        )

        searchJob = scope.launch(CoroutineExceptionHandler { _, error ->
            if (!isCurrentGeneration(generation)) return@CoroutineExceptionHandler
            val checkpoint = pageRecovery
            checkpoint?.pendingSourceUrls?.forEach { checkpoint.recordFailure(it, error.message ?: "搜索失败") }
            publishIfCurrent(generation, session.value.copy(
                isRunning = false,
                isPaused = false,
                hasMore = checkpoint?.pendingSourceUrls?.isNotEmpty() == true,
                sourceTotalCount = checkpoint?.sourceTotalCount ?: 0,
                completedSourceCount = checkpoint?.completedSourceCount ?: 0,
                failedSourceCount = checkpoint?.failedSourceCount ?: 0,
                error = error.message ?: "搜索失败",
            ))
        }) {
            val runtime = preferencesStore.runtimeConfig.first()
            val sources = resolveSources(searchScope)
            if (!isCurrentGeneration(generation)) return@launch
            val checkpoint = recovery ?: SearchPageRecovery(
                normalizedKeyword, searchScope, requestedPage, seedResults, seedResultIds,
                sources.map { it.bookSourceUrl },
            )
            checkpoint.retainAvailableSources(sources.mapTo(mutableSetOf()) { it.bookSourceUrl })
            pageRecovery = checkpoint
            val pendingUrls = checkpoint.pendingSourceUrls
            val pendingSources = sources.filter { it.bookSourceUrl in pendingUrls }
            checkpoint.beginAttempt(pendingSources.mapTo(mutableSetOf()) { it.bookSourceUrl })
            if (checkpoint.sourceTotalCount == 0) {
                publishIfCurrent(
                    generation = generation,
                    sessionState = session.value.copy(
                        isRunning = false,
                        sourceTotalCount = 0,
                        completedSourceCount = 0,
                        failedSourceCount = 0,
                        error = "当前搜索范围没有可用书源",
                    ),
                )
                if (isCurrentGeneration(generation) && seedResults.isEmpty()) {
                    searchUseCase.clear()
                }
                return@launch
            }

            var aggregated = mergeResults(seedResults, checkpoint.books, normalizedKeyword, runtime.precisionSearch)
            var lastPublishedResults = visibleResults
            var lastPublishAt = 0L
            val guard = Mutex()
            val semaphore = Semaphore(SearchExecutionPolicy.effectiveSourceConcurrency(runtime.threadCount))
            publishIfCurrent(generation, session.value.copy(
                sourceTotalCount = checkpoint.sourceTotalCount,
                completedSourceCount = checkpoint.completedSourceCount,
                failedSourceCount = checkpoint.failedSourceCount,
            ))

            coroutineScope {
                pendingSources.map { source ->
                    launch {
                        awaitResume()
                        semaphore.withPermit {
                            if (!isCurrentGeneration(generation)) return@withPermit
                            awaitResume()
                            runCatching {
                                withTimeout(SOURCE_SEARCH_TIMEOUT_MS) {
                                    searchWebBooksUseCase.searchFromSource(source, normalizedKeyword, requestedPage).getOrThrow()
                                }
                            }.recoverCatching { throwable ->
                                if (throwable is TimeoutCancellationException) {
                                    throw IllegalStateException("搜索超时: ${source.bookSourceName.ifBlank { source.bookSourceUrl }}", throwable)
                                }
                                throw throwable
                            }
                                .onSuccess { books ->
                                    var partialState: SearchSessionState? = null
                                    guard.withLock {
                                        checkpoint.recordSuccess(source.bookSourceUrl, books)
                                        aggregated = mergeResults(
                                            existing = seedResults,
                                            incoming = checkpoint.books,
                                            keyword = normalizedKeyword,
                                            precision = runtime.precisionSearch,
                                        )
                                        val now = currentTimeMillis()
                                        val shouldPublish = aggregated != lastPublishedResults &&
                                            (checkpoint.completedSourceCount == checkpoint.sourceTotalCount ||
                                                now - lastPublishAt >= PARTIAL_PUBLISH_INTERVAL_MS)
                                        if (shouldPublish) {
                                            lastPublishedResults = aggregated
                                            lastPublishAt = now
                                            partialState = session.value.copy(
                                                results = aggregated,
                                                sourceTotalCount = checkpoint.sourceTotalCount,
                                                completedSourceCount = checkpoint.completedSourceCount,
                                                failedSourceCount = checkpoint.failedSourceCount,
                                                error = null,
                                            )
                                        }
                                    }
                                    partialState?.let { publishIfCurrent(generation, it) }
                                }
                                .onFailure { throwable ->
                                    if (throwable is CancellationException) throw throwable
                                    guard.withLock {
                                        checkpoint.recordFailure(source.bookSourceUrl, throwable.message ?: "搜索失败")
                                    }
                                }
                        }
                    }
                }.forEach { it.join() }
            }

            if (!isCurrentGeneration(generation)) {
                return@launch
            }
            searchUseCase.setResults(aggregated)
            if (!isCurrentGeneration(generation)) return@launch
            seenResultIds = seedResultIds + checkpoint.resultIds
            publishSession(
                session.value.copy(
                    isRunning = false,
                    isPaused = false,
                    results = aggregated,
                    hasMore = checkpoint.hasMore || checkpoint.pendingSourceUrls.isNotEmpty(),
                    sourceTotalCount = checkpoint.sourceTotalCount,
                    completedSourceCount = checkpoint.completedSourceCount,
                    failedSourceCount = checkpoint.failedSourceCount,
                    error = checkpoint.error,
                )
            )
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadNextPage() = runRecoverable("SearchFacade.loadNextPage") {
        val current = session.value
        val searchScope = current.scope ?: return@runRecoverable
        if (current.keyword.isBlank() || current.isRunning) return@runRecoverable
        val recovery = pageRecovery?.takeIf {
            it.keyword == current.keyword && it.searchScope == searchScope &&
                it.page == current.page && it.pendingSourceUrls.isNotEmpty()
        }
        if (!current.hasMore && recovery == null) return@runRecoverable
        beginSearch(searchScope, current.keyword, recovery?.page ?: current.page.coerceAtLeast(1) + 1, recovery)
    }

    fun pauseSearch() {
        session.updateAndGet { current ->
            if (current.isRunning) current.copy(isPaused = true) else current
        }
    }

    fun resumeSearch() {
        session.updateAndGet { current ->
            if (current.isRunning) current.copy(isPaused = false) else current
        }
    }

    fun cancelSearch() {
        searchGeneration.updateAndGet { it + 1 }
        searchJob?.cancel()
        searchJob = null
        publishSession(session.value.copy(isRunning = false, isPaused = false))
    }

    /**
     * 精准搜索：遍历多个书源，按书名+作者精确匹配，找到第一个匹配即返回。
     * 对应 legado WebBook.preciseSearch 语义。
     * 用于换源、书架刷新等场景。
     *
     * @param name 精确书名
     * @param author 精确作者
     * @param sources 要搜索的书源列表（为空时使用全部启用书源）
     * @return 匹配的 Book 和对应 BookSource，未找到则返回 null
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun preciseSearch(
        name: String,
        author: String,
        sources: List<BookSource>? = null,
    ): Pair<Book, BookSource>? = runRecoverable("SearchFacade.preciseSearch") {
        val trimmedName = name.trim()
        val trimmedAuthor = author.trim()
        require(trimmedName.isNotEmpty()) { "书名不能为空" }
        val searchSources = sources ?: getBookSourcesUseCase.getEnabled()
        for (source in searchSources) {
            kotlin.coroutines.coroutineContext.ensureActive()
            val book = searchWebBooksUseCase.preciseSearchAwait(source, trimmedName, trimmedAuthor).getOrNull()
            if (book != null) {
                return@runRecoverable Pair(book, source)
            }
        }
        null
    }

    /**
     * 精准搜索（通过 BookSourcePart 列表）：遍历多个书源部件，
     * 解析对应的完整 BookSource 后按书名+作者精确匹配。
     * 对应 legado WebBook.preciseSearch(bookSourceParts) 语义。
     *
     * @param name 精确书名
     * @param author 精确作者
     * @param sourceParts 要搜索的书源部件列表
     * @return 匹配的 Book 和对应 BookSource，未找到则返回 null
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun preciseSearchByParts(
        name: String,
        author: String,
        sourceParts: List<BookSourcePart>,
    ): Pair<Book, BookSource>? = runRecoverable("SearchFacade.preciseSearchByParts") {
        val trimmedName = name.trim()
        val trimmedAuthor = author.trim()
        require(trimmedName.isNotEmpty()) { "书名不能为空" }
        for (part in sourceParts) {
            kotlin.coroutines.coroutineContext.ensureActive()
            val source = getBookSourcesUseCase.getByUrl(part.bookSourceUrl) ?: continue
            val book = searchWebBooksUseCase.preciseSearchAwait(source, trimmedName, trimmedAuthor).getOrNull()
            if (book != null) {
                return@runRecoverable Pair(book, source)
            }
        }
        null
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadExploreKinds(sourceUrl: String, forceRefresh: Boolean = false): List<ExploreKind> =
        runRecoverable("SearchFacade.loadExploreKinds") {
            val source = requireSource(sourceUrl)
            if (forceRefresh) {
                getExploreKindsUseCase.clearCache(source)
            }
            getExploreKindsUseCase(source).getOrThrow()
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadExploreBooks(sourceUrl: String, exploreUrl: String): List<SearchBook> =
        runRecoverable("SearchFacade.loadExploreBooks") {
            val source = requireSource(sourceUrl)
            exploreBooksUseCase(source, exploreUrl).getOrThrow()
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadCachedResults(): List<SearchBook> = runRecoverable("SearchFacade.loadCachedResults") {
        searchUseCase.getResults()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadSearchHistory(keyword: String = ""): List<SearchKeyword> =
        runRecoverable("SearchFacade.loadSearchHistory") {
            val normalizedKeyword = keyword.trim()
            if (normalizedKeyword.isBlank()) {
                getSearchKeywordsUseCase.getAll()
                    .sortedByDescending { it.lastUseTime }
            } else {
                getSearchKeywordsUseCase.search(normalizedKeyword).first()
            }
        }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearSearchHistory() = runRecoverable("SearchFacade.clearSearchHistory") {
        deleteSearchKeywordUseCase.deleteAll()
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteSearchHistory(word: String) = runRecoverable("SearchFacade.deleteSearchHistory") {
        deleteSearchKeywordUseCase.delete(word)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun search(sourceUrl: String, keyword: String): List<SearchBook> = runRecoverable("SearchFacade.search") {
        val normalizedKeyword = keyword.trim()
        require(normalizedKeyword.isNotEmpty()) { "请输入搜索关键词" }
        val source = requireSource(sourceUrl)
        val results = searchWebBooksUseCase.searchFromSource(source, normalizedKeyword, 1).getOrThrow()
        searchUseCase.setResults(results)
        results
    }

    private suspend fun resolveSources(searchScope: SearchScope): List<BookSource> {
        return when (searchScope) {
            is SearchScope.Source -> {
                // Android keeps an explicitly selected disabled source, but falls back after deletion.
                getBookSourcesUseCase.getByUrl(searchScope.sourceUrl)?.let { listOf(it) }
                    ?: getBookSourcesUseCase.getEnabled()
            }
            is SearchScope.Group -> {
                // SearchScope.kt:117 resolves each selected group, not the combined comma string.
                val groups = searchScope.group.split(',').map(String::trim).filter(String::isNotEmpty)
                val enabled = getBookSourcesUseCase.getEnabled()
                enabled.filter { source -> groups.any(source::hasGroup) }.ifEmpty { enabled }
            }

            SearchScope.AllEnabled -> {
                getBookSourcesUseCase.getEnabled()
            }

            SearchScope.ExploreEnabled -> {
                val parts = getBookSourcesUseCase.getEnabledExploreParts()
                parts.mapNotNull { part -> getBookSourcesUseCase.getByUrl(part.bookSourceUrl) }
            }
        }.distinctBy { it.bookSourceUrl }
    }

    private suspend fun requireSource(sourceUrl: String): BookSource {
        return requireNotNull(getBookSourcesUseCase.getByUrl(sourceUrl)) {
            "Book source not found: $sourceUrl"
        }
    }

    private suspend fun awaitResume() {
        while (session.value.isRunning && session.value.isPaused) {
            delay(50)
        }
    }

    private fun isCurrentGeneration(generation: Long): Boolean {
        return generation == searchGeneration.value
    }

    private fun publishIfCurrent(generation: Long, sessionState: SearchSessionState) {
        if (isCurrentGeneration(generation)) {
            publishSession(sessionState)
        }
    }

    private fun publishSession(sessionState: SearchSessionState) {
        // Source progress retains the scheduling gate; explicit pause/resume updates it directly.
        session.updateAndGet { current ->
            if (current.isRunning && sessionState.isRunning) sessionState.copy(isPaused = current.isPaused) else sessionState
        }
    }

    private fun mergeResults(
        existing: List<SearchBook>,
        incoming: List<SearchBook>,
        keyword: String,
        precision: Boolean,
    ): List<SearchBook> {
        val merged = linkedMapOf<String, SearchBook>()
        (existing + incoming).forEach { book ->
            val key = "${book.name.trim()}::${book.author.trim()}"
            val previous = merged[key]
            merged[key] = if (previous == null) {
                book
            } else {
                mergeBook(previous, book)
            }
        }

        val exact = mutableListOf<SearchBook>()
        val contains = mutableListOf<SearchBook>()
        val other = mutableListOf<SearchBook>()
        merged.values.forEach { book ->
            when {
                book.name == keyword || book.author == keyword -> exact += book
                book.name.contains(keyword) || book.author.contains(keyword) -> contains += book
                !precision -> other += book
            }
        }
        exact.sortByDescending { it.origins.size }
        contains.sortByDescending { it.origins.size }
        other.sortByDescending { it.origins.size }
        return buildList {
            addAll(exact)
            addAll(contains)
            if (!precision) addAll(other)
        }
    }

    private fun mergeBook(base: SearchBook, incoming: SearchBook): SearchBook {
        val preferredCover = base.coverUrl ?: incoming.coverUrl
        val preferredKind = base.kind?.takeIf { it.isNotBlank() } ?: incoming.kind
        val preferredIntro = base.intro?.takeIf { it.isNotBlank() } ?: incoming.intro
        val preferredLatest = base.latestChapterTitle?.takeIf { it.isNotBlank() } ?: incoming.latestChapterTitle
        val preferredWordCount = base.wordCount?.takeIf { it.isNotBlank() } ?: incoming.wordCount
        val preferredRespondTime = listOf(base.respondTime, incoming.respondTime)
            .filter { it >= 0 }
            .minOrNull() ?: maxOf(base.respondTime, incoming.respondTime)
        return base.copy(
            coverUrl = preferredCover,
            kind = preferredKind,
            intro = preferredIntro,
            latestChapterTitle = preferredLatest,
            wordCount = preferredWordCount,
            respondTime = preferredRespondTime,
        ).mergeOrigin(incoming.origin)
    }
}
