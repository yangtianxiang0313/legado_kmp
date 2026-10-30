package io.legado.kmp.shared.network

import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.Url
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okio.ByteString.Companion.toByteString

/** Independent Jsoup connections never enter the application's source-header or cookie pipeline. */
internal class LegacyJsoupRequestExecutor {
    suspend fun execute(requestJson: String): String {
        val context = currentCoroutineContext()
        context.ensureActive()
        val request = json.decodeFromString<LegacyJsoupRequest>(requestJson)
        val prepared = request.prepare { context.ensureActive() }
        val session = LegacyJsoupCookieSession(request.cookieStore)
        val response = if (request.timeoutMillis == 0) execute(request, prepared, session) else {
            withTimeout(request.timeoutMillis.toLong()) { execute(request, prepared, session) }
        }
        context.ensureActive()
        return json.encodeToString(response).also { context.ensureActive() }
    }

    private suspend fun execute(
        request: LegacyJsoupRequest,
        initial: LegacyJsoupPreparedRequest,
        session: LegacyJsoupCookieSession,
    ): LegacyJsoupResponse {
        var pending = initial
        var redirects = 0
        val context = currentCoroutineContext()
        while (true) {
            context.ensureActive()
            val headers = pending.headers.filterKeys { !it.equals(HttpHeaders.Cookie, true) }.toMutableMap()
            listOfNotNull(
                session.requestHeader(pending.url, pending.explicitCookies),
                pending.headers.entries.firstOrNull { it.key.equals(HttpHeaders.Cookie, true) }?.value,
            ).joinToString("; ").takeIf { it.isNotBlank() }?.let { headers[HttpHeaders.Cookie] = it }
            val response = legacyJsoupTransport(
                LegacyJsoupTransportRequest(
                    url = pending.url.toString(), method = pending.method, headers = headers,
                    body = pending.body, timeoutMillis = request.timeoutMillis, maxBodySize = request.maxBodySize,
                ),
            ) { head ->
                !(request.followRedirects && head.allHeaders.firstHeader(HttpHeaders.Location) != null) &&
                    (request.ignoreHttpErrors || head.statusCode in 200..399) &&
                    (request.ignoreContentType || legacyJsoupTextContentType(head.allHeaders.firstHeader(HttpHeaders.ContentType)))
            }
            context.ensureActive()
            val head = response.head
            val responseUrl = legacyJsoupUrl(head.url)
            require(pending.url.sameLegacyJsoupOrigin(responseUrl)) { "Unexpected platform HTTP redirect" }
            val allHeaders = head.allHeaders.mapValues { (_, values) -> values.map(::legacyJsoupResponseHeader) }
                .withSplitSetCookieHeaders()
            session.receive(responseUrl, allHeaders.headerValues(HttpHeaders.SetCookie)) { context.ensureActive() }
            check(redirects < MAX_REDIRECTS) { "Too many Jsoup redirects" }
            val location = allHeaders.firstHeader(HttpHeaders.Location)
            if (request.followRedirects && location != null) {
                pending = pending.redirect(responseUrl, location, head.statusCode)
                redirects++
                continue
            }
            val contentType = allHeaders.firstHeader(HttpHeaders.ContentType)
            val readable = (request.ignoreHttpErrors || head.statusCode in 200..399) &&
                (request.ignoreContentType || legacyJsoupTextContentType(contentType))
            val bytes = response.body
            val declaredSize = allHeaders.firstHeader(HttpHeaders.ContentLength)?.toLongOrNull()
            val coding = allHeaders.firstHeader(HttpHeaders.ContentEncoding)?.trim()?.lowercase()
            val platformDecoded = coding != null && legacyJsoupPlatformDecodesContentEncoding(coding)
            if (readable && pending.method != "HEAD" && head.statusCode != 204 && head.statusCode != 304 &&
                declaredSize != null && declaredSize >= 0 && !platformDecoded
            ) {
                check(bytes.size.toLong() == declaredSize ||
                    request.maxBodySize > 0 && bytes.size == request.maxBodySize && declaredSize > bytes.size
                ) { "Jsoup response Content-Length mismatch" }
            }
            val decoded = legacyJsoupDecodeBody(bytes, contentType) { context.ensureActive() }
            context.ensureActive()
            return LegacyJsoupResponse(
                url = responseUrl.toString(), method = pending.method, statusCode = head.statusCode,
                statusMessage = HttpStatusCode.fromValue(head.statusCode).description,
                headers = allHeaders.mapValues { it.value.firstOrNull().orEmpty() }, allHeaders = allHeaders,
                cookies = session.responseCookies(), cookieStore = session.snapshot(),
                bodyText = decoded.text, bodyBase64 = bytes.toByteString().base64(),
                charset = decoded.charset, contentType = contentType, hadRedirectToGet = pending.hadRedirectToGet,
            )
        }
    }

    private companion object {
        const val MAX_REDIRECTS = 20
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}

private fun Map<String, List<String>>.headerValues(name: String): List<String> =
    entries.firstOrNull { it.key.equals(name, true) }?.value.orEmpty()

private fun Map<String, List<String>>.firstHeader(name: String): String? = headerValues(name).firstOrNull()

internal fun Url.sameLegacyJsoupOrigin(other: Url): Boolean =
    protocol == other.protocol && host.equals(other.host, true) && port == other.port
