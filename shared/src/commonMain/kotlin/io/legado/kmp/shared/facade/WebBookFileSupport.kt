package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.network.SharedCapabilityException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json

internal object WebBookFileLimits {
    const val URL_BYTES = 64 * 1024
    const val RULE_BYTES = 64 * 1024
    const val OPTIONS = 64
    const val OPTIONS_BYTES = 512 * 1024
    const val SNAPSHOT_BYTES = 512 * 1024
    const val CACHE_BOOKS = 4
    const val CACHE_BYTES = 4 * 1024 * 1024
    const val HEADERS = 128
    const val HEADER_BYTES = 64 * 1024
    const val HEADER_VALUE_BYTES = 16 * 1024
    const val BODY_BYTES = 1024 * 1024
    const val DETAIL_BYTES = 8 * 1024 * 1024
    const val SET_COOKIES = 128
}

internal class WebBookFileFailure(val reason: String, message: String) : Exception(message)

internal fun requireWebBookFile(value: Boolean, reason: String, message: String) {
    if (!value) throw WebBookFileFailure(reason, message)
}

internal fun webBookFileBounded(value: String, limit: Int): Boolean =
    value.length <= limit && value.encodeToByteArray().size <= limit

internal fun requireWebBookFileRule(rule: String) {
    requireWebBookFile(rule.isNotBlank() && '\u0000' !in rule && webBookFileBounded(rule, WebBookFileLimits.RULE_BYTES),
        "invalidRule", "文件下载规则为空或超过大小限制")
}

internal fun webBookFileUrl(value: String): Url {
    requireWebBookFile(webBookFileBounded(value, WebBookFileLimits.URL_BYTES) && value.isNotBlank() &&
        (value.startsWith("http://", ignoreCase = true) || value.startsWith("https://", ignoreCase = true)) &&
        value.none { it.code <= 32 || it.code == 127 || it == '\\' }, "invalidUrl", "文件下载地址无效或超过大小限制")
    val parsed = try { Url(value) } catch (_: Exception) { null }
    requireWebBookFile(parsed != null && parsed.protocol.name in setOf("http", "https") &&
        parsed.host.isNotBlank() && parsed.port in 1..65535 &&
        parsed.user.isNullOrEmpty() && parsed.password.isNullOrEmpty(), "invalidUrl", "文件下载仅支持不含内嵌凭据的 HTTP(S) 地址")
    return parsed!!
}

internal fun Url.sameWebBookFileOrigin(other: Url): Boolean =
    protocol == other.protocol && host.equals(other.host, ignoreCase = true) && port == other.port

internal fun requireWebBookFileHeaders(headers: Map<String, String>) {
    requireWebBookFile(headers.size <= WebBookFileLimits.HEADERS, "invalidHeaders", "文件请求头数量超过限制")
    var bytes = 0
    for ((name, value) in headers) {
        requireWebBookFile(name.isNotEmpty() && name.length <= 256 &&
            name.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it in "!#$%&'*+-.^_`|~" } &&
            value.none { it.code < 32 && it != '\t' || it.code == 127 } &&
            webBookFileBounded(value, WebBookFileLimits.HEADER_VALUE_BYTES), "invalidHeaders", "文件请求头无效或超过大小限制")
        bytes += name.length + value.encodeToByteArray().size
        requireWebBookFile(bytes <= WebBookFileLimits.HEADER_BYTES, "invalidHeaders", "文件请求头总大小超过限制")
    }
}

internal fun webBookFileSourceSnapshot(source: BookSource): String = Json.encodeToString(BookSource.serializer(), source).also {
    requireWebBookFile(webBookFileBounded(it, WebBookFileLimits.SNAPSHOT_BYTES), "sourceTooLarge", "文件书源配置超过大小限制")
}

