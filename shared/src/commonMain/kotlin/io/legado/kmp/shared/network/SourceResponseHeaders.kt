package io.legado.kmp.shared.network

import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMessage
import io.ktor.http.renderSetCookieHeader
import io.ktor.http.setCookie

/** Darwin can combine Set-Cookie fields; Expires commas are not cookie separators. */
internal fun Map<String, List<String>>.withSplitSetCookieHeaders(): Map<String, List<String>> =
    mapValues { (name, values) ->
        if (name.equals("Set-Cookie", ignoreCase = true)) values.flatMap(::splitCombinedCookieField)
        else values
    }

private fun splitCombinedCookieField(value: String): List<String> {
    if (',' !in value) return listOf(value)
    val message = object : HttpMessage {
        override val headers: Headers = Headers.build { append(HttpHeaders.SetCookie, value) }
    }
    // The public parser handles combined fields; its raw splitting helper is internal to Ktor.
    return runCatching { message.setCookie() }.getOrDefault(emptyList()).mapNotNull { cookie ->
        runCatching {
            renderSetCookieHeader(
                name = cookie.name,
                value = cookie.value,
                encoding = cookie.encoding,
                maxAge = cookie.maxAge,
                expires = cookie.expires,
                domain = cookie.domain,
                path = cookie.path,
                secure = cookie.secure,
                httpOnly = cookie.httpOnly,
                extensions = cookie.extensions,
                includeEncoding = false,
            )
        }.getOrNull()
    }
}
