package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.WebBookRepository
import io.legado.kmp.shared.domain.usecase.ChapterListLoadResult
import io.legado.kmp.shared.domain.usecase.FetchChapterListContractUseCase
import io.legado.kmp.shared.domain.webBook.BookSourceDebugSink
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.BookSourceType
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.util.currentTimeMillis
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive

/** Invocation-local orchestration matching Android Debug.startDebug and its stage chain. */
internal class BookSourceDebugQuerySupport(
    private val source: BookSource,
    private val webBookRepository: WebBookRepository,
    private val fetchChapterListUseCase: FetchChapterListContractUseCase,
    private val debugSink: BookSourceDebugSink,
) {
    private val mutableSteps = mutableListOf<BookSourceDebugStep>()

    val steps: List<BookSourceDebugStep>
        get() = mutableSteps.toList()

    suspend fun run(keyword: String): Boolean {
        coroutineContext.ensureActive()
        // Order matters: an absolute detail URL can itself contain "::".
        return when {
            keyword.startsWith("http://", ignoreCase = true) ||
                keyword.startsWith("https://", ignoreCase = true) -> {
                debugSink.log(message = "⇒开始访问详情页:$keyword")
                debugInfo(newBook(bookUrl = keyword))
            }
            keyword.contains("::") -> {
                val url = keyword.substringAfter("::")
                debugSink.log(message = "⇒开始访问发现页:$url")
                debugList(url, isExplore = true)
            }
            keyword.startsWith("++") -> {
                val url = keyword.substring(2)
                debugSink.log(message = "⇒开始访目录页:$url")
                debugToc(newBook(tocUrl = url))
            }
            keyword.startsWith("--") -> {
                val url = keyword.substring(2)
                debugSink.log(message = "⇒开始访正文页:$url")
                debugContent(newBook(), BookChapter(title = "调试", url = url))
            }
            else -> {
                debugSink.log(message = "⇒开始搜索关键字:$keyword")
                debugList(keyword, isExplore = false)
            }
        }
    }

    private suspend fun debugList(query: String, isExplore: Boolean): Boolean {
        val stage = if (isExplore) "发现" else "搜索"
        val results = runStep(
            stage = stage,
            detail = if (isExplore) query else "关键词：$query",
            summary = { books: List<SearchBook> ->
                "返回 ${books.size} 条；首条：${books.firstOrNull().displayNameOrPlaceholder()}"
            },
        ) {
            debugSink.log(message = "︾开始解析${stage}页")
            if (isExplore) {
                webBookRepository.exploreBook(source, query, page = 1, debugSink = debugSink).getOrThrow()
            } else {
                webBookRepository.searchBook(source, query, page = 1, debugSink = debugSink).getOrThrow()
            }
        } ?: return false

        val book = results.firstOrNull()?.toBook()
        if (book == null) {
            debugSink.log(state = -1, message = "︽未获取到书籍")
            return false
        }
        debugSink.log(message = "︽${stage}页解析完成")
        debugSink.log(showTime = false)
        return debugInfo(book)
    }

    private suspend fun debugInfo(book: Book): Boolean {
        val resolved = if (book.tocUrl.isNotBlank()) {
            val message = "≡已获取目录链接,跳过详情页"
            mutableSteps += BookSourceDebugStep("详情", "skipped", message, book.bookUrl)
            debugSink.log(message = message)
            debugSink.log(showTime = false)
            book
        } else {
            runStep(
                stage = "详情",
                detail = book.bookUrl,
                summary = { result: Book ->
                    listOf(
                        result.displayNameOrPlaceholder(),
                        result.kind?.takeIf(String::isNotBlank),
                        result.latestChapterTitle?.takeIf(String::isNotBlank),
                    ).filterNotNull().joinToString(" / ")
                },
            ) {
                debugSink.log(message = "︾开始解析详情页")
                webBookRepository.getBookInfo(
                    source = source,
                    book = book.withSourceBookType(),
                    canReName = true,
                    debugSink = debugSink,
                ).getOrThrow()
            }?.also {
                debugSink.log(message = "︽详情页解析完成")
                debugSink.log(showTime = false)
            } ?: return false
        }

        if (resolved.isWebFile) {
            val message = "≡文件类书源跳过解析目录"
            mutableSteps += BookSourceDebugStep("目录", "skipped", message, resolved.tocUrl)
            debugSink.log(state = 1000, message = message)
            return true
        }
        return debugToc(resolved)
    }

    private suspend fun debugToc(book: Book): Boolean {
        val result = runStep(
            stage = "目录",
            detail = book.tocUrl.ifBlank { book.bookUrl },
            summary = { result: ChapterListLoadResult ->
                val firstChapter = result.chapters.firstOrNull { it.isDebugContentChapter() }
                "返回 ${result.chapters.size} 章；首章：${firstChapter?.title?.takeIf(String::isNotBlank) ?: "无"}"
            },
        ) {
            debugSink.log(message = "︾开始解析目录页")
            fetchChapterListUseCase(
                source = source,
                book = book,
                runPreUpdateJs = true,
                debugSink = debugSink,
            ).getOrThrow()
        } ?: return false

        debugSink.log(message = "︽目录页解析完成")
        debugSink.log(showTime = false)
        val contentChapters = result.chapters.filter { it.isDebugContentChapter() }
        val chapter = contentChapters.firstOrNull()
        if (chapter == null) {
            debugSink.log(state = 1000, message = "≡没有正文章节")
            return false
        }
        val nextChapterUrl = contentChapters.getOrNull(1)?.url ?: chapter.url
        return debugContent(result.book, chapter, nextChapterUrl)
    }

    private suspend fun debugContent(book: Book, chapter: BookChapter, nextChapterUrl: String? = null): Boolean {
        val content = runStep(
            stage = "正文",
            detail = chapter.title,
            summary = { text: String -> "正文长度 ${text.length} 字；预览：${text.previewText()}" },
        ) {
            debugSink.log(message = "︾开始解析正文页")
            webBookRepository.getChapterContent(
                source = source,
                book = book,
                chapter = chapter,
                needSave = false,
                debugSink = debugSink,
                nextChapterUrl = nextChapterUrl,
            ).getOrThrow()
        } ?: return false
        debugSink.log(state = 1000, message = "︽正文页解析完成")
        return content.isNotBlank()
    }

    private suspend fun <T : Any> runStep(
        stage: String,
        detail: String?,
        summary: (T) -> String,
        block: suspend () -> T,
    ): T? {
        coroutineContext.ensureActive()
        val start = currentTimeMillis()
        return try {
            val result = block()
            coroutineContext.ensureActive()
            mutableSteps += BookSourceDebugStep(
                stage = stage,
                status = "success",
                message = summary(result),
                detail = detail,
                durationMs = currentTimeMillis() - start,
            )
            result
        } catch (error: Throwable) {
            coroutineContext.ensureActive()
            findFacadeRequestCancellation(error)?.let { throw it }
            val failureMessage = error.message ?: error::class.simpleName.orEmpty()
            mutableSteps += BookSourceDebugStep(
                stage = stage,
                status = "failed",
                message = failureMessage,
                detail = detail,
                durationMs = currentTimeMillis() - start,
            )
            debugSink.log(state = -1, message = failureMessage)
            null
        }
    }

    private fun newBook(bookUrl: String = "", tocUrl: String = ""): Book = Book(
        bookUrl = bookUrl,
        tocUrl = tocUrl,
        origin = source.bookSourceUrl,
        originName = source.bookSourceName,
        type = sourceBookType(),
    )

    // Android WebBook.getBookInfoAwait assigns the source's book type before parsing details.
    private fun Book.withSourceBookType(): Book = copy(type = sourceBookType()).also {
        it.infoHtml = infoHtml
        it.tocHtml = tocHtml
        it.downloadUrls = downloadUrls
    }

    private fun sourceBookType(): Int = when (source.bookSourceType) {
        BookSourceType.FILE -> BookType.TEXT or BookType.WEB_FILE
        BookSourceType.IMAGE -> BookType.IMAGE
        BookSourceType.AUDIO -> BookType.AUDIO
        else -> BookType.TEXT
    }
}

private fun BookChapter.isDebugContentChapter(): Boolean = !(isVolume && url.startsWith(title))

private fun SearchBook?.displayNameOrPlaceholder(): String {
    if (this == null) return "无"
    return listOf(name, author).filter { it.isNotBlank() }.joinToString(" / ").ifBlank { bookUrl }
}

private fun Book.displayNameOrPlaceholder(): String {
    return listOf(name, author).filter { it.isNotBlank() }.joinToString(" / ").ifBlank { bookUrl }
}

private fun String.previewText(maxLength: Int = 120): String {
    val normalized = replace("\r", "\n")
        .lines()
        .map(String::trim)
        .filter(String::isNotEmpty)
        .joinToString(" ")
    return if (normalized.length <= maxLength) normalized else normalized.take(maxLength) + "..."
}
