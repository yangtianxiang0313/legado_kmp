package io.legado.kmp.shared.network

import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.header
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.utils.io.readAvailable
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okio.Buffer

/** A short-lived, redirectless transport. No auth cache, cookies, JS, retries, or legacy expansion. */
internal class ScopedWebDavClient(
    private val scope: ScopedWebDavScope,
    private val authorization: String,
) {
    private val client = createPlatformHttpClient {
        followRedirects = false
        expectSuccess = false
        install(HttpTimeout) {
            connectTimeoutMillis = 20_000L
            socketTimeoutMillis = 60_000L
            requestTimeoutMillis = 180_000L
        }
    }

    fun close() {
        try {
            client.close()
        } catch (_: Throwable) {
            // Never replace a known mutation outcome with a cleanup/transport diagnostic.
        } finally {
            try { client.coroutineContext.cancel() } catch (_: Throwable) { }
        }
    }

    suspend fun list(directoryUrl: String, check: suspend () -> Unit): List<WebDavFile> {
        val directory = scope.directory(directoryUrl)
        check()
        return client.prepareRequest {
            method = HttpMethod("PROPFIND")
            url(directory)
            header(HttpHeaders.Authorization, authorization)
            header(HttpHeaders.ContentType, "application/xml; charset=utf-8")
            header(HttpHeaders.AcceptEncoding, "identity")
            header("Depth", "1")
            setBody(PROPFIND)
        }.execute { response ->
            check()
            requireResponseUrl(response, directory)
            if (response.status.value != 207) scopedWebDavHttpFailure(response.status.value)
            val bytes = readProperties(response)
            check()
            val xml = try { bytes.decodeToString(throwOnInvalidSequence = true) }
            catch (_: Exception) { scopedWebDavFail(ScopedWebDavProblem.RESPONSE) }
            parseScopedWebDavListing(xml, scope, directory).also { check() }
        }
    }

    suspend fun upload(
        targetUrl: String,
        bytes: ByteArray,
        check: suspend () -> Unit,
        dispatched: () -> Unit,
        confirmed: () -> Unit,
    ) {
        if (bytes.isEmpty() || bytes.size > MAX_UPLOAD_BYTES) scopedWebDavFail(ScopedWebDavProblem.LIMIT)
        mutate(HttpMethod.Put, targetUrl, bytes, check, dispatched, confirmed)
    }

    suspend fun delete(
        targetUrl: String,
        check: suspend () -> Unit,
        dispatched: () -> Unit,
        confirmed: () -> Unit,
    ) = mutate(HttpMethod.Delete, targetUrl, null, check, dispatched, confirmed)

    private suspend fun mutate(
        method: HttpMethod,
        targetUrl: String,
        bytes: ByteArray?,
        check: suspend () -> Unit,
        dispatched: () -> Unit,
        confirmed: () -> Unit,
    ) {
        val target = scope.requireUrl(targetUrl)
        if (target.segments == scope.rootSegments) scopedWebDavFail(ScopedWebDavProblem.SCOPE)
        check()
        val statement = client.prepareRequest {
            this.method = method
            url(target.url)
            header(HttpHeaders.Authorization, authorization)
            header(HttpHeaders.AcceptEncoding, "identity")
            if (bytes != null) {
                header(HttpHeaders.ContentType, "application/octet-stream")
                setBody(bytes)
            }
        }
        check()
        // From this point cancellation/connection failure cannot prove the server rolled back.
        dispatched()
        statement.execute { response ->
            requireResponseUrl(response, target.url)
            val status = response.status.value
            val success = if (method == HttpMethod.Put) status in setOf(200, 201, 204)
                else status in setOf(200, 204, 404)
            if (success) confirmed()
            response.bodyAsChannel().cancel(null)
            check()
            if (!success) scopedWebDavHttpFailure(status)
        }
        check()
    }

    private fun requireResponseUrl(response: HttpResponse, expected: String) {
        if (scope.requireUrl(response.call.request.url.toString()).url != expected) {
            scopedWebDavFail(ScopedWebDavProblem.SCOPE)
        }
    }

    private suspend fun readProperties(response: HttpResponse): ByteArray {
        val encoding = response.headers[HttpHeaders.ContentEncoding]
        if (encoding != null && !encoding.equals("identity", true)) scopedWebDavFail(ScopedWebDavProblem.RESPONSE)
        val declared = response.headers[HttpHeaders.ContentLength]?.let {
            it.toLongOrNull()?.takeIf { length -> length >= 0 } ?: scopedWebDavFail(ScopedWebDavProblem.RESPONSE)
        }
        if (declared != null && declared > MAX_XML_BYTES) scopedWebDavFail(ScopedWebDavProblem.LIMIT)
        val channel = response.bodyAsChannel()
        val output = Buffer()
        val buffer = ByteArray(16 * 1024)
        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                val count = channel.readAvailable(buffer)
                if (count < 0) break
                if (count == 0) continue
                if (output.size + count > MAX_XML_BYTES) scopedWebDavFail(ScopedWebDavProblem.LIMIT)
                output.write(buffer, 0, count)
            }
            if (declared != null && output.size != declared) scopedWebDavFail(ScopedWebDavProblem.RESPONSE)
            return output.readByteArray()
        } finally {
            channel.cancel(null)
            output.clear()
        }
    }

    override fun toString(): String = "ScopedWebDavClient(redacted)"

    companion object {
        const val MAX_UPLOAD_BYTES = 128 * 1024 * 1024
        private const val MAX_XML_BYTES = 4 * 1024 * 1024
        private const val PROPFIND = """<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>"""
    }
}
