package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ContentProcessor
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
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
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.domain.usecase.SaveChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SearchUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.exception.ContentEmptyException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.ReadSimulationSchedule
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.model.isTxtLocalBook
import io.legado.kmp.shared.model.rule.ContentRule
import io.legado.kmp.shared.model.rule.TocRule
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlin.math.max
import kotlin.math.min
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext

/** Loads and processes chapters without persisting a reading position. */
internal class ReaderChapterLoader(
    private val getBookUseCase: GetBookUseCase,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
    private val loadChapterContentUseCase: LoadChapterContentUseCase,
    private val getBookSourcesUseCase: GetBookSourcesUseCase,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val saveChaptersUseCase: SaveChaptersUseCase,
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
    private val chapterImages: CacheChapterImages? = null,
) {
    private val loadingStates = mutableMapOf<String, ChapterLoadingState>()
    private val loadingMutex = Mutex()
    private val downloadSemaphore = Semaphore(1)

    suspend fun prepareChapter(
        bookUrl: String,
        chapterIndex: Int,
        refreshContent: Boolean,
    ): ReaderChapterPreparation {
        coroutineContext.ensureActive()
        val loadingState = loadingState(bookUrl)
        val book = requireBook(bookUrl)
        coroutineContext.ensureActive()
        if (book.config.readSimulating) {
            val readable = ReadSimulationSchedule.count(book.readConfig, observeBookChaptersUseCase(bookUrl).first().size)
            check(readable > 0 && chapterIndex < readable) { "模拟追读：当前章节尚未解锁" }
        }
        if (book.isTxtLocalBook) {
            return loadTxtLocalChapter(book, chapterIndex, refreshContent)
        }
        if (book.isEpub) {
            return loadLocalBookChapter(
                book, chapterIndex, refreshContent,
                parse = { parseEpubLocalFileUseCase(it).let { p -> PreparedBook(p.book, p.chapters) } },
                readContent = { localBook, chapter -> loadEpubLocalChapterContentUseCase(localBook, chapter) },
            )
        }
        if (book.isLocal) {
            when (book.bookUrl.substringAfterLast('.', "").lowercase()) {
                "pdf" -> return loadLocalBookChapter(
                    book, chapterIndex, refreshContent,
                    parse = { parsePdfLocalFileUseCase(it).let { p -> PreparedBook(p.book, p.chapters) } },
                    readContent = { localBook, chapter ->
                        val pageIndex = chapter.url.removePrefix("pdf-page-").toIntOrNull()?.minus(1)
                        require(pageIndex != null && pageIndex >= 0) { "Invalid PDF chapter URL: ${chapter.url}" }
                        loadPdfLocalChapterContentUseCase(localBook, chapter.copy(index = pageIndex))
                    },
                )
                "umd" -> return loadLocalBookChapter(
                    book, chapterIndex, refreshContent,
                    parse = { parseUmdLocalFileUseCase(it).let { p -> PreparedBook(p.book, p.chapters) } },
                    readContent = { localBook, chapter -> loadUmdLocalChapterContentUseCase(localBook, chapter) },
                )
                "mobi", "azw", "azw3" -> return loadLocalBookChapter(
                    book, chapterIndex, refreshContent,
                    parse = { parseMobiLocalFileUseCase(it).let { p -> PreparedBook(p.book, p.chapters) } },
                    readContent = { localBook, chapter -> loadMobiLocalChapterContentUseCase(localBook, chapter) },
                )
                "epub" -> return loadLocalBookChapter(
                    book, chapterIndex, refreshContent,
                    parse = { parseEpubLocalFileUseCase(it).let { p -> PreparedBook(p.book, p.chapters) } },
                    readContent = { localBook, chapter -> loadEpubLocalChapterContentUseCase(localBook, chapter) },
                )
            }
        }
        return loadWebChapter(book, chapterIndex, refreshContent, loadingState)
    }

    private suspend fun loadWebChapter(
        book: Book,
        chapterIndex: Int,
        refreshContent: Boolean,
        loadingState: ChapterLoadingState,
    ): ReaderChapterPreparation {
        val prepared = ensureWebChapters(book)
        val chapters = prepared.chapters
        require(chapters.isNotEmpty()) { "No chapters found for ${prepared.book.bookUrl}" }
        val normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
        val chapter = chapters[normalizedIndex]
        var currentChapter = chapter
        val didAddLoading = addLoading(book.bookUrl, loadingState, normalizedIndex)
        val payload = try {
            coroutineContext.ensureActive()
            // Refresh bypasses reads, but keeps the old cache until fresh content is ready.
            val cached = if (refreshContent) null else chapterContentRepository.getContent(prepared.book, chapter)
            coroutineContext.ensureActive()
            val rawContent = if (cached != null) cached else {
                val source = requireSource(prepared.book)
                val loaded = loadChapterContentUseCase.loadWithChapter(source, prepared.book, chapter).getOrThrow()
                coroutineContext.ensureActive()
                currentChapter = loaded.chapter
                if (!refreshContent) {
                    withLoadingState(book.bookUrl, loadingState) {}
                    chapterContentRepository.saveContent(prepared.book, currentChapter, loaded.content)
                }
                coroutineContext.ensureActive()
                loaded.content
            }
            // Validate raw text: title removal or replace rules may legitimately empty the display text.
            if (refreshContent && !currentChapter.isVolume && rawContent.isBlank()) {
                throw ContentEmptyException()
            }
            // BookChapter.equals compares URLs, not metadata snapshots.
            val currentChapters = if (currentChapter === chapter) chapters else chapters.toMutableList().apply {
                this[normalizedIndex] = currentChapter
            }
            val loadedPayload = createPayload(
                prepared.book, currentChapters, currentChapter, normalizedIndex, rawContent,
            )
            if (refreshContent) {
                coroutineContext.ensureActive()
                withLoadingState(book.bookUrl, loadingState) {}
                check(rawContent.isEmpty() || chapterContentRepository.saveContent(prepared.book, currentChapter, rawContent)) {
                    "Failed to save refreshed chapter cache"
                }
                coroutineContext.ensureActive()
            }
            loadedPayload
        } finally {
            if (didAddLoading) {
                // Only guard cleanup is non-cancellable; content I/O keeps the request Job.
                withContext(NonCancellable) {
                    removeLoading(loadingState, normalizedIndex)
                }
            }
        }
        coroutineContext.ensureActive()
        withLoadingState(book.bookUrl, loadingState) {}
        return ReaderChapterPreparation(
            currentBook = book,
            payload = payload,
            preloadAdjacent = true,
        )
    }

    private suspend fun loadLocalBookChapter(
        book: Book,
        chapterIndex: Int,
        refreshContent: Boolean,
        parse: suspend (Book) -> PreparedBook,
        readContent: suspend (Book, BookChapter) -> String,
    ): ReaderChapterPreparation {
        val prepared = ensureLocalBookChapters(book, parse)
        val chapters = prepared.chapters
        require(chapters.isNotEmpty()) { "Chapter list is empty for ${prepared.book.bookUrl}" }
        val normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
        val chapter = chapters[normalizedIndex]
        coroutineContext.ensureActive()
        if (refreshContent) {
            check(chapterContentRepository.deleteContent(prepared.book, chapter)) { "Failed to reset edited chapter cache" }
            coroutineContext.ensureActive()
        }
        val rawContent = chapterContentRepository.getContent(prepared.book, chapter)
            ?: readContent(prepared.book, chapter)
        coroutineContext.ensureActive()
        return ReaderChapterPreparation(
            currentBook = book,
            payload = createPayload(prepared.book, chapters, chapter, normalizedIndex, rawContent),
        )
    }

    private suspend fun loadTxtLocalChapter(
        book: Book,
        chapterIndex: Int,
        refreshContent: Boolean,
    ): ReaderChapterPreparation {
        var prepared = ensureTxtLocalChapters(book)
        var chapters = prepared.chapters
        require(chapters.isNotEmpty()) { "TXT chapter list is empty for ${prepared.book.bookUrl}" }
        var normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
        var chapter = chapters[normalizedIndex]
        coroutineContext.ensureActive()
        if (refreshContent) {
            check(chapterContentRepository.deleteContent(prepared.book, chapter)) { "Failed to reset edited chapter cache" }
            coroutineContext.ensureActive()
        }
        var rawContent = chapterContentRepository.getContent(prepared.book, chapter)
            ?: loadTxtLocalChapterContentUseCase(prepared.book, chapter)
        coroutineContext.ensureActive()
        if (rawContent.isEmpty() && !chapter.isVolume) {
            prepared = reparseTxtLocalBook(prepared.book, expected = book)
            chapters = prepared.chapters
            require(chapters.isNotEmpty()) { "TXT chapter list is empty for ${prepared.book.bookUrl}" }
            normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
            chapter = chapters[normalizedIndex]
            coroutineContext.ensureActive()
            if (refreshContent) {
                check(chapterContentRepository.deleteContent(prepared.book, chapter)) { "Failed to reset edited chapter cache" }
                coroutineContext.ensureActive()
            }
            rawContent = chapterContentRepository.getContent(prepared.book, chapter)
                ?: loadTxtLocalChapterContentUseCase(prepared.book, chapter)
            coroutineContext.ensureActive()
        }
        return ReaderChapterPreparation(
            currentBook = book,
            payload = createPayload(prepared.book, chapters, chapter, normalizedIndex, rawContent),
        )
    }

    private suspend fun ensureWebChapters(book: Book): PreparedBook {
        coroutineContext.ensureActive()
        val storedChapters = observeBookChaptersUseCase(book.bookUrl).first()
        coroutineContext.ensureActive()
        if (storedChapters.isNotEmpty()) {
            return PreparedBook(book, storedChapters)
        }
        val refreshed = fetchChapterListUseCase(requireSource(book), book, runPreUpdateJs = true).getOrThrow()
        return savePreparedChapters(expected = book, book = refreshed.book, chapters = refreshed.chapters)
    }

    private suspend fun ensureLocalBookChapters(
        book: Book,
        parse: suspend (Book) -> PreparedBook,
    ): PreparedBook {
        coroutineContext.ensureActive()
        val storedChapters = observeBookChaptersUseCase(book.bookUrl).first()
        coroutineContext.ensureActive()
        if (storedChapters.isNotEmpty()) {
            return PreparedBook(book, storedChapters)
        }
        val parsed = parse(book)
        return savePreparedChapters(
            expected = book,
            book = parsed.book.copy(readConfig = book.readConfig?.copy()),
            chapters = orderParsedLocalChapters(book, parsed.chapters),
        )
    }

    private suspend fun ensureTxtLocalChapters(book: Book): PreparedBook {
        coroutineContext.ensureActive()
        val storedChapters = observeBookChaptersUseCase(book.bookUrl).first()
        coroutineContext.ensureActive()
        if (hasUsableTxtOffsets(storedChapters)) {
            return PreparedBook(book, storedChapters)
        }
        return reparseTxtLocalBook(book, expected = book)
    }

    private suspend fun hasUsableTxtOffsets(chapters: List<BookChapter>): Boolean {
        return chapters.isNotEmpty() && chapters.all { chapter ->
            coroutineContext.ensureActive()
            if (chapter.isVolume) {
                true
            } else {
                val start = chapter.start
                val end = chapter.end
                start != null && end != null && end > start
            }
        }
    }

    private suspend fun reparseTxtLocalBook(book: Book, expected: Book): PreparedBook {
        coroutineContext.ensureActive()
        val parsed = parseTxtLocalFileUseCase(book)
        return savePreparedChapters(
            expected = expected,
            book = parsed.book.copy(readConfig = book.readConfig?.copy()),
            chapters = orderParsedLocalChapters(book, parsed.chapters),
        )
    }

    private suspend fun savePreparedChapters(
        expected: Book,
        book: Book,
        chapters: List<BookChapter>,
    ): PreparedBook {
        coroutineContext.ensureActive()
        // Finish a local metadata/directory commit once begun; network and parsing remain cancellable.
        val savedBook = withContext(NonCancellable) {
            saveBookUseCase.ifSourceUnchanged(expected = expected, book = book, chapters = chapters)
        }
        coroutineContext.ensureActive()
        return PreparedBook(savedBook, chapters)
    }

    private suspend fun createPayload(
        book: Book,
        chapters: List<BookChapter>,
        chapter: BookChapter,
        chapterIndex: Int,
        rawContent: String,
        updateDisplayProgress: Boolean = true,
    ): ReaderChapterPayload {
        coroutineContext.ensureActive()
        val chapterPosition = if (chapterIndex == book.durChapterIndex) book.durChapterPos else 0
        val displayTitle = resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
        coroutineContext.ensureActive()
        val useReplace = book.config.useReplaceRule ?: defaultUseReplaceRule(book)
        coroutineContext.ensureActive()
        val processed = processContent(book, chapter, rawContent, displayTitle, useReplace)
        coroutineContext.ensureActive()
        return ReaderChapterPayload(
            book = if (updateDisplayProgress) {
                book.updateReadingProgress(chapterIndex, displayTitle, chapterPosition)
            } else {
                book
            },
            chapters = chapters,
            chapter = chapter,
            content = processed.content,
            displayTitle = displayTitle,
            blocks = buildReaderContentBlocks(displayTitle, processed.content),
            sameTitleRemoved = processed.sameTitleRemoved,
        ).also { coroutineContext.ensureActive() }
    }

    suspend fun cachedChapterPayload(bookUrl: String, chapterIndex: Int): ReaderChapterPayload? {
        val state = loadingState(bookUrl)
        val book = getBookUseCase.get(bookUrl) ?: error("Book not found: $bookUrl")
        if (book.isLocal || book.isTxtLocalBook) return null
        val chapters = observeBookChaptersUseCase(bookUrl).first()
        if (chapters.isEmpty()) return null
        val normalizedIndex = chapterIndex.coerceIn(0, chapters.lastIndex)
        val chapter = chapters[normalizedIndex]
        val cached = chapterContentRepository.getContent(book, chapter) ?: return null
        val payload = createPayload(book, chapters, chapter, normalizedIndex, cached, updateDisplayProgress = false)
        withLoadingState(bookUrl, state) {}
        return payload
    }

    suspend fun requireBook(bookUrl: String): Book {
        coroutineContext.ensureActive()
        val stored = getBookUseCase.get(bookUrl)
        coroutineContext.ensureActive()
        if (stored != null) return stored
        val candidate = searchUseCase.getByBookUrl(bookUrl)?.toBook()
        coroutineContext.ensureActive()
        val fallback = candidate ?: error("Book not found: $bookUrl")
        val saved = saveBookUseCase.ifSourceUnchanged(expected = fallback, book = fallback, allowInsert = true)
        coroutineContext.ensureActive()
        return saved
    }

    suspend fun requireSource(book: Book): BookSource {
        coroutineContext.ensureActive()
        val source = getBookSourcesUseCase.getByUrl(book.origin)
        coroutineContext.ensureActive()
        return requireNotNull(source) {
            "Book source not found: ${book.origin}"
        }
    }

    suspend fun defaultUseReplaceRule(book: Book): Boolean {
        coroutineContext.ensureActive()
        if (book.isImage || book.isEpub) return false
        val config = preferencesStore.runtimeConfig.first()
        coroutineContext.ensureActive()
        return config.replaceRuleEnabledByDefault
    }

    suspend fun processContent(
        book: Book,
        chapter: BookChapter,
        content: String,
        displayTitle: String,
        useReplace: Boolean,
    ): ContentProcessor.Result {
        coroutineContext.ensureActive()
        val chineseConvert = preferencesStore.runtimeConfig.first().reader.chineseMode
        coroutineContext.ensureActive()
        val shouldRemoveSameTitle = chapterContentRepository.removeSameTitle(book, chapter)
        coroutineContext.ensureActive()
        return contentProcessor.process(
            book = book,
            chapter = chapter,
            content = content,
            displayTitle = displayTitle,
            useReplace = useReplace,
            chineseConvert = chineseConvert,
            shouldRemoveSameTitle = shouldRemoveSameTitle,
        ).also { coroutineContext.ensureActive() }
    }

    suspend fun setCharset(bookUrl: String, charset: String): Book {
        val book = requireBook(bookUrl)
        return saveBookUseCase.updateCharset(book.bookUrl, book.origin, charset)
    }

    suspend fun downloadIndex(bookUrl: String, chapterIndex: Int) {
        try {
            val state = loadingState(bookUrl)
            val book = getBookUseCase.get(bookUrl) ?: return
            if (book.isLocal || book.isTxtLocalBook) return
            val chapters = observeBookChaptersUseCase(bookUrl).first()
            if (chapterIndex < 0 || chapterIndex > chapters.lastIndex) return
            val chapter = chapters[chapterIndex]
            if (chapterIndex >= ReadSimulationSchedule.count(book.readConfig, chapters.size)) return
            val source = getBookSourcesUseCase.getByUrl(book.origin) ?: return
            val snapshot = PreloadSnapshot(book, source, chapters)
            withPreloadSnapshot(snapshot, state) {
                preloadChapter(book, source, chapter, chapterIndex, state, snapshot)
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "downloadIndex", error = e)
        }
    }

    suspend fun preloadAdjacentChapters(
        bookUrl: String,
        chapterIndex: Int,
        preDownloadNum: Int,
        includeCurrent: Boolean = false,
    ) {
        try {
            coroutineContext.ensureActive()
            val window = preDownloadNum.coerceIn(0, 9999).let { if (includeCurrent) it.coerceAtLeast(1) else it }
            if (window == 0 || chapterIndex < 0) return
            val state = loadingState(bookUrl)
            val book = getBookUseCase.get(bookUrl) ?: return
            if (book.isTxtLocalBook || book.isLocal) return
            val chapters = observeBookChaptersUseCase(bookUrl).first()
            if (chapterIndex !in chapters.indices) return
            val source = getBookSourcesUseCase.getByUrl(book.origin) ?: return
            // Prefetch is cache-only: directory refreshes can update book metadata/progress separately.
            val readableLast = ReadSimulationSchedule.count(book.readConfig, chapters.size) - 1
            if (chapterIndex > readableLast) return
            val snapshot = PreloadSnapshot(book, source, chapters)
            withPreloadSnapshot(snapshot, state) {
                var currentImageError: Exception? = null
                if (includeCurrent) {
                    try {
                        cacheDisplayedChapterImages(book, source, chapters[chapterIndex], state, snapshot)
                    } catch (cancelled: CancellationException) {
                        throw cancelled
                    } catch (error: Exception) {
                        coroutineContext.ensureActive()
                        findFacadeRequestCancellation(error)?.let { throw it }
                        currentImageError = error
                    }
                }
                // Layout neighbors stay ahead of the expanded window, even when N is 9999.
                if (chapterIndex < readableLast) {
                    preloadChapter(book, source, chapters[chapterIndex + 1], chapterIndex + 1, state, snapshot)
                }
                if (chapterIndex > 0) {
                    preloadChapter(book, source, chapters[chapterIndex - 1], chapterIndex - 1, state, snapshot)
                }
                val maxForward = min(chapterIndex.toLong() + window, readableLast.toLong()).toInt()
                // One sequential chapter worker, not one coroutine per requested chapter.
                for (idx in (chapterIndex.toLong() + 2)..maxForward.toLong()) {
                    coroutineContext.ensureActive()
                    val index = idx.toInt()
                    preloadChapter(book, source, chapters[index], index, state, snapshot)
                }
                val backwardRange = min(window, 5)
                val minBackward = max(chapterIndex - backwardRange, 0)
                for (idx in (chapterIndex - 2) downTo minBackward) {
                    coroutineContext.ensureActive()
                    preloadChapter(book, source, chapters[idx], idx, state, snapshot)
                }
                currentImageError?.let { throw it }
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            findFacadeRequestCancellation(e)?.let { throw it }
            CrashCollector.record("ReaderFacade", "preloadAdjacentChapters", error = e)
            throw e
        }
    }

    private suspend fun cacheDisplayedChapterImages(
        book: Book,
        source: BookSource,
        chapter: BookChapter,
        state: ChapterLoadingState,
        snapshot: PreloadSnapshot,
    ) {
        if (chapter.isVolume) return
        downloadSemaphore.withPermit {
            requirePreloadSnapshot(snapshot, state)
            // Read raw persisted text so hidden/replaced images are included. Never fetch a missing body.
            val content = checkNotNull(chapterContentRepository.getContent(book, chapter)) {
                "Displayed chapter cache is missing"
            }
            requirePreloadSnapshot(snapshot, state)
            // Do not skip an already displayed chapter because of old failures or a display loading guard.
            chapterImages?.save(book, source, chapter, content)
            requirePreloadSnapshot(snapshot, state)
            withLoadingState(book.bookUrl, state) { it.failures.remove(chapter.index) }
        }
    }

    private suspend fun preloadChapter(
        book: Book,
        source: BookSource,
        chapter: BookChapter,
        index: Int,
        state: ChapterLoadingState,
        snapshot: PreloadSnapshot,
    ) {
        coroutineContext.ensureActive()
        if (chapter.isVolume) return
        if (withLoadingState(book.bookUrl, state) { (it.failures[index] ?: 0) >= 3 }) return
        if (!addLoading(book.bookUrl, state, index)) return
        try {
            // Hold the chapter permit through image work, including repairs to cached bodies.
            downloadSemaphore.withPermit {
                coroutineContext.ensureActive()
                requirePreloadSnapshot(snapshot, state)
                val cached = chapterContentRepository.getContent(book, chapter)
                coroutineContext.ensureActive()
                var currentChapter = chapter
                val content = cached ?: run {
                    val loaded = loadChapterContentUseCase.loadWithChapter(source, book, chapter).getOrThrow()
                    coroutineContext.ensureActive()
                    requirePreloadSnapshot(snapshot, state)
                    currentChapter = loaded.chapter
                    if (!snapshot.matchesChapter(index, currentChapter)) {
                        throw CancellationException("Preload chapter changed")
                    }
                    check(chapterContentRepository.saveContent(book, currentChapter, loaded.content)) {
                        "Failed to save prefetched chapter: $index"
                    }
                    loaded.content
                }
                coroutineContext.ensureActive()
                requirePreloadSnapshot(snapshot, state)
                // Body persistence alone is not success when any chapter image is still missing.
                chapterImages?.save(book, source, currentChapter, content)
                coroutineContext.ensureActive()
                requirePreloadSnapshot(snapshot, state)
                withLoadingState(book.bookUrl, state) { it.failures.remove(index) }
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (error: Exception) {
            coroutineContext.ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            withLoadingState(book.bookUrl, state) { it.failures[index] = (it.failures[index] ?: 0) + 1 }
            CrashCollector.record("ReaderFacade", "preloadChapter", mapOf("index" to index.toString()), error)
        } finally {
            withContext(NonCancellable) { removeLoading(state, index) }
        }
    }

    private suspend fun withPreloadSnapshot(
        snapshot: PreloadSnapshot,
        state: ChapterLoadingState,
        block: suspend () -> Unit,
    ) = coroutineScope {
        val windowJob = coroutineContext.job
        fun invalidate() {
            windowJob.cancel(CancellationException("Preload target changed"))
        }
        val ready = List(3) { CompletableDeferred<Unit>() }
        // Keep image downloads cancellable too, including a late response after a source/TOC change.
        val observers = listOf(
            launch(start = CoroutineStart.UNDISPATCHED) {
                getBookUseCase(snapshot.bookUrl).collect { book ->
                    if (!snapshot.matchesBook(book)) invalidate()
                    ready[0].complete(Unit)
                }
            },
            launch(start = CoroutineStart.UNDISPATCHED) {
                observeBookChaptersUseCase(snapshot.bookUrl).collect { chapters ->
                    if (!snapshot.matchesChapters(chapters)) invalidate()
                    ready[1].complete(Unit)
                }
            },
            launch(start = CoroutineStart.UNDISPATCHED) {
                getBookSourcesUseCase().collect { sources ->
                    if (!snapshot.matchesSource(sources.firstOrNull { it.bookSourceUrl == snapshot.origin })) invalidate()
                    ready[2].complete(Unit)
                }
            },
        )
        try {
            ready.forEach { it.await() }
            requirePreloadSnapshot(snapshot, state)
            block()
            requirePreloadSnapshot(snapshot, state, checkChapters = true)
        } finally {
            observers.forEach { it.cancel() }
            withContext(NonCancellable) { observers.forEach { it.cancelAndJoin() } }
        }
    }

    private suspend fun requirePreloadSnapshot(
        snapshot: PreloadSnapshot,
        state: ChapterLoadingState,
        checkChapters: Boolean = false,
    ) {
        coroutineContext.ensureActive()
        withLoadingState(snapshot.bookUrl, state) {}
        // The window observer validates TOC emissions. Do not requery/scan the full TOC per chapter I/O.
        if (!snapshot.matchesBook(getBookUseCase.get(snapshot.bookUrl)) ||
            (checkChapters && !snapshot.matchesChapters(observeBookChaptersUseCase(snapshot.bookUrl).first())) ||
            !snapshot.matchesSource(getBookSourcesUseCase.getByUrl(snapshot.origin))
        ) {
            throw CancellationException("Preload target changed")
        }
        coroutineContext.ensureActive()
        withLoadingState(snapshot.bookUrl, state) {}
    }

    private class PreloadSnapshot(book: Book, source: BookSource, private val chapters: List<BookChapter>) {
        val bookUrl = book.bookUrl
        val origin = book.origin
        private val tocUrl = book.tocUrl
        private val reverseToc = book.config.reverseToc
        private val cacheFolder = book.getCacheFolderName()
        private val isImage = book.isImage
        private val sourceRules = PreloadSourceRules(source)

        // Page position, timestamps and display settings do not change the prefetch target.
        fun matchesBook(book: Book?): Boolean = book != null && book.bookUrl == bookUrl &&
            book.origin == origin && book.tocUrl == tocUrl && book.config.reverseToc == reverseToc &&
            book.getCacheFolderName() == cacheFolder && book.isImage == isImage && !book.isLocal

        fun matchesSource(source: BookSource?): Boolean = source != null && PreloadSourceRules(source) == sourceRules

        fun matchesChapters(latest: List<BookChapter>): Boolean = latest.size == chapters.size &&
            latest.indices.all { index -> matchesChapter(index, latest[index]) }

        fun matchesChapter(index: Int, current: BookChapter): Boolean {
            val expected = chapters.getOrNull(index) ?: return false
            // Content rules may update title/variables, and cache writes update wordCount.
            return current.bookUrl == expected.bookUrl && current.index == expected.index &&
                current.url == expected.url && current.baseUrl == expected.baseUrl &&
                current.isVolume == expected.isVolume && current.resourceUrl == expected.resourceUrl &&
                current.isVip == expected.isVip && current.isPay == expected.isPay
        }
    }

    private data class PreloadSourceRules(
        val url: String,
        val type: Int,
        val jsLib: String?,
        val header: String?,
        val loginUrl: String?,
        val loginCheckJs: String?,
        val cookieJar: Boolean,
        val concurrentRate: String?,
        val toc: TocRule?,
        val content: ContentRule?,
    ) {
        constructor(source: BookSource) : this(
            url = source.bookSourceUrl,
            type = source.bookSourceType,
            jsLib = source.jsLib,
            header = source.header,
            loginUrl = source.loginUrl,
            loginCheckJs = source.loginCheckJs,
            cookieJar = source.enabledCookieJar,
            concurrentRate = source.concurrentRate,
            toc = source.ruleToc?.copy(),
            content = source.ruleContent?.copy(imageStyle = null),
        )
    }

    suspend fun refreshTocIfNeeded(bookUrl: String): Boolean {
        return try {
            val book = getBookUseCase.get(bookUrl) ?: return false
            if (!book.shouldUpdate()) return false
            val chapters = observeBookChaptersUseCase(bookUrl).first()
            val chapterSize = chapters.size
            if (chapterSize - book.durChapterIndex - 1 >= 3) return false
            if (currentTimeMillis() - book.lastCheckTime < 600000) return false
            val source = getBookSourcesUseCase.getByUrl(book.origin) ?: return false
            val updatedBook = saveBookUseCase.ifSourceUnchanged(
                expected = book,
                book = book.copy(lastCheckTime = currentTimeMillis()),
            )
            val result = fetchChapterListUseCase(source, updatedBook, runPreUpdateJs = true).getOrThrow()
            if (result.chapters.size > chapterSize) {
                saveBookUseCase.ifSourceUnchanged(
                    expected = book,
                    book = result.book,
                    chapters = result.chapters,
                )
                true
            } else {
                false
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "refreshTocIfNeeded", error = e)
            false
        }
    }

    suspend fun clearLoadingState(bookUrl: String? = null) {
        loadingMutex.withLock {
            if (bookUrl == null) loadingStates.clear() else loadingStates.remove(bookUrl)
        }
    }

    suspend fun clearExpiredLoadingJobs(currentIndex: Int, windowSize: Int, clearAll: Boolean) {
        try {
            loadingMutex.withLock {
                loadingStates.values.forEach { state ->
                    if (clearAll) {
                        state.loading.clear()
                    } else {
                        state.loading.removeAll { idx ->
                            idx < currentIndex - windowSize || idx > currentIndex + windowSize
                        }
                    }
                }
            }
        } catch (e: kotlin.coroutines.cancellation.CancellationException) {
            throw e
        } catch (e: Throwable) {
            CrashCollector.record("ReaderFacade", "clearExpiredLoadingJobs", mapOf("currentIndex" to currentIndex.toString()), e)
        }
    }

    private suspend fun loadingState(bookUrl: String): ChapterLoadingState = loadingMutex.withLock {
        loadingStates.getOrPut(bookUrl) { ChapterLoadingState() }
    }

    private suspend fun <T> withLoadingState(
        bookUrl: String,
        state: ChapterLoadingState,
        block: (ChapterLoadingState) -> T,
    ): T = loadingMutex.withLock {
        if (loadingStates[bookUrl] !== state) {
            throw CancellationException("Chapter indices were invalidated for $bookUrl")
        }
        block(state)
    }

    private suspend fun addLoading(bookUrl: String, state: ChapterLoadingState, index: Int): Boolean {
        return withLoadingState(bookUrl, state) { it.loading.add(index) }
    }

    private suspend fun removeLoading(state: ChapterLoadingState, index: Int) {
        loadingMutex.withLock {
            state.loading.remove(index)
        }
    }

    private class ChapterLoadingState {
        val loading = mutableSetOf<Int>()
        val failures = mutableMapOf<Int, Int>()
    }

    private data class PreparedBook(
        val book: Book,
        val chapters: List<BookChapter>,
    )
}

internal data class ReaderChapterPreparation(
    /** Revision snapshot taken before directory parsing or content I/O. */
    val currentBook: Book,
    val payload: ReaderChapterPayload,
    val preloadAdjacent: Boolean = false,
)
