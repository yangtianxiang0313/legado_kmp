package io.legado.kmp.shared.network

import io.ktor.http.ParametersBuilder
import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.encodeURLQueryComponent
import io.ktor.http.takeFrom
import io.legado.kmp.shared.model.StoredHttpCookie
import kotlinx.serialization.Serializable
import kotlin.random.Random

@Serializable
internal data class LegacyJsoupRequest(
    val url: String,
    val method: String = "GET",
    val headers: Map<String, String> = emptyMap(),
    val cookies: Map<String, String> = emptyMap(),
    val data: List<List<String>> = emptyList(),
    val requestBody: String? = null,
    val timeoutMillis: Int = 30_000,
    val maxBodySize: Int = 2_097_152,
    val followRedirects: Boolean = true,
    val ignoreHttpErrors: Boolean = false,
    val ignoreContentType: Boolean = false,
    val postDataCharset: String = "UTF-8",
    val cookieStore: List<StoredHttpCookie> = emptyList(),
)

@Serializable
internal data class LegacyJsoupResponse(
    val url: String,
    val method: String,
    val statusCode: Int,
    val statusMessage: String,
    val headers: Map<String, String>,
    val allHeaders: Map<String, List<String>>,
    val cookies: Map<String, String>,
    val cookieStore: List<StoredHttpCookie>,
    val bodyText: String,
    val bodyBase64: String,
    val charset: String?,
    val contentType: String?,
    val hadRedirectToGet: Boolean = false,
)

internal data class LegacyJsoupPreparedRequest(
    val url: Url,
    val method: String,
    val headers: Map<String, String>,
    val explicitCookies: String?,
    val body: ByteArray?,
    val redirectBody: ByteArray? = null,
    val hadRedirectToGet: Boolean = false,
) {
    fun redirect(origin: Url, location: String, status: Int): LegacyJsoupPreparedRequest {
        require(location.none { it < ' ' || it == '\u007f' || it == '\\' }) { "Invalid Jsoup redirect URL" }
        val fixedLocation = if (location.startsWith("http:/") && location.getOrNull(6) != '/') {
            location.substring(6)
        } else location
        val resolved = URLBuilder(origin).apply {
            if (fixedLocation.isNotEmpty() && !fixedLocation.startsWith('#')) parameters.clear()
        }.takeFrom(fixedLocation)
        val rawQuery = when {
            '?' in fixedLocation.substringBefore('#') -> fixedLocation.substringBefore('#').substringAfter('?')
            fixedLocation.isEmpty() || fixedLocation.startsWith('#') -> origin.encodedQuery
            else -> ""
        }
        resolved.legacyJsoupRawQuery(legacyJsoupEncodeRawQuery(rawQuery))
        val target = legacyJsoupUrl(resolved.buildString())
        require(origin.protocol.name != "https" || target.protocol.name == "https") {
            "Jsoup HTTPS redirect downgrade is not allowed"
        }
        val sameOrigin = origin.sameLegacyJsoupOrigin(target)
        val redirectToGet = status != 307
        return copy(
            url = target,
            method = if (redirectToGet) "GET" else method,
            headers = headers.filterKeys { name ->
                !(redirectToGet && name.lowercase() in BODY_HEADERS) &&
                    !(!sameOrigin && name.lowercase() in SENSITIVE_HEADERS)
            },
            explicitCookies = explicitCookies.takeIf { sameOrigin },
            body = (redirectBody ?: body).takeUnless { redirectToGet },
            redirectBody = null,
            hadRedirectToGet = hadRedirectToGet || redirectToGet,
        )
    }
}

