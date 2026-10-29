package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.BookRepository
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.BookSourceRepository
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.getCacheFolderName
import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlin.coroutines.coroutineContext
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The automatic batch owns immutable targets, not the book's changing reading position. */
internal class AutomaticBookCacheTarget private constructor(
    private val books: BookRepository,
    private val chapters: BookChapterRepository,
    private val sources: BookSourceRepository,
    private val preferences: AppPreferencesStore,
    private val book: Book,
    source: BookSource,
    private val catalog: List<BookChapter>,
    private val count: Int,
) {
    private var requestJob: Job? = null
    private val sourceRules = source.rules()
    private val folder = book.getCacheFolderName()

    companion object {
        suspend fun create(
            books: BookRepository, chapters: BookChapterRepository, sources: BookSourceRepository,
            preferences: AppPreferencesStore?, bookUrl: String,
        ): AutomaticBookCacheTarget {
            val config = checkNotNull(preferences)
            val book = books.getBook(bookUrl) ?: throw CancellationException("Automatic cache book removed")
            if (!book.shouldUpdate() || book.isNotShelf || book.isLocal) {
                throw CancellationException("Automatic cache book changed")
            }
            val source = sources.getBookSource(book.origin)
                ?: throw CancellationException("Automatic cache source removed")
            val count = config.runtimeConfig.first().preDownloadNum.coerceIn(0, 9999)
            if (count == 0) throw CancellationException("Automatic cache disabled")
            return AutomaticBookCacheTarget(
                books, chapters, sources, config, book, source,
                chapters.getChaptersByBookUrl(bookUrl), count,
            )
        }

        private fun BookSource.rules(): List<Any?> = listOf(
            bookSourceUrl, bookSourceType, jsLib, header, loginUrl, loginCheckJs,
            enabledCookieJar, concurrentRate, ruleToc?.copy(), ruleContent?.copy(imageStyle = null),
        )
    }

    private fun matchesBook(current: Book?): Boolean = current != null &&
        current.bookUrl == book.bookUrl && current.origin == book.origin && current.tocUrl == book.tocUrl &&
        current.getCacheFolderName() == folder && current.config.reverseToc == book.config.reverseToc &&
        current.type == book.type && current.shouldUpdate() && !current.isNotShelf && !current.isLocal

    private fun matchesChapter(current: BookChapter?): Boolean {
        current ?: return false
        val expected = catalog.getOrNull(current.index) ?: return false
        return current.bookUrl == expected.bookUrl && current.index == expected.index &&
            current.url == expected.url && current.baseUrl == expected.baseUrl &&
            current.resourceUrl == expected.resourceUrl && current.isVolume == expected.isVolume &&
            current.isVip == expected.isVip && current.isPay == expected.isPay
    }

    private fun reject() {
        requestJob?.cancel(CancellationException("Automatic cache target changed"))
    }

    suspend fun <T> run(block: suspend () -> T): T = coroutineScope {
        requestJob = coroutineContext.job
        val ready = List(3) { CompletableDeferred<Unit>() }
        val observers = listOf(
            launch(start = CoroutineStart.UNDISPATCHED) {
                books.observeBook(book.bookUrl).collect {
                    if (!matchesBook(it)) reject()
                    ready[0].complete(Unit)
                }
            },
            launch(start = CoroutineStart.UNDISPATCHED) {
                sources.observeAllBookSources().collect { all ->
                    if (all.firstOrNull { it.bookSourceUrl == book.origin }?.rules() != sourceRules) reject()
                    ready[1].complete(Unit)
                }
            },
            launch(start = CoroutineStart.UNDISPATCHED) {
                preferences.runtimeConfig.collect {
                    if (it.preDownloadNum.coerceIn(0, 9999) != count) reject()
                    ready[2].complete(Unit)
                }
            },
        )
        try {
            ready.forEach { it.await() }
            coroutineContext.ensureActive()
            block()
        } finally {
            observers.forEach { it.cancel() }
            withContext(NonCancellable) { observers.forEach { it.cancelAndJoin() } }
            requestJob = null
        }
    }

    suspend fun requireChapter(chapter: BookChapter) {
        coroutineContext.ensureActive()
        if (!matchesBook(books.getBook(book.bookUrl)) ||
            sources.getBookSource(book.origin)?.rules() != sourceRules ||
            !matchesChapter(chapter) || !matchesChapter(chapters.getChapter(book.bookUrl, chapter.index))
        ) {
            reject()
            throw CancellationException("Automatic cache target changed")
        }
        coroutineContext.ensureActive()
    }

    suspend fun <T> withChapter(chapter: BookChapter, block: suspend () -> T): T = coroutineScope {
        val ready = CompletableDeferred<Unit>()
        // Observe one indexed row per active worker, never materialize the whole TOC per body/image write.
        val observer = launch(start = CoroutineStart.UNDISPATCHED) {
            chapters.observeChapterByBookUrlAndIndex(book.bookUrl, chapter.index).collect {
                if (!matchesChapter(it)) reject()
                ready.complete(Unit)
            }
        }
        try {
            ready.await()
            requireChapter(chapter)
            block().also { requireChapter(chapter) }
        } finally {
            observer.cancel()
            withContext(NonCancellable) { observer.cancelAndJoin() }
        }
    }
}
