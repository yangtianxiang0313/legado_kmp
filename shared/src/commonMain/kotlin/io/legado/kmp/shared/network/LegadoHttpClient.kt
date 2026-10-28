package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.request.HttpRequestBuilder
import io.ktor.client.request.header
import io.ktor.client.request.parameter
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse as KtorHttpResponse
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod as KtorHttpMethod
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.readAvailable
import io.legado.kmp.shared.platform.TextCodec
import io.legado.kmp.shared.preferences.AppPreferencesStore
import okio.Buffer
import okio.GzipSource
import okio.Inflater
import okio.InflaterSource
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

/**
 * HTTP request method enum
 */
enum class HttpMethod {
    GET,
    POST,
    HEAD,  // Will use GET with fallback
    PUT,   // Will use POST with override header
    DELETE, // Will use POST with override header
    PATCH  // Will use POST with override header
}

/**
 * HTTP response wrapper
 */
data class HttpResponse(
    val statusCode: Int,
    val statusText: String,
    val headers: Map<String, String>,
    val allHeaders: Map<String, List<String>> = headers.mapValues { listOf(it.value) },
    val body: ByteArray,
    val bodyText: String,
    val url: String = "",
    val errorBodyText: String? = null
) {
    val isSuccessful: Boolean
        get() = statusCode in 200..299

    val isRedirect: Boolean
        get() = statusCode in 300..399

    val isClientError: Boolean
        get() = statusCode in 400..499

    val isServerError: Boolean
        get() = statusCode in 500..599

    companion object {
        fun success(body: String = "", bodyBytes: ByteArray = ByteArray(0)): HttpResponse {
            return HttpResponse(200, "OK", emptyMap(), emptyMap(), bodyBytes, body, "", null)
        }

        fun error(statusCode: Int, message: String): HttpResponse {
            return HttpResponse(statusCode, "Error", emptyMap(), emptyMap(), ByteArray(0), message, "", message)
        }
    }
}

/**
 * HTTP request configuration
 */
data class HttpRequestConfig(
    val url: String,
    val method: HttpMethod = HttpMethod.GET,
    val headers: Map<String, String> = emptyMap(),
    val parameters: Map<String, String> = emptyMap(),
    val body: String? = null,
    val bodyBytes: ByteArray? = null,
    val timeout: Duration = 30.seconds,
    val followRedirects: Boolean = true,
    val cacheStrategy: CacheStrategy = CacheStrategy.Default
)

/**
 * Cache strategy for HTTP requests
 */
enum class CacheStrategy {
    Default,
    NoCache,
    ForceCache,
    OnlyIfCached
}

/**
 * Result of a streaming download
 */
data class StreamResult(
    val contentLength: Long?,
    val contentType: String?,
    val stream: Flow<ByteArray>
)

/**
 * HTTP client wrapper for Ktor
 * Provides a unified interface for HTTP operations across platforms
 */
