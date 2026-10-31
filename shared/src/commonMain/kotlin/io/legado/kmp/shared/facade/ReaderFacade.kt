package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ContentProcessor
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.GetPayActionUseCase
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.usecase.LoadChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadEpubLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadMobiLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadPdfLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadTxtLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadUmdLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.ParseEpubLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseMobiLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParsePdfLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseTxtLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.ParseUmdLocalFileUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.domain.usecase.SaveChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SearchUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookmarkUseCase
import io.legado.kmp.shared.domain.usecase.GetBookmarksUseCase
import io.legado.kmp.shared.domain.usecase.DeleteBookmarkUseCase
import io.legado.kmp.shared.domain.usecase.UpdateReadingProgressUseCase
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.Bookmark
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.model.ReadConfig
import io.legado.kmp.shared.model.ReplaceRule
import io.legado.kmp.shared.model.isTxtLocalBook
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ReaderFacade(
    private val getBookUseCase: GetBookUseCase,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
    private val loadChapterContentUseCase: LoadChapterContentUseCase,
    private val updateReadingProgressUseCase: UpdateReadingProgressUseCase,
    private val getPayActionUseCase: GetPayActionUseCase,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val saveChaptersUseCase: SaveChaptersUseCase,
    private val saveBookmarkUseCase: SaveBookmarkUseCase,
    private val getBookmarksUseCase: GetBookmarksUseCase,
    private val deleteBookmarkUseCase: DeleteBookmarkUseCase,
    private val searchUseCase: SearchUseCase,
    private val parseTxtLocalFileUseCase: ParseTxtLocalFileUseCase,
    private val loadTxtLocalChapterContentUseCase: LoadTxtLocalChapterContentUseCase,
    private val parseEpubLocalFileUseCase: ParseEpubLocalFileUseCase,
    private val loadEpubLocalChapterContentUseCase: LoadEpubLocalChapterContentUseCase,
    private val parsePdfLocalFileUseCase: ParsePdfLocalFileUseCase,
    private val loadPdfLocalChapterContentUseCase: LoadPdfLocalChapterContentUseCase,
    private val parseUmdLocalFileUseCase: ParseUmdLocalFileUseCase,
    private val loadUmdLocalChapterContentUseCase: LoadUmdLocalChapterContentUseCase,
    private val parseMobiLocalFileUseCase: ParseMobiLocalFileUseCase,
    private val loadMobiLocalChapterContentUseCase: LoadMobiLocalChapterContentUseCase,
    private val chapterContentRepository: ChapterContentRepository,
    private val contentProcessor: ContentProcessor,
    private val preferencesStore: AppPreferencesStore,
    private val settingsFacade: SettingsFacade,
    private val readRecordRepository: ReadRecordRepository,
    private val paginationService: ReaderPaginationService = ReaderPaginationService(),
    private val chapterImages: CacheChapterImages? = null,
) {
    private val configurationSupport = ReaderConfigurationSupport(
        getBookSourcesUseCase = getBookSourcesUseCase,
        saveBookUseCase = saveBookUseCase,
        preferencesStore = preferencesStore,
    )

    private val progressPersistence = ReaderProgressPersistence(
        getBookUseCase = getBookUseCase,
        observeBookChaptersUseCase = observeBookChaptersUseCase,
        updateReadingProgressUseCase = updateReadingProgressUseCase,
        applyReplaceRulesUseCase = applyReplaceRulesUseCase,
        preferencesStore = preferencesStore,
        settingsFacade = settingsFacade,
    )

    private val chapterLoader = ReaderChapterLoader(
        getBookUseCase = getBookUseCase,
        observeBookChaptersUseCase = observeBookChaptersUseCase,
        fetchChapterListUseCase = fetchChapterListUseCase,
        loadChapterContentUseCase = loadChapterContentUseCase,
        getBookSourcesUseCase = getBookSourcesUseCase,
        applyReplaceRulesUseCase = applyReplaceRulesUseCase,
        saveBookUseCase = saveBookUseCase,
        saveChaptersUseCase = saveChaptersUseCase,
        searchUseCase = searchUseCase,
        parseTxtLocalFileUseCase = parseTxtLocalFileUseCase,
        loadTxtLocalChapterContentUseCase = loadTxtLocalChapterContentUseCase,
        parseEpubLocalFileUseCase = parseEpubLocalFileUseCase,
        loadEpubLocalChapterContentUseCase = loadEpubLocalChapterContentUseCase,
        parsePdfLocalFileUseCase = parsePdfLocalFileUseCase,
        loadPdfLocalChapterContentUseCase = loadPdfLocalChapterContentUseCase,
        parseUmdLocalFileUseCase = parseUmdLocalFileUseCase,
        loadUmdLocalChapterContentUseCase = loadUmdLocalChapterContentUseCase,
        parseMobiLocalFileUseCase = parseMobiLocalFileUseCase,
        loadMobiLocalChapterContentUseCase = loadMobiLocalChapterContentUseCase,
        chapterContentRepository = chapterContentRepository,
        contentProcessor = contentProcessor,
        preferencesStore = preferencesStore,
        chapterImages = chapterImages,
    )

    private val contentEditing = ReaderContentEditingSupport(
        getBookUseCase, observeBookChaptersUseCase, saveChaptersUseCase,
        chapterContentRepository, applyReplaceRulesUseCase, chapterLoader,
    )

    private val chapterListSupport = ReaderChapterListSupport(
        requireBook = { requireBook(it) },
        observeBookChaptersUseCase = observeBookChaptersUseCase,
        applyReplaceRulesUseCase = applyReplaceRulesUseCase,
        preferencesStore = preferencesStore,
        chapterContentRepository = chapterContentRepository,
        getBookUseCase = getBookUseCase,
        getBookmarksUseCase = getBookmarksUseCase,
        saveBookUseCase = saveBookUseCase,
        chapterImages = chapterImages,
        invalidateChapterIndices = {
            chapterLoader.clearLoadingState(it)
            progressPersistence.clearSnapshots()
        },
    )

    private val bookContentSearch = ReaderBookContentSearch(
        chapterLoader = chapterLoader,
        observeBookChaptersUseCase = observeBookChaptersUseCase,
        readRawContent = ReaderContentSearchSource(
            chapterContentRepository = chapterContentRepository,
            loadTxtLocalChapterContentUseCase = loadTxtLocalChapterContentUseCase,
            loadEpubLocalChapterContentUseCase = loadEpubLocalChapterContentUseCase,
            loadUmdLocalChapterContentUseCase = loadUmdLocalChapterContentUseCase,
            loadMobiLocalChapterContentUseCase = loadMobiLocalChapterContentUseCase,
        )::read,
        applyReplaceRulesUseCase = applyReplaceRulesUseCase,
        preferencesStore = preferencesStore,
    )

    private val readTimeSupport = ReaderReadTimeSupport(
        getBookUseCase = getBookUseCase,
        readRecordRepository = readRecordRepository,
        preferencesStore = preferencesStore,
    )

    private val chapterPreload = ReaderChapterPreload(chapterLoader)

    // S14: Non-exception status message channel (e.g., "Loading...", "Downloading images...")
    private val _readerMessage = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val readerMessage: SharedFlow<String> = _readerMessage.asSharedFlow()

    // S23: Web/WebDAV synced progress, used by setProgress()
    var webBookProgress: BookProgress?
        get() = progressPersistence.webBookProgress
        set(value) {
            progressPersistence.webBookProgress = value
        }

    // --- S05: Simulated chapter size ---

    /**
     * Compute the simulated chapter size based on readConfig simulation settings.
     * Aligns with legado BookExtensions.simulatedTotalChapterNum().
     */
    fun computeSimulatedChapterSize(readConfig: ReadConfig?, realChapterSize: Int): Int {
        return configurationSupport.computeSimulatedChapterSize(readConfig, realChapterSize)
    }

    // --- S16/S21/M34: Read record / read time ---

    /** Synchronous and non-throwing. Repeated begins for the active book are idempotent. */
    fun beginReadSession(bookUrl: String) {
        readTimeSupport.beginReadSession(bookUrl)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun endReadSession(bookUrl: String) = runRecoverable("ReaderFacade.endReadSession") {
        cancelPreDownloadTask()
        readTimeSupport.endReadSession(bookUrl)
    }

    /**
     * Emit a non-exception status message to the reader UI.
     * Mirrors legado ReadBook.upMsg().
     */
    fun upMsg(msg: String) {
        _readerMessage.tryEmit(msg)
    }

    /**
     * Persist only the elapsed portion of an explicitly begun visible reading session.
     * An instance that has never begun a session has nothing to record.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateReadTime(bookUrl: String) = runRecoverable("ReaderFacade.updateReadTime") {
        readTimeSupport.updateReadTime(bookUrl)
    }

    /**
     * Refresh book data from DB after external changes (e.g., chapter list update).
     * Mirrors legado ReadBook.upData(book):
     * - Re-reads book from DB
     * - Updates chapterSize and simulatedChapterSize
     * - Clears loading/download tracking
     * - Calls upWebBook logic (imageStyle / pageAnim from source contentRule)
     * - Returns whether chapters changed and the new counts
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun upData(bookUrl: String): UpDataResult = runRecoverable("ReaderFacade.upData") {
        cancelPreDownloadTask()
        val book = getBookUseCase.get(bookUrl) ?: error("Book not found: $bookUrl")
        val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
        val oldChapterSize = chapters.size
        val newChapterSize = chapters.size
        val simSize = computeSimulatedChapterSize(book.readConfig, newChapterSize)
        // Clear loading/download tracking as legado does
        chapterLoader.clearLoadingState(bookUrl)
        // M03: upWebBook — set imageStyle and pageAnim from source contentRule
        upWebBook(book)
        readTimeSupport.prepareRecord(book)
        UpDataResult(
            chaptersChanged = oldChapterSize != newChapterSize,
            newChapterCount = newChapterSize,
            simulatedChapterSize = simSize,
        )
    }

    /**
     * Initialize book source and image style settings.
     * Mirrors legado ReadBook.upWebBook(book):
     * - For local books: sets imageStyle to FULL if book is image or PDF and no style set
     * - For web books: reads source contentRule.imageStyle, applies it, and if SINGLE sets pageAnim=0
     */
    private suspend fun upWebBook(book: Book) {
        configurationSupport.upWebBook(book)
    }

    /**
     * Update reader config based on book type.
     * Mirrors legado ReadBook.upReadBookConfig(book):
     * - Detects if book is image/manga type and adjusts config accordingly
     * - Returns whether the config was changed (so iOS can reload UI)
     */
    suspend fun upReadBookConfig(bookUrl: String): Boolean {
        return try {
            val book = getBookUseCase.get(bookUrl) ?: return false
            book.isImage
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "upReadBookConfig", error = e)
            false
        }
    }

    fun watchBook(bookUrl: String, onUpdate: (Book?) -> Unit): FlowSubscription {
        return watchFlow(getBookUseCase(bookUrl), onUpdate, label = "ReaderFacade.book")
    }

    fun watchChapters(bookUrl: String, onUpdate: (List<BookChapter>) -> Unit): FlowSubscription {
        return watchFlow(observeBookChaptersUseCase(bookUrl), onUpdate, label = "ReaderFacade.chapters")
    }

    fun watchChapterListChanges(bookUrl: String, onChange: () -> Unit): FlowSubscription =
        watchFlow(chapterListSupport.chapterListChanges(bookUrl), { onChange() }, label = "ReaderFacade.chapterListChanges")

    fun watchBookmarks(bookUrl: String, onUpdate: (List<Bookmark>) -> Unit): FlowSubscription =
        watchFlow(chapterListSupport.bookmarks(bookUrl), onUpdate, label = "ReaderFacade.bookmarks")

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadChapter(bookUrl: String, chapterIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.loadChapter") {
            loadPreparedChapter(bookUrl, chapterIndex, refreshContent = false)
        }
    }

    private suspend fun loadPreparedChapter(
        bookUrl: String,
        chapterIndex: Int,
        refreshContent: Boolean,
        requestedProgress: ReaderProgressWrite? = null,
    ): ReaderChapterPayload {
        requestedProgress?.let { progressPersistence.requireProgressTarget(it) }
        val prepared = chapterLoader.prepareChapter(bookUrl, chapterIndex, refreshContent)
        val displayBook = if (requestedProgress == null) {
            progressPersistence.persistLoadedProgress(current = prepared.currentBook, updated = prepared.payload.book)
        } else {
            progressPersistence.resolveRequestedProgress(requestedProgress, prepared)
        }
        if (prepared.preloadAdjacent) {
            try {
                preloadAdjacentChapters(bookUrl, prepared.payload.book.durChapterIndex, preDownloadNum = 1)
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                throw e
            } catch (_: Exception) {
                // Preload is best-effort
            }
        }
        val finalBook = if (requestedProgress != null && prepared.preloadAdjacent) {
            progressPersistence.resolveRequestedProgress(requestedProgress, prepared)
        } else displayBook
        return prepared.payload.copy(book = finalBook)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun peekChapter(bookUrl: String, chapterIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.peekChapter") {
            chapterLoader.prepareChapter(bookUrl, chapterIndex, refreshContent = false).payload
        }
    }

    /** Prepares display content without saving progress or starting adjacent preloads. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepareChapter(
        bookUrl: String,
        chapterIndex: Int,
        refreshContent: Boolean,
    ): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.prepareChapter") {
            coroutineContext.ensureActive()
            val prepared = try {
                chapterLoader.prepareChapter(bookUrl, chapterIndex, refreshContent)
            } catch (error: Throwable) {
                coroutineContext.ensureActive()
                findReaderChapterCancellation(error)?.let { throw it }
                throw error
            }
            coroutineContext.ensureActive()
            prepared.payload
        }
    }

    /** Delivers one terminal result on the completing thread, not necessarily the UI thread. */
    fun prepareChapterRequest(
        bookUrl: String,
        chapterIndex: Int,
        refreshContent: Boolean,
        onResult: (ReaderChapterRequestResult) -> Unit,
    ): FlowSubscription = ReaderChapterRequest.start(
        prepare = { prepareChapter(bookUrl, chapterIndex, refreshContent) },
        onResult = onResult,
    )

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshChapterContent(bookUrl: String, chapterIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.refreshChapterContent") {
            loadPreparedChapter(bookUrl, chapterIndex, refreshContent = true)
        }
    }

    /**
     * 刷新从 fromIndex 开始到末尾的所有章节内容缓存，然后重新加载当前章节。
     * Mirrors legado ReadBookActivity "刷新之后章节" handling.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshChapterContentFromIndex(bookUrl: String, fromIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.refreshChapterContentFromIndex") {
            val resolvedBook = requireBook(bookUrl)
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            require(chapters.isNotEmpty()) { "No chapters found for $bookUrl" }
            val normalizedFrom = fromIndex.coerceIn(0, chapters.lastIndex)
            for (i in normalizedFrom..chapters.lastIndex) {
                coroutineContext.ensureActive()
                chapterContentRepository.deleteContent(resolvedBook, chapters[i])
            }
            loadChapter(bookUrl, normalizedFrom)
        }
    }

    /**
     * 刷新所有章节内容缓存，然后重新加载当前章节。
     * Mirrors legado ReadBookActivity "刷新全部章节" handling.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun refreshAllChapterContent(bookUrl: String, currentIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.refreshAllChapterContent") {
            val resolvedBook = requireBook(bookUrl)
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            require(chapters.isNotEmpty()) { "No chapters found for $bookUrl" }
            for (chapter in chapters) {
                coroutineContext.ensureActive()
                chapterContentRepository.deleteContent(resolvedBook, chapter)
            }
            val normalizedIndex = currentIndex.coerceIn(0, chapters.lastIndex)
            loadChapter(bookUrl, normalizedIndex)
        }
    }

    /**
     * Download a single chapter's content to cache, checking if already cached first.
     * Mirrors legado ReadBook.downloadIndex().
     * M27: downloadIndex(bookUrl, chapterIndex).
     *
     * @param bookUrl the book URL
     * @param chapterIndex the chapter index to download
     */
    suspend fun downloadIndex(bookUrl: String, chapterIndex: Int) {
        chapterLoader.downloadIndex(bookUrl, chapterIndex)
    }

    /**
     * Cancel any running preload/pre-download tasks.
     * Mirrors legado ReadBook.cancelPreDownloadTask().
     * M31: cancelPreDownloadTask.
     */
    fun cancelPreDownloadTask() {
        chapterPreload.cancel()
    }

    /**
     * Preload adjacent chapters around the current reading position.
     * A negative preDownloadNum uses the persisted runtime configuration; zero disables prefetch.
     * Aligns with legado ReadBook.preDownload().
     * M28/M29: Uses downloadSemaphore for concurrency control.
     *
     * @param preDownloadNum forward count (0..9999), with at most five backward chapters
     */
    @Throws(Exception::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun preloadAdjacentChapters(bookUrl: String, chapterIndex: Int, preDownloadNum: Int = -1) {
        val count = if (preDownloadNum < 0) preferencesStore.runtimeConfig.first().preDownloadNum else preDownloadNum
        chapterPreload.run(bookUrl, chapterIndex, count)
    }

    /** Completes the displayed chapter's raw-cache images, then max(persisted N, 1) adjacent chapters. */
    @Throws(Exception::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun cacheDisplayedChapter(bookUrl: String, chapterIndex: Int) {
        val count = preferencesStore.runtimeConfig.first().preDownloadNum
        chapterPreload.run(bookUrl, chapterIndex, count, includeCurrent = true)
    }

    /**
     * Load current + prev + next chapters concurrently.
     * Mirrors legado ReadBook.loadContent(resetPageOffset) which loads
     * durChapterIndex, durChapterIndex+1, durChapterIndex-1.
     *
     * @return the payload for the current (center) chapter
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadContentTriple(bookUrl: String, chapterIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.loadContentTriple") {
            coroutineScope {
                val prevJob = if (chapterIndex > 0) {
                    launch {
                        try { peekChapter(bookUrl, chapterIndex - 1) } catch (_: Exception) {}
                    }
                } else null
                val nextJob = launch {
                    try { peekChapter(bookUrl, chapterIndex + 1) } catch (_: Exception) {}
                }
                val current = loadChapter(bookUrl, chapterIndex)
                // Wait for adjacent loads to complete (best-effort)
                prevJob?.join()
                nextJob.join()
                current
            }
        }
    }

    /**
     * Load chapter content if not already cached; otherwise return cached content.
     * Mirrors legado ReadBook.loadOrUpContent(): if content is already available,
     * returns it immediately; otherwise loads from network.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadOrUpContent(bookUrl: String, chapterIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.loadOrUpContent") {
            chapterLoader.cachedChapterPayload(bookUrl, chapterIndex) ?: loadChapter(bookUrl, chapterIndex)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun updateReadingProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPosition: Int,
    ) {
        runRecoverable("ReaderFacade.updateReadingProgress") {
            progressPersistence.updateReadingProgress(
                bookUrl = bookUrl,
                current = requireBook(bookUrl),
                chapterIndex = chapterIndex,
                chapterTitle = chapterTitle,
                chapterPosition = chapterPosition,
            )
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun loadChapterListState(bookUrl: String): List<ReaderChapterListItem> =
        runRecoverable("ReaderFacade.loadChapterListState") { chapterListSupport.loadChapterListState(bookUrl) }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun reverseChapterList(bookUrl: String): BookDetailRefreshResult {
        return runRecoverable("ReaderFacade.reverseChapterList") {
            cancelPreDownloadTask()
            chapterListSupport.reverseChapterList(bookUrl)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun paginateChapter(
        chapterIndex: Int,
        chapterTitle: String,
        content: String,
        style: io.legado.kmp.shared.preferences.ReaderStylePreferences,
        runtime: io.legado.kmp.shared.preferences.ReaderRuntimeConfig,
        viewport: ReaderViewport,
        imageStyle: String? = null,
    ): ReaderChapterLayout {
        return runRecoverable("ReaderFacade.paginateChapter") {
            withContext(Dispatchers.Default) {
                val capturedCoroutine = coroutineContext
                paginationService.paginate(
                    chapterIndex = chapterIndex,
                    chapterTitle = chapterTitle,
                    content = content,
                    config = ReaderPaginationConfig.from(style, runtime, imageStyle),
                    viewport = viewport,
                    checkActive = { capturedCoroutine.ensureActive() },
                )
            }
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun requestPayAction(bookUrl: String, chapterIndex: Int): String {
        return runRecoverable("ReaderFacade.requestPayAction") {
            val book = requireBook(bookUrl)
            require(!book.isTxtLocalBook) { "TXT local books do not provide pay actions" }
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            val chapter = chapters.getOrNull(chapterIndex.coerceIn(0, chapters.lastIndex))
                ?: error("Chapter not found: $chapterIndex")
            getPayActionUseCase(requireSource(book), book, chapter).getOrThrow()
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun addBookmark(
        bookUrl: String,
        chapterIndex: Int,
        chapterPosition: Int,
        pageText: String,
    ) {
        runRecoverable("ReaderFacade.addBookmark") {
            val book = requireBook(bookUrl)
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            val normalizedIndex = if (chapters.isEmpty()) {
                chapterIndex.coerceAtLeast(0)
            } else {
                chapterIndex.coerceIn(0, chapters.lastIndex)
            }
            val resolvedChapter = chapters.getOrNull(normalizedIndex)
            val chapterName = resolvedChapter?.let { resolveDisplayChapterTitle(book, it, applyReplaceRulesUseCase) }
                ?: book.durChapterTitle.orEmpty()
            saveBookmarkUseCase.create(
                bookName = book.name,
                bookAuthor = book.author,
                chapterIndex = normalizedIndex,
                chapterPos = chapterPosition.coerceAtLeast(0),
                chapterName = chapterName,
                bookText = pageText.trim(),
            )
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getBookmarks(bookUrl: String): List<Bookmark> {
        return runRecoverable("ReaderFacade.getBookmarks") {
            val book = requireBook(bookUrl)
            getBookmarksUseCase.getByBook(book.name, book.author)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun deleteBookmark(bookmarkTime: Long) {
        runRecoverable("ReaderFacade.deleteBookmark") {
            deleteBookmarkUseCase(bookmarkTime)
        }
    }

    /**
     * 反转当前章节内容（用于部分网站内容被反转加密的情况）
     * 将章节内容的文字行逐行反转后重新保存，然后重新加载章节
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun reverseContent(bookUrl: String, chapterIndex: Int): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.reverseContent") {
            val book = requireBook(bookUrl)
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            require(chapters.isNotEmpty()) { "No chapters found for $bookUrl" }
            val normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
            val chapter = chapters[normalizedIndex]
            // 获取当前缓存的原文内容
            val content = chapterContentRepository.getContent(book, chapter)
            if (content != null) {
                // 将内容按行反转
                val reversed = StringBuilder()
                content.lines().forEach { line ->
                    reversed.insert(0, line + "\n")
                }
                // 保存反转后的内容
                chapterContentRepository.saveContent(book, chapter, reversed.toString().trimEnd())
            }
            // 重新加载章节
            loadChapter(bookUrl, normalizedIndex)
        }
    }

    /**
     * 获取当前对此书生效的替换规则列表
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getEffectiveReplaceRules(bookUrl: String): List<ReplaceRule> {
        return runRecoverable("ReaderFacade.getEffectiveReplaceRules") {
            val book = requireBook(bookUrl)
            val useReplace = book.config.useReplaceRule ?: defaultUseReplaceRule(book)
            if (!useReplace) {
                return@runRecoverable emptyList()
            }
            applyReplaceRulesUseCase.getApplicableRules(book.origin)
        }
    }

    /**
     * Apply replace rules to arbitrary text for the given book.
     * Used by F52 (text selection replace).
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun applyReplaceRules(bookUrl: String, text: String): String {
        return runRecoverable("ReaderFacade.applyReplaceRules") {
            val book = requireBook(bookUrl)
            val useReplace = book.config.useReplaceRule ?: defaultUseReplaceRule(book)
            if (!useReplace) {
                return@runRecoverable text
            }
            applyReplaceRulesUseCase.applyToContent(text, book.origin)
        }
    }

    /**
     * Persist the charset, invalidating local chapters when it changes. The caller reloads afterward,
     * mirroring legado ReadBook.setCharset() calling callBack.loadChapterList().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setCharset(bookUrl: String, charset: String): Book {
        return runRecoverable("ReaderFacade.setCharset") {
            chapterLoader.setCharset(bookUrl, charset)
        }
    }

    /**
     * Set whether to remove duplicate title for a specific chapter.
     * Mirrors legado BookHelp.setRemoveSameTitle().
     * After toggling, the chapter should be reloaded to reflect the change.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setRemoveSameTitle(bookUrl: String, chapterIndex: Int, removeSameTitle: Boolean) {
        runRecoverable("ReaderFacade.setRemoveSameTitle") {
            val book = requireBook(bookUrl)
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            require(chapters.isNotEmpty()) { "No chapters found for $bookUrl" }
            val normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
            val chapter = chapters[normalizedIndex]
            chapterContentRepository.setRemoveSameTitle(book, chapter, removeSameTitle)
        }
    }

    suspend fun toggleReplaceRule(bookUrl: String): Book {
        return runRecoverable("ReaderFacade.toggleReplaceRule") {
            val book = requireBook(bookUrl)
            val defaultValue = defaultUseReplaceRule(book)
            val updated = book.copy(
                readConfig = book.config.copy(
                    useReplaceRule = !(book.config.useReplaceRule ?: defaultValue)
                )
            )
            saveBookUseCase(updated)
            updated
        }
    }

    /**
     * Toggle a delTag bit on the book's ReadConfig.
     * Mirrors legado ReadBookActivity menu_del_ruby_tag / menu_del_h_tag handling.
     */
    suspend fun toggleDelTag(bookUrl: String, tag: Long): Book {
        return runRecoverable("ReaderFacade.toggleDelTag") {
            configurationSupport.toggleDelTag(requireBook(bookUrl), tag)
        }
    }

    /**
     * 保存编辑后的章节内容到缓存，然后重新加载章节。
     * Mirrors legado ContentEditDialog.save() → BookHelp.saveText().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveChapterContent(bookUrl: String, chapterIndex: Int, content: String): ReaderChapterPayload {
        return runRecoverable("ReaderFacade.saveChapterContent") {
            contentEditing.save(bookUrl, chapterIndex, content)
            loadChapter(bookUrl, chapterIndex)
        }
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun saveChapterContentChecked(
        bookUrl: String, chapterIndex: Int, expectedChapterUrl: String, content: String,
    ): ReaderChapterPayload = runRecoverable("ReaderFacade.saveChapterContentChecked") {
        contentEditing.saveChecked(bookUrl, chapterIndex, expectedChapterUrl, content)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun renameChapterTitle(
        bookUrl: String, chapterIndex: Int, expectedChapterUrl: String, title: String,
    ): ReaderChapterPayload = runRecoverable("ReaderFacade.renameChapterTitle") {
        contentEditing.rename(bookUrl, chapterIndex, expectedChapterUrl, title)
    }

    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resetChapterContentChecked(
        bookUrl: String, chapterIndex: Int, expectedChapterUrl: String,
    ): ReaderChapterPayload = runRecoverable("ReaderFacade.resetChapterContentChecked") {
        contentEditing.resetChecked(bookUrl, chapterIndex, expectedChapterUrl)
    }

    /**
     * 切换重新分段标记。
     * Mirrors legado ReadBookActivity menu_re_segment handling.
     */
    suspend fun toggleReSegment(bookUrl: String): Book {
        return runRecoverable("ReaderFacade.toggleReSegment") {
            val book = requireBook(bookUrl)
            val updated = book.copy(
                readConfig = book.config.copy(
                    reSegment = !book.config.reSegment
                )
            )
            saveBookUseCase(updated)
            updated
        }
    }

    /**
     * 获取当前章节的原始内容（用于编辑）。
     * 返回经过 ContentProcessor 处理后的内容文本。
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getChapterRawContent(bookUrl: String, chapterIndex: Int): String {
        return runRecoverable("ReaderFacade.getChapterRawContent") {
            contentEditing.processedCachedContent(bookUrl, chapterIndex)
        }
    }

    /**
     * Content search retaining the original book/default replacement semantics.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchInBook(
        bookUrl: String,
        keyword: String,
        onResult: (ContentSearchResult) -> Unit,
        onFinished: () -> Unit,
    ) {
        runRecoverable("ReaderFacade.searchInBook") {
            bookContentSearch.search(bookUrl, keyword, null, onResult, onFinished)
        }
    }

    /** Android content-search options are per search, never persisted to the book or preferences. */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun searchInBookWithOptions(
        bookUrl: String,
        keyword: String,
        replaceEnabled: Boolean,
        onResult: (ContentSearchResult) -> Unit,
        onFinished: () -> Unit,
    ) {
        runRecoverable("ReaderFacade.searchInBookWithOptions") {
            bookContentSearch.search(bookUrl, keyword, replaceEnabled, onResult, onFinished)
        }
    }

    fun searchInBookRequest(
        bookUrl: String,
        keyword: String,
        onResult: (ContentSearchResult) -> Unit,
        onFinished: (ReaderContentSearchCompletion) -> Unit,
    ): FlowSubscription = bookContentSearch.start(bookUrl, keyword, null, onResult, onFinished)

    fun searchInBookWithOptionsRequest(
        bookUrl: String,
        keyword: String,
        replaceEnabled: Boolean,
        onResult: (ContentSearchResult) -> Unit,
        onFinished: (ReaderContentSearchCompletion) -> Unit,
    ): FlowSubscription = bookContentSearch.start(bookUrl, keyword, replaceEnabled, onResult, onFinished)

    /**
     * Set the image style for a book.
     * Mirrors legado ReadBookActivity menu_image_style handling.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setImageStyle(bookUrl: String, imageStyle: String): Book {
        return runRecoverable("ReaderFacade.setImageStyle") {
            configurationSupport.setImageStyle(requireBook(bookUrl), imageStyle)
        }
    }

    /**
     * Save the current book progress before a jump (e.g., search result navigation).
     * If lastBookProgress is already set, does nothing — preserves the original position
     * across consecutive jumps. Mirrors legado ReadBook.saveCurrentBookProgress().
     */
    suspend fun saveCurrentBookProgress(bookUrl: String) {
        progressPersistence.saveCurrentBookProgress(bookUrl)
    }

    /**
     * Restore the progress saved by [saveCurrentBookProgress].
     * Returns a new [ReaderChapterPayload] if progress actually changed, null otherwise.
     * Mirrors legado ReadBook.restoreLastBookProgress().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun restoreLastBookProgress(bookUrl: String): ReaderChapterPayload? {
        val progress = progressPersistence.takeLastBookProgress() ?: return null
        return setProgress(bookUrl, progress)
    }

    /**
     * Apply a [BookProgress] to the current book, updating chapter index and position.
     * Only acts if the progress actually differs from the current state and the target
     * chapter index is in range. Returns a new [ReaderChapterPayload] on change, null if no-op.
     * Mirrors legado ReadBook.setProgress().
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun setProgress(bookUrl: String, progress: BookProgress): ReaderChapterPayload? {
        return runRecoverable("ReaderFacade.setProgress") {
            val book = requireBook(bookUrl)
            val written = progressPersistence.setProgress(bookUrl, book, progress) ?: return@runRecoverable null
            // An explicit jump owns its display anchor; preparation must not persist it again.
            loadPreparedChapter(bookUrl, written.book.durChapterIndex, refreshContent = false, requestedProgress = written)
        }
    }

    /**
     * Sync reading progress with WebDAV server.
     * Three-way comparison mirrors legado ReadBook.syncProgress():
     * - If server progress is behind or absent → upload local progress
     * - If server progress is ahead → return [SyncProgressResult.ServerAhead] for user confirmation
     * - If identical → return [SyncProgressResult.InSync]
     */
    suspend fun syncProgress(bookUrl: String): SyncProgressResult {
        return progressPersistence.syncProgress(bookUrl)
    }

    private suspend fun requireBook(bookUrl: String): Book {
        return chapterLoader.requireBook(bookUrl)
    }

    private suspend fun requireSource(book: Book): BookSource {
        return chapterLoader.requireSource(book)
    }

    private suspend fun defaultUseReplaceRule(book: Book): Boolean {
        return chapterLoader.defaultUseReplaceRule(book)
    }

    // --- M18: onPageChanged ---

    /**
     * Called when the reader page changes.
     * Updates read time and triggers preload of adjacent chapters.
     * Aligns with legado ReadBook.curPageChanged().
     */
    suspend fun onPageChanged(bookUrl: String) {
        try {
            updateReadTime(bookUrl)
            preloadAdjacentChapters(bookUrl, getBookUseCase.get(bookUrl)?.durChapterIndex ?: 0)
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "onPageChanged", error = e)
        }
    }

    // --- M32: upToc / refreshTocIfNeeded ---

    /**
     * Refresh the table of contents if near the end and last check was long ago.
     * Aligns with legado ReadBook.upToc():
     * - Only refreshes if <= 3 chapters remaining
     * - Only refreshes if last check was >= 10 minutes ago (600000 ms)
     * - Only refreshes if book canUpdate
     *
     * @return true if TOC was refreshed with new chapters
     */
    suspend fun refreshTocIfNeeded(bookUrl: String): Boolean {
        return chapterLoader.refreshTocIfNeeded(bookUrl)
    }

    // --- M33: onChapterListUpdated ---

    /**
     * Handle chapter list changes: clamp durChapterIndex to valid range, reload content.
     * Aligns with legado ReadBook.onChapterListUpdated().
     */
    suspend fun onChapterListUpdated(bookUrl: String) {
        try {
            val book = getBookUseCase.get(bookUrl) ?: return
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            if (chapters.isEmpty()) return
            val simSize = computeSimulatedChapterSize(book.readConfig, chapters.size)
            val clampedIndex = if (simSize > 0 && book.durChapterIndex >= simSize) {
                simSize - 1
            } else {
                book.durChapterIndex.coerceIn(0, chapters.lastIndex)
            }
            if (clampedIndex != book.durChapterIndex) {
                val chapter = chapters[clampedIndex]
                val displayTitle = resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
                val updated = book.updateReadingProgress(clampedIndex, displayTitle, 0)
                progressPersistence.persistProgressIfChanged(current = book, updated = updated)
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "onChapterListUpdated", error = e)
        }
    }

    // --- M11/M12/M13: moveToNextChapter / moveToPrevChapter ---

    /**
     * Move to the next chapter.
     * Mirrors legado ReadBook.moveToNextChapter():
     * - Increments durChapterIndex, resets durChapterPos to 0
     * - Saves reading progress
     * - Loads the new chapter content
     * - Triggers preload of the next+1 chapter
     *
     * @return [ChapterNavigationResult] with success=false if already at last chapter
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun moveToNextChapter(bookUrl: String): ChapterNavigationResult {
        return runRecoverable("ReaderFacade.moveToNextChapter") {
            var book = requireBook(bookUrl)
            var chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            if (chapters.isEmpty()) return@runRecoverable ChapterNavigationResult(success = false)
            var simSize = computeSimulatedChapterSize(book.readConfig, chapters.size)
            var effectiveSize = simSize
            if (effectiveSize <= 0) return@runRecoverable ChapterNavigationResult(success = false)
            if (book.durChapterIndex >= effectiveSize - 1) {
                if (!refreshTocIfNeeded(bookUrl)) {
                    return@runRecoverable ChapterNavigationResult(success = false)
                }
                book = requireBook(bookUrl)
                chapters = observeBookChaptersUseCase(bookUrl).firstValue()
                if (chapters.isEmpty()) return@runRecoverable ChapterNavigationResult(success = false)
                simSize = computeSimulatedChapterSize(book.readConfig, chapters.size)
                effectiveSize = simSize
                if (book.durChapterIndex >= effectiveSize - 1) {
                    return@runRecoverable ChapterNavigationResult(success = false)
                }
            }
            val newIndex = book.durChapterIndex + 1
            val chapter = chapters[newIndex]
            val displayTitle = resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
            val updatedBook = book.updateReadingProgress(newIndex, displayTitle, 0)
            progressPersistence.persistProgressIfChanged(current = book, updated = updatedBook)
            clearExpiredLoadingJobs(newIndex)
            val payload = loadChapter(bookUrl, newIndex)
            // Preload next+1
            try {
                preloadAdjacentChapters(bookUrl, newIndex)
            } catch (_: Exception) {}
            ChapterNavigationResult(success = true, payload = payload)
        }
    }

    /**
     * Move to the previous chapter.
     * Mirrors legado ReadBook.moveToPrevChapter():
     * - Decrements durChapterIndex
     * - Sets durChapterPos to 0, or the previous chapter's last position when toLast=true
     * - Saves reading progress
     * - Loads the new chapter content
     * - Triggers preload of the prev-1 chapter
     *
     * @param toLast when true, jump to the previous chapter's last page; matches legado's
     * prevTextChapter?.lastReadLength ?: Int.MAX_VALUE fallback.
     * @return [ChapterNavigationResult] with success=false if already at first chapter
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun moveToPrevChapter(bookUrl: String, toLast: Boolean = true): ChapterNavigationResult {
        return runRecoverable("ReaderFacade.moveToPrevChapter") {
            val book = requireBook(bookUrl)
            if (book.durChapterIndex <= 0) {
                return@runRecoverable ChapterNavigationResult(success = false)
            }
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            if (chapters.isEmpty()) return@runRecoverable ChapterNavigationResult(success = false)
            val readable = computeSimulatedChapterSize(book.readConfig, chapters.size)
            if (readable <= 0) return@runRecoverable ChapterNavigationResult(success = false)
            val newIndex = (book.durChapterIndex - 1).coerceIn(0, readable - 1)
            val chapter = chapters[newIndex]
            val displayTitle = resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
            val chapterPosition = if (toLast) Int.MAX_VALUE else 0
            val updatedBook = book.updateReadingProgress(newIndex, displayTitle, chapterPosition)
            progressPersistence.persistProgressIfChanged(current = book, updated = updatedBook)
            clearExpiredLoadingJobs(newIndex)
            val payload = loadChapter(bookUrl, newIndex)
            // Preload prev-1
            try {
                preloadAdjacentChapters(bookUrl, newIndex)
            } catch (_: Exception) {}
            ChapterNavigationResult(success = true, payload = payload)
        }
    }

    // --- M25/M26: contentLoadFinish ---

    /**
     * Handle content load completion for a specific chapter index.
     * Determines the relative position (prev/cur/next) based on the current reading index
     * and returns which position was updated.
     * Mirrors legado ReadBook.contentLoadFinish() which assigns to prev/cur/nextTextChapter
     * based on offset from durChapterIndex.
     *
     * @return the [RelativePosition] that was updated, or null if the chapter is out of range
     */
    suspend fun contentLoadFinish(bookUrl: String, chapterIndex: Int): RelativePosition? {
        return try {
            val book = getBookUseCase.get(bookUrl) ?: return null
            val offset = chapterIndex - book.durChapterIndex
            when (offset) {
                0 -> RelativePosition.CUR
                -1 -> RelativePosition.PREV
                1 -> RelativePosition.NEXT
                else -> null
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "contentLoadFinish", mapOf("bookUrl" to bookUrl, "chapterIndex" to chapterIndex.toString()), e)
            null
        }
    }

    // --- C03/C04: upContent ---

    /**
     * Refresh/reload content at the given relative position (prev=-1, cur=0, next=1).
     * Mirrors legado ReadBook.loadOrUpContent() per-position logic.
     * Returns the payload for the requested position, or null if not applicable.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun upContent(bookUrl: String, relativePosition: Int): ReaderChapterPayload? {
        return runRecoverable("ReaderFacade.upContent") {
            val book = getBookUseCase.get(bookUrl) ?: return@runRecoverable null
            val targetIndex = book.durChapterIndex + relativePosition
            if (targetIndex < 0) return@runRecoverable null
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            if (chapters.isEmpty() || targetIndex > chapters.lastIndex) return@runRecoverable null
            loadOrUpContent(bookUrl, targetIndex)
        }
    }

    // --- M19: readAloud / getReadAloudContent ---

    /**
     * Get the text content of a chapter suitable for TTS (read aloud).
     * Extracts plain text from the processed chapter content, stripping HTML tags and images.
     * Mirrors legado ReadAloud content extraction from TextChapter pages.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getReadAloudContent(bookUrl: String, chapterIndex: Int, pageIndex: Int): String {
        return runRecoverable("ReaderFacade.getReadAloudContent") {
            val book = requireBook(bookUrl)
            val chapters = observeBookChaptersUseCase(bookUrl).firstValue()
            if (chapters.isEmpty()) return@runRecoverable ""
            val normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
            val chapter = chapters[normalizedIndex]
            val rawContent = chapterContentRepository.getContent(book, chapter) ?: return@runRecoverable ""
            val displayTitle = resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
            val useReplace = book.config.useReplaceRule ?: defaultUseReplaceRule(book)
            val processed = chapterLoader.processContent(
                book = book, chapter = chapter,
                content = rawContent, displayTitle = displayTitle,
                useReplace = useReplace,
            )
            // Strip HTML and return plain text suitable for TTS
            processed.content
                .replace(Regex("""<img[^>]*>""", RegexOption.IGNORE_CASE), "")
                .replace(Regex("""<[^>]+>"""), "")
                .trim()
        }
    }

    // --- A01-A03, A06: TTS/ReadAloud support ---

    /**
     * Split chapter text into paragraphs for TTS consumption.
     * Each paragraph becomes one TTS utterance.
     * Mirrors legado's approach of splitting content into individual lines for reading aloud.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun getReadAloudParagraphs(bookUrl: String, chapterIndex: Int): List<String> {
        return runRecoverable("ReaderFacade.getReadAloudParagraphs") {
            val plainText = getReadAloudContent(bookUrl, chapterIndex, 0)
            if (plainText.isBlank()) return@runRecoverable emptyList()
            plainText
                .replace("\r\n", "\n")
                .replace('\r', '\n')
                .split('\n')
                .map { it.trim() }
                .filter { it.isNotEmpty() }
        }
    }

    // --- M48: releaseAndCancel ---

    /**
     * Release all resources held by this facade instance.
     * Ends any active reading session and clears loading guards, downloads and progress snapshots.
     * Mirrors legado ReadBook.releaseAndCancel().
     * Should be called when the reader is dismissed.
     */
    suspend fun releaseAndCancel() {
        try {
            try {
                readTimeSupport.endActiveSession()
            } finally {
                cancelPreDownloadTask()
                chapterLoader.clearLoadingState()
                progressPersistence.clearSnapshots()
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "releaseAndCancel", error = e)
        }
    }

    /** Get the current TTS configuration from preferences. */
    suspend fun getReadAloudConfig(): ReadAloudConfig {
        return configurationSupport.getReadAloudConfig()
    }

    /** Persist the TTS speech rate, clamped to the existing 0-45 scale. */
    suspend fun setTtsSpeechRate(rate: Int) {
        configurationSupport.setTtsSpeechRate(rate)
    }

    /** Persist the reading stop timer in minutes; zero disables the timer. */
    suspend fun setReadTimer(minutes: Int) {
        configurationSupport.setReadTimer(minutes)
    }

    // --- M49: clearExpiredLoadingJobs ---

    /**
     * Remove loading entries that are outside the current reading window.
     * Prevents stale loading guards from blocking future loads after jumps.
     * Mirrors legado ReadBook.clearExpiredChapterLoadingJob().
     *
     * @param currentIndex the current chapter index
     * @param windowSize the half-window size to keep (default 3)
     * @param clearAll if true, clears all loading entries regardless of window
     */
    suspend fun clearExpiredLoadingJobs(currentIndex: Int, windowSize: Int = 3, clearAll: Boolean = false) {
        chapterLoader.clearExpiredLoadingJobs(currentIndex, windowSize, clearAll)
    }
}

private suspend fun <T> kotlinx.coroutines.flow.Flow<T>.firstValue(): T {
    return first()
}