internal fun webBookFileRuleData(book: Book): Map<String, Any?> = linkedMapOf<String, Any?>(
    "book" to linkedMapOf(
        "bookUrl" to book.bookUrl,
        "tocUrl" to book.tocUrl,
        "origin" to book.origin,
        "originName" to book.originName,
        "name" to book.name,
        "author" to book.author,
        "kind" to book.kind,
        "intro" to book.displayIntro,
        "coverUrl" to book.displayCoverUrl,
        "wordCount" to book.wordCount,
        "type" to book.type,
        "latestChapterTitle" to book.latestChapterTitle,
        "totalChapterNum" to book.totalChapterNum,
        "variable" to book.variableMap,
    ),
    "bookUrl" to book.bookUrl,
    "bookName" to book.name,
    "bookCoverUrl" to book.displayCoverUrl,
    "bookTotalChapterNum" to book.totalChapterNum,
    "author" to book.author,
).apply { putAll(book.variableMap) }

internal class WebBookFileIssued(
    val book: Book,
    val baselineVariable: String?,
    val sourceSnapshot: String,
    val options: List<WebBookFileOption>,
) {
    val byteSize: Int

    init {
        val bookJson = Json.encodeToString(Book.serializer(), book)
        requireWebBookFile(webBookFileBounded(bookJson, WebBookFileLimits.SNAPSHOT_BYTES) &&
            webBookFileBounded(baselineVariable.orEmpty(), WebBookFileLimits.SNAPSHOT_BYTES),
            "bookTooLarge", "文件书籍上下文超过大小限制")
        byteSize = bookJson.encodeToByteArray().size + baselineVariable.orEmpty().encodeToByteArray().size +
            sourceSnapshot.encodeToByteArray().size + options.sumOf { it.urlRule.encodeToByteArray().size + it.fileName.encodeToByteArray().size }
    }

    override fun toString(): String = "WebBookFileIssued(redacted)"
}

// Accessed only under the owning facade's mutex; no source script executes during lookup.
internal class WebBookFileIssuedOptions {
    private val books = LinkedHashMap<String, WebBookFileIssued>()

    fun remove(bookUrl: String) { books.remove(bookUrl) }

    fun get(bookUrl: String): WebBookFileIssued? = books[bookUrl]

    fun put(bookUrl: String, issued: WebBookFileIssued) {
        requireWebBookFile(issued.byteSize <= WebBookFileLimits.CACHE_BYTES, "optionsTooLarge", "文件选项上下文超过大小限制")
        books.remove(bookUrl)
        books[bookUrl] = issued
        while (books.size > WebBookFileLimits.CACHE_BOOKS || books.values.sumOf { it.byteSize } > WebBookFileLimits.CACHE_BYTES) {
            books.remove(books.keys.first())
        }
    }
}

internal suspend fun <T> recoverWebBookFile(method: String, block: suspend () -> T): T = try {
    currentCoroutineContext().ensureActive()
    block().also { currentCoroutineContext().ensureActive() }
} catch (error: Throwable) {
    currentCoroutineContext().ensureActive()
    findFacadeRequestCancellation(error)?.let { throw it }
    // Never retain a cause or record an upstream exception containing signed URLs or credentials.
    throw when (error) {
        is WebBookFileFailure -> RecoverableSharedException("WebBookFileFacade.${error.reason}", error.message.orEmpty())
        is SharedCapabilityException -> RecoverableSharedException("WebBookFileFacade.unsupported", "书源请求包含当前文件下载器不支持的能力")
        else -> RecoverableSharedException("WebBookFileFacade.$method", "文件书源准备失败，请刷新列表或检查书源及登录状态")
    }
}

internal fun <T> deliverWebBookFileResult(result: T, callback: (T) -> Unit) {
    try {
        callback(result)
    } catch (error: Throwable) {
        findFacadeRequestCancellation(error)?.let { throw it }
        throw IllegalStateException("File preparation callback failed")
    }
}

internal fun webBookFileCallbackError(error: Throwable): RecoverableSharedException =
    if (error is RecoverableSharedException && error.code.startsWith("WebBookFileFacade.")) error
    else RecoverableSharedException("WebBookFileFacade.request", "文件书源请求准备失败")
