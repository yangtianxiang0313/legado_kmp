package io.legado.kmp.shared.scripting

import io.ktor.http.URLBuilder
import io.ktor.http.encodedPath
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.platform.TextCodec

internal fun legacyHttpRequestUrl(url: String): String = runCatching {
    val builder = URLBuilder(url)
    // OkHttp HttpUrl serializes an authority-only URL with a root slash.
    if (builder.build().encodedPath.isEmpty()) {
        builder.encodedPath = "/"
    }
    builder.buildString()
}.getOrDefault(url)

internal fun legacyJsUrl(url: String, baseUrl: String?): Map<String, Any?> {
    val resolved = if (!baseUrl.isNullOrBlank()) AnalyzeUrl.join(baseUrl, url) else url
    val builder = URLBuilder(resolved)
    val defaultPort = builder.protocol.defaultPort
    val portSuffix = if (builder.port > 0 && builder.port != defaultPort) ":${builder.port}" else ""
    return linkedMapOf(
        "host" to builder.host,
        "origin" to "${builder.protocol.name}://${builder.host}$portSuffix",
        "pathname" to builder.build().encodedPath,
        "searchParams" to legacyJsUrlSearchParams(resolved)
    )
}

private fun legacyJsUrlSearchParams(url: String): Map<String, String>? {
    val queryStart = url.indexOf('?')
    if (queryStart < 0) return null
    val fragmentStart = url.indexOf('#', startIndex = queryStart + 1).takeIf { it >= 0 } ?: url.length
    val query = url.substring(queryStart + 1, fragmentStart)
    val params = linkedMapOf<String, String>()
    query.split("&").forEach { entry ->
        val separator = entry.indexOf('=')
        if (separator >= 0) {
            params[entry.substring(0, separator)] = entry.substring(separator + 1).legacyUrlQueryDecodeUtf8()
        }
    }
    return params
}

private fun String.legacyUrlQueryDecodeUtf8(): String {
    if (isEmpty()) return ""
    val out = StringBuilder()
    val bytes = ArrayList<Byte>()
    fun flushBytes() {
        if (bytes.isEmpty()) return
        out.append(bytes.toByteArray().decodeToString())
        bytes.clear()
    }
    var index = 0
    while (index < length) {
        val char = this[index]
        when {
            char == '+' -> {
                flushBytes()
                out.append(' ')
                index += 1
            }
            char == '%' && index + 2 < length -> {
                val value = substring(index + 1, index + 3).toIntOrNull(16)
                if (value != null) {
                    bytes.add(value.toByte())
                    index += 3
                } else {
                    flushBytes()
                    out.append(char)
                    index += 1
                }
            }
            else -> {
                flushBytes()
                out.append(char)
                index += 1
            }
        }
    }
    flushBytes()
    return out.toString()
}

internal fun String.legacyUrlEncode(charsetName: String): String {
    val out = StringBuilder()
    var pending = StringBuilder()
    fun flushPending() {
        if (pending.isEmpty()) return
        TextCodec.encode(pending.toString(), charsetName).forEach { byte ->
            out.append('%')
            val value = byte.toInt() and 0xff
            out.append(value.toString(16).uppercase().padStart(2, '0'))
        }
        pending = StringBuilder()
    }
    for (char in this) {
        when {
            char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char == '.' || char == '-' || char == '*' || char == '_' -> {
                flushPending()
                out.append(char)
            }
            char == ' ' -> {
                flushPending()
                out.append('+')
            }
            else -> pending.append(char)
        }
    }
    flushPending()
    return out.toString()
}
