package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.ChapterContentRepository
import io.legado.kmp.shared.domain.usecase.ApplyReplaceRulesUseCase
import io.legado.kmp.shared.domain.usecase.ObserveBookChaptersUseCase
import io.legado.kmp.shared.domain.usecase.resolveDisplayChapterTitle
import io.legado.kmp.shared.preferences.AppPreferencesStore
import io.legado.kmp.shared.util.ChineseConverter
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.first

data class ReaderContentSearchCompletion(
    val errorCode: String?,
    val errorMessage: String?,
    val isCancelled: Boolean,
)

internal class ReaderBookContentSearch(
    private val chapterLoader: ReaderChapterLoader,
    private val observeBookChaptersUseCase: ObserveBookChaptersUseCase,
    private val chapterContentRepository: ChapterContentRepository,
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
            coroutineContext.ensureActive()
            if (chapter.isVolume) continue
            val rawContent = chapterContentRepository.getContent(book, chapter) ?: continue
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
            val positions = mutableListOf<Int>()
            var index = text.indexOf(keyword)
            while (index >= 0) {
                coroutineContext.ensureActive()
                positions.add(index)
                index = text.indexOf(keyword, index + keyword.length)
            }
            for (position in positions) {
                coroutineContext.ensureActive()
                val start = (position - 20).coerceAtLeast(0)
                val end = (position + keyword.length + 20).coerceAtMost(text.length)
                onResult(
                    ContentSearchResult(
                        chapterIndex = chapter.index,
                        chapterTitle = displayTitle,
                        matchText = text.substring(start, end),
                        query = keyword,
                        queryIndexInResult = position - start,
                        queryIndexInChapter = position,
                    )
                )
            }
        }
        coroutineContext.ensureActive()
        onFinished()
    }

    fun start(
        bookUrl: String,
        keyword: String,
        replaceEnabled: Boolean,
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
