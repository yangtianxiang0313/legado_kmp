package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.GetBookmarksUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.SaveBookUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.Bookmark
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield

internal class ReaderChapterListSupport(
    private val requireBook: suspend (String) -> Book,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val preferencesStore: AppPreferencesStore,
    private val chapterContentRepository: ChapterContentRepository,
    private val getBookUseCase: GetBookUseCase,
    private val getBookmarksUseCase: GetBookmarksUseCase,
    private val saveBookUseCase: SaveBookUseCase,
    private val chapterImages: CacheChapterImages?,
    private val invalidateChapterIndices: suspend (String) -> Unit,
) {
    /** Reload signals only; the UI owns reload coalescing and thread dispatch. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun chapterListChanges(bookUrl: String): Flow<Unit> = merge(
        getBookUseCase(bookUrl).map { Unit },
        observeBookChaptersUseCase(bookUrl).map { Unit },
        chapterContentRepository.saveContentEvents
            .filter { it.book.bookUrl == bookUrl }
            .map { Unit },
        getBookUseCase(bookUrl)
            .distinctUntilChangedBy { it?.getCacheFolderName() }
            .flatMapLatest { book ->
                if (book == null) emptyFlow() else chapterImages?.changes(book) ?: emptyFlow()
            },
        preferencesStore.runtimeConfig
            .map { it.tocUiUseReplace to it.replaceRuleEnabledByDefault }
            .distinctUntilChanged()
            .map { Unit },
    )

    @OptIn(ExperimentalCoroutinesApi::class)
    fun bookmarks(bookUrl: String): Flow<List<Bookmark>> = getBookUseCase(bookUrl)
        .map { book -> book?.let { it.name to it.author } }
        .distinctUntilChanged()
        .flatMapLatest { identity ->
            if (identity == null) {
                flowOf(emptyList())
            } else {
                getBookmarksUseCase(identity.first, identity.second)
            }
        }
        .distinctUntilChanged()

    suspend fun loadChapterListState(bookUrl: String): List<ReaderChapterListItem> {
        val book = requireBook(bookUrl)
        val preferences = preferencesStore.runtimeConfig.first()
        val useReplaceRule = book.config.useReplaceRule
            ?: (!book.isImage && !book.isEpub && preferences.replaceRuleEnabledByDefault)
        val useReplace = preferences.tocUiUseReplace && useReplaceRule
        val chapters = observeBookChaptersUseCase(bookUrl).first()
        return chapters.mapIndexed { index, chapter ->
            coroutineContext.ensureActive()
            // Check sequentially and yield between bounded batches, including missing bodies.
            if (index % 32 == 0) yield()
            val displayTitle = if (useReplace) {
                resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
            } else {
                chapter.getDisplayTitle()
            }
            coroutineContext.ensureActive()
            ReaderChapterListItem(
                chapter = chapter,
                displayTitle = displayTitle,
                isCurrent = chapter.index == book.durChapterIndex,
                isCached = isCached(book, chapter),
            )
        }
    }

    private suspend fun isCached(book: Book, chapter: BookChapter): Boolean {
        coroutineContext.ensureActive()
        if (book.isLocal || chapter.isVolume) return true
        val cached = try {
            val content = chapterContentRepository.getContent(book, chapter)
            coroutineContext.ensureActive()
            !content.isNullOrEmpty() && chapterImages?.isComplete(book, chapter, content) == true
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            false
        }
        coroutineContext.ensureActive()
        return cached
    }

    suspend fun reverseChapterList(bookUrl: String): BookDetailRefreshResult {
        coroutineContext.ensureActive()
        val current = getBookUseCase.get(bookUrl) ?: error("Book not found: $bookUrl")
        val book = current.copy(readConfig = current.readConfig?.copy())
        val chapters = observeBookChaptersUseCase(bookUrl).first().sortedBy { it.index }
        require(chapters.isNotEmpty()) { "Cannot reverse an empty chapter list" }
        coroutineContext.ensureActive()
        invalidateChapterIndices(bookUrl)
        return try {
            // Prepare URL-addressed caches before touching the directory; never delete old files here.
            chapterContentRepository.prepareForChapterReorder(book, chapters)
            coroutineContext.ensureActive()
            val committed = saveBookUseCase.reverseChapterListIfUnchanged(book, chapters)
            // Once committed, hand off its exact snapshot without further cancellable work.
            BookDetailRefreshResult(committed.book, committed.chapters)
        } finally {
            withContext(NonCancellable) { invalidateChapterIndices(bookUrl) }
        }
    }
}

/** Apply only to a parser's natural-order output, never to stored or network-ordered chapters. */
internal fun orderParsedLocalChapters(book: Book, chapters: List<BookChapter>): List<BookChapter> {
    if (!book.config.reverseToc) return chapters
    return chapters.asReversed().mapIndexed { index, chapter -> chapter.copy(index = index) }
}
