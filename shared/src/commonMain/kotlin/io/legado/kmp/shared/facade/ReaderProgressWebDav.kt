package io.legado.kmp.shared.facade

import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.utils.io.readAvailable
import io.legado.kmp.shared.model.BookProgress
import io.legado.kmp.shared.network.createPlatformHttpClient
import io.legado.kmp.shared.preferences.AppRuntimeConfig
import kotlin.coroutines.cancellation.CancellationException
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import okio.Buffer

/** Progress has stricter missing/error semantics than an optional backup listing. */
internal class ReaderProgressWebDav {
    private var closed = false
    private val clientDelegate = lazy {
        createPlatformHttpClient {
            expectSuccess = false
            followRedirects = false
            install(HttpTimeout) {
                requestTimeoutMillis = 20_000
                connectTimeoutMillis = 10_000
                socketTimeoutMillis = 20_000
            }
        }
    }
    private val client by clientDelegate
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    data class Endpoint(val root: String, val account: String, val password: String) {
        private val address = readerProgressAddress(root)
        internal val rootDirectory = readerProgressUrl(address.origin, address.segments, true)
        val directory: String = readerProgressUrl(address.origin, address.segments + "bookProgress", true)

        init {
            requireProgressCredentials(account, password)
        }

        fun file(name: String, author: String): String = readerProgressUrl(
            address.origin, address.segments + listOf("bookProgress", progressFileName(name, author)), false,
        )

        internal fun requireTarget(raw: String): ReaderProgressAddress {
            val target = readerProgressAddress(raw)
            val collection = address.segments + "bookProgress"
            if (target.origin != address.origin ||
                !(target.segments == address.segments || target.segments == collection ||
                    (target.segments.size == collection.size + 1 && target.segments.dropLast(1) == collection))
            ) invalidProgressAddress()
            return target
        }

        override fun toString(): String = "Endpoint(redacted)"
    }

    data class Document(val progress: BookProgress?, val etag: String?)

    /** Keys are href basenames decoded once, including .json; timestamps are Unix milliseconds. */
    suspend fun list(endpoint: Endpoint): Map<String, Long> = request(
        endpoint, endpoint.directory, HttpMethod("PROPFIND"),
        configure = {
            header(HttpHeaders.ContentType, "application/xml; charset=utf-8")
            header(HttpHeaders.Accept, "application/xml, text/xml")
            header("Depth", "1")
            setBody(PROPFIND)
        },
    ) { response ->
        if (response.status.value == 404) return@request emptyMap()
        requireStatus(response.status.value, 207, "获取云端进度目录")
        val bytes = readBounded(response, MAX_LISTING_BYTES, listing = true)
        parseReaderProgressListing(strictProgressText(bytes, listing = true), endpoint.directory)
    }

    suspend fun read(endpoint: Endpoint, name: String, author: String): Document = request(
        endpoint, endpoint.file(name, author), HttpMethod.Get,
        configure = { header(HttpHeaders.Accept, "application/json") },
    ) { response ->
        if (response.status.value == 404) return@request Document(null, null)
        requireStatus(response.status.value, 200, "获取云端进度")
        val bytes = readBounded(response, MAX_PROGRESS_BYTES, listing = false)
        val progress = try {
            json.decodeFromString(BookProgress.serializer(), strictProgressText(bytes, listing = false))
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            currentCoroutineContext().ensureActive()
            throw RecoverableSharedException("PROGRESS_INVALID", "无法解析云端阅读进度")
        }
        if (progress.name != name || progress.author != author || progress.durChapterIndex < 0 ||
            progress.durChapterPos < 0 || progress.durChapterTime < 0
        ) {
            throw RecoverableSharedException("PROGRESS_INVALID", "云端进度与当前书籍不匹配或位置无效")
        }
        Document(progress, response.headers[HttpHeaders.ETag]?.takeIf { !it.startsWith("W/") })
    }

    suspend fun write(endpoint: Endpoint, progress: BookProgress, compared: Document? = null) {
        val payload = json.encodeToString(BookProgress.serializer(), progress).encodeToByteArray()
        suspend fun put(): Int = request(
            endpoint, endpoint.file(progress.name, progress.author), HttpMethod.Put,
            configure = {
                header(HttpHeaders.ContentType, "application/json")
                if (compared != null) {
                    if (compared.progress == null) header(HttpHeaders.IfNoneMatch, "*")
                    else compared.etag?.let { header(HttpHeaders.IfMatch, it) }
                }
                setBody(payload)
            },
        ) { it.status.value }
        var status = put()
        if (status == 404 || status == 409) {
            ensureDirectory(endpoint, endpoint.rootDirectory)
            ensureDirectory(endpoint, endpoint.directory)
            currentCoroutineContext().ensureActive()
            status = put()
        }
        currentCoroutineContext().ensureActive()
        requireSuccess(status, "上传阅读进度")
    }

