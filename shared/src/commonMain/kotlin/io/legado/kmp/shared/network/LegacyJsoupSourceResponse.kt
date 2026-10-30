package io.legado.kmp.shared.network

import io.ktor.http.HttpHeaders
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

internal fun LegacyJsoupResponse.toSourceResponse(check: () -> Unit = {}): SourceResponse {
    check()
    val bytes = requireNotNull(bodyBase64.decodeBase64()) { "Invalid Jsoup response bodyBase64" }.toByteArray()
    check()
    return SourceResponse(
        url = url, bodyText = bodyText, body = bytes, statusCode = statusCode, statusText = statusMessage,
        headers = headers, allHeaders = allHeaders,
    )
}

/** Rebuild raw-helper metadata from the actual bytes, without changing SourceResponse's public API. */
internal fun SourceResponse.toLegacyJsoupResponseJson(check: () -> Unit = {}): String {
    check()
    val multiHeaders = linkedMapOf<String, List<String>>()
    fun putHeaders(values: Map<String, List<String>>, onlyMissing: Boolean) {
        values.forEach { (name, fields) ->
            check()
            val key = multiHeaders.keys.firstOrNull { it.equals(name, true) }
            if (!onlyMissing || key == null) {
                val target = key ?: name
                multiHeaders[target] = multiHeaders[target].orEmpty() + fields.map {
                    check()
                    legacyJsoupResponseHeader(it)
                }
            }
        }
    }
    putHeaders(allHeaders, onlyMissing = false)
    putHeaders(headers.mapValues { listOf(it.value) }, onlyMissing = true)
    val normalizedHeaders = multiHeaders.withSplitSetCookieHeaders()
    val contentType = normalizedHeaders.entries.firstOrNull { it.key.equals(HttpHeaders.ContentType, true) }
        ?.value?.firstOrNull()
    val decoded = legacyJsoupDecodeBody(body, contentType, check)
    val cookies = LegacyJsoupCookieSession(emptyList()).apply {
        receive(
            legacyJsoupUrl(url),
            normalizedHeaders.entries.filter { it.key.equals(HttpHeaders.SetCookie, true) }.flatMap { it.value },
            check,
        )
    }.responseCookies()
    check()
    val response = LegacyJsoupResponse(
        url = url, method = "GET", statusCode = statusCode, statusMessage = statusText,
        headers = normalizedHeaders.mapValues { it.value.firstOrNull().orEmpty() }, allHeaders = normalizedHeaders,
        cookies = cookies, cookieStore = emptyList(), bodyText = decoded.text, bodyBase64 = body.toByteString().base64(),
        charset = decoded.charset, contentType = contentType,
    )
    check()
    return legacyJsoupResponseJson.encodeToString(response).also { check() }
}

private val legacyJsoupResponseJson = Json { encodeDefaults = true }