internal fun LegacyJsoupRequest.prepare(check: () -> Unit = {}): LegacyJsoupPreparedRequest {
    check()
    require(method in METHODS) { "Unsupported Jsoup HTTP method: $method" }
    require(timeoutMillis >= 0) { "Jsoup timeoutMillis must be 0 or greater" }
    require(maxBodySize >= 0) { "Jsoup maxBodySize must be 0 or greater" }
    require(postDataCharset.none { it <= ' ' || it == '\u007f' || it == '"' || it == '\'' }) {
        "Invalid Jsoup postDataCharset"
    }
    val charset = requireNotNull(legacyJsoupCharset(postDataCharset)) { "Unsupported Jsoup postDataCharset" }
    require(data.all { it.size == 2 && it[0].isNotEmpty() }) { "Jsoup data must contain nonempty key/value pairs" }
    val hasBody = method in BODY_METHODS
    require(hasBody || requestBody == null) { "Jsoup $method must not have a request body" }
    var target = legacyJsoupUrl(url)
    val normalizedHeaders = linkedMapOf("Accept-Encoding" to "gzip", "User-Agent" to DEFAULT_UA)
    headers.forEach { (name, value) ->
        check()
        require(legacyJsoupToken(name) && value.none { it < ' ' || it == '\u007f' }) { "Invalid Jsoup HTTP header" }
        require(name.lowercase() !in TRANSPORT_HEADERS) { "Jsoup transport owns header: $name" }
        normalizedHeaders.keys.firstOrNull { it.equals(name, true) }?.let(normalizedHeaders::remove)
        if (name.equals("Cookie", true)) legacyJsoupValidateCookieHeader(value)
        normalizedHeaders[name] = value
    }
    cookies.forEach { (name, value) -> check(); legacyJsoupValidateCookie(name, value) }
    val explicitCookies = mapToCookieString(cookies)
    val queryData = data.isNotEmpty() && (!hasBody || requestBody != null)
    if (queryData) {
        // Append encoded pairs, not Parameters: repeated names must retain their interleaved order.
        target = URLBuilder(target).apply {
            val query = data.joinToString("&") {
                check()
                legacyJsoupForm(it[0], "UTF-8", check) + "=" + legacyJsoupForm(it[1], "UTF-8", check)
            }
            legacyJsoupRawQuery(if (target.encodedQuery.isEmpty() && !target.trailingQuery) query else "${target.encodedQuery}&$query")
        }.build()
    }
    val contentType = normalizedHeaders.entries.firstOrNull { it.key.equals("Content-Type", true) }?.value
    var boundary: String? = null
    if (hasBody && contentType == null && !queryData) {
        normalizedHeaders["Content-Type"] = "application/x-www-form-urlencoded; charset=$postDataCharset"
    } else if (hasBody && contentType == null) {
        // With data + requestBody, Jsoup skips setOutputContentType; HttpURLConnection supplies this default.
        normalizedHeaders["Content-Type"] = "application/x-www-form-urlencoded"
    } else if (hasBody && !queryData && contentType != null) {
        if (contentType.contains("multipart/form-data") && !contentType.contains("boundary")) {
            boundary = buildString { repeat(32) { append(BOUNDARY_CHARS[Random.nextInt(BOUNDARY_CHARS.length)]) } }
            normalizedHeaders.keys.firstOrNull { it.equals("Content-Type", true) }?.let(normalizedHeaders::remove)
            normalizedHeaders["Content-Type"] = "multipart/form-data; boundary=$boundary"
        }
    }
    fun plainBody(): ByteArray = if (requestBody != null) legacyJsoupEncode(requestBody, charset, check) else {
        val form = data.joinToString("&") {
            check()
            legacyJsoupForm(it[0], charset, check) + "=" + legacyJsoupForm(it[1], charset, check)
        }
        legacyJsoupEncode(form, charset, check)
    }
    val body = if (!hasBody) null else when {
        boundary != null -> legacyJsoupEncode(buildString {
            data.forEach { (name, value) ->
                check()
                require(name.none { it < ' ' || it == '\u007f' }) { "Invalid Jsoup multipart field name" }
                append("--").append(boundary).append("\r\nContent-Disposition: form-data; name=\"")
                append(name.replace("\"", "%22")).append("\"\r\n\r\n").append(value).append("\r\n")
            }
            append("--").append(boundary).append("--")
        }, charset, check)
        else -> plainBody()
    }
    // On a subsequent 307, 1.16.2 sees the existing multipart boundary and writes the ordinary body.
    val redirectBody = if (boundary != null) plainBody() else null
    check()
    return LegacyJsoupPreparedRequest(target, method, normalizedHeaders, explicitCookies, body, redirectBody)
}