class LegadoHttpClient(
    client: HttpClient? = null,
    noRedirectClient: HttpClient? = null,
    private val preferencesStore: AppPreferencesStore? = null,
) {

    private val redirectingClient: HttpClient by lazy {
        client?.withUserAgentPolicy(preferencesStore)
            ?: createDefaultHttpClient(followRedirects = true, preferencesStore = preferencesStore)
    }

    private val redirectlessClient: HttpClient by lazy {
        noRedirectClient?.withUserAgentPolicy(preferencesStore) ?: if (client == null) {
            createDefaultHttpClient(followRedirects = false, preferencesStore = preferencesStore)
        } else {
            redirectingClient
        }
    }

    /**
     * Execute an HTTP request
     *
     * @param config Request configuration
     * @return HTTP response
     */
    suspend fun execute(config: HttpRequestConfig): HttpResponse {
        val requestConfig = config.copy(headers = requestHeaders(config.headers))
        val response = if (requestConfig.followRedirects && requestConfig.method != HttpMethod.GET && requestConfig.method != HttpMethod.HEAD) {
            executeSourceHttpRedirects(requestConfig) { redirectedConfig ->
                redirectlessClient.request { applyConfig(redirectedConfig) }
            }
        } else {
            val activeClient = if (requestConfig.followRedirects) redirectingClient else redirectlessClient
            activeClient.request { applyConfig(requestConfig) }
        }

        val rawBodyBytes = response.body<ByteArray>()
        val bodyBytes = decompressResponseBody(
            bodyBytes = rawBodyBytes,
            contentEncodingHeader = response.headers[HttpHeaders.ContentEncoding]
        )
        val decodedBody = decodeResponseBody(
            bodyBytes = bodyBytes,
            contentTypeHeader = response.headers[HttpHeaders.ContentType],
        )

        val responseHeaders = response.headers.toMap().withSplitSetCookieHeaders()
        return HttpResponse(
            statusCode = response.status.value,
            statusText = response.status.description,
            headers = responseHeaders.mapValues { it.value.firstOrNull() ?: "" },
            allHeaders = responseHeaders,
            body = bodyBytes,
            bodyText = decodedBody,
            url = response.call.request.url.toString(),
            errorBodyText = decodedBody.takeIf { response.status.value !in 200..299 }
        )
    }

    /**
     * Execute a GET request
     *
     * @param url The URL to request
     * @param headers Optional headers
     * @param parameters Optional query parameters
     * @return HTTP response
     */
    suspend fun get(
        url: String,
        headers: Map<String, String> = emptyMap(),
        parameters: Map<String, String> = emptyMap()
    ): HttpResponse {
        return execute(HttpRequestConfig(
            url = url,
            method = HttpMethod.GET,
            headers = headers,
            parameters = parameters
        ))
    }

    /**
     * Execute a POST request
     *
     * @param url The URL to request
     * @param body Request body
     * @param headers Optional headers
     * @return HTTP response
     */
    suspend fun post(
        url: String,
        body: String? = null,
        headers: Map<String, String> = emptyMap()
    ): HttpResponse {
        return execute(HttpRequestConfig(
            url = url,
            method = HttpMethod.POST,
            headers = headers,
            body = body
        ))
    }

    /**
     * Execute a POST request with bytes
     *
     * @param url The URL to request
     * @param bodyBytes Request body as bytes
     * @param headers Optional headers
     * @return HTTP response
     */
    suspend fun postBytes(
        url: String,
        bodyBytes: ByteArray,
        headers: Map<String, String> = emptyMap()
    ): HttpResponse {
        return execute(HttpRequestConfig(
            url = url,
            method = HttpMethod.POST,
            headers = headers,
            bodyBytes = bodyBytes
        ))
    }

    /**
     * Execute a HEAD request
     *
     * @param url The URL to request
     * @param headers Optional headers
     * @return HTTP response (without body)
     */
    suspend fun head(
        url: String,
        headers: Map<String, String> = emptyMap()
    ): HttpResponse {
        return execute(HttpRequestConfig(
            url = url,
            method = HttpMethod.HEAD,
            headers = headers
        ))
    }

    /**
     * Stream a download as chunks
     *
     * @param url The URL to download from
     * @param headers Optional headers
     * @param chunkSize Size of chunks to emit
     * @return Flow of byte arrays
     */
    fun stream(
        url: String,
        headers: Map<String, String> = emptyMap(),
        chunkSize: Int = 8192
    ): Flow<ByteArray> = flow {
        val resolvedHeaders = requestHeaders(headers)
        val response = redirectingClient.request(normalizePlatformRequestUrl(url)) {
            resolvedHeaders.forEach { (key, value) -> header(key, value) }
        }

        val channel: ByteReadChannel = response.body()
        val buffer = ByteArray(chunkSize)

        while (!channel.isClosedForRead) {
            val read = channel.readAvailable(buffer)
            if (read > 0) {
                emit(buffer.copyOf(read))
            }
        }
    }

    /**
     * Get content length from HEAD request
     *
     * @param url The URL to check
     * @return Content length in bytes, or null if not available
     */
    suspend fun getContentLength(url: String): Long? {
        return try {
            val response = head(url)
            response.headers["Content-Length"]?.toLongOrNull()
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Close the HTTP client
     */
    fun close() {
        redirectingClient.close()
        if (redirectlessClient !== redirectingClient) {
            redirectlessClient.close()
        }
    }

    /**
     * Apply request configuration to Ktor HttpRequestBuilder
     */
    private fun HttpRequestBuilder.applyConfig(config: HttpRequestConfig) {
        url(normalizePlatformRequestUrl(config.url))

        when (config.method) {
            HttpMethod.GET -> { method = KtorHttpMethod.Get }
            HttpMethod.POST -> { method = KtorHttpMethod.Post }
            HttpMethod.HEAD -> {
                method = KtorHttpMethod.Head
            }
            HttpMethod.PUT, HttpMethod.DELETE, HttpMethod.PATCH -> {
                // Fallback to POST for simplicity
                method = KtorHttpMethod.Post
                // Add X-HTTP-Method-Override header
                header("X-HTTP-Method-Override", config.method.name)
            }
        }

        config.headers.forEach { (key, value) -> header(key, value) }

        config.parameters.forEach { (key, value) ->
            parameter(key, value)
        }

        config.body?.let {
            setBody(it)
        }

        config.bodyBytes?.let {
            setBody(it)
        }

        // Note: Timeout and redirect configuration would be applied via client configuration
        // For per-request timeout, you would use HttpTimeout plugin with request scope
    }

    companion object {
        /**
         * Create a default HTTP client with standard configuration
         */
        fun createDefaultHttpClient(
            followRedirects: Boolean = true,
            preferencesStore: AppPreferencesStore? = null,
        ): HttpClient {
            return createPlatformHttpClient {
                this.followRedirects = followRedirects

                // Configure timeout
                install(HttpTimeout) {
                    requestTimeoutMillis = 60_000
                    connectTimeoutMillis = 15_000
                    socketTimeoutMillis = 60_000
                }

                defaultRequest {
                    if (headers["Keep-Alive"] == null) {
                        header("Keep-Alive", "300")
                    }
                    if (headers["Connection"] == null) {
                        header("Connection", "Keep-Alive")
                    }
                    if (headers["Cache-Control"] == null) {
                        header("Cache-Control", "no-cache")
                    }
                    if (headers["Accept"] == null) {
                        header(
                            "Accept",
                            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
                        )
                    }
                    if (headers["Accept-Language"] == null) {
                        header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8")
                    }
                }

                // Enable automatic decompression
                // Note: This would be configured with proper plugins

                expectSuccess = false
            }.withUserAgentPolicy(preferencesStore)
        }
    }

    private suspend fun requestHeaders(headers: Map<String, String>): Map<String, String> {
        return LinkedHashMap<String, String>().apply {
            putAllUserAgentAware(headers)
            putDefaultUserAgent { configuredUserAgent(preferencesStore) }
        }
    }
}

/**
 * Extension to convert Ktor Headers to Map
 */
private fun io.ktor.http.Headers.toMap(): Map<String, List<String>> {
    val result = mutableMapOf<String, List<String>>()
    forEach { key, values ->
        result[key] = values.toList()
    }
    return result
}

private fun decodeResponseBody(
    bodyBytes: ByteArray,
    contentTypeHeader: String?,
): String {
    if (bodyBytes.isEmpty()) {
        return ""
    }
    val sanitizedBytes = bodyBytes.removeUtf8Bom()
    val charset = parseCharsetFromContentType(contentTypeHeader)
        ?: detectHtmlDeclaredCharset(sanitizedBytes)
        ?: TextCodec.detectCharset(sanitizedBytes)
    return TextCodec.decode(sanitizedBytes, charset)
}

private fun decompressResponseBody(
    bodyBytes: ByteArray,
    contentEncodingHeader: String?,
): ByteArray {
    if (bodyBytes.isEmpty()) {
        return bodyBytes
    }
    return when (contentEncodingHeader?.substringBefore(';')?.trim()?.lowercase()) {
        "gzip", "x-gzip" -> runCatching { bodyBytes.gunzip() }.getOrElse { bodyBytes }
        "deflate" -> runCatching { bodyBytes.inflateRawDeflate() }.getOrElse { bodyBytes }
        else -> bodyBytes
    }
}

private fun ByteArray.gunzip(): ByteArray {
    val compressed = Buffer().apply { write(this@gunzip) }
    val decompressed = Buffer()
    val source = GzipSource(compressed)
    try {
        decompressed.writeAll(source)
    } finally {
        source.close()
    }
    return decompressed.readByteArray()
}

private fun ByteArray.inflateRawDeflate(): ByteArray {
    val compressed = Buffer().apply { write(this@inflateRawDeflate) }
    val decompressed = Buffer()
    val source = InflaterSource(compressed, Inflater(true))
    try {
        decompressed.writeAll(source)
    } finally {
        source.close()
    }
    return decompressed.readByteArray()
}

private fun ByteArray.removeUtf8Bom(): ByteArray {
    return if (TextCodec.hasUtf8Bom(this)) {
        copyOfRange(3, size)
    } else {
        this
    }
}

private fun parseCharsetFromContentType(contentTypeHeader: String?): String? {
    if (contentTypeHeader.isNullOrBlank()) {
        return null
    }
    return charsetTokenRegex.find(contentTypeHeader)
        ?.groupValues
        ?.getOrNull(1)
        ?.normalizeCharsetName()
}

private fun detectHtmlDeclaredCharset(bodyBytes: ByteArray): String? {
    val sampleBytes = bodyBytes.copyOf(minOf(bodyBytes.size, htmlCharsetProbeLimit))
    val sample = TextCodec.decode(sampleBytes, "ISO-8859-1")
    val head = headRegex.find(sample)?.value ?: sample
    val metaTags = metaTagRegex.findAll(head).map { it.value }
    for (metaTag in metaTags) {
        metaCharsetRegex.find(metaTag)
            ?.groupValues
            ?.getOrNull(1)
            ?.normalizeCharsetName()
            ?.let { return it }
        if (metaHttpEquivRegex.containsMatchIn(metaTag)) {
            metaContentRegex.find(metaTag)
                ?.groupValues
                ?.getOrNull(1)
                ?.let(::parseCharsetFromContentType)
                ?.let { return it }
        }
    }
    return null
}

private fun String.normalizeCharsetName(): String? {
    val normalized = trim().trim('"', '\'', ';')
    return normalized.takeIf { it.isNotEmpty() }
}

private const val htmlCharsetProbeLimit = 16 * 1024
private val charsetTokenRegex = Regex("(?i)charset\\s*=\\s*[\"']?([^\\s;\"'>]+)")
private val headRegex = Regex("(?is)<head\\b[^>]*>.*?</head>")
private val metaTagRegex = Regex("(?is)<meta\\b[^>]*>")
private val metaCharsetRegex = Regex("(?i)charset\\s*=\\s*[\"']?([^\\s/>\"';]+)")
private val metaHttpEquivRegex = Regex("(?i)http-equiv\\s*=\\s*[\"']?content-type[\"']?")
private val metaContentRegex = Regex("(?i)content\\s*=\\s*[\"']([^\"']+)[\"']")
