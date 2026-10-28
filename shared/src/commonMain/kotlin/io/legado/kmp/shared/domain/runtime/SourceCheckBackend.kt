package io.legado.kmp.shared.domain.runtime

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.exception.ContentEmptyException
import io.legado.kmp.shared.exception.TocEmptyException
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourceType
import io.legado.kmp.shared.scripting.JsExecutionException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.datetime.Clock

data class SourceCheckConfig(
    val keyword: String = "我的",
    val timeoutMs: Long = 180000L,
    val checkSearch: Boolean = true,
    val checkDiscovery: Boolean = true,
    val checkInfo: Boolean = true,
    val checkCategory: Boolean = true,
    val checkContent: Boolean = true,
)

data class SourceCheckResult(
    val sourceUrl: String,
    val invalidGroups: Set<String>,
    val failureMessage: String? = null,
    val respondTimeMs: Long = 0L,
)

class SourceCheckBackend(
    private val webBookRepository: WebBookRepository,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
    private val resolveExploreUrl: suspend (BookSource) -> String? = { source ->
        source.exploreUrl?.trim()?.takeUnless(String::isBlank)
    },
) {

    suspend fun checkSource(
        source: BookSource,
        config: SourceCheckConfig = SourceCheckConfig(),
    ): SourceCheckResult {
        val startTimeMs = currentTimeMs()
        val invalidGroups = linkedSetOf<String>()
        var failureMessage: String? = null
        try {
            withTimeout(config.timeoutMs) {
                doCheckSource(source, config, invalidGroups)
            }
        } catch (_: TimeoutCancellationException) {
            currentCoroutineContext().ensureActive()
            invalidGroups += "校验超时"
            failureMessage = "校验超时"
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            currentCoroutineContext().ensureActive()
            invalidGroups += if (error.isJsFailure()) "js失效" else "网站失效"
            failureMessage = error.message ?: error::class.simpleName
        }
        return SourceCheckResult(
            sourceUrl = source.bookSourceUrl,
            invalidGroups = invalidGroups,
            failureMessage = failureMessage,
            respondTimeMs = (currentTimeMs() - startTimeMs).coerceAtLeast(0L),
        )
    }

    private suspend fun doCheckSource(
        source: BookSource,
        config: SourceCheckConfig,
        invalidGroups: MutableSet<String>,
    ) {
        if (config.checkSearch) {
            if (source.searchUrl.isNullOrBlank()) {
                invalidGroups += "搜索链接规则为空"
            } else {
                val searchWord = source.getCheckKeyword(config.keyword)
                val searchBooks = webBookRepository.searchBook(source, searchWord, 1).getOrThrow()
                if (searchBooks.isEmpty()) {
                    invalidGroups += "搜索失效"
                } else {
                    checkBook(
                        source = source,
                        book = searchBooks.first().toBook(),
                        isSearchBook = true,
                        config = config,
                        invalidGroups = invalidGroups,
                    )
                }
            }
        }
        if (config.checkDiscovery && !source.exploreUrl.isNullOrBlank()) {
            val exploreUrl = resolveExploreUrl(source)
            if (exploreUrl.isNullOrBlank()) {
                invalidGroups += "发现规则为空"
            } else {
                val exploreBooks = webBookRepository.exploreBook(source, exploreUrl, 1).getOrThrow()
                if (exploreBooks.isEmpty()) {
                    invalidGroups += "发现失效"
                } else {
                    checkBook(
                        source = source,
                        book = exploreBooks.first().toBook(),
                        isSearchBook = false,
                        config = config,
                        invalidGroups = invalidGroups,
                    )
                }
            }
        }
    }

    private suspend fun checkBook(
        source: BookSource,
        book: Book,
        isSearchBook: Boolean,
        config: SourceCheckConfig,
        invalidGroups: MutableSet<String>,
    ) {
        val bookType = if (isSearchBook) "搜索" else "发现"
        try {
            if (!config.checkInfo) {
                return
            }
            val resolvedBook = if (book.tocUrl.isBlank()) {
                webBookRepository.getBookInfo(source, book, canReName = true).getOrThrow()
            } else {
                book
            }
            if (!config.checkCategory || source.bookSourceType == BookSourceType.FILE) {
                return
            }
            val tocResult = fetchChapterListUseCase(source, resolvedBook, runPreUpdateJs = true).getOrThrow()
            val toc = tocResult.chapters
                .asSequence()
                .filterNot { it.isVolume && it.url.startsWith(it.title) }
                .take(2)
                .toList()
            if (toc.isEmpty()) {
                invalidGroups += "${bookType}目录失效"
                return
            }
            if (!config.checkContent) {
                return
            }
            webBookRepository.getChapterContent(
                source, tocResult.book, toc.first(), needSave = false,
                nextChapterUrl = toc.getOrNull(1)?.url ?: toc.first().url,
            ).getOrThrow()
            invalidGroups -= "${bookType}目录失效"
            invalidGroups -= "${bookType}正文失效"
        } catch (_: ContentEmptyException) {
            invalidGroups += "${bookType}正文失效"
        } catch (_: TocEmptyException) {
            invalidGroups += "${bookType}目录失效"
        }
    }
}

private fun Throwable.isJsFailure(): Boolean {
    if (this is JsExecutionException) {
        return true
    }
    val name = this::class.simpleName.orEmpty()
    return name == "ScriptException" ||
        name == "WrappedException" ||
        cause?.isJsFailure() == true
}

internal fun currentTimeMs(): Long = Clock.System.now().toEpochMilliseconds()
