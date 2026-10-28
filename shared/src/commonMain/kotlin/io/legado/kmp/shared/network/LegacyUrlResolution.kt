package io.legado.kmp.shared.network

import io.ktor.http.URLBuilder
import io.ktor.http.authority
import io.ktor.http.encodedPath
import io.ktor.http.takeFrom

internal fun resolveLegacyNetworkUrl(base: String, relative: String): String {
    val reference = relative.trim()
    if (base.isBlank() || reference.startsWith("http://", true) || reference.startsWith("https://", true)) return reference
    if (reference.startsWith("data:", true)) return reference
    if (reference.startsWith("javascript", true)) return ""
    val baseUrl = base.substringBefore(',').trim()
    if (reference.isEmpty()) return baseUrl
    return runCatching {
        val builder = URLBuilder(baseUrl)
        require(builder.host.isNotEmpty() && baseUrl.contains("://"))
        if (reference.startsWith("//")) return@runCatching "${builder.protocol.name}:$reference"

        val originalPath = builder.encodedPath
        val suffixStart = reference.indexOfAny(charArrayOf('?', '#'))
        val referencePath = if (suffixStart < 0) reference else reference.substring(0, suffixStart)
        val suffix = if (suffixStart < 0) "" else reference.substring(suffixStart)
        builder.encodedParameters.clear()
        builder.encodedFragment = ""
        builder.trailingQuery = false
        if (reference.startsWith('#')) {
            // Fragments keep the current document and its raw, possibly signed query.
            return@runCatching builder.toLegacyUrlString() + rawQuery(baseUrl) + reference
        }
        if (reference.startsWith('?')) {
            // java.net.URL resolves a query-only reference against the containing directory.
            builder.encodedPath = originalPath.substringBeforeLast('/', "") + "/"
        } else {
            builder.takeFrom(referencePath)
            if (!referencePath.startsWith('/') && originalPath.isNotEmpty()) {
                builder.encodedPath = normalizeLegacyRelativePath(builder.encodedPath)
            }
        }
        builder.toLegacyUrlString() + suffix
    }.getOrDefault(reference)
}

private fun URLBuilder.toLegacyUrlString(): String {
    val url = buildString()
    // Ktor omits explicit default ports; java.net.URL retains them in book identity URLs.
    if (port != 0 && port == protocol.defaultPort) {
        val prefix = "${protocol.name}://$authority"
        return "$prefix:$port" + url.removePrefix(prefix)
    }
    return url
}

private fun rawQuery(url: String): String {
    val document = url.substringBefore('#')
    val start = document.indexOf('?')
    return if (start < 0) "" else document.substring(start)
}

// Only merged relative paths are normalized by Android's java.net.URL handler.
private fun normalizeLegacyRelativePath(path: String): String {
    val segments = path.split('/')
    val result = mutableListOf<String>()
    for ((index, segment) in segments.withIndex()) {
        when (segment) {
            "." -> if (index == segments.lastIndex) result.add("")
            ".." -> {
                if (result.size > 1 && result.last() != "..") {
                    result.removeAt(result.lastIndex)
                    if (index == segments.lastIndex) result.add("")
                } else {
                    result.add(segment)
                }
            }
            else -> result.add(segment)
        }
    }
    return result.joinToString("/")
}
