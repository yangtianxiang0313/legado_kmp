package io.legado.kmp.shared.facade

import io.legado.kmp.shared.content.BookHelp
import io.legado.kmp.shared.domain.usecase.ContentProcessor
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.usecase.LoadChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.RefreshBookInfoUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/** Enriches candidates without writing bookshelf state, reading progress, or chapter cache. */
internal class SourceChangeCandidateLoader(
    private val book: Book,
    private val oldChapters: List<BookChapter>,
    private val fromReader: Boolean,
    private val refreshBookInfo: RefreshBookInfoUseCase,
    private val fetchChapters: FetchChapterListContractUseCase,
    private val loadContent: LoadChapterContentUseCase,
    private val contentProcessor: ContentProcessor,
) {
    suspend fun load(source: BookSource, searchBook: SearchBook, config: AppRuntimeConfig, refresh: Boolean = false): BookSourceChangeCandidate {
        if (!refresh && !config.changeSourceLoadInfo && !config.changeSourceLoadToc && !config.changeSourceLoadWordCount) {
            return searchBook.toSourceChangeCandidate()
        }
        var candidateBook = searchBook.toBook()
        if (candidateBook.tocUrl.isBlank()) {
            candidateBook = refreshBookInfo(source, candidateBook).getOrThrow()
        }
        coroutineContext.ensureActive()
        var candidate = searchBook.toSourceChangeCandidate().copy(
            sourceName = source.bookSourceName,
            displayName = candidateBook.name,
            author = candidateBook.author,
            latestChapterTitle = candidateBook.latestChapterTitle,
        )
        if (!config.changeSourceLoadToc && !config.changeSourceLoadWordCount) return candidate
        val loaded = fetchChapters(source, candidateBook, runPreUpdateJs = true).getOrThrow()
        coroutineContext.ensureActive()
        candidateBook = loaded.book
        val chapters = loaded.chapters
        candidate = candidate.copy(latestChapterTitle = candidateBook.latestChapterTitle ?: chapters.lastOrNull()?.title)
        if (!config.changeSourceLoadWordCount) return candidate
        require(chapters.isNotEmpty()) { "Candidate source has no chapters" }
        val selectedIndex = if (fromReader) {
            BookHelp.getDurChapter(
                oldDurChapterIndex = book.durChapterIndex,
                oldDurChapterName = oldChapters.getOrNull(book.durChapterIndex)?.title ?: book.durChapterTitle,
                newChapterList = chapters,
                oldChapterListSize = oldChapters.size,
            ).coerceIn(0, chapters.lastIndex)
        } else {
            chapters.lastIndex
        }
        val chapter = chapters[selectedIndex]
        val title = chapter.title.trim().let { if (it.length > 20) it.take(20) + "…" else it }
        val start = currentTimeMillis()
        val count: Int
        val text: String
        try {
            val raw = loadContent(source, candidateBook, chapter).getOrThrow()
            coroutineContext.ensureActive()
            val processed = contentProcessor.process(
                book = book, chapter = chapter, content = raw, displayTitle = chapter.title,
                useReplace = false, chineseConvert = config.reader.chineseMode,
            ).content
            count = processed.length
            text = "[${selectedIndex + 1}] $title\n字数：$count"
        } catch (error: Throwable) {
            coroutineContext.ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            return candidate.copy(
                chapterWordCount = -1,
                chapterWordCountText = "[${selectedIndex + 1}] $title\n获取字数失败：${error.message ?: error::class.simpleName}",
                respondTime = elapsed(start),
            )
        }
        coroutineContext.ensureActive()
        return candidate.copy(chapterWordCount = count, chapterWordCountText = text, respondTime = elapsed(start))
    }

    fun refreshBook(candidate: BookSourceChangeCandidate, source: BookSource): SearchBook = SearchBook(
        bookUrl = candidate.bookUrl, origin = source.bookSourceUrl, originName = source.bookSourceName,
        name = candidate.displayName, author = candidate.author, type = book.type,
        latestChapterTitle = candidate.latestChapterTitle, originOrder = source.customOrder,
        chapterWordCount = candidate.chapterWordCount, chapterWordCountText = candidate.chapterWordCountText,
        respondTime = candidate.respondTime,
    )

    private fun elapsed(start: Long): Int = (currentTimeMillis() - start).coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
}