internal fun legacyJsoupUrl(value: String): Url {
    require(value.isNotEmpty() && value.none { it < ' ' || it == '\u007f' || it == '\\' }) { "Invalid Jsoup URL" }
    require(value.startsWith("http://", true) || value.startsWith("https://", true)) { "Jsoup URL must use HTTP or HTTPS" }
    val authority = value.substringAfter("://").substringBefore('/').substringBefore('?').substringBefore('#')
    require(authority.isNotBlank() && '@' !in authority && authority.none { it.isWhitespace() }) {
        "Jsoup URL must have a nonempty authority without credentials"
    }
    val normalized = normalizePlatformRequestUrl(value)
    val builder = URLBuilder(normalized)
    builder.legacyJsoupRawQuery(legacyJsoupEncodeRawQuery(normalized.substringBefore('#').substringAfter('?', "")))
    val parsed = builder.build()
    require(parsed.protocol.name in setOf("http", "https") && parsed.host.isNotBlank() &&
        parsed.user == null && parsed.password == null
    ) { "Invalid Jsoup HTTP URL" }
    return parsed
}

/** Ktor groups ordinary Parameters by name; one already-encoded valueless component retains wire order. */
internal fun URLBuilder.legacyJsoupRawQuery(query: String) {
    encodedParameters = ParametersBuilder().apply {
        if (query.isNotEmpty()) appendAll(query, emptyList())
    }
}

private fun legacyJsoupEncodeRawQuery(query: String): String = RAW_QUERY_PARTS.findAll(query).joinToString("") {
    val part = it.value
    if (part.length == 3 && part[0] == '%') part
    else part.encodeURLQueryComponent(encodeFull = false, spaceToPlus = true)
}

internal fun legacyJsoupToken(value: String): Boolean = value.isNotEmpty() &&
    value.all { it in '0'..'9' || it in 'a'..'z' || it in 'A'..'Z' || it in "!#$%&'*+-.^_`|~" }

internal fun legacyJsoupValidateCookie(name: String, value: String) {
    require(legacyJsoupToken(name) && value.none { it < ' ' || it == '\u007f' || it == ';' }) {
        "Invalid Jsoup cookie"
    }
    require(name.length + value.length <= 4096) { "Jsoup cookie is too large" }
}

private fun legacyJsoupValidateCookieHeader(value: String) {
    value.split(';').filter { it.isNotBlank() }.forEach {
        val pair = it.trim()
        require(pair.indexOf('=') > 0) { "Invalid Jsoup Cookie header" }
        legacyJsoupValidateCookie(pair.substringBefore('='), pair.substringAfter('='))
    }
}

private fun legacyJsoupForm(value: String, charset: String, check: () -> Unit): String = buildString {
    var offset = 0
    while (offset < value.length) {
        check()
        val char = value[offset]
        when {
            char == ' ' -> { append('+'); offset++ }
            char.isFormSafe() -> { append(char); offset++ }
            else -> {
                val start = offset++
                while (offset < value.length && value[offset] != ' ' && !value[offset].isFormSafe()) {
                    if (offset % 8192 == 0) check()
                    offset++
                }
                // Java URLEncoder encodes each consecutive unsafe run, not the complete string.
                val bytes = legacyJsoupEncode(value.substring(start, offset), charset, check)
                bytes.forEachIndexed { index, byte ->
                    if (index % 8192 == 0) check()
                    val unsigned = byte.toInt() and 0xff
                    append('%').append(HEX[unsigned shr 4]).append(HEX[unsigned and 15])
                }
            }
        }
    }
}

private fun Char.isFormSafe(): Boolean = this in 'a'..'z' || this in 'A'..'Z' || this in '0'..'9' || this in "-_." || this == '*'

internal fun legacyJsoupTextContentType(value: String?): Boolean {
    if (value == null) return true
    return value.startsWith("text/") || XML_CONTENT_TYPE.matches(value)
}

private val METHODS = setOf("GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "TRACE")
private val BODY_METHODS = setOf("POST", "PUT", "DELETE", "PATCH")
private val BODY_HEADERS = setOf("content-type", "content-length", "transfer-encoding", "x-http-method-override")
private val SENSITIVE_HEADERS = setOf("authorization", "proxy-authorization", "cookie")
private val TRANSPORT_HEADERS = setOf("host", "content-length", "transfer-encoding")
private const val BOUNDARY_CHARS = "-_1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
private const val DEFAULT_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
    "(KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36"
private val RAW_QUERY_PARTS = Regex("%[0-9a-fA-F]{2}|[^%]+|%")
private val XML_CONTENT_TYPE = Regex("(application|text)/\\w*\\+?xml.*")
private const val HEX = "0123456789ABCDEF"
