package io.legado.kmp.shared.facade

import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.header
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.encodeURLPathPart
import io.ktor.utils.io.readAvailable
import io.legado.kmp.shared.network.createPlatformHttpClient
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okio.Buffer

/** Dedicated export transport, not SettingsWebDavSupport's arbitrary-subdirectory uploader. */
internal class BookExportCloudStore(private val config: CloudBackupConfiguration) {
    @OptIn(ExperimentalEncodingApi::class)
    private val authorization = "Basic " + Base64.encode("${config.account}:${config.password}".encodeToByteArray())

    private val client = createPlatformHttpClient {
        expectSuccess = false
        followRedirects = false
        // No HttpCookies, Auth cache or logging plugins; the platform factory disables system cookies.
        install(HttpTimeout) {
            connectTimeoutMillis = 20_000L
            socketTimeoutMillis = 60_000L
            requestTimeoutMillis = 180_000L
        }
    }

    // Android AppWebDav.kt:43: exportsWebDavUrl = "${rootWebDavUrl}books/".
    private val exportParts = config.pathSegments + "books"
    private val exportRoot = directory(exportParts)

    fun close() {
        try {
            client.close()
        } catch (_: Throwable) {
            // Cleanup errors must not expose transport state or escape a native close() call.
        } finally {
            try {
                client.coroutineContext.cancel()
            } catch (_: Throwable) {
                // The caller still owns the previously reported remote outcome.
            }
        }
    }

    suspend fun ensureDirectory(check: suspend () -> Unit) {
        suspend fun ensure(parts: List<String>) {
            check()
            val path = directory(parts)
            if (collectionExists(path, check)) return
            if (parts.isEmpty()) throw BookExportCloudFailure(BookExportCloudMessage.COLLECTION)
            suspend fun create(): Int = request(HttpMethod("MKCOL"), path, check = check) {
                it.status.value
            }
            var status = create()
            if (status == 409) {
                // Walk only validated, same-origin configured ancestors after a missing-parent response.
                ensure(parts.dropLast(1))
                status = create()
            }
            if (status !in listOf(200, 201, 204, 405)) bookExportCloudHttpFailure(status)
            // 405 alone proves nothing: every created/raced directory must be a DAV collection.
            if (!collectionExists(path, check)) throw BookExportCloudFailure(BookExportCloudMessage.COLLECTION)
            check()
        }
        ensure(exportParts)
    }

    suspend fun upload(
        fileName: String,
        bytes: ByteArray,
        contentType: String,
        overwrite: Boolean,
        transfer: BookExportCloudTransfer,
        check: suspend () -> Unit,
    ) {
        check()
        val statement = client.prepareRequest {
            method = HttpMethod.Put
            url(exportRoot + fileName.encodeURLPathPart())
            header(HttpHeaders.Authorization, authorization)
            header(HttpHeaders.ContentType, contentType)
            header(HttpHeaders.AcceptEncoding, "identity")
            header(HttpHeaders.CacheControl, "no-cache")
            if (!overwrite) header(HttpHeaders.IfNoneMatch, "*")
            setBody(bytes)
        }
        check()
        // Once handed to the transport, failure/cancellation cannot prove the server did not accept it.
        transfer.dispatch()
        statement.execute { response ->
            transfer.receive(response.status.value)
            response.bodyAsChannel().cancel(null)
            check()
            when (response.status.value) {
                200, 201, 204, 412 -> Unit
                else -> bookExportCloudHttpFailure(response.status.value)
            }
        }
        check()
    }

    private fun directory(parts: List<String>): String = config.origin + "/" +
        parts.joinToString("/") { it.encodeURLPathPart() } + if (parts.isEmpty()) "" else "/"

    private suspend fun collectionExists(path: String, check: suspend () -> Unit): Boolean = request(
        HttpMethod("PROPFIND"), path, PROPFIND.encodeToByteArray(), "application/xml; charset=utf-8", check,
    ) { response ->
        if (response.status.value == 404) return@request false
        if (response.status.value != 207) bookExportCloudHttpFailure(response.status.value)
        val resources = parseWebDavBackups(
            readProperties(response).decodeToString(throwOnInvalidSequence = true),
            CloudBackupConfiguration(config.snapshot.copy(webDavUrl = path, webDavDir = "")),
        )
        val self = resources.singleOrNull()?.takeIf { it.name == null && it.isCollection }
            ?: throw BookExportCloudFailure(BookExportCloudMessage.COLLECTION)
        self.isCollection
    }

    private suspend fun <T> request(
        method: HttpMethod,
        path: String,
        data: ByteArray? = null,
        contentType: String? = null,
        check: suspend () -> Unit,
        handle: suspend (HttpResponse) -> T,
    ): T {
        check()
        val result = client.prepareRequest {
            this.method = method
            url(path)
            header(HttpHeaders.Authorization, authorization)
            header(HttpHeaders.AcceptEncoding, "identity")
            header(HttpHeaders.CacheControl, "no-cache")
            if (method.value == "PROPFIND") header("Depth", "0")
            contentType?.let { header(HttpHeaders.ContentType, it) }
            data?.let { setBody(it) }
        }.execute { response ->
            check()
            handle(response).also { check() }
        }
        check()
        return result
    }

    private suspend fun readProperties(response: HttpResponse): ByteArray {
        val encoding = response.headers[HttpHeaders.ContentEncoding]
        if (encoding != null && !encoding.equals("identity", true)) invalidResponse()
        val declared = response.headers[HttpHeaders.ContentLength]?.let {
            it.toLongOrNull()?.takeIf { size -> size in 0L..MAX_XML_BYTES.toLong() } ?: invalidResponse()
        }
        val channel = response.bodyAsChannel()
        val output = Buffer()
        val buffer = ByteArray(16 * 1024)
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = channel.readAvailable(buffer)
                if (count < 0) break
                if (count == 0) continue
                if (output.size + count > MAX_XML_BYTES) invalidResponse()
                output.write(buffer, 0, count)
            }
            if (declared != null && output.size != declared) invalidResponse()
            return output.readByteArray()
        } finally {
            channel.cancel(null)
            output.clear()
        }
    }

    private fun invalidResponse(): Nothing = throw BookExportCloudFailure(BookExportCloudMessage.RESPONSE)

    private companion object {
        const val MAX_XML_BYTES = 4 * 1024 * 1024
        const val PROPFIND = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"""
    }
}
