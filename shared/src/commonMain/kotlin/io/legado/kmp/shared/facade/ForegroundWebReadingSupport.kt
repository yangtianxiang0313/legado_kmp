package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.repository.CacheRepository
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.RefreshBookInfoUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.Cache
import io.legado.kmp.shared.model.SearchBook
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.*

/** Web layout is independent of native reader preferences; only explicit /saveBook adds a shelf book. */
internal class ForegroundWebReadingSupport(
    private val cache: CacheRepository,
    private val details: BookDetailFacade,
    private val shelf: BookshelfFacade,
    private val reader: ReaderFacade,
    private val sources: GetBookSourcesUseCase,
    private val refreshInfo: RefreshBookInfoUseCase,
    private val images: BookImageFacade,
    private val json: Json,
) {
    suspend fun getReadConfig(): JsonElement {
        val raw = cache.getValue(READ_CONFIG_KEY) ?: error("没有配置")
        require(raw.isNotBlank() && checkedJson(raw) is JsonObject) { "Web 阅读配置不是 JSON 对象" }
        return JsonPrimitive(raw)
    }

    suspend fun saveReadConfig(body: String): JsonElement {
        requireJsonSize(body)
        val value = if (body.isBlank()) null else checkedJson(body)
        require(value == null || value is JsonNull || value is JsonObject) { "Web 阅读配置必须为 JSON 对象" }
        currentCoroutineContext().ensureActive()
        if (value == null || value is JsonNull) {
            cache.delete(READ_CONFIG_KEY)
        } else {
            // Preserve the original JSON, including unknown fields, whitespace and number spelling.
            cache.insert(Cache(key = READ_CONFIG_KEY, value = body, deadline = 0L))
        }
        return JsonPrimitive("")
    }

    suspend fun getBookInfo(bookUrl: String, origin: String?): JsonElement {
        var book = persistedBook(bookUrl, origin)
        if (book != null && !book.isNotShelf) return json.encodeToJsonElement(book)
        if (book == null) {
            require(BookLinkAddressValidator.accepts(bookUrl)) { "搜索预览必须为 HTTP(S) 书籍地址" }
            val candidate = if (origin != null) {
                require(origin.isNotBlank() && origin.length <= 32 * 1024 && '\u0000' !in origin) { "书源地址无效" }
                val source = requireNotNull(sources.getByUrl(origin)) { "未找到对应书源" }
                // Same production detail use case as BookLinkResolver, with the selected source kept explicit.
                refreshInfo(source, bookUrl).getOrThrow()
            } else {
                shelf.prepareBookLink(bookUrl)
            }
            require(candidate.bookUrl == bookUrl && !candidate.isLocal && candidate.name.isNotBlank()) { "书籍详情解析无效" }
            require(origin == null || candidate.origin == origin) { "书籍详情与所选书源不一致" }
            currentCoroutineContext().ensureActive()
            // Native preview insertion is atomic and NOT_SHELF; it never replaces an existing row.
            book = details.preparePreview(SearchBook.fromBook(candidate))
            require(book.origin == candidate.origin && !book.isLocal) { "相同地址已有其他书源书籍，未覆盖原书" }
        }
        val prepared = requireNotNull(book)
        if (!prepared.isNotShelf) return json.encodeToJsonElement(prepared)
        val refreshed = details.refreshInfo(prepared.bookUrl)
        require(refreshed.origin == prepared.origin) { "书籍已换源，请重新读取详情" }
        currentCoroutineContext().ensureActive()
        val result = if (reader.loadChapterListState(prepared.bookUrl).isEmpty()) {
            details.refreshChapters(prepared.bookUrl).book
        } else refreshed
        require(result.origin == prepared.origin) { "书籍已换源，请重新读取详情" }
        return json.encodeToJsonElement(result)
    }

    suspend fun persistedBook(bookUrl: String, origin: String?): Book? {
        validateBookUrl(bookUrl)
        return details.resolvePersistedBook(bookUrl)?.also {
            require(origin == null || it.origin == origin) { "相同地址已有其他书源书籍，未覆盖原书" }
        }
    }

    /** data is a plain base64 string, without a data-URL prefix or a MIME object. */
    suspend fun getBookImage(bookUrl: String, src: String, origin: String?): JsonElement {
        require(src.isNotBlank() && src.length <= 64 * 1024 && '\u0000' !in src) { "图片链接为空或过长" }
        requireNotNull(persistedBook(bookUrl, origin)) { "请先读取书籍详情" }
        val data = requireNotNull(images.loadBookImageBase64(bookUrl, src, isCover = false)) { "图片加载失败" }
        require(data.isNotEmpty() && data.length <= MAX_IMAGE_BASE64_CHARS) { "图片为空或超过 Web 响应容量" }
        return JsonPrimitive(data)
    }

    suspend fun getCover(bookUrl: String, origin: String?): JsonElement {
        requireNotNull(persistedBook(bookUrl, origin)) { "请先读取书籍详情" }
        val data = images.loadBookCoverBase64(bookUrl) ?: return JsonNull
        require(data.length <= MAX_IMAGE_BASE64_CHARS) { "封面超过 Web 响应容量" }
        return JsonPrimitive(data)
    }

    /** Android /saveBook acknowledges with ""; no client path, cover, progress, group or layout is imported. */
    suspend fun saveBook(request: ForegroundWebRequestSupport): JsonElement {
        val payload = checkedJson(request.body) as? JsonObject ?: error("书籍必须为 JSON 对象")
        val bookUrl = payload.foregroundWebString("bookUrl")?.takeIf(String::isNotBlank)
            ?: request.parameter("url", "bookUrl")
        val origin = payload.foregroundWebString("origin")?.takeIf(String::isNotBlank)
            ?: request.optionalParameter("origin")
        val trusted = requireNotNull(persistedBook(bookUrl, origin)) { "请先读取书籍详情后再加入书架" }
        currentCoroutineContext().ensureActive()
        // This native transaction rechecks origin and changes only NOT_SHELF, preserving all saved fields.
        details.completePreviewReadingExit(trusted.bookUrl, trusted.origin, addToShelf = true)
        return JsonPrimitive("")
    }

    private fun validateBookUrl(bookUrl: String) {
        require(bookUrl.isNotBlank() && bookUrl.length <= 32 * 1024 && '\u0000' !in bookUrl) { "书籍地址为空或过长" }
    }

    private fun requireJsonSize(raw: String) {
        require(raw.length <= MAX_JSON_BYTES && raw.encodeToByteArray().size <= MAX_JSON_BYTES) { "JSON 正文超过 1 MiB" }
    }

    private suspend fun checkedJson(raw: String): JsonElement {
        requireJsonSize(raw)
        // Bound nesting before the structured parser so hostile input cannot exhaust its stack.
        var depth = 0
        var quoted = false
        var escaped = false
        raw.forEachIndexed { index, character ->
            if (index % 4096 == 0) currentCoroutineContext().ensureActive()
            if (quoted) {
                if (escaped) escaped = false else when (character) {
                    '\\' -> escaped = true
                    '"' -> quoted = false
                }
            } else when (character) {
                '"' -> quoted = true
                '{', '[' -> { depth++; require(depth <= 64) { "JSON 嵌套超过上限" } }
                '}', ']' -> { depth--; require(depth >= 0) { "JSON 格式不对" } }
            }
        }
        val value = try { json.parseToJsonElement(raw) } catch (_: SerializationException) { error("JSON 格式不对") }
        val pending = ArrayDeque<JsonElement>()
        pending.add(value)
        var count = 0
        while (pending.isNotEmpty()) {
            if (++count % 256 == 0) currentCoroutineContext().ensureActive()
            require(count <= 20_000) { "JSON 元素数量超过上限" }
            when (val element = pending.removeLast()) {
                is JsonObject -> pending.addAll(element.values)
                is JsonArray -> pending.addAll(element)
                is JsonPrimitive -> require(element is JsonNull || element.isString || element.content == "true" || element.content == "false" || JSON_NUMBER.matches(element.content)) {
                    "JSON 值格式不对"
                }
            }
            require(count + pending.size <= 20_000) { "JSON 元素数量超过上限" }
        }
        return value
    }

    private companion object {
        const val READ_CONFIG_KEY = "webReadConfig"
        const val MAX_JSON_BYTES = 1024 * 1024
        const val MAX_IMAGE_BASE64_CHARS = 16 * 1024 * 1024 - 1024
        val JSON_NUMBER = Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")
    }
}
