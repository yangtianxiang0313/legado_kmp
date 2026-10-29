package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookGroupRepository
import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.repository.SaveContentEvent
import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookGroup
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.hasType
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.image.ImageDiskCache
import io.legado.kmp.shared.network.LegadoHttpClient
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.platform.AppFilesDirectory
import io.legado.kmp.shared.platform.FileAccess
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext

data class BookCacheInfo(
    val book: Book,
    val cachedCount: Int,
    val totalCount: Int,
    val isLocal: Boolean,
)

data class CacheProgress(
    val bookUrl: String,
    val cached: Int,
    val total: Int,
    val isRunning: Boolean,
    val error: String? = null,
)

/**
 * C37: Download state enum, mirrors legado EventBus.UP_DOWNLOAD_STATE transitions.
 */
enum class DownloadState {
    IDLE, RUNNING, PAUSED, COMPLETED
}

data class BookDownloadSummary(
    val totalChapters: Int,
    val downloaded: Int,
    val pending: Int,
    val active: Int,
    val errors: Int,
)

class CacheFacade(
    private val bookRepository: BookRepository,
    private val bookChapterRepository: BookChapterRepository,
    private val chapterContentRepository: ChapterContentRepository,
    private val bookSourceRepository: BookSourceRepository,
    private val webBookRepository: WebBookRepository,
    private val bookGroupRepository: BookGroupRepository,
    private val fileAccess: FileAccess,
    private val appFilesDirectory: AppFilesDirectory,
    private val imageDiskCache: ImageDiskCache,
    private val headerResolver: SourceHeaderResolver,
    private val httpClient: LegadoHttpClient? = null,
    private val preferencesStore: AppPreferencesStore? = null,
    private val chapterImages: CacheChapterImages,
    private val bookExporter: BookExportFacade,
) {
    /** Active download jobs keyed by bookUrl -- used by stopDownload to cancel */
    private class DownloadSession(val job: Job) {
        val model = MutableStateFlow<CacheFacade.CacheBookModel?>(null)
    }
    private val downloadJobs = MutableStateFlow<Map<String, DownloadSession>>(emptyMap())
    private val downloadLimiter = CacheDownloadLimiter()
    private val downloadLedger = CacheDownloadLedger()

    /** Per-book download models, mirrors legado CacheBook.cacheBookMap */
    private val cacheBookMap = MutableStateFlow<Map<String, CacheBookModel>>(emptyMap())

    /**
     * C37: Download state changes, mirrors legado EventBus.UP_DOWNLOAD_STATE.
     * Emits IDLE / RUNNING / PAUSED / COMPLETED as download lifecycle progresses.
     */
    private val _downloadStateChanged = MutableStateFlow(DownloadState.IDLE)
    val downloadStateChanged: SharedFlow<DownloadState> get() = _downloadStateChanged

    /**
     * C38: Expose save-content events from ChapterContentRepository so callers
     * (cache list, chapter list UI) can observe chapter save completions in real time.
     * Mirrors legado EventBus.SAVE_CONTENT.
     */
    val saveContentEvents: SharedFlow<SaveContentEvent>
        get() = chapterContentRepository.saveContentEvents

    /** Thread count for parallel downloads (mirrors AppConfig.threadCount) */
    var threadCount: Int = 3

    /**
     * Controls the pause/resume state of the download processing loop.
     * When false, the processing loop suspends until resumed.
     * Mirrors legado CacheBook.workingState (MutableStateFlow<Boolean>).
     */
    private val workingState = MutableStateFlow(true)

    /**
     * Set the working state to pause (false) or resume (true) download processing.
     * Mirrors legado CacheBook.setWorkingState(value).
     */
    fun setWorkingState(value: Boolean) {
        workingState.value = value
        if (value) {
            if (isRun) _downloadStateChanged.value = DownloadState.RUNNING
        } else {
            if (isRun) _downloadStateChanged.value = DownloadState.PAUSED
        }
    }

    /**
     * Whether the download processing is paused.
     */
    val isPaused: Boolean
        get() = !workingState.value

    /** Mutex protecting cacheBookMap access at facade level */
    private val facadeMutex = Mutex()

    // ── Watch APIs (unchanged) ──────────────────────────────────────────

    fun watchBookGroups(onUpdate: (List<BookGroup>) -> Unit): FlowSubscription {
        return watchFlow(bookGroupRepository.observeAllBookGroups(), onUpdate, label = "CacheFacade.groups")
    }

    fun watchBooks(groupId: Long?, onUpdate: (List<Book>) -> Unit): FlowSubscription {
        val flow: Flow<List<Book>> = bookRepository.observeAllBooks()
            .map { books -> books.filterForGroup(groupId) }
        return watchFlow(flow, { books ->
            onUpdate(books.filter { !it.isAudio })
        }, label = "CacheFacade.books")
    }

    // ── Cache info queries (unchanged) ──────────────────────────────────

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getBookCacheInfo(book: Book): BookCacheInfo {
        return runRecoverable("CacheFacade.cacheInfo") {
            if (book.isLocal) {
                BookCacheInfo(book, 0, 0, isLocal = true)
            } else {
                val chapters = bookChapterRepository.getChaptersByBookUrl(book.bookUrl)
                var cached = 0
                for (ch in chapters) {
                    if (isChapterOffline(book, ch)) {
                        cached++
                    }
                }
                BookCacheInfo(book, cached, chapters.size, isLocal = false)
            }
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getBooksWithCacheInfo(groupId: Long?): List<BookCacheInfo> {
        return runRecoverable("CacheFacade.allCacheInfo") {
            val books = bookRepository.getAllBooks().filterForGroup(groupId)
            books.filter { !it.isAudio }.map { book ->
                if (book.isLocal) {
                    BookCacheInfo(book, 0, 0, isLocal = true)
                } else {
                    val chapters = bookChapterRepository.getChaptersByBookUrl(book.bookUrl)
                    var cached = 0
                    for (ch in chapters) {
                        if (isChapterOffline(book, ch)) {
                            cached++
                        }
                    }
                    BookCacheInfo(book, cached, chapters.size, isLocal = false)
                }
            }
        }
    }

    private fun List<Book>.filterForGroup(groupId: Long?): List<Book> {
        return when (groupId) {
            null, BookGroup.ID_ALL -> this
            BookGroup.ID_LOCAL -> filter { it.isLocal }
            BookGroup.ID_AUDIO -> filter { it.isAudio }
            BookGroup.ID_NET_NONE -> filter { !it.isLocal && it.group == 0L }
            BookGroup.ID_LOCAL_NONE -> filter { it.isLocal && it.group == 0L }
            BookGroup.ID_ERROR -> filter { it.hasType(BookType.UPDATE_ERROR) }
            else -> {
                if (groupId > 0) {
                    filter { it.group and groupId != 0L }
                } else {
                    emptyList()
                }
            }
        }
    }

    private suspend fun isChapterOffline(book: Book, chapter: BookChapter): Boolean {
        coroutineContext.ensureActive()
        if (chapter.isVolume) return true
        val content = chapterContentRepository.getContent(book, chapter) ?: return false
        return chapterImages.isComplete(book, chapter, content)
    }

    private suspend fun offlineChapterFiles(book: Book, chapters: List<BookChapter>): Set<String> = buildSet {
        for (chapter in chapters) {
            if (isChapterOffline(book, chapter)) add(chapter.getFileName())
        }
    }

    // ── CacheBookModel (mirrors legado CacheBook.CacheBookModel) ────────

    /**
     * Per-book download state, mirroring legado's CacheBook.CacheBookModel.
     * Manages waitDownloadSet / onDownloadSet / error retry / isVolume skip.
     * Uses Mutex instead of synchronized for KMP commonMain compatibility.
     */
    inner class CacheBookModel(
        var bookSource: BookSource,
        var book: Book,
    ) {
        private val queue = CacheDownloadQueue()
        internal var batchProgress: CacheBatchProgress? = null
        internal var automaticTarget: AutomaticBookCacheTarget? = null

        suspend fun getWaitCount(): Int = queue.pendingCount
        suspend fun getOnDownloadCount(): Int = queue.activeCount
        fun getWaitCountSync(): Int = queue.pendingCount
        fun getOnDownloadCountSync(): Int = queue.activeCount
        fun isRunSync(): Boolean = queue.isRunning
        suspend fun isRun(): Boolean = queue.isRunning
        suspend fun isStop(): Boolean = queue.isStopped
        suspend fun isLoading(): Boolean = queue.isLoading
        internal suspend fun awaitPending(): Boolean = queue.awaitPending(workingState)
        suspend fun setLoading() = queue.setLoading()
        suspend fun stop() = queue.stop()
        fun stopSync() = queue.stop()

        suspend fun addDownload(start: Int, end: Int) {
            queue.add(start, end)
            cacheBookMap.update { it + (book.bookUrl to this) }
        }

        private fun onSuccess(chapter: BookChapter) {
            downloadLedger.success(chapter)
            batchProgress?.success(chapter)
            queue.finish(chapter.index)
        }

        private fun onPreError(chapter: BookChapter, error: Throwable) {
            downloadLedger.failure(chapter, error)
        }

        private fun onPostError(chapter: BookChapter) {
            queue.finish(chapter.index, retry = downloadLedger.attempts(chapter) < 3)
        }

        private fun onError(chapter: BookChapter, error: Throwable) {
            onPreError(chapter, error)
            onPostError(chapter)
        }

        private fun onCancel(index: Int) = queue.finish(index, retry = true)

        internal fun claimNext(): Int? = queue.claimNext()

        internal fun cancelClaim(index: Int) {
            onCancel(index)
            onFinally()
        }

        private fun onFinally() {
            if (!queue.isRunning) {
                cacheBookMap.update { if (it[book.bookUrl] === this) it - book.bookUrl else it }
            }
        }

        /**
         * Download one chapter from waitDownloadSet (batch download path).
         * Mirrors legado CacheBookModel.download(scope, context).
         *
         * Skips volume headings. Cached bodies still require complete image verification.
         * For chapters without content, fetches via WebBook.getContent.
         */
        suspend fun download(): Boolean {
            val chapterIndex = claimNext() ?: return false
            downloadClaimed(chapterIndex)
            return true
        }

        internal suspend fun downloadClaimed(chapterIndex: Int) {
            var downloadingChapter: BookChapter? = null
            var released = false
            try {
                coroutineContext.ensureActive()
                val chapter = bookChapterRepository.getChapter(book.bookUrl, chapterIndex)
                downloadingChapter = chapter
                checkNotNull(chapter) { "Chapter disappeared during download: ${book.bookUrl}, $chapterIndex" }
                if (chapter.isVolume) {
                    queue.finish(chapterIndex)
                    released = true
                    return
                }
                downloadAndCache(chapter)
                onSuccess(chapter)
                released = true
            } catch (e: CancellationException) {
                onCancel(chapterIndex)
                released = true
                throw e
            } catch (e: Exception) {
                try {
                    coroutineContext.ensureActive()
                    val chapter = downloadingChapter ?: throw e
                    onPreError(chapter, e)
                    delay(1000)
                    onPostError(chapter)
                    released = true
                } catch (cancelled: CancellationException) {
                    onCancel(chapterIndex)
                    released = true
                    throw cancelled
                }
            } finally {
                // Never release a retried index twice: another worker may already have claimed it.
                if (!released) queue.finish(chapterIndex)
                onFinally()
            }
        }

        private suspend fun saveDownloadedContent(chapter: BookChapter, content: String) {
            automaticTarget?.requireChapter(chapter)
            // Synthetic volume headings are always available and may have no body to cache.
            if (content.isEmpty() && chapter.isVolume && chapter.url.startsWith(chapter.title)) return
            check(chapterContentRepository.saveContent(book, chapter, content)) {
                "Failed to save chapter cache: ${book.bookUrl}, chapter ${chapter.index}"
            }
        }

        private suspend fun downloadAndCache(chapter: BookChapter): String {
            val target = automaticTarget
            return if (target == null) downloadAndCacheContent(chapter)
            else target.withChapter(chapter) { downloadAndCacheContent(chapter) }
        }

        private suspend fun downloadAndCacheContent(chapter: BookChapter): String {
            val content = chapterContentRepository.getContent(book, chapter) ?: run {
                val downloaded = webBookRepository.getChapterContent(bookSource, book, chapter).getOrThrow()
                coroutineContext.ensureActive()
                saveDownloadedContent(chapter, downloaded)
                downloaded
            }
            automaticTarget?.requireChapter(chapter)
            chapterImages.save(book, bookSource, chapter, content)
            coroutineContext.ensureActive()
            automaticTarget?.requireChapter(chapter)
            return content
        }

        /**
         * Synchronous (suspend) download of a single chapter.
         * Mirrors legado CacheBookModel.downloadAwait.
         * Used by the reader for on-demand chapter fetching.
         */
        suspend fun downloadAwait(chapter: BookChapter): String {
            while (!queue.claim(chapter.index)) {
                delay(20)
            }
            try {
                val content = downloadAndCache(chapter)
                onSuccess(chapter)
                return content
            } catch (e: CancellationException) {
                onCancel(chapter.index)
                throw e
            } catch (e: Exception) {
                onError(chapter, e)
                return "获取正文失败\n${e.message}"
            }
        }

        /**
         * Download a single chapter for reader use (non-blocking launch).
         * Mirrors legado CacheBookModel.download(scope, chapter, semaphore, resetPageOffset).
         */
        fun downloadForReader(
            scope: CoroutineScope,
            chapter: BookChapter,
            semaphore: Semaphore?,
            onFinish: ((BookChapter, String, Boolean) -> Unit)? = null,
        ) {
            scope.launch {
                if (!queue.claim(chapter.index)) return@launch

                try {
                    if (semaphore != null) {
                        semaphore.withPermit {
                            val content = downloadAndCache(chapter)
                            onSuccess(chapter)
                            onFinish?.invoke(chapter, content, false)
                        }
                    } else {
                        val content = downloadAndCache(chapter)
                        onSuccess(chapter)
                        onFinish?.invoke(chapter, content, false)
                    }
                } catch (e: CancellationException) {
                    onCancel(chapter.index)
                    onFinish?.invoke(chapter, "download canceled", true)
                } catch (e: Exception) {
                    onError(chapter, e)
                    onFinish?.invoke(chapter, "获取正文失败\n${e.message}", false)
                }
            }
        }
    }

    // ── CacheBookModel management ───────────────────────────────────────

    /**
     * Update bookSource reference for all models using the same source URL.
     * Mirrors legado CacheBook.updateBookSource.
     */
    private fun updateBookSource(newBookSource: BookSource) {
        cacheBookMap.value.forEach { (_, model) ->
            if (model.bookSource.bookSourceUrl == newBookSource.bookSourceUrl) {
                model.bookSource = newBookSource
            }
        }
    }

    /**
     * Get or create a CacheBookModel for a book.
     * Mirrors legado CacheBook.getOrCreate.
     */
    suspend fun getOrCreate(bookUrl: String): CacheBookModel? {
        return try {
            val book = bookRepository.getBook(bookUrl) ?: return null
            val bookSource = bookSourceRepository.getBookSource(book.origin) ?: return null
            facadeMutex.withLock {
                updateBookSource(bookSource)
                val model = cacheBookMap.value[bookUrl]
                if (model != null) {
                    model.bookSource = bookSource
                    model.book = book
                    model
                } else {
                    val created = CacheBookModel(bookSource, book)
                    cacheBookMap.update { it + (bookUrl to created) }
                    created
                }
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("CacheFacade", "getOrCreate", mapOf("bookUrl" to bookUrl), e)
            null
        }
    }

    /**
     * Get or create with pre-resolved book and source.
     */
    suspend fun getOrCreate(bookSource: BookSource, book: Book): CacheBookModel {
        return facadeMutex.withLock {
            updateBookSource(bookSource)
            val model = cacheBookMap.value[book.bookUrl]
            if (model != null) {
                model.bookSource = bookSource
                model.book = book
                model
            } else {
                val created = CacheBookModel(bookSource, book)
                cacheBookMap.update { it + (book.bookUrl to created) }
                created
            }
        }
    }

    // ── Download entry points ───────────────────────────────────────────

    /**
     * Start downloading chapters for a book.
     * Registers the job in downloadJobs so stopDownload can cancel it.
     * Uses CacheBookModel for per-chapter state management.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun startDownload(
        bookUrl: String,
        startIndex: Int = 0,
        endIndex: Int = Int.MAX_VALUE,
        onProgress: (CacheProgress) -> Unit,
    ) {
        startDownloadSession(bookUrl, startIndex, endIndex, onProgress)
    }

    internal suspend fun downloadAutomatically(
        bookUrl: String, startIndex: Int, endIndex: Int, onProgress: (CacheProgress) -> Unit,
    ) {
        val target = AutomaticBookCacheTarget.create(
            bookRepository, bookChapterRepository, bookSourceRepository, preferencesStore, bookUrl,
        )
        target.run { startDownloadSession(bookUrl, startIndex, endIndex, onProgress, target) }
    }

    private suspend fun startDownloadSession(
        bookUrl: String, startIndex: Int, endIndex: Int, onProgress: (CacheProgress) -> Unit,
        target: AutomaticBookCacheTarget? = null,
    ) {
        runRecoverable("CacheFacade.download") {
            coroutineScope {
                val session = DownloadSession(coroutineContext[Job]!!)
                while (true) {
                    ensureActive()
                    val current = downloadJobs.value
                    val previous = current[bookUrl]
                    if (previous != null) {
                        check(!previous.job.isActive) { "Book download already running: $bookUrl" }
                        previous.job.join()
                        continue
                    }
                    if (downloadJobs.compareAndSet(current, current + (bookUrl to session))) break
                }
                var completed = false
                try {
                    completed = runDownloadBatch(session, bookUrl, startIndex, endIndex, onProgress, target)
                } finally {
                    session.model.value?.stopSync()
                    session.model.value?.automaticTarget = null
                    downloadJobs.update { if (it[bookUrl] === session) it - bookUrl else it }
                    if (downloadJobs.value.isEmpty() && !isRun) {
                        _downloadStateChanged.value = if (completed) DownloadState.COMPLETED else DownloadState.IDLE
                    }
                }
            }
        }
    }

    private suspend fun runDownloadBatch(
        session: DownloadSession,
        bookUrl: String,
        startIndex: Int,
        endIndex: Int,
        onProgress: (CacheProgress) -> Unit,
        target: AutomaticBookCacheTarget?,
    ): Boolean {
        val book = bookRepository.getBook(bookUrl)
            ?: throw IllegalArgumentException("Book not found: $bookUrl")
        val source = bookSourceRepository.getBookSource(book.origin)
            ?: throw IllegalArgumentException("Source not found: ${book.origin}")
        val chapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
        val effectiveEnd = endIndex.coerceAtMost(chapters.size - 1)
        val effectiveStart = startIndex.coerceAtLeast(0)
        val progress = CacheBatchProgress(
            chapters, offlineChapterFiles(book, chapters), effectiveStart, effectiveEnd,
        )
        downloadLedger.resetFailures(bookUrl)
        suspend fun emitProgress(running: Boolean) {
            coroutineContext.ensureActive()
            val errors = if (running) 0 else downloadLedger.errorCount(bookUrl)
            onProgress(CacheProgress(
                bookUrl, progress.count(), chapters.size, isRunning = running,
                error = if (errors == 0) null else "$errors 章缓存失败：${downloadLedger.lastError(bookUrl).orEmpty()}",
            ))
        }
        emitProgress(true)
        _downloadStateChanged.value = if (isPaused) DownloadState.PAUSED else DownloadState.RUNNING
        val model = getOrCreate(source, book)
        model.batchProgress = progress
        model.automaticTarget = target
        session.model.value = model
        coroutineContext.ensureActive()
        model.addDownload(effectiveStart, effectiveEnd)
        downloadLimiter.configure(preferencesStore?.runtimeConfig?.first()?.threadCount ?: threadCount)
        val progressMutex = Mutex()
        coroutineScope {
            while (model.awaitPending()) {
                val permit = downloadLimiter.acquire()
                var handedOff = false
                try {
                    ensureActive()
                    // Pausing never holds a global slot while waiting to resume.
                    if (!workingState.value) continue
                    val chapterIndex = model.claimNext() ?: continue
                    try {
                        // Enter cleanup even if cancellation races with the launch.
                        launch(start = CoroutineStart.UNDISPATCHED) {
                            try {
                                model.downloadClaimed(chapterIndex)
                                progressMutex.withLock { emitProgress(true) }
                            } finally {
                                permit.release()
                            }
                        }
                        handedOff = true
                    } finally {
                        if (!handedOff) model.cancelClaim(chapterIndex)
                    }
                } finally {
                    if (!handedOff) permit.release()
                }
            }
        }
        emitProgress(false)
        return downloadLedger.errorCount(bookUrl) == 0
    }

    /**
     * Stop downloading a specific book.
     * Cancels the job and stops the model.
     * Mirrors legado CacheBook.remove.
     */
    fun stopDownload(bookUrl: String) {
        downloadJobs.value[bookUrl]?.let {
            it.model.value?.stopSync()
            it.job.cancel()
        }
        if (!isRun) _downloadStateChanged.value = DownloadState.IDLE
    }

    /**
     * Stop all downloads. Cancels all jobs and stops all models.
     * Mirrors legado CacheBook.stop (via CacheBookService).
     */
    fun stopAll() {
        downloadJobs.value.values.forEach {
            it.model.value?.stopSync()
            it.job.cancel()
        }
        cacheBookMap.value.values.forEach { it.stopSync() }
        _downloadStateChanged.value = DownloadState.IDLE
    }

    /**
     * Stop all downloads and clear all state (models, success/error tracking).
     * Mirrors legado CacheBook.close.
     */
    fun close() {
        stopAll()
        cacheBookMap.value = emptyMap()
        downloadLedger.clear()
        _downloadStateChanged.value = DownloadState.IDLE
    }

    /**
     * Download a single chapter synchronously (suspend).
     * Mirrors legado CacheBookModel.downloadAwait.
     * For use by the reader when it needs content on-demand.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun downloadChapterAwait(bookUrl: String, chapter: BookChapter): String {
        return runRecoverable("CacheFacade.downloadAwait") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            val source = bookSourceRepository.getBookSource(book.origin)
                ?: throw IllegalArgumentException("Source not found: ${book.origin}")
            val model = getOrCreate(source, book)
            model.downloadAwait(chapter)
        }
    }

    // ── Download summary / status ───────────────────────────────────────

    /**
     * Aggregate download summary string.
     * Mirrors legado CacheBook.downloadSummary format:
     * "正在下载:{onDownloadCount}|等待中:{waitCount}|失败:{errorCount}|成功:{successCount}"
     */
    val downloadSummary: String
        get() {
            var wait = 0
            var onDownload = 0
            cacheBookMap.value.values.forEach { model ->
                wait += model.getWaitCountSync()
                onDownload += model.getOnDownloadCountSync()
            }
            return "正在下载:${onDownload}|等待中:${wait}|失败:${downloadLedger.errorCount()}|成功:${downloadLedger.successCount()}"
        }

    /**
     * Whether any model is currently running (has pending or active downloads).
     * Mirrors legado CacheBook.isRun.
     */
    val isRun: Boolean
        get() {
            cacheBookMap.value.values.forEach { model ->
                if (model.isRunSync()) return true
            }
            return false
        }

    /** Alias kept for backward compatibility */
    val isDownloading: Boolean
        get() = isRun

    /**
     * Aggregate wait count across all models.
     * Mirrors legado CacheBook.waitCount.
     */
    val waitCount: Int
        get() {
            var count = 0
            cacheBookMap.value.values.forEach { count += it.getWaitCountSync() }
            return count
        }

    /**
     * Aggregate on-download count across all models.
     * Mirrors legado CacheBook.onDownloadCount.
     */
    val onDownloadCount: Int
        get() {
            var count = 0
            cacheBookMap.value.values.forEach { count += it.getOnDownloadCountSync() }
            return count
        }

    /**
     * Get download summary for a specific book.
     * Returns total chapters, downloaded, pending (in waitSet), errors for this book.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getDownloadSummaryForBook(bookUrl: String): BookDownloadSummary {
        return runRecoverable("CacheFacade.downloadSummaryForBook") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            val chapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
            val files = offlineChapterFiles(book, chapters)
            val failedUrls = downloadLedger.failedUrls(bookUrl)
            var downloaded = 0
            for (ch in chapters) {
                if (ch.url !in failedUrls && (ch.isVolume || ch.getFileName() in files)) downloaded++
            }
            val model = cacheBookMap.value[bookUrl]
            val pending = model?.getWaitCountSync() ?: 0
            val active = model?.getOnDownloadCountSync() ?: 0
            val errors = chapters.count { it.url in failedUrls }
            BookDownloadSummary(
                totalChapters = chapters.size,
                downloaded = downloaded,
                pending = pending,
                active = active,
                errors = errors,
            )
        }
    }

    // ── Export (unchanged) ──────────────────────────────────────────────

    /**
     * C42: Export book as TXT with proper chapter title headers and formatting.
     * Mirrors legado ExportBookUtils.exportTxt() which prepends chapter titles
     * with separator lines and uses consistent formatting.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookAsTxt(bookUrl: String): String {
        return runRecoverable("CacheFacade.exportTxt") {
            bookExporter.prepare(bookUrl, "txt", onProgress = {}).data.decodeToString()
        }
    }

    // ── C39: Generic file download ──────────────────────────────────────

    /**
     * C39: Download a generic file by URL (not chapter content).
     * Mirrors legado Download.start() for arbitrary file downloads.
     * Returns the downloaded file bytes.
     *
     * @param url the URL to download from
     * @param fileName the desired file name (used for tracking/display, not for storage path)
     * @return the downloaded bytes
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun downloadFile(url: String, fileName: String): ByteArray {
        return runRecoverable("CacheFacade.downloadFile") {
            val client = httpClient
                ?: throw IllegalStateException("HttpClient not available for file download")
            val response = client.get(url)
            response.body
        }
    }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun getAllGroups(): List<BookGroup> {
        return runRecoverable("CacheFacade.groups") {
            bookGroupRepository.getAllBookGroups()
        }
    }

    // ── Cache clearing (DIFF-001 / DIFF-002) ────────────────────────────

    /**
     * Clear all book cache (all books).
     * Mirrors legado BookHelp.clearCache().
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun clearCache() {
        runRecoverable("CacheFacade.clearCache") {
            check(chapterContentRepository.clearCache()) {
                "Failed to clear book caches"
            }
        }
    }

    /**
     * Clear cache for a specific book.
     * Mirrors legado BookHelp.clearCache(book).
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun clearCache(bookUrl: String) {
        runRecoverable("CacheFacade.clearBookCache") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            check(chapterContentRepository.clearCache(book)) {
                "Failed to clear book cache: $bookUrl"
            }
        }
    }

    // ── Cache migration (DIFF-003) ──────────────────────────────────────

    /**
     * Migrate cache folder when a book changes source.
     * Copies files from old cache directory to new, then removes old.
     * Mirrors legado BookHelp.updateCacheFolder(oldBook, newBook).
     *
     * @param oldBook the book before source change
     * @param newBook the book after source change
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun updateCacheFolder(oldBook: Book, newBook: Book) {
        runRecoverable("CacheFacade.updateCacheFolder") {
            val oldFolderName = oldBook.getCacheFolderName()
            val newFolderName = newBook.getCacheFolderName()
            if (oldFolderName == newFolderName) return@runRecoverable
            check(chapterContentRepository.moveCacheFolder(oldFolderName, newFolderName)) {
                "Failed to move book cache: $oldFolderName -> $newFolderName"
            }
        }
    }

    // ── Invalid cache cleanup (DIFF-004) ─────────────────────────────────

    /**
     * Clear cached content for books that no longer exist in the database.
     * Mirrors legado BookHelp.clearInvalidCache().
     * Iterates over cache folders on disk, removes any that don't belong to a known book.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun clearInvalidCache() {
        runRecoverable("CacheFacade.clearInvalidCache") {
            val allBooks = bookRepository.getAllBooks()
            val validFolderNames = allBooks.map { it.getCacheFolderName() }.toSet()
            val diskFolders = chapterContentRepository.listCacheFolders()
            for (folderName in diskFolders) {
                if (!validFolderNames.contains(folderName)) {
                    check(chapterContentRepository.deleteCacheFolder(folderName)) {
                        "Failed to delete invalid book cache: $folderName"
                    }
                }
            }
        }
    }

    // ── C43/C44/C45/C46: Export formats ─────────────────────────────────

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookAsEpub(bookUrl: String): ByteArray =
        runRecoverable("CacheFacade.exportBookAsEpub") {
            bookExporter.prepare(bookUrl, "epub", onProgress = {}).data
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookAsSplitFiles(bookUrl: String, outputDir: String): Int =
        runRecoverable("CacheFacade.exportBookAsSplitFiles") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            val directory = outputDir.trim().trimEnd('/', '\\')
            require(directory.isNotEmpty()) { "Output directory is empty" }
            require(fileAccess.createDirectory(directory)) { "Failed to create output directory" }
            val chapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
            var exported = 0
            for (chapter in chapters) {
                val content = chapterContentRepository.getContent(book, chapter) ?: continue
                val fileName = "${chapter.index.toString().padStart(5, '0')}-${chapter.title.sanitizedExportFileName()}.txt"
                val text = buildString {
                    appendLine(chapter.title)
                    appendLine()
                    append(content)
                    if (!content.endsWith('\n')) appendLine()
                }
                if (fileAccess.write("$directory/$fileName", text.encodeToByteArray())) exported++
            }
            exported
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookImages(bookUrl: String, outputDir: String): Int =
        runRecoverable("CacheFacade.exportBookImages") {
            val book = bookRepository.getBook(bookUrl)
                ?: throw IllegalArgumentException("Book not found: $bookUrl")
            val source = bookSourceRepository.getBookSource(book.origin)
                ?: throw IllegalArgumentException("Source not found: ${book.origin}")
            val directory = outputDir.trim().trimEnd('/', '\\')
            require(directory.isNotEmpty()) { "Output directory is empty" }
            require(fileAccess.createDirectory(directory)) { "Failed to create output directory" }
            val chapters = bookChapterRepository.getChaptersByBookUrl(bookUrl)
            val exportedUrls = linkedSetOf<String>()
            var exported = 0
            for (chapter in chapters) {
                val content = chapterContentRepository.getContent(book, chapter) ?: continue
                chapterImages.save(book, source, chapter, content)
                val imageUrls = chapterImages.imageUrls(chapter, content, allowRawUrls = book.isImage)
                    .filter { exportedUrls.add(it) }
                for ((imageIndex, imageUrl) in imageUrls.withIndex()) {
                    coroutineContext.ensureActive()
                    val bytes = checkNotNull(imageDiskCache.getImage(book.getCacheFolderName(), book.imageCacheIdentity(imageUrl))) {
                        "Image cache disappeared during export"
                    }
                    val extension = imageUrl.imageExtensionFromUrl()
                    val fileName = "${chapter.index.toString().padStart(5, '0')}-${(imageIndex + 1).toString().padStart(3, '0')}.$extension"
                    check(fileAccess.write("$directory/$fileName", bytes)) { "Failed to export image: $fileName" }
                    exported++
                }
            }
            exported
        }

    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun exportBookToPath(bookUrl: String, outputPath: String, format: String = "txt"): String =
        runRecoverable("CacheFacade.exportBookToPath") {
            val normalizedPath = outputPath.trim()
            require(normalizedPath.isNotEmpty()) { "Output path is empty" }
            when (format.lowercase()) {
                "txt" -> {
                    normalizedPath.cacheExportParentPath()?.let { parent ->
                        require(fileAccess.createDirectory(parent)) { "Failed to create output directory" }
                    }
                    check(fileAccess.write(normalizedPath, exportBookAsTxt(bookUrl).encodeToByteArray())) {
                        "Failed to write exported book"
                    }
                    normalizedPath
                }
                "epub" -> {
                    normalizedPath.cacheExportParentPath()?.let { parent ->
                        require(fileAccess.createDirectory(parent)) { "Failed to create output directory" }
                    }
                    check(fileAccess.write(normalizedPath, exportBookAsEpub(bookUrl))) {
                        "Failed to write exported book"
                    }
                    normalizedPath
                }
                "split", "chapter", "chapters" -> {
                    exportBookAsSplitFiles(bookUrl, normalizedPath)
                    normalizedPath
                }
                "images", "image" -> {
                    exportBookImages(bookUrl, normalizedPath)
                    normalizedPath
                }
                else -> throw IllegalArgumentException("Unsupported export format: $format")
            }
        }
}
