package io.legado.kmp.shared.domain.usecase

import io.legado.kmp.shared.analyze.AnalyzeRule
import io.legado.kmp.shared.domain.repository.BookChapterRepository
import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.JsExecutor
import io.legado.kmp.shared.network.LegacyJsConnectGateway
import io.legado.kmp.shared.network.SourceHeaderResolver
import io.legado.kmp.shared.scripting.SourceJsRuntime
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlin.coroutines.cancellation.CancellationException

data class ChapterListLoadResult(
    val book: Book,
    val chapters: List<BookChapter>
)

class FetchChapterListUseCase(
    private val repository: WebBookRepository,
    private val chapterRepository: BookChapterRepository,
    private val applyReplaceRulesUseCase: ApplyReplaceRulesUseCase,
    private val sourceStateStore: SourceStateStore,
    private val jsExecutor: JsExecutor,
    private val sourceJsRuntime: SourceJsRuntime? = null,
    private val connectGateway: LegacyJsConnectGateway? = null,
    private val headerResolver: SourceHeaderResolver? = null
) {
    suspend operator fun invoke(
        source: BookSource,
        book: Book,
        runPreUpdateJs: Boolean = false,
        debugSink: BookSourceDebugSink? = null,
    ): Result<ChapterListLoadResult> = runCatching {
        val preparedBook = if (runPreUpdateJs) {
            executePreUpdateJs(source, book)
        } else {
            book
        }

        val detailedBook = ensureTocReadyBook(source, preparedBook)
        val result = repository.getChapterListWithBook(source, detailedBook, debugSink).getOrThrow()
        val chaptersWithWordCount = mergeWordCount(result.book.bookUrl, result.chapters)
        val updatedBook = buildUpdatedBook(result.book, chaptersWithWordCount)
        ChapterListLoadResult(updatedBook, chaptersWithWordCount)
    }.onFailure { error ->
        if (error is CancellationException) throw error
        currentCoroutineContext().ensureActive()
    }

    private suspend fun ensureTocReadyBook(source: BookSource, book: Book): Book {
        if (book.tocUrl.isNotBlank() || source.isFile) {
            return book
        }
        return repository.getBookInfo(source, book, canReName = true)
            .getOrElse { error ->
                if (error is CancellationException) throw error
                currentCoroutineContext().ensureActive()
                book
            }
    }

    private suspend fun executePreUpdateJs(source: BookSource, book: Book): Book {
        val preUpdateJs = source.ruleToc?.preUpdateJs?.takeIf { it.isNotBlank() } ?: return book
        var currentBook = book
        val analyzeRule = AnalyzeRule(
            source = source,
            sourceStateStore = sourceStateStore,
            jsExecutor = jsExecutor,
            connectGateway = connectGateway,
            headerResolver = headerResolver,
            sourceJsRuntime = sourceJsRuntime,
            legacyReGetBook = {
                currentBook = reGetBookInPreUpdate(source, currentBook)
                currentBook
            },
            legacyRefreshTocUrl = {
                currentBook = refreshTocUrlInPreUpdate(source, currentBook)
                currentBook
            }
        )
        analyzeRule.setContent("", book.bookUrl)
        analyzeRule.setBookContext(book)
        analyzeRule.getString("@js:$preUpdateJs")
        val runtimeBook = analyzeRule.getBookContext() ?: currentBook
        val updatedVariables = analyzeRule.getVariables()
        val mergedRuntimeVariables = runtimeBook.variableMap + updatedVariables
        return if (mergedRuntimeVariables.isEmpty()) {
            runtimeBook
        } else {
            runtimeBook.copy(variable = variableJson.encodeToString(mergedRuntimeVariables)).also {
                it.infoHtml = runtimeBook.infoHtml
                it.tocHtml = runtimeBook.tocHtml
                it.downloadUrls = runtimeBook.downloadUrls
            }
        }
    }

    private suspend fun reGetBookInPreUpdate(source: BookSource, book: Book): Book {
        val matched = repository.searchBook(source, book.name, 1).getOrThrow()
            .firstOrNull { it.name == book.name && it.author == book.author }
            ?: error("未搜索到 ${book.name}(${book.author}) 书籍")
        val searchedBook = mergePreUpdateBook(
            base = book,
            incoming = matched.toBook(),
            mergedVariable = mergedVariablePayload(book.variableMap, matched.variableMap)
        )
        val detailedBook = repository.getBookInfo(source, searchedBook.copy(), canReName = false).getOrThrow()
        return mergePreUpdateBook(
            base = searchedBook,
            incoming = detailedBook,
            mergedVariable = searchedBook.variable
        )
    }

    private suspend fun refreshTocUrlInPreUpdate(source: BookSource, book: Book): Book {
        val detailedBook = repository.getBookInfo(source, book.copy(), canReName = false).getOrThrow()
        return mergePreUpdateBook(
            base = book,
            incoming = detailedBook,
            mergedVariable = book.variable
        )
    }

    private fun mergePreUpdateBook(
        base: Book,
        incoming: Book,
        mergedVariable: String?
    ): Book {
        return base.copy(
            bookUrl = incoming.bookUrl.ifBlank { base.bookUrl },
            tocUrl = incoming.tocUrl.ifBlank { base.tocUrl },
            name = base.name,
            author = base.author,
            kind = incoming.kind ?: base.kind,
            coverUrl = incoming.coverUrl ?: base.coverUrl,
            intro = incoming.intro ?: base.intro,
            wordCount = incoming.wordCount ?: base.wordCount,
            latestChapterTitle = incoming.latestChapterTitle ?: base.latestChapterTitle,
            variable = mergedVariable
        ).also {
            it.infoHtml = incoming.infoHtml ?: base.infoHtml
            it.tocHtml = incoming.tocHtml ?: base.tocHtml
            it.downloadUrls = incoming.downloadUrls ?: base.downloadUrls
        }
    }

    private fun mergedVariablePayload(
        base: Map<String, String>,
        incoming: Map<String, String>
    ): String? {
        if (base.isEmpty() && incoming.isEmpty()) return null
        return variableJson.encodeToString(base + incoming)
    }

    private suspend fun mergeWordCount(bookUrl: String, chapters: List<BookChapter>): List<BookChapter> {
        val existing = chapterRepository.getChaptersByBookUrl(bookUrl)
        if (existing.isEmpty()) return chapters
        val existingMap = existing.associateBy({ it.getFileName() }, { it.wordCount })
        return chapters.map { chapter ->
            val wordCount = existingMap[chapter.getFileName()]
            if (wordCount == null) chapter else chapter.copy(wordCount = wordCount)
        }
    }

    private suspend fun buildUpdatedBook(book: Book, chapters: List<BookChapter>): Book {
        val now = io.legado.kmp.shared.util.currentTimeMillis()
        val currentChapter = chapters.getOrElse(book.durChapterIndex) { chapters.last() }
        val lastChapter = chapters.last()
        val displayCurrentTitle = resolveDisplayChapterTitle(book, currentChapter, applyReplaceRulesUseCase)
        val displayLastTitle = resolveDisplayChapterTitle(book, lastChapter, applyReplaceRulesUseCase)
        val increased = chapters.size > book.totalChapterNum

        return book.copy(
            totalChapterNum = chapters.size,
            durChapterTitle = displayCurrentTitle,
            latestChapterTitle = displayLastTitle,
            latestChapterTime = if (increased) now else book.latestChapterTime,
            lastCheckTime = now,
            lastCheckCount = if (increased) (chapters.size - book.totalChapterNum) else book.lastCheckCount
        ).also {
            it.infoHtml = book.infoHtml
            it.tocHtml = book.tocHtml
            it.downloadUrls = book.downloadUrls
        }
    }

    private companion object {
        val variableJson = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
    }
}