    fun close() {
        closed = true
        if (!clientDelegate.isInitialized()) return
        try {
            client.close()
        } catch (_: Exception) {
            // Cleanup must not expose engine diagnostics or replace a known mutation outcome.
        } finally {
            try { client.coroutineContext.cancel() } catch (_: Exception) { }
        }
    }

    private suspend fun ensureDirectory(endpoint: Endpoint, directory: String) {
        val status = request(endpoint, directory, HttpMethod("MKCOL")) { it.status.value }
        if (status == 405) {
            request(endpoint, directory, HttpMethod("PROPFIND"), configure = {
                header(HttpHeaders.ContentType, "application/xml; charset=utf-8")
                header("Depth", "0")
                setBody(PROPFIND)
            }) { response ->
                requireStatus(response.status.value, 207, "检查进度目录")
                val bytes = readBounded(response, MAX_LISTING_BYTES, listing = true)
                parseReaderProgressListing(strictProgressText(bytes, listing = true), directory, requireCollection = true)
            }
        } else {
            requireSuccess(status, "创建进度目录")
        }
    }

    private suspend fun <T> request(
        endpoint: Endpoint,
        targetUrl: String,
        method: HttpMethod,
        configure: HttpRequestBuilder.() -> Unit = {},
        receive: suspend (HttpResponse) -> T,
    ): T {
        currentCoroutineContext().ensureActive()
        if (closed) throw RecoverableSharedException("WEBDAV_CLOSED", "WebDAV 进度会话已关闭")
        val expected = endpoint.requireTarget(targetUrl)
        try {
            return client.prepareRequest {
                this.method = method
                url(expected.url)
                header(HttpHeaders.Authorization, authorization(endpoint))
                header(HttpHeaders.AcceptEncoding, "identity")
                header(HttpHeaders.CacheControl, "no-cache")
                configure()
            }.execute { response ->
                try {
                    currentCoroutineContext().ensureActive()
                    if (endpoint.requireTarget(response.call.request.url.toString()).url != expected.url) {
                        invalidProgressAddress()
                    }
                    receive(response).also { currentCoroutineContext().ensureActive() }
                } finally {
                    // Cancel both the channel and call, including redirects, missing files and failures.
                    try { response.bodyAsChannel().cancel(null) } catch (_: Exception) { }
                    finally { try { response.coroutineContext.cancel() } catch (_: Exception) { } }
                }
            }
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            currentCoroutineContext().ensureActive()
            if (error is RecoverableSharedException) throw error
            throw RecoverableSharedException("WEBDAV_NETWORK", "WebDAV 进度请求失败，请检查网络后重试")
        }
    }

