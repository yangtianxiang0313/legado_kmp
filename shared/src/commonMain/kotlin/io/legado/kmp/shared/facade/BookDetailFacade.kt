package io.legado.kmp.shared.facade

import io.legado.kmp.shared.content.BookHelp
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.DeleteBookUseCase
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.GetBooksUseCase
import io.legado.kmp.shared.domain.usecase.LoadChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.ParseEpubLocalFileUseCase
import io.legado.kmp.shared.domain.localbook.EpubCatalogReflowPlan
import io.legado.kmp.shared.domain.usecase.EpubCatalogReflowPreparer
import io.legado.kmp.shared.domain.usecase.ParseTxtLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseMobiLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParsePdfLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseUmdLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.RefreshBookInfoUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.domain.usecase.SaveChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SearchUseCase
import io.legado.kmp.shared.domain.usecase.SearchWebBooksUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.model.isTxtLocalBook
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.coroutineContext

data class BookDetailRefreshResult(
    val book: Book,
    val chapters: List<BookChapter>,
    val epubReflowPlan: EpubCatalogReflowPlan? = null,
)

data class BookDetailVariableSnapshot(
    val bookUrl: String,
    val sourceUrl: String,
    val variable: String?,
    val comment: String?,
)

data class ChapterSourceChangeToc(
    val book: Book,
    val chapters: List<BookChapter>,
    val suggestedIndex: Int,
)

data class BookSourceChangeCandidate(
    val bookUrl: String,
    val sourceUrl: String,
    val sourceName: String,
    val displayName: String,
    val author: String,
    val latestChapterTitle: String? = null,
    val chapterWordCountText: String? = null,
    val respondTime: Int = -1,
    val chapterWordCount: Int = -1,
    val bookType: Int = BookType.TEXT,
)

/**
 * Progress update during source-change search.
 * @param searched number of sources searched so far
 * @param total total number of sources to search
 * @param currentSourceName name of the source currently being searched
 */
data class SourceChangeSearchProgress(
    val searched: Int,
    val total: Int,
    val currentSourceName: String,
)

/**
 * Result from cover search: a cover URL found at a particular book source.
 */
data class CoverSearchResult(
    val coverUrl: String,
    val sourceName: String,
    val sourceUrl: String,
)

/**
 * Progress update during cover search.
 */
data class CoverSearchProgress(
    val searched: Int,
    val total: Int,
    val found: Int,
)

/**
 * Streaming cover search session.
 * Searches all enabled book sources for covers matching a book's name+author.
 * Follows the same start/stop/restart pattern as [SourceChangeSearchSession].
 */
class CoverSearchSession internal constructor(
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val searchWebBooksUseCase: SearchWebBooksUseCase,
    private val book: Book,
    private val onResult: (CoverSearchResult) -> Unit,
    private val onProgress: (CoverSearchProgress) -> Unit,
    private val onFinished: () -> Unit,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null
    private val found = mutableSetOf<String>()

    val isSearching: Boolean get() = job?.isActive == true

    fun start() {
        if (job?.isActive == true) return
        found.clear()
        startInternal()
    }

    fun stop() {
        job?.cancel()
    }

    fun restart() {
        stop()
        found.clear()
        startInternal()
    }

    fun dispose() {
        job?.cancel()
        scope.coroutineContext[Job]?.cancel()
    }

    private fun startInternal() {
        job = scope.launch {
            try {
                val keyword = book.name.trim()
                val author = book.author.trim()
                val enabledSources = getBookSourcesUseCase.getEnabled()
                val total = enabledSources.size

                for ((index, source) in enabledSources.withIndex()) {
                    ensureActive()
                    onProgress(CoverSearchProgress(
                        searched = index,
                        total = total,
                        found = found.size,
                    ))
                    val results = searchWebBooksUseCase.searchFromSource(source, keyword, page = 1)
                        .getOrDefault(emptyList())
                        .filter { candidate ->
                            candidate.name.trim() == keyword &&
                                (author.isBlank() || candidate.author.trim() == author) &&
                                !candidate.coverUrl.isNullOrBlank()
                        }
                        .take(1)
                    for (result in results) {
                        val coverUrl = result.coverUrl ?: continue
                        if (found.add(coverUrl)) {
                            onResult(CoverSearchResult(
                                coverUrl = coverUrl,
                                sourceName = result.originName,
                                sourceUrl = result.origin,
                            ))
                        }
                    }
                }
                onProgress(CoverSearchProgress(
                    searched = total,
                    total = total,
                    found = found.size,
                ))
                onFinished()
            } catch (_: kotlin.coroutines.cancellation.CancellationException) {
                // Stopped by user – not an error
            }
        }
    }

    companion object
}

