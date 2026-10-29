package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.SearchWebBooksUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.getAndUpdate
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Streaming source-change search session with start/stop/restart semantics.
 *
 * Callbacks are serialized per session on background threads, not the UI thread.
 * Cross-source candidate order is unspecified; result order within a source is preserved.
 * Progress counts completed sources (including failures/timeouts); final progress precedes
 * onFinished. Every callback checks cancellation and generation; a callback already entered
 * cannot be revoked by stop/restart/dispose. Callers must also gate work they enqueue elsewhere.
 */
class SourceChangeSearchSession internal constructor(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val searchWebBooksUseCase: SearchWebBooksUseCase,
    private val book: Book,
    private val onCandidate: (BookSourceChangeCandidate) -> Unit,
    private val onProgress: (SourceChangeSearchProgress) -> Unit,
    private val onFinished: () -> Unit,
    private val preferencesStore: AppPreferencesStore,
    private val candidateLoader: SourceChangeCandidateLoader,
) {
    private data class SessionState(
        val generation: Long = 0L,
        val job: Job? = null,
        val disposed: Boolean = false,
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val state = MutableStateFlow(SessionState())
    private val callbackMutex = Mutex()

    val isSearching: Boolean get() = state.value.job?.isActive == true

    fun start() {
        startInternal(restart = false)
    }

    fun stop() {
        invalidate(dispose = false)
    }

    fun restart() {
        startInternal(restart = true)
    }

    fun refresh(candidates: List<BookSourceChangeCandidate>, onlyMissingWordCount: Boolean) {
        val selected = if (onlyMissingWordCount) candidates.filter { it.chapterWordCountText == null } else candidates.toList()
        startInternal(restart = true, refreshCandidates = selected)
    }

    fun dispose() {
        invalidate(dispose = true)
        scope.coroutineContext[Job]?.cancel()
    }

    private fun invalidate(dispose: Boolean) {
        val previous = state.getAndUpdate {
            it.copy(generation = it.generation + 1, job = null, disposed = it.disposed || dispose)
        }
        previous.job?.cancel()
    }

    private fun startInternal(restart: Boolean, refreshCandidates: List<BookSourceChangeCandidate>? = null) {
        while (true) {
            val previous = state.value
            if (previous.disposed) return
            // A lazily installed job also counts as running until its owner starts it.
            if (!restart && previous.job?.let { !it.isCompleted && !it.isCancelled } == true) return
            val generation = previous.generation + 1
            val nextJob = scope.launch(start = CoroutineStart.LAZY) { search(generation, refreshCandidates) }
            if (state.compareAndSet(previous, previous.copy(generation = generation, job = nextJob))) {
                previous.job?.cancel()
                nextJob.start()
                return
            }
            nextJob.cancel()
        }
    }

    private suspend fun search(generation: Long, refreshCandidates: List<BookSourceChangeCandidate>?) {
        // The mutex also serializes callbacks across generations; run data never escapes this job.
        val found = mutableSetOf<Pair<String, String>>()
        var searched = 0
        var total = 0
        var lastSourceName = ""
        var finish = true
        try {
            ensureCurrent(generation)
            val keyword = book.name.trim()
            val author = book.author.replace(Regex("^\\s*作\\s*者[:：\\s]+|\\s+著"), "")
            val config = preferencesStore.runtimeConfig.first()
            val allSources = getBookSourcesUseCase.getEnabled()
            val groupedSources = if (config.searchGroup.isBlank()) allSources else {
                getBookSourcesUseCase.getEnabledPartsByGroup(config.searchGroup).mapNotNull { part ->
                    allSources.firstOrNull { it.bookSourceUrl == part.bookSourceUrl }
                }.ifEmpty {
                    preferencesStore.setSearchGroup("")
                    allSources
                }
            }
            val sources = if (refreshCandidates == null) groupedSources else allSources
            ensureCurrent(generation)
            val work = refreshCandidates?.mapNotNull { candidate ->
                sources.firstOrNull { it.bookSourceUrl == candidate.sourceUrl }?.let { it to candidate }
            } ?: sources.map { it to null }
            total = work.size

            forEachSourceWithWorkers(work, config.threadCount) { (source, refreshCandidate) ->
                callbackMutex.withLock {
                    callback(generation, "onProgress") {
                        onProgress(SourceChangeSearchProgress(searched, total, source.bookSourceName))
                    }
                }
                ensureCurrent(generation)
                val enriched = loadCandidates(generation, source, keyword, author, refreshCandidate)
                callbackMutex.withLock {
                    ensureCurrent(generation)
                    for (result in enriched) {
                        if (found.add(result.sourceUrl to result.bookUrl)) {
                            callback(generation, "onCandidate") {
                                onCandidate(result)
                            }
                        }
                    }
                    searched += 1
                    lastSourceName = source.bookSourceName
                    callback(generation, "onProgress") {
                        onProgress(SourceChangeSearchProgress(searched, total, source.bookSourceName))
                    }
                }
            }
        } catch (error: Throwable) {
            findFacadeRequestCancellation(error)?.let {
                finish = false
                throw it
            }
            ensureCurrent(generation)
            CrashCollector.record("SourceChangeSearchSession", "search", error = error)
        } finally {
            if (finish && coroutineContext.isActive && state.value.generation == generation) {
                callbackMutex.withLock {
                    callback(generation, "onProgress") {
                        onProgress(SourceChangeSearchProgress(searched, total, lastSourceName))
                    }
                    callback(generation, "onFinished", onFinished)
                }
            }
        }
    }

    private suspend fun loadCandidates(
        generation: Long,
        source: BookSource,
        keyword: String,
        author: String,
        refreshCandidate: BookSourceChangeCandidate?,
    ): List<BookSourceChangeCandidate> {
        val enriched = mutableListOf<BookSourceChangeCandidate>()
        try {
            // The original source deadline includes search, details, TOC and optional body inspection.
            withTimeoutOrNull(60_000L) {
                val config = preferencesStore.runtimeConfig.first()
                if (refreshCandidate != null) {
                    enriched.add(candidateLoader.load(
                        source, candidateLoader.refreshBook(refreshCandidate, source), config, refresh = true))
                } else {
                    val results = searchSource(source, keyword)
                    for (result in results) {
                        ensureCurrent(generation)
                        val currentConfig = preferencesStore.runtimeConfig.first()
                        if (result.name == keyword && (!currentConfig.changeSourceCheckAuthor || result.author.contains(author))) {
                            enriched.add(candidateLoader.load(source, result, currentConfig))
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            ensureCurrent(generation)
            // Source-local failure/cancellation counts as completed work, not a cancelled picker.
            CrashCollector.record("SourceChangeSearchSession", "loadCandidate", error = error)
        }
        ensureCurrent(generation)
        return enriched
    }

    private suspend fun searchSource(source: BookSource, keyword: String): List<SearchBook> {
        return try {
            withTimeoutOrNull(60_000L) {
                val response = searchWebBooksUseCase.searchFromSource(source, keyword, page = 1)
                // Repositories may wrap cancellation in Result.failure instead of throwing it.
                coroutineContext.ensureActive()
                response.getOrThrow()
            } ?: emptyList()
        } catch (error: Throwable) {
            coroutineContext.ensureActive()
            // A source-local cancellation is a failed source while this search job is still active.
            if (findFacadeRequestCancellation(error) != null) return emptyList()
            CrashCollector.record(
                "SourceChangeSearchSession",
                "searchSource",
                params = mapOf("sourceUrl" to source.bookSourceUrl),
                error = error,
            )
            emptyList()
        }
    }

    // Called only while callbackMutex is held; callback failures must not skip onFinished.
    private suspend fun callback(generation: Long, method: String, block: () -> Unit) {
        ensureCurrent(generation)
        try {
            block()
        } catch (error: Throwable) {
            ensureCurrent(generation)
            findFacadeRequestCancellation(error)?.let { throw it }
            CrashCollector.record("SourceChangeSearchSession", method, error = error)
        }
    }

    private suspend fun ensureCurrent(generation: Long) {
        coroutineContext.ensureActive()
        if (state.value.generation != generation) {
            throw CancellationException("Source-change search session is no longer current")
        }
    }

    companion object
}