    private suspend fun readBounded(response: HttpResponse, limit: Int, listing: Boolean): ByteArray {
        val output = Buffer()
        val channel = response.bodyAsChannel()
        try {
            val encoding = response.headers.getAll(HttpHeaders.ContentEncoding)
            if (encoding != null && (encoding.size != 1 || !encoding.single().equals("identity", true))) {
                invalidProgressBody(listing)
            }
            if (response.headers[HttpHeaders.ContentRange] != null) invalidProgressBody(listing)
            val lengths = response.headers.getAll(HttpHeaders.ContentLength)
            val declared = lengths?.let {
                if (it.size != 1 || response.headers[HttpHeaders.TransferEncoding] != null) invalidProgressBody(listing)
                val text = it.single().trim(' ', '\t')
                if (text.isEmpty() || text.any { digit -> digit !in '0'..'9' }) invalidProgressBody(listing)
                text.toLongOrNull() ?: invalidProgressBody(listing)
            }
            if (declared != null && declared > limit) progressBodyLimit(listing)
            val buffer = ByteArray(16 * 1024)
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = channel.readAvailable(buffer, 0, minOf(buffer.size, limit - output.size.toInt() + 1))
                if (count < 0) break
                if (count == 0) continue
                if (output.size + count > limit) progressBodyLimit(listing)
                output.write(buffer, 0, count)
                if (declared != null && output.size > declared) invalidProgressBody(listing)
            }
            currentCoroutineContext().ensureActive()
            if (output.size == 0L || (declared != null && output.size != declared)) invalidProgressBody(listing)
            return output.readByteArray()
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            currentCoroutineContext().ensureActive()
            if (error is RecoverableSharedException) throw error
            // Engines may report a truncated Content-Length as a channel failure rather than EOF.
            invalidProgressBody(listing)
        } finally {
            try { channel.cancel(null) } catch (_: Exception) { }
            finally { output.clear() }
        }
    }

    @OptIn(ExperimentalEncodingApi::class)
    private fun authorization(endpoint: Endpoint): String =
        "Basic " + Base64.encode("${endpoint.account}:${endpoint.password}".encodeToByteArray())

    private fun requireStatus(status: Int, expected: Int, action: String) {
        if (status != expected) readerProgressHttpFailure(status, action)
    }

    private fun requireSuccess(status: Int, action: String) {
        if (status !in 200..299) readerProgressHttpFailure(status, action)
    }

    companion object {
        private const val MAX_PROGRESS_BYTES = 256 * 1024
        private const val MAX_LISTING_BYTES = 4 * 1024 * 1024
        private const val PROPFIND = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getlastmodified/></d:prop></d:propfind>"""

        fun endpoint(config: AppRuntimeConfig): Endpoint? {
            val account = config.webDavAccount?.takeIf { it.isNotBlank() } ?: return null
            val password = config.webDavPassword?.takeIf { it.isNotBlank() } ?: return null
            requireProgressCredentials(account, password)
            val configuredUrl = config.webDavUrl.orEmpty()
            if (configuredUrl.any { it.isISOControl() }) invalidProgressAddress()
            val raw = configuredUrl.trim().ifEmpty { SettingsWebDavSupport.DEFAULT_WEBDAV_URL }
            val normalized = when {
                raw.startsWith("davs://", true) -> "https://" + raw.substring(7)
                raw.startsWith("dav://", true) -> "http://" + raw.substring(6)
                else -> raw
            }
            val address = readerProgressAddress(normalized)
            val configuredDir = config.webDavDir
            if (configuredDir.any { it.isISOControl() || it == '\\' } || "//" in configuredDir) invalidProgressDirectory()
            val directory = configuredDir.trim().trim('/')
            val parts = if (directory.isEmpty()) emptyList() else directory.split('/').map {
                readerProgressSegment(it, ::invalidProgressDirectory)
            }
            return Endpoint(readerProgressUrl(address.origin, address.segments + parts, true), account, password)
        }

        fun progressFileName(name: String, author: String): String =
            "${name}_${author}".replace(Regex("[\\\\/:*?\"<>|]"), "_") + ".json"
    }
}

private fun requireProgressCredentials(account: String, password: String) {
    if (account.isBlank() || password.isBlank() || ':' in account ||
        account.any { it.isISOControl() } || password.any { it.isISOControl() }
    ) throw RecoverableSharedException("WEBDAV_CREDENTIALS", "WebDAV 账号或密码格式无效")
    try {
        account.encodeToByteArray(throwOnInvalidSequence = true)
        password.encodeToByteArray(throwOnInvalidSequence = true)
    } catch (_: Exception) {
        throw RecoverableSharedException("WEBDAV_CREDENTIALS", "WebDAV 账号或密码格式无效")
    }
}

private fun strictProgressText(bytes: ByteArray, listing: Boolean): String = try {
    bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF")
} catch (_: Exception) {
    invalidProgressBody(listing)
}

private fun invalidProgressBody(listing: Boolean): Nothing = if (listing) invalidProgressListing()
else throw RecoverableSharedException("PROGRESS_INVALID", "云端阅读进度响应无效或不完整")

private fun progressBodyLimit(listing: Boolean): Nothing = throw RecoverableSharedException(
    if (listing) "PROGRESS_LISTING_LIMIT" else "PROGRESS_LIMIT",
    if (listing) "云端进度目录响应超过大小限制" else "云端阅读进度超过大小限制",
)

internal fun readerProgressHttpFailure(status: Int, action: String): Nothing = when (status) {
    401, 403 -> throw RecoverableSharedException("WEBDAV_AUTH", "WebDAV 认证失败，请检查账号和密码")
    412 -> throw RecoverableSharedException("PROGRESS_CONFLICT", "云端进度已改变，请重新同步后确认")
    in 300..399 -> throw RecoverableSharedException("WEBDAV_REDIRECT", "WebDAV 返回重定向，请填写最终服务地址")
    in 100..599 -> throw RecoverableSharedException("WEBDAV_HTTP_$status", "$action 失败（HTTP $status），可稍后重试")
    else -> throw RecoverableSharedException("WEBDAV_RESPONSE", "WebDAV 返回的 HTTP 状态无效")
}

private fun invalidProgressDirectory(): Nothing = throw RecoverableSharedException("WEBDAV_DIR", "WebDAV 目录无效")
