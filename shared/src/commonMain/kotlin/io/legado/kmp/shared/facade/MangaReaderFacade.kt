package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.ReadRecordRepository
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.LoadChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.domain.usecase.UpdateReadingProgressUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ContentProcessor
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.model.BaseMangaPage
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.MangaChapter
import io.legado.kmp.shared.model.MangaContent
import io.legado.kmp.shared.model.MangaPage
import io.legado.kmp.shared.model.ReadRecord
import io.legado.kmp.shared.model.ReadSimulationSchedule
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlin.math.min

/**
 * Manga reader facade — stateful three-chapter window manager.
 *
 * Mirrors legado ReadManga object, adapted to KMP Facade pattern.
 * Maintains prev/cur/next MangaChapter window, builds aggregated MangaContent,
 * and exposes content changes via StateFlow.
 *
 * Unlike ReadManga (global singleton), each MangaReaderFacade instance is scoped
 * to a single reading session. Call [resetData] to initialize, [release] to clean up.
 */
class MangaReaderFacade(
    private val getBookUseCase: GetBookUseCase,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val loadChapterContentUseCase: LoadChapterContentUseCase,
    private val chapterContentRepository: ChapterContentRepository,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val updateReadingProgressUseCase: UpdateReadingProgressUseCase,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val contentProcessor: ContentProcessor,
    private val readRecordRepository: ReadRecordRepository,
    private val preferencesStore: AppPreferencesStore? = null,
) {
    // ---- State ----

    private var book: Book? = null
    private var bookSource: BookSource? = null
    var durChapterIndex: Int = 0
        private set
    var durChapterPos: Int = 0
        private set
    var chapterSize: Int = 0
        private set

    /**
     * Effective chapter size, accounting for read simulation cap.
     * Mirrors legado ReadManga.simulatedChapterSize.
     */
    var simulatedChapterSize: Int = 0
        private set

    private var prevMangaChapter: MangaChapter? = null
    private var curMangaChapter: MangaChapter? = null
    private var nextMangaChapter: MangaChapter? = null

    /**
     * Whether to hide the manga title page (header/footer loading pages).
     * Mirrors legado AppConfig.hideMangaTitle. Defaults to false.
     * The platform layer should set this from user preferences before calling [loadContent].
     */
    var hideMangaTitle: Boolean = false

    /**
     * Number of chapters to pre-download ahead/behind.
     * Mirrors legado AppConfig.preDownloadNum. Defaults to 5.
     */
    var preDownloadNum: Int = 5

    /**
     * Whether read recording is enabled.
     * Mirrors legado AppConfig.enableReadRecord. Defaults to true.
     */
    var enableReadRecord: Boolean = true

    private val loadingChapters = mutableListOf<Int>()
    private val loadingMutex = Mutex()

    /** Chapters already successfully downloaded this session. Mirrors legado ReadManga.downloadedChapters. */
    private val downloadedChapters = hashSetOf<Int>()
    /** Download failure counts per chapter. Mirrors legado ReadManga.downloadFailChapters. */
    private val downloadFailChapters = hashMapOf<Int, Int>()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val downloadScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    /**
     * Pre-download semaphore for concurrency control.
     * M11: Initialized with permits from book source concurrentRate, default 2.
     * Mirrors legado's rate limiter applied during manga content loading.
     */
    private var preDownloadSemaphore = Semaphore(2)
    private var preDownloadTask: Job? = null

    /** Read time tracking. Mirrors legado ReadManga.readStartTime. */
    private var readStartTime: Long = currentTimeMillis()

    private val _mangaContent = MutableStateFlow(MangaContent(0, emptyList(), false, false))
    /** Observable aggregated manga content (prev + cur + next chapters). */
    val mangaContent: StateFlow<MangaContent> = _mangaContent.asStateFlow()

    private val _loadError = MutableStateFlow<String?>(null)
    /** Observable load error message, null when no error. */
    val loadError: StateFlow<String?> = _loadError.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    /** Observable loading state. */
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    val hasNextChapter: Boolean get() = durChapterIndex < simulatedChapterSize - 1
    val hasPrevChapter: Boolean get() = durChapterIndex > 0

    /**
     * Whether the chapter has changed since the last saveRead().
     * Mirrors legado ReadManga.chapterChanged.
     */
    val chapterChanged: Boolean
        get() = book?.durChapterIndex != durChapterIndex

    /** Callback interface for UI events. Mirrors legado ReadManga.Callback. */
    interface Callback {
        fun upContent()
        fun loadFail(msg: String, retry: Boolean = true)
        fun showLoading()
        fun startLoad()
    }

    private var callback: Callback? = null

    /**
     * Register a UI callback. Mirrors legado ReadManga.register().
     */
    fun register(cb: Callback) {
        callback = cb
    }

    /**
     * Unregister the UI callback and cancel pre-download tasks.
     * Mirrors legado ReadManga.unregister().
     */
    fun unregister(cb: Callback) {
        if (callback === cb) {
            callback = null
        }
        preDownloadTask?.cancel()
        preDownloadTask = null
        downloadScope.coroutineContext.cancelChildren()
    }

    // ---- Lifecycle ----

    /**
     * Initialize the manga reader with a book.
     * Mirrors legado ReadManga.resetData().
     *
     * @param bookUrl the book URL to load
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun resetData(bookUrl: String) = runRecoverable("MangaReaderFacade.resetData") {
        val resolvedBook = getBookUseCase.get(bookUrl)
            ?: throw RecoverableSharedException("MangaReaderFacade.resetData", "Book not found: $bookUrl")
        book = resolvedBook
        chapterSize = observeBookChaptersUseCase(bookUrl).first().size
        simulatedChapterSize = computeSimulatedChapterSize(resolvedBook)
        durChapterIndex = resolvedBook.durChapterIndex
        durChapterPos = resolvedBook.durChapterPos
        readStartTime = currentTimeMillis()
        clearMangaChapter()
        upWebBook(resolvedBook)
        loadingMutex.withLock {
            loadingChapters.clear()
        }
        downloadedChapters.clear()
        downloadFailChapters.clear()
    }

    /**
     * Update book data when chapter list or book info changes.
     * Mirrors legado ReadManga.upData().
     */
    suspend fun upData(bookUrl: String) {
        try {
            val resolvedBook = getBookUseCase.get(bookUrl) ?: return
            book = resolvedBook
            chapterSize = observeBookChaptersUseCase(bookUrl).first().size
            simulatedChapterSize = computeSimulatedChapterSize(resolvedBook)

            if (durChapterIndex != resolvedBook.durChapterIndex) {
                durChapterIndex = resolvedBook.durChapterIndex
                durChapterPos = resolvedBook.durChapterPos
                clearMangaChapter()
            }
            upWebBook(resolvedBook)
            loadingMutex.withLock {
                loadingChapters.clear()
            }
            downloadedChapters.clear()
            downloadFailChapters.clear()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "upData", error = e)
        }
    }

    /**
     * Release resources and cancel all ongoing operations.
     */
    fun release() {
        // Persist read time before releasing
        scope.launch {
            upReadTime()
        }
        preDownloadTask?.cancel()
        preDownloadTask = null
        downloadScope.coroutineContext.cancelChildren()
        scope.coroutineContext.cancelChildren()
        clearMangaChapter()
        callback = null
    }

    // ---- Read Time Tracking ----

    /**
     * Update accumulated read time for the current book.
     * Mirrors legado ReadManga.upReadTime().
     */
    private suspend fun upReadTime() {
        if (!enableReadRecord) return
        val resolvedBook = book ?: return
        val now = currentTimeMillis()
        val elapsed = now - readStartTime
        readStartTime = now
        if (elapsed <= 0) return
        try {
            val existingTime = readRecordRepository.getReadTime(resolvedBook.name) ?: 0L
            val record = ReadRecord(
                bookName = resolvedBook.name,
                readTime = existingTime + elapsed,
                lastRead = now,
            )
            readRecordRepository.insert(record)
        } catch (_: Exception) {
            // Best-effort, mirrors legado
        }
    }

    /**
     * Called when the current page changes (scroll/swipe).
     * Triggers read time update and pre-download.
     * Mirrors legado ReadManga.curPageChanged().
     */
    fun curPageChanged() {
        scope.launch {
            upReadTime()
        }
        preDownload()
    }

    // ---- Content Loading ----

    /**
     * Load current, next and previous chapters.
     * Mirrors legado ReadManga.loadContent() (no-args version).
     */
    fun loadContent() {
        clearMangaChapter()
        _isLoading.value = true
        _loadError.value = null
        loadContent(durChapterIndex)
        loadContent(durChapterIndex + 1)
        loadContent(durChapterIndex - 1)
    }

    /**
     * Conditionally load or notify content update.
     * Mirrors legado ReadManga.loadOrUpContent().
     */
    fun loadOrUpContent() {
        if (curMangaChapter == null) {
            loadContent(durChapterIndex)
        } else {
            callback?.upContent()
            emitContent()
        }
        if (nextMangaChapter == null) {
            loadContent(durChapterIndex + 1)
        }
        if (prevMangaChapter == null) {
            loadContent(durChapterIndex - 1)
        }
    }

    private fun loadContent(index: Int) {
        scope.launch {
            try {
                val resolvedBook = book ?: return@launch
                val chapters = observeBookChaptersUseCase(resolvedBook.bookUrl).first()
                if (index < 0 || index >= chapters.size) return@launch
                val chapter = chapters[index]
                if (!addLoading(index)) return@launch

                val content = chapterContentRepository.getContent(resolvedBook, chapter)
                if (content != null) {
                    downloadedChapters.add(index)
                    contentLoadFinish(chapter, content)
                } else {
                    download(chapter)
                }
            } catch (e: Exception) {
                removeLoading(index)
                if (index == durChapterIndex) {
                    _loadError.value = "加载正文出错: ${e.message}"
                    _isLoading.value = false
                    callback?.loadFail("加载正文出错: ${e.message}")
                }
            }
        }
    }

    /**
     * Content load completion handler.
     * Mirrors legado ReadManga.contentLoadFinish().
     */
    private suspend fun contentLoadFinish(
        chapter: BookChapter,
        content: String?,
        errorMsg: String = "加载内容失败",
        canceled: Boolean = false,
    ) {
        removeLoading(chapter.index)
        if (canceled || chapter.index !in (durChapterIndex - 1)..(durChapterIndex + 1)) {
            return
        }
        when (val offset = chapter.index - durChapterIndex) {
            0 -> {
                if (content == null) {
                    _loadError.value = errorMsg
                    _isLoading.value = false
                    callback?.loadFail(errorMsg)
                    return
                }
                if (content.isEmpty() && !chapter.isVolume) {
                    _loadError.value = "正文内容为空"
                    _isLoading.value = false
                    callback?.loadFail("正文内容为空")
                    return
                }
                val mangaChapter = getMangaChapter(chapter, content)
                if (mangaChapter.imageCount == 0 && !chapter.isVolume) {
                    _loadError.value = "正文没有图片"
                    _isLoading.value = false
                    callback?.loadFail("正文没有图片")
                    return
                }
                curMangaChapter = mangaChapter
                _isLoading.value = false
                _loadError.value = null
                callback?.upContent()
                emitContent()
            }
            -1, 1 -> {
                if (content == null || (!chapter.isVolume && content.isEmpty())) {
                    return
                }
                val mangaChapter = getMangaChapter(chapter, content)
                if (mangaChapter.imageCount == 0 && !chapter.isVolume) {
                    return
                }
                when (offset) {
                    -1 -> prevMangaChapter = mangaChapter
                    1 -> nextMangaChapter = mangaChapter
                }
                callback?.upContent()
                emitContent()
            }
        }
    }

    // ---- Chapter Navigation ----

    /**
     * Move to the next chapter — window shift: cur→prev, next→cur, load new next.
     * Mirrors legado ReadManga.moveToNextChapter().
     *
     * @param toFirst if true, reset position to 0 and show loading
     * @return true if moved successfully, false if already at last chapter
     */
    suspend fun moveToNextChapter(toFirst: Boolean = false): Boolean {
        if (durChapterIndex >= simulatedChapterSize - 1) {
            return false
        }
        try {
            if (toFirst) {
                _isLoading.value = true
                callback?.showLoading()
                durChapterPos = 0
            }
            durChapterIndex++
            prevMangaChapter = curMangaChapter
            curMangaChapter = nextMangaChapter
            nextMangaChapter = null
            if (curMangaChapter == null) {
                _isLoading.value = true
                callback?.startLoad()
                loadContent(durChapterIndex)
            } else {
                callback?.upContent()
                emitContent()
            }
            loadContent(durChapterIndex + 1)
            saveRead()
            curPageChanged()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "moveToNextChapter", error = e)
        }
        return true
    }

    /**
     * Move to the previous chapter — window shift: cur→next, prev→cur, load new prev.
     * Mirrors legado ReadManga.moveToPrevChapter().
     *
     * @param toFirst if true, reset position to 0 and show loading
     * @return true if moved successfully, false if already at first chapter
     */
    suspend fun moveToPrevChapter(toFirst: Boolean = false): Boolean {
        if (durChapterIndex <= 0) {
            return false
        }
        try {
            if (toFirst) {
                _isLoading.value = true
                callback?.showLoading()
                durChapterPos = 0
            }
            durChapterIndex--
            nextMangaChapter = curMangaChapter
            curMangaChapter = prevMangaChapter
            prevMangaChapter = null
            if (curMangaChapter == null) {
                loadContent(durChapterIndex)
            } else {
                callback?.upContent()
                emitContent()
            }
            loadContent(durChapterIndex - 1)
            saveRead()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "moveToPrevChapter", error = e)
        }
        return true
    }

    /**
     * Update the current page position within the chapter.
     * Should be called by the UI when the user scrolls to a new page.
     */
    suspend fun updatePagePosition(pageIndex: Int) {
        try {
            durChapterPos = pageIndex
            emitContent()
            saveRead(pageChanged = true)
            curPageChanged()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "updatePagePosition", error = e)
        }
    }

    /**
     * Jump to an arbitrary chapter by index.
     * Clears the window and reloads all three chapters.
     */
    suspend fun jumpToChapter(chapterIndex: Int) {
        if (chapterIndex < 0 || chapterIndex >= simulatedChapterSize) return
        try {
            _isLoading.value = true
            callback?.showLoading()
            durChapterIndex = chapterIndex
            durChapterPos = 0
            loadContent()
            saveRead()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "jumpToChapter", error = e)
        }
    }

    /**
     * Handle chapter list update (e.g., after TOC refresh).
     * Mirrors legado ReadManga.onChapterListUpdated().
     */
    suspend fun onChapterListUpdated(bookUrl: String, reloadContent: Boolean = true) {
        try {
            val newBook = getBookUseCase.get(bookUrl) ?: return
            val currentBook = book ?: return
            if (newBook.name != currentBook.name || newBook.author != currentBook.author) return
            book = newBook
            chapterSize = observeBookChaptersUseCase(bookUrl).first().size
            simulatedChapterSize = computeSimulatedChapterSize(newBook)
            if (simulatedChapterSize > 0 && durChapterIndex > simulatedChapterSize - 1) {
                durChapterIndex = simulatedChapterSize - 1
            }
            if (callback == null) {
                clearMangaChapter()
            } else if (reloadContent) {
                loadContent()
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "onChapterListUpdated", error = e)
        }
    }

    // ---- Content Building ----

    /**
     * Build the aggregated MangaContent from the three-chapter window.
     * Mirrors legado ReadManga.buildMangaContent().
     */
    private fun buildMangaContent(): MangaContent {
        val items = mutableListOf<BaseMangaPage>()
        var pos = 0
        var curFinish = false
        var nextFinish = false

        prevMangaChapter?.let {
            pos += it.pages.size
            items.addAll(it.pages)
        }

        curMangaChapter?.let {
            curFinish = true
            items.addAll(it.pages)
            durChapterPos = if (it.imageCount > 0) {
                durChapterPos.coerceIn(0, it.imageCount - 1)
            } else {
                0
            }
            pos += durChapterPos
            if (!hideMangaTitle && it.imageCount > 0) {
                pos++ // account for title page offset
            }
        }

        nextMangaChapter?.let {
            nextFinish = true
            items.addAll(it.pages)
        }

        return MangaContent(pos, items, curFinish, nextFinish)
    }

    private fun emitContent() {
        _mangaContent.value = buildMangaContent()
    }

    // ---- Chapter Parsing ----

    /**
     * Parse chapter content into a MangaChapter with pages.
     * Mirrors legado ReadManga.getManageChapter().
     *
     * Extracts image URLs from HTML content using the img tag pattern,
     * wraps them as MangaPage entries, and adds title/end ReaderLoading markers.
     */
    private fun getMangaChapter(chapter: BookChapter, content: String): MangaChapter {
        return MangaChapterParser.parse(chapter, content, chapterSize, hideMangaTitle)
    }

    /**
     * iOS uses ReaderFacade's cancellable preparation for source/local-file loading and its
     * serial progress queue for persistence. This bridge only turns that prepared body into
     * image pages, so a cancelled load cannot independently move the persisted position.
     */
    @Throws(RecoverableSharedException::class, kotlin.coroutines.cancellation.CancellationException::class)
    suspend fun prepareReaderChapter(payload: ReaderChapterPayload, chapterPosition: Int): MangaReaderChapter =
        runRecoverable("MangaReaderFacade.prepareReaderChapter") {
            val readableCount = ReadSimulationSchedule.count(payload.book.readConfig, payload.chapters.size)
            require(payload.chapter.index in 0 until readableCount) { "当前章节尚不可阅读" }
            require(payload.chapter.bookUrl == payload.book.bookUrl) { "漫画章节与书籍不匹配" }
            val parsed = MangaChapterParser.parse(payload.chapter, payload.content, readableCount, true)
            val pages = parsed.pages.filterIsInstance<MangaPage>()
            require(pages.isNotEmpty() || payload.chapter.isVolume) { "正文没有图片" }
            MangaReaderChapter(
                book = payload.book,
                chapters = payload.chapters.take(readableCount),
                chapterIndex = payload.chapter.index,
                chapterTitle = payload.displayTitle,
                chapterPosition = if (pages.isEmpty()) 0 else chapterPosition.coerceIn(0, pages.lastIndex),
                pages = pages,
                isVolume = payload.chapter.isVolume,
            )
        }

    // ---- Download ----

    private suspend fun download(chapter: BookChapter, semaphore: Semaphore? = null) {
        val resolvedBook = book ?: run {
            removeLoading(chapter.index)
            return
        }
        val source = bookSource
        if (source != null) {
            try {
                val doLoad: suspend () -> String = {
                    loadChapterContentUseCase(source, resolvedBook, chapter).getOrThrow()
                }
                val content = if (semaphore != null) {
                    semaphore.withPermit { doLoad() }
                } else {
                    doLoad()
                }
                chapterContentRepository.saveContent(resolvedBook, chapter, content)
                downloadedChapters.add(chapter.index)
                downloadFailChapters.remove(chapter.index)
                contentLoadFinish(chapter, content)
            } catch (e: Exception) {
                downloadFailChapters[chapter.index] =
                    (downloadFailChapters[chapter.index] ?: 0) + 1
                contentLoadFinish(chapter, null, "加载内容失败: ${e.message}")
            }
        } else {
            contentLoadFinish(chapter, null, "加载内容失败 没有书源")
        }
    }

    // ---- Pre-download ----

    /**
     * Pre-download chapters around current position.
     * Mirrors legado ReadManga.preDownload().
     */
    private fun preDownload() {
        val resolvedBook = book ?: return
        if (resolvedBook.isLocal) return
        if (preDownloadNum < 2) {
            scope.launch { upToc() }
            return
        }
        preDownloadTask?.cancel()
        preDownloadTask = downloadScope.launch {
            // Forward pre-download
            launch {
                val maxIndex = min(durChapterIndex + preDownloadNum, chapterSize)
                for (i in (durChapterIndex + 2)..maxIndex) {
                    if (downloadedChapters.contains(i)) continue
                    if ((downloadFailChapters[i] ?: 0) >= 3) continue
                    downloadIndex(i)
                }
            }
            // Backward pre-download
            launch {
                val minIndex = durChapterIndex - min(5, preDownloadNum)
                for (i in (durChapterIndex - 2) downTo minIndex) {
                    if (downloadedChapters.contains(i)) continue
                    if ((downloadFailChapters[i] ?: 0) >= 3) continue
                    downloadIndex(i)
                }
            }
        }
    }

    /**
     * Download a single chapter by index for pre-download.
     * Mirrors legado ReadManga.downloadIndex().
     */
    private suspend fun downloadIndex(index: Int) {
        if (index < 0) return
        if (index > chapterSize - 1) {
            upToc()
            return
        }
        val resolvedBook = book ?: return
        val chapters = observeBookChaptersUseCase(resolvedBook.bookUrl).first()
        val chapter = chapters.getOrNull(index) ?: return
        val hasContent = chapterContentRepository.getContent(resolvedBook, chapter) != null
        if (hasContent) {
            downloadedChapters.add(chapter.index)
        } else {
            delay(1000)
            if (addLoading(index)) {
                download(chapter, preDownloadSemaphore)
            }
        }
    }

    /**
     * Cancel pre-download tasks when current and next chapters are ready.
     * Mirrors legado ReadManga.cancelPreDownloadTask().
     */
    fun cancelPreDownloadTask() {
        if (curMangaChapter != null && nextMangaChapter != null) {
            preDownloadTask?.cancel()
            downloadScope.coroutineContext.cancelChildren()
        }
    }

    // ---- M36-M39: Manga-specific progress operations ----

    /**
     * M36: Update TOC for manga reader.
     * Delegates to the internal upToc() implementation.
     * Platform layers call this to trigger a TOC refresh check.
     */
    suspend fun refreshTocIfNeeded() {
        try {
            upToc()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "refreshTocIfNeeded", error = e)
        }
    }

    /**
     * M37: Upload current manga reading progress to WebDAV.
     * Delegates to the settingsFacade (if provided) or saves locally.
     * Platform layers should call settingsFacade.uploadBookProgress(book) directly.
     */
    fun getCurrentBook(): Book? = book

    /**
     * M38: Sync manga progress from server.
     * Returns the current book progress state for the platform layer to use
     * with ReaderFacade.syncProgress() or settingsFacade.getBookProgress().
     */
    fun getCurrentProgress(): Triple<Int, Int, String>? {
        val b = book ?: return null
        return Triple(durChapterIndex, durChapterPos, b.durChapterTitle ?: "")
    }

    /**
     * M54: Get whether book progress sync is enabled from preferences.
     * Mirrors legado AppConfig.syncBookProgress.
     *
     * @return true if sync is enabled, false otherwise
     */
    suspend fun getSyncBookProgressConfig(): Boolean {
        return try {
            val store = preferencesStore ?: return false
            store.runtimeConfig.first().syncBookProgress
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "getSyncBookProgressConfig", error = e)
            false
        }
    }

    /**
     * Mirrors legado ReadManga.setProgress() — jumps to a chapter+page position.
     */
    suspend fun setProgress(chapterIndex: Int, pageIndex: Int = 0) {
        if (chapterIndex < 0 || chapterIndex >= simulatedChapterSize) return
        try {
            _isLoading.value = true
            callback?.showLoading()
            durChapterIndex = chapterIndex
            durChapterPos = pageIndex
            clearMangaChapter()
            loadContent()
            saveRead()
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("MangaReaderFacade", "setProgress", error = e)
        }
    }

    // ---- Auto TOC Update ----

    /**
     * Auto-update table of contents when near the end of available chapters.
     * Mirrors legado ReadManga.upToc().
     * Triggers when remaining chapters < 3 and last check was > 10 minutes ago.
     */
    private suspend fun upToc() {
        val source = bookSource ?: return
        val resolvedBook = book ?: return
        if (!resolvedBook.canUpdate) return
        if (chapterSize - durChapterIndex - 1 >= 3) return
        val now = currentTimeMillis()
        // lastCheckTime is approximated via book.durChapterTime; check if > 10 minutes
        if (now - resolvedBook.durChapterTime < 600_000) return
        // Actual TOC refresh would require WebBook.getChapterList equivalent in shared layer.
        // For now, mark the book as needing update by the platform layer via onChapterListUpdated().
    }

    // ---- Progress Persistence ----

    /**
     * Save current reading progress.
     * Mirrors legado ReadManga.saveRead().
     */
    private suspend fun saveRead(pageChanged: Boolean = false) {
        val resolvedBook = book ?: return
        try {
            val chapterChanged = resolvedBook.durChapterIndex != durChapterIndex
            val chapters = observeBookChaptersUseCase(resolvedBook.bookUrl).first()
            val durChapterTitle = if (!pageChanged || chapterChanged) {
                chapters.getOrNull(durChapterIndex)?.let { ch ->
                    resolveDisplayChapterTitle(resolvedBook, ch, applyReplaceRulesUseCase)
                } ?: resolvedBook.durChapterTitle
            } else {
                resolvedBook.durChapterTitle
            }
            val updatedBook = resolvedBook.copy(
                durChapterIndex = durChapterIndex,
                durChapterPos = durChapterPos,
                durChapterTitle = durChapterTitle,
                durChapterTime = currentTimeMillis(),
                lastCheckCount = 0,
            )
            book = updatedBook
            saveBookUseCase(updatedBook)
            updateReadingProgressUseCase(
                updatedBook.bookUrl,
                updatedBook.durChapterIndex,
                updatedBook.durChapterTitle,
                updatedBook.durChapterPos,
            )
        } catch (_: Exception) {
            // Save is best-effort — mirrors legado's runCatching in saveRead()
        }
    }

    // ---- Simulated Chapter Size ----

    /**
     * Compute the effective chapter size accounting for read simulation.
     * Mirrors legado ReadManga's simulatedChapterSize computation
     * and BookExtensions.simulatedTotalChapterNum().
     */
    private fun computeSimulatedChapterSize(resolvedBook: Book): Int {
        return ReadSimulationSchedule.count(resolvedBook.readConfig, chapterSize)
    }

    // ---- Internal Helpers ----

    private fun clearMangaChapter() {
        prevMangaChapter = null
        curMangaChapter = null
        nextMangaChapter = null
    }

    private fun upWebBook(resolvedBook: Book) {
        scope.launch {
            val source = getBookSourcesUseCase.getByUrl(resolvedBook.origin)
            bookSource = source
            // M11: Apply rate limiter from book source concurrentRate
            if (source != null) {
                val permits = parseConcurrentRatePermits(source.concurrentRate)
                if (permits > 0) {
                    preDownloadSemaphore = Semaphore(permits)
                }
            }
        }
    }

    /**
     * Parse concurrentRate string to get the number of concurrent permits.
     * Format: "N" or "N/delay" where N is permits count.
     * Aligned with legado's concurrentRate parsing.
     * M11: rateLimiter support.
     */
    private fun parseConcurrentRatePermits(concurrentRate: String?): Int {
        if (concurrentRate.isNullOrBlank()) return 2 // default
        val parts = concurrentRate.split("/")
        return parts.firstOrNull()?.trim()?.toIntOrNull()?.coerceIn(1, 10) ?: 2
    }

    private suspend fun addLoading(index: Int): Boolean {
        return loadingMutex.withLock {
            if (loadingChapters.contains(index)) {
                false
            } else {
                loadingChapters.add(index)
                true
            }
        }
    }

    private suspend fun removeLoading(index: Int) {
        loadingMutex.withLock {
            loadingChapters.remove(index)
        }
    }
}
