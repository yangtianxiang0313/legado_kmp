package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.ChineseConverter
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.yield

data class ReaderContentSearchCompletion(
    val errorCode: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

internal class ReaderBookContentSearch(
    private val chapterLoader: ReaderChapterLoader,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val readRawContent: suspend (Book, BookChapter) -> String?,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val preferencesStore: AppPreferencesStore,
) {
    // A null option is reserved for the original API's book/default-based behavior.
    suspend fun search(
        bookUrl: String,
        keyword: String,
        replaceEnabled: Boolean?,
        onResult: (ContentSearchResult) -> Unit,
        onFinished: () -> Unit,
    ) {
        coroutineContext.ensureActive()
        if (keyword.isEmpty() || (replaceEnabled != null && keyword.isBlank())) {
            onFinished()
            return
        }
        val book = chapterLoader.requireBook(bookUrl)
        val chapters = observeBookChaptersUseCase(bookUrl).first()
        val useReplace = replaceEnabled ?: book.config.useReplaceRule ?: chapterLoader.defaultUseReplaceRule(book)
        val chineseMode = if (replaceEnabled != null) {
            preferencesStore.runtimeConfig.first().reader.chineseMode
        } else {
            0
        }
        for (chapter in chapters) {
            yield()
            if (chapter.isVolume) continue
            val rawContent = readRawContent(book, chapter) ?: continue
            coroutineContext.ensureActive()
            val searchChapter = if (replaceEnabled == null) {
                chapter
            } else {
                chapter.copy(
                    title = when (chineseMode) {
                        1 -> ChineseConverter.t2s(chapter.title)
                        2 -> ChineseConverter.s2t(chapter.title)
                        else -> chapter.title
                    }
                )
            }
            // Android search converts the title but never applies title replacement rules.
            val displayTitle = if (replaceEnabled == null) {
                resolveDisplayChapterTitle(book, chapter, applyReplaceRulesUseCase)
            } else {
                searchChapter.title
            }
            val processed = chapterLoader.processContent(
                book = book,
                chapter = searchChapter,
                content = rawContent,
                displayTitle = displayTitle,
                useReplace = useReplace,
            )
            val text = processed.content
            val searchContext = coroutineContext
            var textIndex: ReaderSearchTextIndex? = null
            val lastMatchStart = text.length - keyword.length
            var searchIndex = 0
            var matchesSinceYield = 0
            while (searchIndex <= lastMatchStart) {
                yield()
                val batchStart = searchIndex
                val batchEnd = batchStart + minOf(maxOf(8_192, keyword.length), lastMatchStart - batchStart + 1)
                // Bound candidate starts but keep the tail needed for cross-window matches.
                val batchText = text.substring(batchStart, batchEnd + keyword.length - 1)
                var index = batchText.indexOf(keyword)
                while (index >= 0) {
                    coroutineContext.ensureActive()
                    val position = batchStart + index
                    val start = (position - 20).coerceAtLeast(0)
                    val end = (position + keyword.length + 20).coerceAtMost(text.length)
                    val coordinates = textIndex ?: ReaderSearchTextIndex.create(text) { searchContext.ensureActive() }
                        .also { textIndex = it }
                    onResult(
                        ContentSearchResult(
                            chapterIndex = chapter.index,
                            chapterTitle = displayTitle,
                            matchText = text.substring(start, end),
                            query = keyword,
                            queryIndexInResult = position - start,
                            queryIndexInChapter = position,
                        ).attachSearchCoordinates(coordinates)
                    )
                    searchIndex = position + keyword.length
                    matchesSinceYield++
                    if (matchesSinceYield == 64) {
                        yield()
                        matchesSinceYield = 0
                    }
                    index = batchText.indexOf(keyword, searchIndex - batchStart)
                }
                searchIndex = maxOf(searchIndex, batchEnd)
            }
        }
        coroutineContext.ensureActive()
        onFinished()
    }

    fun start(
        bookUrl: String,
        keyword: String,
        replaceEnabled: Boolean?,
        onResult: (ContentSearchResult) -> Unit,
        onFinished: (ReaderContentSearchCompletion) -> Unit,
    ): FlowSubscription = CancellableFacadeRequest.start(
        prepare = {
            runRecoverable("ReaderFacade.searchInBookWithOptions") {
                search(bookUrl, keyword, replaceEnabled, onResult, onFinished = {})
            }
            ReaderContentSearchCompletion(null, null, isCancelled = false)
        },
        cancelledResult = ReaderContentSearchCompletion(null, null, isCancelled = true),
        failureResult = { error ->
            val failure = error.asRecoverableSharedException("ReaderFacade.searchInBookWithOptions")
            ReaderContentSearchCompletion(failure.code, failure.message, isCancelled = false)
        },
        onResult = onFinished,
        facade = "ReaderFacade",
        callbackMethod = "searchInBookWithOptionsRequest.onFinished",
        missingResultMessage = "Content search completed without a result",
    )
}