class BookDetailFacade(
    private val getBookUseCase: GetBookUseCase,
    private val getBooksUseCase: GetBooksUseCase,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val refreshBookInfoUseCase: RefreshBookInfoUseCase,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val deleteBookUseCase: DeleteBookUseCase,
    private val saveChaptersUseCase: SaveChaptersUseCase,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val searchUseCase: SearchUseCase,
    private val searchWebBooksUseCase: SearchWebBooksUseCase,
    private val parseTxtLocalFileUseCase: ParseTxtLocalFileUseCase,
    private val loadChapterContentUseCase: LoadChapterContentUseCase,
    private val bookChapterRepository: BookChapterRepository,
    private val chapterContentRepository: ChapterContentRepository,
    private val parseEpubLocalFileUseCase: ParseEpubLocalFileUseCase,
    private val preferencesStore: io.legado.kmp.shared.preferences.AppPreferencesStore,
    private val contentProcessor: io.legado.kmp.shared.domain.usecase.ContentProcessor,
    private val sourceStateStore: SourceStateStore? = null,
    private val parseMobiLocalFileUseCase: ParseMobiLocalFileUseCase,
    private val parsePdfLocalFileUseCase: ParsePdfLocalFileUseCase,
    private val parseUmdLocalFileUseCase: ParseUmdLocalFileUseCase,
    private val epubCatalogReflowPreparer: EpubCatalogReflowPreparer? = null,
) {
    private val sourceChangePreparationOwner = Any()

    fun watchBook(bookUrl: String, onUpdate: (Book?) -> Unit): FlowSubscription {
        return watchFlow(getBookUseCase(bookUrl), onUpdate, label = "BookDetailFacade.book")
    }

    fun watchChapters(bookUrl: String, onUpdate: (List<BookChapter>) -> Unit): FlowSubscription {
        return watchFlow(observeBookChaptersUseCase(bookUrl), onUpdate, label = "BookDetailFacade.chapters")
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resolveBook(bookUrl: String): Book? {
        return runRecoverable("BookDetailFacade.resolveBook") {
            getBookUseCase.get(bookUrl) ?: searchUseCase.getByBookUrl(bookUrl)?.toNotShelfBook()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resolvePersistedBook(bookUrl: String): Book? = runRecoverable("BookDetailFacade.resolvePersistedBook") {
        getBookUseCase.get(bookUrl)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun preparePreview(candidate: SearchBook): Book {
        return runRecoverable("BookDetailFacade.preparePreview") {
            require(candidate.bookUrl.isNotBlank()) { "Book URL is empty" }
            bookSaveMutex.withLock {
                getBookUseCase.get(candidate.bookUrl)
                    ?: saveBookUseCase.insertPreviewIfAbsent(candidate.toNotShelfBook())
            }
        }
    }

    /** Explicitly read again after preview exit; only a retained search candidate can rebuild a missing row. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepareReadingPreview(bookUrl: String): Book {
        return runRecoverable("BookDetailFacade.prepareReadingPreview") {
            require(bookUrl.isNotBlank()) { "Book URL is empty" }
            bookSaveMutex.withLock {
                val (book, persisted) = resolveBookWithPersistenceState(bookUrl)
                if (persisted) book else saveBookUseCase.insertPreviewIfAbsent(book)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshInfo(bookUrl: String): Book {
        return runRecoverable("BookDetailFacade.refreshInfo") {
            val book = requireBook(bookUrl)
            parseLocalChapters(book)?.let {
                return@runRecoverable saveRefreshedChapters(book, it).book
            }
            val source = requireSource(book)
            val refreshed = refreshBookInfoUseCase(source, book).getOrThrow()
            saveBookPreservingState(
                book, refreshed = refreshed, preserveChapterStats = true,
            )
        }
    }

    /** Delivers one terminal result on the completing thread, not necessarily the UI thread. */
    fun refreshInfoRequest(
        bookUrl: String,
        onResult: (BookDetailBookRequestResult) -> Unit,
    ): FlowSubscription = BookDetailBookRequest.start(
        refresh = { refreshInfo(bookUrl) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshChapters(bookUrl: String): BookDetailRefreshResult {
        return runRecoverable("BookDetailFacade.refreshChapters") {
            try {
                coroutineContext.ensureActive()
                val book = requireBook(bookUrl)
                coroutineContext.ensureActive()
                val refreshed = parseLocalChapters(book) ?: run {
                    val source = requireSource(book)
                    coroutineContext.ensureActive()
                    val result = fetchChapterListUseCase(source, book, runPreUpdateJs = true).getOrThrow()
                    BookDetailRefreshResult(result.book, result.chapters)
                }
                saveRefreshedChapters(book, refreshed)
            } catch (error: Throwable) {
                coroutineContext.ensureActive()
                findFacadeRequestCancellation(error)?.let { throw it }
                throw error
            }
        }
    }

    /** Delivers one terminal result on the completing thread, not necessarily the UI thread. */
    fun refreshChaptersRequest(
        bookUrl: String,
        onResult: (BookDetailChapterRequestResult) -> Unit,
    ): FlowSubscription = BookDetailChapterRequest.start(
        refresh = { refreshChapters(bookUrl) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun preloadChapters(bookUrl: String): BookDetailRefreshResult {
        return runRecoverable("BookDetailFacade.preloadChapters") {
            val (book, isPersistedBook) = resolveBookWithPersistenceState(bookUrl)
            val refreshed = parseLocalChapters(book) ?: run {
                val source = requireSource(book)
                val result = fetchChapterListUseCase(source, book, runPreUpdateJs = true).getOrThrow()
                BookDetailRefreshResult(result.book, result.chapters)
            }
            saveRefreshedChapters(book, refreshed, persist = isPersistedBook)
        }
    }

    private suspend fun parseLocalChapters(book: Book): BookDetailRefreshResult? {
        coroutineContext.ensureActive()
        val parsed = when {
            book.isTxtLocalBook -> parseTxtLocalFileUseCase(book).let { BookDetailRefreshResult(it.book, it.chapters) }
            book.isLocal && book.isEpub -> parseEpubLocalFileUseCase(book).let { BookDetailRefreshResult(it.book, it.chapters) }
            book.isLocal && book.bookUrl.substringAfterLast('.').lowercase() in setOf("mobi", "azw", "azw3") ->
                parseMobiLocalFileUseCase(book).let { BookDetailRefreshResult(it.book, it.chapters) }
            book.isLocal && book.bookUrl.endsWith(".pdf", true) ->
                parsePdfLocalFileUseCase(book).let { BookDetailRefreshResult(it.book, it.chapters) }
            book.isLocal && book.bookUrl.endsWith(".umd", true) ->
                parseUmdLocalFileUseCase(book).let { BookDetailRefreshResult(it.book, it.chapters) }
            else -> null
        }
        coroutineContext.ensureActive()
        return parsed?.let {
            BookDetailRefreshResult(
                it.book.copy(readConfig = book.readConfig?.copy()),
                orderParsedLocalChapters(book, it.chapters),
            )
        }
    }

    private suspend fun saveRefreshedChapters(
        book: Book,
        refreshed: BookDetailRefreshResult,
        persist: Boolean = true,
    ): BookDetailRefreshResult {
        coroutineContext.ensureActive()
        // Prepare source-derived offsets while cancellation still owns all I/O and parsing.
        // The repository rechecks the complete directory/profile inside its short write transaction.
        val reflow = if (book.isLocal && book.isEpub) epubCatalogReflowPreparer?.prepare(
            book, refreshed.book, observeBookChaptersUseCase(book.bookUrl).first(), refreshed.chapters,
        ) else null
        coroutineContext.ensureActive()
        val merged = bookSaveMutex.withLock {
            coroutineContext.ensureActive()
            reflow?.validate()
            coroutineContext.ensureActive()
            // Finish only local writes once started; waiting for the lock stays cancellable.
            withContext(NonCancellable) {
                saveBookPreservingStateLocked(
                    // Refresh callbacks cannot recreate a book removed by preview exit.
                    book, refreshed = refreshed.book, persist = persist,
                    chapters = refreshed.chapters,
                    epubReflowPlan = reflow?.plan,
                )
            }
        }
        coroutineContext.ensureActive()
        return BookDetailRefreshResult(merged, refreshed.chapters, reflow?.plan)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addToBookshelf(bookUrl: String): Book {
        return runRecoverable("BookDetailFacade.addToBookshelf") {
            val (book, wasPersisted) = resolveBookWithPersistenceState(bookUrl)
            saveBookPreservingState(book, isNotShelf = false, allowInsert = !wasPersisted)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun removeFromBookshelf(bookUrl: String) {
        runRecoverable("BookDetailFacade.removeFromBookshelf") {
            val book = requireBook(bookUrl)
            saveBookPreservingState(book, isNotShelf = true)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun completePreviewReadingExit(bookUrl: String, expectedOrigin: String, addToShelf: Boolean): Book? {
        return runRecoverable("BookDetailFacade.completePreviewReadingExit") {
            bookSaveMutex.withLock {
                saveBookUseCase.completePreviewReadingExit(bookUrl, expectedOrigin, addToShelf)
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateGroup(bookUrl: String, groupId: Long): Book {
        return runRecoverable("BookDetailFacade.updateGroup") {
            bookSaveMutex.withLock {
                saveBookUseCase.updateGroup(bookUrl, groupId) ?: error("Book not found: $bookUrl")
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadSourceChangeCandidates(bookUrl: String): List<BookSourceChangeCandidate> {
        return runRecoverable("BookDetailFacade.loadSourceChangeCandidates") {
            val book = requireBook(bookUrl)
            require(book.isLocal.not()) { "Local books do not support source switching" }
            val keyword = book.name.trim()
            require(keyword.isNotEmpty()) { "Book name is empty" }
            val enabledSources = getBookSourcesUseCase.getEnabled()
                .filter { it.bookSourceUrl != book.origin }
            val author = book.author.trim()
            enabledSources.flatMap { source ->
                searchWebBooksUseCase.searchFromSource(source, keyword, page = 1)
                    .getOrDefault(emptyList())
                    .filter { candidate ->
                        candidate.name.trim() == keyword &&
                            (author.isBlank() || candidate.author.trim() == author)
                    }
                    .take(3)
                    .map { candidate -> candidate.toSourceChangeCandidate() }
            }.distinctBy { "${it.sourceUrl}::${it.bookUrl}" }
        }
    }

    /**
     * Create a streaming source-change search session.
     * The session emits candidates and progress through callbacks.
     * Caller must call [SourceChangeSearchSession.start] to begin and
     * [SourceChangeSearchSession.dispose] when done.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun createSourceChangeSearchSession(
        bookUrl: String,
        onCandidate: (BookSourceChangeCandidate) -> Unit,
        onProgress: (SourceChangeSearchProgress) -> Unit,
        onFinished: () -> Unit,
        fromReader: Boolean = false,
    ): SourceChangeSearchSession {
        return runRecoverable("BookDetailFacade.createSourceChangeSearchSession") {
            val book = requireBook(bookUrl)
            require(book.isLocal.not()) { "Local books do not support source switching" }
            require(book.name.trim().isNotEmpty()) { "Book name is empty" }
            SourceChangeSearchSession(
                getBookSourcesUseCase = getBookSourcesUseCase,
                searchWebBooksUseCase = searchWebBooksUseCase,
                book = book,
                onCandidate = onCandidate,
                onProgress = onProgress,
                onFinished = onFinished,
                preferencesStore = preferencesStore,
                candidateLoader = SourceChangeCandidateLoader(
                    book = book,
                    oldChapters = bookChapterRepository.getChaptersByBookUrl(bookUrl),
                    fromReader = fromReader,
                    refreshBookInfo = refreshBookInfoUseCase,
                    fetchChapters = fetchChapterListUseCase,
                    loadContent = loadChapterContentUseCase,
                    contentProcessor = contentProcessor,
                ),
            )
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepareSourceChange(
        bookUrl: String,
        candidateBookUrl: String,
        sourceUrl: String,
    ): PreparedBookSourceChange {
        return runRecoverable("BookDetailFacade.prepareSourceChange") {
            try {
                coroutineContext.ensureActive()
                require(bookUrl.isNotBlank()) { "Book URL is empty" }
                require(candidateBookUrl.isNotBlank()) { "Replacement book URL is empty" }
                require(sourceUrl.isNotBlank()) { "Book source URL is empty" }
                val current = requireBook(bookUrl).sourceChangeSnapshot()
                require(!current.isLocal) { "Local books do not support source switching" }
                val source = requireNotNull(getBookSourcesUseCase.getByUrl(sourceUrl)) {
                    "Book source not found: $sourceUrl"
                }
                val candidate = searchUseCase.getByBookUrl(candidateBookUrl)?.takeIf { it.origin == sourceUrl }
                    ?: searchWebBooksUseCase.searchFromSource(source, current.name, page = 1).getOrThrow()
                        .firstOrNull { it.bookUrl == candidateBookUrl && it.origin == sourceUrl }
                    ?: error("Replacement source candidate not found")
                val candidateBook = candidate.toBook()
                val replacement = candidateBook.copy(
                    group = current.group,
                    order = current.order,
                    durChapterTitle = current.durChapterTitle,
                    durChapterIndex = current.durChapterIndex,
                    durChapterPos = current.durChapterPos,
                    durChapterTime = current.durChapterTime,
                    canUpdate = current.canUpdate,
                    readConfig = current.readConfig?.copy(),
                ).withSourceChangeTransientFrom(candidateBook)
                val result = fetchChapterListUseCase(source, replacement, runPreUpdateJs = true).getOrThrow()
                require(result.book.bookUrl.isNotBlank()) { "Replacement book URL must not be blank" }
                require(result.chapters.isNotEmpty()) { "Candidate source has no chapters" }
                // Same-type media keeps Android Book.migrateTo's millisecond or image-index anchor.
                val keepsMediaPosition = current.isAudio && result.book.isAudio || current.isImage && result.book.isImage
                val chapterPosition = if (keepsMediaPosition) current.durChapterPos else 0
                val migrated = result.book.migrateShelfStateFrom(current, result.chapters)
                    .copy(durChapterPos = chapterPosition).withSourceChangeTransientFrom(result.book)
                coroutineContext.ensureActive()
                PreparedBookSourceChange(current, migrated, result.chapters, sourceChangePreparationOwner)
            } catch (error: Throwable) {
                coroutineContext.ensureActive()
                findFacadeRequestCancellation(error)?.let { throw it }
                throw error
            }
        }
    }

    /** Delivers one terminal result on the completing thread, not necessarily the UI thread. */
    fun prepareSourceChangeRequest(
        bookUrl: String,
        candidateBookUrl: String,
        sourceUrl: String,
        onResult: (SourceChangePreparationResult) -> Unit,
    ): FlowSubscription = SourceChangePreparationRequest.start(
        prepare = { prepareSourceChange(bookUrl, candidateBookUrl, sourceUrl) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun commitSourceChange(prepared: PreparedBookSourceChange): BookDetailRefreshResult {
        return runRecoverable("BookDetailFacade.commitSourceChange") {
            bookSaveMutex.withLock {
                coroutineContext.ensureActive()
                val snapshot = prepared.consume(sourceChangePreparationOwner)
                // No dispatcher change or cancellation check may discard a committed result.
                withContext(NonCancellable) {
                    val persisted = saveBookUseCase.replaceSourceIfUnchanged(
                        snapshot.expectedBook, snapshot.book, snapshot.chapters,
                    ) ?: error("Book state changed or the destination already exists; select the source again")
                    BookDetailRefreshResult(
                        book = persisted.withSourceChangeTransientFrom(snapshot.book),
                        chapters = snapshot.chapters,
                    )
                }
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun changeSource(bookUrl: String, candidateBookUrl: String, sourceUrl: String): BookDetailRefreshResult {
        return runRecoverable("BookDetailFacade.changeSource") {
            commitSourceChange(prepareSourceChange(bookUrl, candidateBookUrl, sourceUrl))
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun autoChangeSource(bookUrl: String, chapterIndex: Int): BookDetailRefreshResult? {
        return runRecoverable("BookDetailFacade.autoChangeSource") {
            val current = requireBook(bookUrl)
            require(current.isLocal.not()) { "Local books do not support source switching" }
            val keyword = current.name.trim()
            require(keyword.isNotEmpty()) { "Book name is empty" }
            val author = current.author.trim()
            // Only discovery and readability checks share the overall network budget.
            val prepared = withTimeoutOrNull(AUTO_SOURCE_TOTAL_TIMEOUT_MS) preparation@{
                val currentChapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
                val normalizedIndex = chapterIndex.coerceInChapterList(currentChapters)
                val enabledSources = getBookSourcesUseCase.getEnabled()
                    .filter { it.bookSourceUrl != current.origin }

                for (source in enabledSources) {
                    coroutineContext.ensureActive()
                    val candidates = withAutoSourceNetworkTimeout(AUTO_SOURCE_SEARCH_TIMEOUT_MS) {
                        searchWebBooksUseCase.searchFromSource(source, keyword, page = 1).getOrThrow()
                    }?.filter { candidate ->
                        candidate.name.trim() == keyword &&
                            (author.isBlank() || candidate.author.trim() == author)
                    }?.take(3) ?: continue
                    for (candidate in candidates) {
                        coroutineContext.ensureActive()
                        val verified = verifyAutoSource(
                            current = current,
                            currentChapters = currentChapters,
                            requestedIndex = normalizedIndex,
                            source = source,
                            candidate = candidate,
                        )
                        if (verified != null) return@preparation verified
                    }
                }
                null
            }
            coroutineContext.ensureActive()
            if (prepared == null) return@runRecoverable null
            persistVerifiedAutoSource(current, prepared)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadChapterSourceToc(
        bookUrl: String,
        candidateBookUrl: String,
        sourceUrl: String,
        currentChapterIndex: Int,
    ): ChapterSourceChangeToc {
        return runRecoverable("BookDetailFacade.loadChapterSourceToc") {
            val current = requireBook(bookUrl)
            require(current.isLocal.not()) { "Local books do not support source switching" }
            val currentChapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
            val currentChapter = currentChapters.getOrNull(currentChapterIndex)
            val (candidateBook, candidateChapters) = fetchCandidateChapterList(current, candidateBookUrl, sourceUrl)
            val suggestedIndex = BookHelp.getDurChapter(
                oldDurChapterIndex = currentChapterIndex,
                oldDurChapterName = currentChapter?.title ?: current.durChapterTitle,
                newChapterList = candidateChapters,
                oldChapterListSize = currentChapters.size,
            ).coerceInChapterList(candidateChapters)
            ChapterSourceChangeToc(
                book = candidateBook,
                chapters = candidateChapters,
                suggestedIndex = suggestedIndex,
            )
        }
    }

    /** Delivers one terminal result on the completing thread, not necessarily the UI thread. */
    fun loadChapterSourceTocRequest(
        bookUrl: String,
        candidateBookUrl: String,
        sourceUrl: String,
        currentChapterIndex: Int,
        onResult: (ChapterSourceChangeTocResult) -> Unit,
    ): FlowSubscription = ChapterSourceChangeTocRequest.start(
        load = { loadChapterSourceToc(bookUrl, candidateBookUrl, sourceUrl, currentChapterIndex) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun replaceChapterContentFromSource(
        bookUrl: String,
        currentChapterIndex: Int,
        candidateBookUrl: String,
        sourceUrl: String,
        candidateChapterIndex: Int,
    ): String {
        return runRecoverable("BookDetailFacade.replaceChapterContentFromSource") {
            val current = requireBook(bookUrl)
            require(current.isLocal.not()) { "Local books do not support source switching" }
            val currentChapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
            val currentChapter = currentChapters.getOrNull(currentChapterIndex)
                ?: error("Current chapter not found")
            val (candidateBook, candidateChapters) = fetchCandidateChapterList(current, candidateBookUrl, sourceUrl)
            val source = requireNotNull(getBookSourcesUseCase.getByUrl(sourceUrl)) {
                "Book source not found: $sourceUrl"
            }
            val candidateChapter = candidateChapters.getOrNull(candidateChapterIndex)
                ?: error("Candidate chapter not found")
            val content = loadChapterContentUseCase(source, candidateBook, candidateChapter).getOrThrow()
            require(content.isNotBlank()) { "Chapter content is empty" }
            check(chapterContentRepository.saveContent(current, currentChapter, content)) {
                "Failed to save chapter content"
            }
            content
        }
    }

    private suspend fun fetchCandidateChapterList(
        current: Book,
        candidateBookUrl: String,
        sourceUrl: String,
    ): Pair<Book, List<BookChapter>> {
        val candidate = resolveSearchCandidate(current, candidateBookUrl, sourceUrl)
        val source = requireNotNull(getBookSourcesUseCase.getByUrl(candidate.origin)) {
            "Book source not found: ${candidate.origin}"
        }
        val candidateBook = candidate.toBook()
        val result = fetchChapterListUseCase(source, candidateBook, runPreUpdateJs = true).getOrThrow()
        require(result.chapters.isNotEmpty()) { "Candidate source has no chapters" }
        return result.book to result.chapters
    }

    private data class PreparedAutoSource(
        val book: Book,
        val chapters: List<BookChapter>,
        val chapterIndex: Int,
        val content: String,
    )

    private suspend fun <T> withAutoSourceNetworkTimeout(
        timeoutMillis: Long,
        block: suspend () -> T,
    ): T? {
        return try {
            withTimeoutOrNull(timeoutMillis) {
                coroutineContext.ensureActive()
                block().also { coroutineContext.ensureActive() }
            }
        } catch (_: TimeoutCancellationException) {
            // A nested request timeout is a failed candidate, not parent cancellation.
            coroutineContext.ensureActive()
            null
        } catch (error: kotlin.coroutines.cancellation.CancellationException) {
            throw error
        } catch (_: Exception) {
            coroutineContext.ensureActive()
            null
        }
    }

    private suspend fun verifyAutoSource(
        current: Book,
        currentChapters: List<BookChapter>,
        requestedIndex: Int,
        source: BookSource,
        candidate: SearchBook,
    ): PreparedAutoSource? {
        return withAutoSourceNetworkTimeout(AUTO_SOURCE_CANDIDATE_TIMEOUT_MS) {
            val replacement = candidate.toBook().copy(
                group = current.group,
                order = current.order,
                durChapterTitle = current.durChapterTitle,
                durChapterIndex = current.durChapterIndex,
                durChapterPos = current.durChapterPos,
                durChapterTime = current.durChapterTime,
                canUpdate = current.canUpdate,
            )
            val result = fetchChapterListUseCase(source, replacement, runPreUpdateJs = true).getOrThrow()
            val candidateChapters = result.chapters
            if (candidateChapters.isEmpty()) return@withAutoSourceNetworkTimeout null
            val oldChapter = currentChapters.getOrNull(requestedIndex)
            val targetIndex = BookHelp.getDurChapter(
                oldDurChapterIndex = requestedIndex,
                oldDurChapterName = oldChapter?.title ?: current.durChapterTitle,
                newChapterList = candidateChapters,
                oldChapterListSize = currentChapters.size,
            ).coerceInChapterList(candidateChapters)
            val candidateChapter = candidateChapters.getOrNull(targetIndex)
                ?: return@withAutoSourceNetworkTimeout null
            if (candidateChapter.isVolume) return@withAutoSourceNetworkTimeout null
            val content = loadChapterContentUseCase(source, result.book, candidateChapter).getOrThrow()
            if (content.isBlank()) return@withAutoSourceNetworkTimeout null
            PreparedAutoSource(result.book, candidateChapters, targetIndex, content)
        }
    }

    private suspend fun persistVerifiedAutoSource(
        current: Book,
        prepared: PreparedAutoSource,
    ): BookDetailRefreshResult? = bookSaveMutex.withLock {
        coroutineContext.ensureActive()
        val candidateChapter = prepared.chapters[prepared.chapterIndex]
        val migrated = prepared.book.migrateShelfStateFrom(current, prepared.chapters).copy(
            durChapterIndex = prepared.chapterIndex,
            durChapterTitle = candidateChapter.getDisplayTitle(),
            durChapterPos = 0,
        )
        coroutineContext.ensureActive()
        val persisted = saveBookUseCase.replaceSourceIfUnchanged(current, migrated, prepared.chapters)
            ?: return@withLock null
        // The database migration is committed. A cache failure must not report it as rolled back.
        withContext(NonCancellable) {
            try {
                check(chapterContentRepository.saveContent(persisted, candidateChapter, prepared.content)) {
                    "Failed to save chapter content"
                }
            } catch (error: Exception) {
                CrashCollector.record("BookDetailFacade", "cacheCommittedAutoSource", error = error)
            }
        }
        BookDetailRefreshResult(book = persisted, chapters = prepared.chapters)
    }

    private fun Book.migrateShelfStateFrom(oldBook: Book, newChapters: List<BookChapter>): Book {
        val newIndex = BookHelp.getDurChapter(oldBook, newChapters).coerceInChapterList(newChapters)
        return copy(
            type = (type and BookType.NOT_SHELF.inv()) or (oldBook.type and BookType.NOT_SHELF),
            durChapterIndex = newIndex,
            durChapterTitle = newChapters.getOrNull(newIndex)?.getDisplayTitle() ?: oldBook.durChapterTitle,
            durChapterPos = oldBook.durChapterPos,
            durChapterTime = oldBook.durChapterTime,
            group = oldBook.group,
            order = oldBook.order,
            originOrder = oldBook.originOrder,
            customCoverUrl = oldBook.customCoverUrl,
            customIntro = oldBook.customIntro,
            customTag = oldBook.customTag,
            charset = oldBook.charset,
            canUpdate = oldBook.canUpdate,
            readConfig = oldBook.readConfig?.copy(),
            syncTime = oldBook.syncTime,
        )
    }

    private fun Int.coerceInChapterList(chapters: List<BookChapter>): Int {
        return if (chapters.isEmpty()) this.coerceAtLeast(0) else coerceIn(0, chapters.lastIndex)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadVariableEditor(bookUrl: String, expectedSourceUrl: String, forSource: Boolean): BookDetailVariableSnapshot {
        return runRecoverable("BookDetailFacade.loadVariableEditor") {
            val book = requireVariableBook(bookUrl, expectedSourceUrl)
            val source = requireSource(book)
            val value = if (forSource) requireNotNull(sourceStateStore).getSourceVariable(source.bookSourceUrl)
                else book.variableMap["custom"].orEmpty()
            coroutineContext.ensureActive()
            BookDetailVariableSnapshot(book.bookUrl, source.bookSourceUrl, value, source.variableComment)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveSourceVariable(bookUrl: String, expectedSourceUrl: String, value: String) {
        runRecoverable("BookDetailFacade.saveSourceVariable") {
            val book = requireVariableBook(bookUrl, expectedSourceUrl)
            val source = requireSource(book)
            coroutineContext.ensureActive()
            requireNotNull(sourceStateStore).setSourceVariable(source.bookSourceUrl, value)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveCustomBookVariable(bookUrl: String, expectedSourceUrl: String, value: String): Book {
        return runRecoverable("BookDetailFacade.saveCustomBookVariable") {
            val book = requireVariableBook(bookUrl, expectedSourceUrl)
            requireSource(book)
            saveBookUseCase.updateCustomVariable(bookUrl, expectedSourceUrl, value)
        }
    }

    private suspend fun requireVariableBook(bookUrl: String, expectedSourceUrl: String): Book {
        val book = requireBook(bookUrl)
        check(!book.isLocal && book.origin == expectedSourceUrl) { "Book source changed or is unavailable" }
        return book
    }

    /**
     * 置顶书籍：将书籍的 order 设置为当前所有书籍中最小值 - 1，使其排在最前
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun pinToTop(bookUrl: String): Book {
        return runRecoverable("BookDetailFacade.pinToTop") {
            val book = requireBook(bookUrl)
            val minOrder = getBooksUseCase.getAll().minOfOrNull { it.order } ?: 0
            val pinned = book.copy(order = minOrder - 1)
            saveBookUseCase.update(pinned)
            pinned
        }
    }

    /**
     * 切换允许更新状态：翻转 Book.canUpdate 字段
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun toggleCanUpdate(bookUrl: String): Book {
        return runRecoverable("BookDetailFacade.toggleCanUpdate") {
            val book = requireBook(bookUrl)
            val toggled = book.copy(canUpdate = !book.canUpdate)
            saveBookUseCase.update(toggled)
            toggled
        }
    }

    /**
     * Set the per-book page animation override.
     * Mirrors legado ReadBookActivity menu_page_anim: -1 means default, 0...4 map to concrete modes.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setPageAnimation(bookUrl: String, pageAnimation: Int): Book {
        return runRecoverable("BookDetailFacade.setPageAnimation") {
            val book = requireBook(bookUrl)
            val normalized = pageAnimation.coerceIn(-1, 4)
            saveBookUseCase.updatePageAnimation(book.bookUrl, book.origin, normalized)
        }
    }

    /** Persist only the simulation settings while retaining the latest book and reading configuration. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateReadSimulation(
        bookUrl: String,
        expectedOrigin: String,
        enabled: Boolean,
        startDateIso: String,
        startChapter: Int,
        dailyChapters: Int,
    ): Book {
        return runRecoverable("BookDetailFacade.updateReadSimulation") {
            bookSaveMutex.withLock {
                saveBookUseCase.updateReadSimulation(
                    bookUrl, expectedOrigin, enabled, startDateIso, startChapter, dailyChapters,
                )
            }
        }
    }

    /** 仅更新编辑字段，null 保持原值，并保留最新书籍的其他字段。 */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateBookInfo(
        bookUrl: String,
        name: String? = null,
        author: String? = null,
        coverUrl: String? = null,
        intro: String? = null,
    ): Book {
        return runRecoverable("BookDetailFacade.updateBookInfo") {
            bookSaveMutex.withLock {
                persistEditedBookInfo(bookUrl, name, author, coverUrl, intro, null)
            }
        }
    }

    /** 保存编辑字段并保留其他状态及类型位；bookType 为 0 正文 / 1 音频 / 2 图片。 */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveEditedBookInfo(
        bookUrl: String,
        name: String,
        author: String,
        coverUrl: String,
        intro: String,
        bookType: Int,
    ): Book {
        return runRecoverable("BookDetailFacade.saveEditedBookInfo") {
            bookSaveMutex.withLock {
                persistEditedBookInfo(bookUrl, name, author, coverUrl, intro, bookType)
            }
        }
    }

    private suspend fun persistEditedBookInfo(
        bookUrl: String,
        name: String?,
        author: String?,
        coverUrl: String?,
        intro: String?,
        bookType: Int?,
    ): Book {
        require(bookType == null || bookType in 0..2) { "Book type must be an index from 0 to 2" }
        val current = requireBook(bookUrl)
        val oldFolder = current.getCacheFolderName()
        val newFolder = current.copy(name = name ?: current.name).getCacheFolderName()
        val movedCache = oldFolder != newFolder && chapterContentRepository.listCacheFolders().contains(oldFolder)
        coroutineContext.ensureActive()
        // Cache paths contain the title. Complete the move and database write as one save operation.
        return withContext(NonCancellable) {
            check(chapterContentRepository.moveCacheFolder(oldFolder, newFolder)) {
                "Failed to move book cache; book info was not saved"
            }
            try {
                saveBookUseCase.updateBookInfo(bookUrl, name, author, coverUrl, intro, bookType)
                    ?: error("Book not found: $bookUrl")
            } catch (error: Throwable) {
                if (movedCache && !chapterContentRepository.moveCacheFolder(newFolder, oldFolder)) {
                    error.addSuppressed(IllegalStateException("Failed to restore book cache after save failure"))
                }
                throw error
            }
        }
    }

    /**
     * Create a streaming cover search session.
     * Searches all enabled sources for covers matching the book's name+author.
     * Caller must call [CoverSearchSession.start] to begin and
     * [CoverSearchSession.dispose] when done.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun createCoverSearchSession(
        bookUrl: String,
        onResult: (CoverSearchResult) -> Unit,
        onProgress: (CoverSearchProgress) -> Unit,
        onFinished: () -> Unit,
    ): CoverSearchSession {
        return runRecoverable("BookDetailFacade.createCoverSearchSession") {
            val book = requireBook(bookUrl)
            require(book.name.trim().isNotEmpty()) { "Book name is empty" }
            CoverSearchSession(
                getBookSourcesUseCase = getBookSourcesUseCase,
                searchWebBooksUseCase = searchWebBooksUseCase,
                book = book,
                onResult = onResult,
                onProgress = onProgress,
                onFinished = onFinished,
            )
        }
    }

    /**
     * 清除缓存：删除该书籍所有章节的正文内容缓存
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun clearCache(bookUrl: String) {
        runRecoverable("BookDetailFacade.clearCache") {
            val book = requireBook(bookUrl)
            val chapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
            chapters.forEach { chapter ->
                chapterContentRepository.deleteContent(book, chapter)
            }
        }
    }

    private suspend fun requireBook(bookUrl: String): Book {
        return resolveBook(bookUrl) ?: error("Book not found: $bookUrl")
    }

    private suspend fun resolveBookWithPersistenceState(bookUrl: String): Pair<Book, Boolean> {
        getBookUseCase.get(bookUrl)?.let { return it to true }
        searchUseCase.getByBookUrl(bookUrl)?.toNotShelfBook()?.let { return it to false }
        error("Book not found: $bookUrl")
    }

    private fun SearchBook.toNotShelfBook(): Book {
        return toBook().copy(type = type or BookType.NOT_SHELF).also {
            it.infoHtml = infoHtml
            it.tocHtml = tocHtml
        }
    }

    private suspend fun saveBookPreservingState(
        book: Book,
        refreshed: Book? = null,
        isNotShelf: Boolean? = null,
        persist: Boolean = true,
        preserveChapterStats: Boolean = false,
        allowInsert: Boolean = false,
    ): Book = bookSaveMutex.withLock {
        saveBookPreservingStateLocked(book, refreshed, isNotShelf, persist, preserveChapterStats, allowInsert)
    }

    private suspend fun saveBookPreservingStateLocked(
        book: Book,
        refreshed: Book? = null,
        isNotShelf: Boolean? = null,
        persist: Boolean = true,
        preserveChapterStats: Boolean = false,
        allowInsert: Boolean = false,
        chapters: List<BookChapter>? = null,
        epubReflowPlan: EpubCatalogReflowPlan? = null,
    ): Book {
        // Refresh may finish after a shelf action or reading/configuration update.
        val persisted = getBookUseCase.get(book.bookUrl)
        val current = persisted ?: book
        val incoming = refreshed ?: current
        val notShelf = isNotShelf ?: current.isNotShelf
        val merged = incoming.copy(
            name = incoming.name.ifBlank { current.name },
            author = incoming.author.ifBlank { current.author },
            kind = incoming.kind?.takeIf { it.isNotBlank() } ?: current.kind,
            coverUrl = incoming.coverUrl?.takeIf { it.isNotBlank() } ?: current.coverUrl,
            intro = incoming.intro?.takeIf { it.isNotBlank() } ?: current.intro,
            wordCount = incoming.wordCount?.takeIf { it.isNotBlank() } ?: current.wordCount,
            type = (incoming.type and BookType.NOT_SHELF.inv()) or
                (if (notShelf) BookType.NOT_SHELF else 0),
            group = current.group,
            order = current.order,
            originOrder = current.originOrder,
            totalChapterNum = if (preserveChapterStats) current.totalChapterNum else incoming.totalChapterNum,
            latestChapterTitle = incoming.latestChapterTitle?.takeIf { it.isNotBlank() } ?: current.latestChapterTitle,
            latestChapterTime = if (preserveChapterStats) current.latestChapterTime else incoming.latestChapterTime,
            lastCheckCount = if (preserveChapterStats) current.lastCheckCount else incoming.lastCheckCount,
            lastCheckTime = if (preserveChapterStats) current.lastCheckTime else incoming.lastCheckTime,
            durChapterTitle = current.durChapterTitle,
            durChapterIndex = current.durChapterIndex,
            durChapterPos = current.durChapterPos,
            durChapterTime = current.durChapterTime,
            customCoverUrl = current.customCoverUrl,
            customIntro = current.customIntro,
            customTag = current.customTag,
            charset = current.charset,
            canUpdate = current.canUpdate,
            readConfig = current.readConfig,
            syncTime = current.syncTime,
        ).also {
            it.infoHtml = incoming.infoHtml
            it.tocHtml = incoming.tocHtml
            it.downloadUrls = incoming.downloadUrls
        }
        return if (persist || persisted != null) {
            // The source check, metadata update, and optional directory replacement share one transaction.
            saveBookUseCase.ifSourceUnchanged(book, merged, chapters, allowInsert, epubReflowPlan).also {
                it.infoHtml = merged.infoHtml
                it.tocHtml = merged.tocHtml
                it.downloadUrls = merged.downloadUrls
            }
        } else {
            merged
        }
    }

    private suspend fun requireSource(book: Book): BookSource {
        return requireNotNull(getBookSourcesUseCase.getByUrl(book.origin)) {
            "Book source not found: ${book.origin}"
        }
    }

    private suspend fun resolveSearchCandidate(current: Book, candidateBookUrl: String, sourceUrl: String): SearchBook {
        searchUseCase.getByBookUrl(candidateBookUrl)?.takeIf { it.origin == sourceUrl }?.let { return it }
        val source = requireNotNull(getBookSourcesUseCase.getByUrl(sourceUrl)) { "Book source not found: $sourceUrl" }
        return searchWebBooksUseCase.searchFromSource(source, current.name, page = 1)
            .getOrDefault(emptyList())
            .firstOrNull { it.bookUrl == candidateBookUrl }
            ?: error("Replacement source candidate not found")
    }

    private companion object {
        const val AUTO_SOURCE_SEARCH_TIMEOUT_MS = 10_000L
        const val AUTO_SOURCE_CANDIDATE_TIMEOUT_MS = 15_000L
        const val AUTO_SOURCE_TOTAL_TIMEOUT_MS = 30_000L
        val bookSaveMutex = Mutex()
    }
}

internal fun SearchBook.toSourceChangeCandidate(): BookSourceChangeCandidate {
    return BookSourceChangeCandidate(
        bookUrl = bookUrl,
        sourceUrl = origin,
        sourceName = originName,
        displayName = name,
        author = author,
        latestChapterTitle = latestChapterTitle,
        chapterWordCountText = chapterWordCountText,
        respondTime = respondTime,
        chapterWordCount = chapterWordCount,
        bookType = type,
    )
}
