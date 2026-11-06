package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.UpdateReadingProgressUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.model.isTxtLocalBook
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class ForegroundWebBookSupport(
    private val shelf: BookshelfFacade,
    private val details: BookDetailFacade,
    private val reader: ReaderFacade,
    private val progressWrites: UpdateReadingProgressUseCase,
    private val progressUploads: ReaderProgressUploadQueue,
    private val json: Json,
    private val reading: ForegroundWebReadingSupport,
) {
    suspend fun getChapterList(bookUrl: String, origin: String? = null): JsonElement {
        if (reading.persistedBook(bookUrl, origin) == null) reading.getBookInfo(bookUrl, origin)
        val chapters = reader.loadChapterListState(bookUrl).map { it.chapter }
        return if (chapters.isEmpty()) refreshToc(bookUrl) else json.encodeToJsonElement(chapters)
    }

    suspend fun getBookContent(request: ForegroundWebRequestSupport): JsonElement {
        val bookUrl = request.parameter("url", "bookUrl")
        val origin = request.optionalParameter("origin")
        val index = request.parameter("index").toIntOrNull() ?: error("章节序号无效")
        require(index >= 0) { "章节序号无效" }
        val book = reading.persistedBook(bookUrl, origin) ?: run {
            reading.getBookInfo(bookUrl, origin)
            requireNotNull(reading.persistedBook(bookUrl, origin)) { "未在数据库找到对应书籍，请先添加" }
        }
        val payload = reader.prepareChapter(bookUrl, index, false)
        check(sameReaderProgressIdentity(book.copy(tocUrl = payload.book.tocUrl), payload.book)) {
            "书籍身份或目录顺序已改变，请重新加载书籍"
        }
        return buildJsonObject {
            put("title", payload.displayTitle)
            put("content", payload.content)
            put("index", payload.chapter.index)
            if (book.isImage) {
                put("imageSources", json.encodeToJsonElement(MangaChapterParser.imageSources(payload.chapter, payload.content)))
            }
        }
    }

    suspend fun refreshToc(bookUrl: String): JsonElement {
        val book = requirePersistedBook(bookUrl)
        if (!book.isLocal && book.tocUrl.isBlank()) {
            details.refreshInfo(bookUrl)
        }
        currentCoroutineContext().ensureActive()
        return json.encodeToJsonElement(details.refreshChapters(bookUrl).chapters)
    }

    suspend fun deleteBook(request: ForegroundWebRequestSupport): JsonElement {
        val payload = request.bodyObject()
        val bookUrl = bookUrl(payload, request) ?: error("缺少书籍地址：bookUrl")
        val current = requirePersistedBook(bookUrl)
        checkOptionalIdentity(payload, current)
        currentCoroutineContext().ensureActive()
        // The existing deletion path owns database cleanup; local original files are never requested here.
        val result = shelf.removeBooks(listOf(current.bookUrl))
        currentCoroutineContext().ensureActive()
        check(result.updatedCount == 1 && result.failedCount == 0) { "删除书籍失败" }
        return JsonPrimitive("")
    }

    suspend fun saveProgress(request: ForegroundWebRequestSupport): JsonElement {
        val payload = request.bodyObject()
        // Android/Gson accepts an absent nullable title; the shared model requires an explicit null.
        val progress = json.decodeFromJsonElement<BookProgress>(JsonObject(
            payload + ("durChapterTitle" to (payload["durChapterTitle"] ?: JsonNull)),
        ))
        require(progress.name.isNotBlank()) { "书名不能为空" }
        require(progress.durChapterIndex >= 0 && progress.durChapterPos >= 0 && progress.durChapterTime >= 0) {
            "阅读进度无效"
        }
        val beforeCatalog = resolveProgressBook(payload, request, progress)
        checkOptionalIdentity(payload, beforeCatalog)
        request.optionalParameter("origin")?.let { require(it == beforeCatalog.origin) { "书源已改变，请重新加载书籍" } }
        val chapters = reader.loadChapterListState(beforeCatalog.bookUrl).map { it.chapter }
        val current = requirePersistedBook(beforeCatalog.bookUrl)
        // First TXT use may populate tocUrl. Adopt that catalog, never a concurrently changed progress revision.
        val expected = if (beforeCatalog.isTxtLocalBook && beforeCatalog.totalChapterNum == 0) {
            beforeCatalog.copy(tocUrl = current.tocUrl)
        } else beforeCatalog
        check(sameReaderProgressRevision(expected, current)) { "本地书籍或阅读进度已改变，请重新加载后重试" }
        val isPdf = current.isLocal && current.bookUrl.substringAfterLast('.').equals("pdf", true)
        // PDF imports persist one chapter per actual page, not the document's outline entries.
        val readableCount = if (isPdf) chapters.size else reader.computeSimulatedChapterSize(current.readConfig, chapters.size)
        require(progress.durChapterIndex in 0 until readableCount &&
            chapters.getOrNull(progress.durChapterIndex)?.index == progress.durChapterIndex
        ) { "阅读进度超出可读目录范围，请先刷新目录" }
        if (isPdf) {
            require(chapters.withIndex().all { (index, chapter) ->
                chapter.index == index && chapter.url == "pdf-page-${index + 1}"
            }) { "PDF 逐页目录无效，请先刷新目录" }
            require(progress.durChapterPos == 0) { "PDF 页内位置必须为 0" }
        }
        val updated = current.copy(
            durChapterIndex = progress.durChapterIndex,
            durChapterPos = progress.durChapterPos,
            durChapterTitle = progress.durChapterTitle,
        )
        currentCoroutineContext().ensureActive()
        // Import the external clock in the same conditional, progress-only transaction.
        val result = progressWrites.ifUnchangedAtTime(current, updated, progress.durChapterTime)
        val saved = requireNotNull(result.book) { "书籍已移除，进度未保存" }
        if (!result.persisted) {
            check(sameReaderProgressRevision(current, saved)) { "本地阅读进度已改变，请重试" }
        } else {
            // This queue obeys syncBookProgress/Plus; enabling Web writes does not enable WebDAV sync.
            progressUploads.stage(saved)
        }
        currentCoroutineContext().ensureActive()
        return JsonPrimitive("")
    }

    private suspend fun resolveProgressBook(
        payload: JsonObject,
        request: ForegroundWebRequestSupport,
        progress: BookProgress,
    ): Book {
        val url = bookUrl(payload, request)
        val book = if (url != null) {
            requirePersistedBook(url)
        } else {
            val matches = shelf.loadBooks(-1).filter { it.name == progress.name && it.author == progress.author }
            require(matches.size == 1) {
                if (matches.isEmpty()) "未找到对应书籍，请先添加" else "存在同名同作者书籍，请指定 bookUrl"
            }
            matches.single()
        }
        require(book.name == progress.name && book.author == progress.author) { "书籍地址与书名、作者不匹配" }
        return book
    }

    private fun bookUrl(payload: JsonObject, request: ForegroundWebRequestSupport): String? =
        payload.foregroundWebString("bookUrl")?.takeIf(String::isNotBlank)
            ?: payload.foregroundWebString("url")?.takeIf(String::isNotBlank)
            ?: request.optionalParameter("url", "bookUrl")

    private fun checkOptionalIdentity(payload: JsonObject, book: Book) {
        payload.foregroundWebString("name")?.let { require(it == book.name) { "书名与书籍地址不匹配" } }
        payload.foregroundWebString("author")?.let { require(it == book.author) { "作者与书籍地址不匹配" } }
        payload.foregroundWebString("origin")?.let { require(it == book.origin) { "书源已改变，请重新加载书籍" } }
    }

    private suspend fun requirePersistedBook(bookUrl: String): Book =
        requireNotNull(details.resolvePersistedBook(bookUrl)) { "未在数据库找到对应书籍，请先添加" }
}
