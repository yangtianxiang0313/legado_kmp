package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.legado.kmp.shared.domain.usecase.GetBookSourcesUseCase
import io.legado.kmp.shared.domain.usecase.GetBookUseCase
import io.legado.kmp.shared.domain.usecase.RefreshBookInfoUseCase
import io.legado.kmp.shared.domain.usecase.SearchUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.network.AnalyzeUrl
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.coroutines.coroutineContext

data class BookLinkPreparationResult(
    val book: Book? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)

/** Stateless routing validation; uses the same grammar as link preparation without DI or I/O. */
object BookLinkAddressValidator {
    fun accepts(address: String): Boolean = try {
        BookLinkAddress.parse(address)
        true
    } catch (_: Exception) {
        false
    }
}

internal class BookLinkResolver(
    private val books: GetBookUseCase,
    private val sources: GetBookSourcesUseCase,
    private val refresh: RefreshBookInfoUseCase,
    private val search: SearchUseCase,
) {
    suspend fun prepare(raw: String): Book {
        val address = BookLinkAddress.parse(raw)
        coroutineContext.ensureActive()
        books.get(address.rule)?.let {
            coroutineContext.ensureActive()
            return it
        }
        val attempted = mutableSetOf<String>()

        suspend fun trySource(source: BookSource?): Book? {
            coroutineContext.ensureActive()
            if (source == null || !attempted.add(source.bookSourceUrl)) return null
            // Keep UrlOption, source headers, cookies and JS in the existing detail pipeline.
            val prepared = try {
                refresh(source, address.rule).getOrThrow().also {
                    require(it.bookUrl.isNotBlank() && it.name.isNotBlank()) { "书籍详情解析为空" }
                }
            } catch (error: Exception) {
                coroutineContext.ensureActive()
                findFacadeRequestCancellation(error)?.let { throw it }
                return null
            }
            coroutineContext.ensureActive()
            books.get(prepared.bookUrl)?.let {
                coroutineContext.ensureActive()
                return it
            }
            coroutineContext.ensureActive()
            // The existing detail page resolves this candidate; opening a link never adds a shelf book.
            search.addResult(SearchBook.fromBook(prepared))
            coroutineContext.ensureActive()
            return prepared
        }

        address.origin?.let { origin ->
            trySource(sources.getByUrl(origin))?.let { return it }
        }
        val enabled = sources.getEnabled().sortedBy { it.customOrder }
        for (source in enabled) {
            coroutineContext.ensureActive()
            if (source.bookSourceUrl.trim().trimEnd('/') == address.baseUrl) {
                trySource(source)?.let { return it }
            }
        }
        for (source in enabled) {
            coroutineContext.ensureActive()
            if (!source.hasBookUrlPattern || source.bookSourceUrl in attempted) continue
            val matches = try {
                Regex(source.bookUrlPattern.orEmpty()).matches(address.rule)
            } catch (_: IllegalArgumentException) {
                false
            }
            if (matches) trySource(source)?.let { return it }
        }
        coroutineContext.ensureActive()
        error(if (attempted.isEmpty()) "未找到匹配书源" else "匹配书源未能解析书籍详情，请检查书源或登录状态")
    }
}

private data class BookLinkAddress(val rule: String, val baseUrl: String, val origin: String?) {
    companion object {
        private val json = Json { isLenient = true }

        fun parse(raw: String): BookLinkAddress {
            require(raw.length <= 32 * 1024 && raw.encodeToByteArray().size <= 32 * 1024) { "书籍地址过长" }
            val rule = raw.trim()
            require(rule.startsWith("http://", ignoreCase = true) || rule.startsWith("https://", ignoreCase = true)) {
                "书籍地址必须是 HTTP(S) 链接"
            }
            val delimiter = AnalyzeUrl.paramPattern.find(rule)
            val prefix = (delimiter?.let { rule.substring(0, it.range.first) } ?: rule).trim()
            require(prefix.none { it.isWhitespace() || it.code < 32 || it == '\\' }) { "书籍地址格式不对" }
            val url = Url(prefix)
            require(url.protocol.name.lowercase() in setOf("http", "https") && url.host.isNotBlank()) { "书籍地址格式不对" }
            require(url.user == null && url.password == null) { "书籍地址不能包含用户名或密码" }
            require(url.port in 1..65535) { "书籍地址端口范围不对" }
            val authority = prefix.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#')
            val portDelimiter = authority.lastIndexOf(':')
            if (portDelimiter > authority.lastIndexOf(']')) {
                val port = authority.substring(portDelimiter + 1)
                require(port.isNotEmpty() && port.all { it in '0'..'9' } && (port.toIntOrNull() ?: 0) in 1..65535) {
                    "书籍地址端口范围不对"
                }
            }
            val options = delimiter?.let {
                json.parseToJsonElement(rule.substring(it.range.last + 1)) as? JsonObject
                    ?: error("UrlOption 必须是 JSON 对象")
            }
            val origin = when (val value = options?.get("origin")) {
                null, JsonNull -> null
                is JsonPrimitive -> {
                    require(value.isString) { "UrlOption origin 必须是字符串" }
                    value.content.takeIf { it.isNotBlank() }
                }
                else -> error("UrlOption origin 必须是字符串")
            }
            return BookLinkAddress(rule, AnalyzeUrl.getBaseUrl(prefix).trimEnd('/'), origin)
        }
    }
}
