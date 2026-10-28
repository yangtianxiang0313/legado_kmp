package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.SearchRepository
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.SearchWebBooksUseCase
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.SearchScope
import io.legado.kmp.shared.platform.SearchExecutionPolicy
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.updateAndGet
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class ForegroundWebStreamSearchSupport(
    private val sources: GetBookSourcesUseCase,
    private val search: SearchWebBooksUseCase,
    private val preferences: AppPreferencesStore,
    private val candidates: SearchRepository,
) {
    suspend fun run(request: ForegroundWebStreamInput, output: ForegroundWebStreamOutput) {
        val keyword = request.requiredString("key", 4096)
        val runtime = preferences.runtimeConfig.value
        val scope = decodeScope(request.optionalString("scope", 8 * 1024) ?: runtime.searchScope)
        val selected = resolveSources(scope)
        require(selected.isNotEmpty()) { "当前搜索范围没有可用书源" }
        require(selected.size <= 2048) { "搜索书源过多，请缩小搜索范围" }
        val concurrency = SearchExecutionPolicy.effectiveSourceConcurrency(runtime.threadCount)
            .coerceIn(1, selected.size)
        var totalBooks = 0
        var failureCount = 0
        var firstFailure: String? = null
        coroutineScope {
            val outcomes = Channel<SourceResult>(concurrency)
            val nextIndex = MutableStateFlow(0)
            val workers = List(concurrency) {
                launch {
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val index = nextIndex.updateAndGet { it + 1 } - 1
                        val source = selected.getOrNull(index) ?: break
                        outcomes.send(searchSource(source, keyword))
                    }
                }
            }
            launch {
                workers.joinAll()
                outcomes.close()
            }
            try {
                for (outcome in outcomes) {
                    currentCoroutineContext().ensureActive()
                    if (outcome.error != null) {
                        failureCount++
                        if (firstFailure == null) firstFailure = outcome.error
                        continue
                    }
                    totalBooks += outcome.books.size
                    require(totalBooks <= 20_000) { "搜索结果过多，请缩小搜索范围" }
                    val books = if (runtime.precisionSearch) {
                        outcome.books.filter { it.name.contains(keyword) || it.author.contains(keyword) }
                    } else outcome.books
                    sendBooks(books, output)
                }
            } finally {
                workers.forEach { it.cancel() }
                outcomes.cancel()
            }
        }
        if (failureCount > 0) output.fail("$failureCount 个书源搜索失败：${firstFailure.orEmpty()}")
    }

    private suspend fun searchSource(source: BookSource, keyword: String): SourceResult {
        return try {
            // Match the native production scheduler: configured platform concurrency, 30s/source, page 1.
            val books = withTimeout(30_000L) { search.searchFromSource(source, keyword, 1).getOrThrow() }
            currentCoroutineContext().ensureActive()
            require(books.size <= 5000) { "单个书源搜索结果过多，请缩小搜索范围" }
            val snapshots = books.map { book ->
                currentCoroutineContext().ensureActive()
                // copy() leaves non-constructor HTML fields empty without mutating cached originals.
                book.copy()
            }
            SourceResult(books = snapshots)
        } catch (error: Throwable) {
            currentCoroutineContext().ensureActive()
            if (error !is TimeoutCancellationException) {
                findFacadeRequestCancellation(error)?.let { throw it }
            }
            val detail = if (error is TimeoutCancellationException) "搜索超时" else error.message ?: "搜索失败"
            SourceResult(error = "${source.bookSourceName.ifBlank { source.bookSourceUrl }.take(256)}：${detail.take(512)}")
        }
    }

    private fun decodeScope(value: String): SearchScope {
        val normalized = value.trim()
        return when {
            "::" in normalized -> SearchScope.Source(normalized.substringAfter("::").trim())
            normalized.isEmpty() -> SearchScope.AllEnabled
            else -> SearchScope.Group(normalized)
        }
    }

    private suspend fun resolveSources(scope: SearchScope): List<BookSource> {
        val selected = when (scope) {
            is SearchScope.Source -> sources.getByUrl(scope.sourceUrl)?.let { listOf(it) } ?: sources.getEnabled()
            is SearchScope.Group -> {
                val groups = scope.group.split(',').map(String::trim).filter(String::isNotEmpty)
                val enabled = sources.getEnabled()
                enabled.filter { source -> groups.any(source::hasGroup) }.ifEmpty { enabled }
            }
            SearchScope.AllEnabled -> sources.getEnabled()
            SearchScope.ExploreEnabled -> sources.getEnabledExploreParts().mapNotNull { sources.getByUrl(it.bookSourceUrl) }
        }
        return selected.distinctBy { it.bookSourceUrl }.sortedBy { it.customOrder }
    }

    private suspend fun sendBooks(books: List<SearchBook>, output: ForegroundWebStreamOutput) {
        if (books.isEmpty()) {
            output.send("[]")
            return
        }
        val chunk = mutableListOf<JsonObject>()
        val chunkBooks = mutableListOf<SearchBook>()
        var chunkBytes = 2
        for (book in books) {
            currentCoroutineContext().ensureActive()
            val item = book.toWebJson()
            val itemBytes = item.toString().encodeToByteArray().size
            require(itemBytes + 2 <= ForegroundWebStreamOutput.MAX_FRAME_BYTES) { "单条搜索结果过大" }
            if (chunk.isNotEmpty() && (chunk.size >= 128 || chunkBytes + itemBytes + 1 > ForegroundWebStreamOutput.MAX_FRAME_BYTES)) {
                publishChunk(chunk, chunkBooks, output)
                chunk.clear()
                chunkBooks.clear()
                chunkBytes = 2
            }
            chunk += item
            chunkBooks += book
            chunkBytes += itemBytes + 1
        }
        if (chunk.isNotEmpty()) publishChunk(chunk, chunkBooks, output)
    }

    private suspend fun publishChunk(
        items: List<JsonObject>,
        books: List<SearchBook>,
        output: ForegroundWebStreamOutput,
    ) {
        currentCoroutineContext().ensureActive()
        // searchFromSource only parses. Retain candidates before they can be opened by URL.
        // Incremental inserts do not clear another connection's or the native search's candidates.
        candidates.addSearchResults(books)
        currentCoroutineContext().ensureActive()
        output.send(JsonArray(items).toString())
    }

    private data class SourceResult(val books: List<SearchBook> = emptyList(), val error: String? = null)
}

/** Android SearchBook wire fields, without transient HTML pages or Kotlin-derived properties. */
private fun SearchBook.toWebJson(): JsonObject {
    val fields = listOf(bookUrl, origin, originName, name, author, kind, coverUrl, intro, wordCount,
        latestChapterTitle, tocUrl, variable, chapterWordCountText)
    require(fields.sumOf { it?.length?.toLong() ?: 0L } <= ForegroundWebStreamOutput.MAX_FRAME_BYTES) { "单条搜索结果过大" }
    return buildJsonObject {
        put("bookUrl", bookUrl)
        put("origin", origin)
        put("originName", originName)
        put("type", type)
        put("name", name)
        put("author", author)
        kind?.let { put("kind", it) }
        coverUrl?.let { put("coverUrl", it) }
        intro?.let { put("intro", it) }
        wordCount?.let { put("wordCount", it) }
        latestChapterTitle?.let { put("latestChapterTitle", it) }
        put("tocUrl", tocUrl)
        put("time", time)
        variable?.let { put("variable", it) }
        put("originOrder", originOrder)
        chapterWordCountText?.let { put("chapterWordCountText", it) }
        put("chapterWordCount", chapterWordCount)
        put("respondTime", respondTime)
    }
}
