package io.legado.kmp.shared.domain.rss

import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.RssSource
import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.network.decodeLegacyUrlOptionObject
import io.legado.kmp.shared.network.resolveLegacyNetworkUrl

internal fun RssSource.asBookSourceShim(): BookSource {
    return BookSource(
        bookSourceUrl = sourceUrl,
        bookSourceName = sourceName,
        enabled = enabled,
        enabledExplore = true,
        jsLib = jsLib,
        enabledCookieJar = enabledCookieJar,
        concurrentRate = concurrentRate,
        header = header,
        loginUrl = loginUrl,
        loginUi = loginUi,
        loginCheckJs = loginCheckJs,
        coverDecodeJs = coverDecodeJs,
        bookSourceComment = sourceComment,
        variableComment = variableComment,
        lastUpdateTime = lastUpdateTime
    )
}

internal fun resolveAgainst(baseUrl: String, value: String): String {
    // An expression at the start may produce the entire URL, including its scheme.
    if (value.trimStart().startsWith("{{")) return value
    val templates = RssUrlTemplates(baseUrl, value)
    val (base, _) = splitRssUrlOptions(templates.mask(baseUrl))
    val (url, suffix) = splitRssUrlOptions(templates.mask(value))
    val resolved = resolveLegacyNetworkUrl(base, url)
    return if (resolved.isEmpty()) "" else templates.restore(resolved + suffix)
}

internal fun rssRuleBaseUrl(value: String): String {
    val templates = RssUrlTemplates(value)
    return templates.restore(splitRssUrlOptions(templates.mask(value)).first).trim()
}

private fun splitRssUrlOptions(value: String): Pair<String, String> {
    // Use AnalyzeUrl's delimiter and decoder, but retain the original option bytes.
    for (delimiter in AnalyzeUrl.paramPattern.findAll(value)) {
        val optionStart = delimiter.range.last + 1
        if (decodeLegacyUrlOptionObject(value.substring(optionStart)) != null) {
            return value.substring(0, delimiter.range.first) to value.substring(delimiter.range.first)
        }
    }
    return value to ""
}

// URLBuilder must not encode template braces or interpret slashes and queries inside JS.
private class RssUrlTemplates(vararg inputs: String) {
    private val prefix: String = run {
        var candidate = "rssurltemplate"
        while (inputs.any { it.contains(candidate, ignoreCase = true) }) candidate += "x"
        candidate
    }
    private val expressions = mutableListOf<Pair<String, String>>()

    fun mask(value: String): String = buildString {
        var index = 0
        while (index < value.length) {
            val start = value.indexOf("{{", index)
            if (start < 0) {
                append(value.substring(index))
                break
            }
            append(value.substring(index, start))
            val end = expressionEnd(value, start)
            val token = "${prefix}${expressions.size}end"
            expressions.add(token to value.substring(start, end))
            append(token)
            index = end
        }
    }

    fun restore(value: String): String {
        var result = value
        for ((token, expression) in expressions) result = result.replace(token, expression)
        return result
    }

    private fun expressionEnd(value: String, start: Int): Int {
        var quote: Char? = null
        var escaped = false
        var depth = 0
        var index = start + 2
        while (index < value.length) {
            val char = value[index]
            if (escaped) {
                escaped = false
            } else if (quote != null) {
                if (char == '\\') escaped = true else if (char == quote) quote = null
            } else {
                when (char) {
                    '\'', '"', '`' -> quote = char
                    '(', '[', '{' -> depth++
                    ')', ']', '}' -> {
                        if (char == '}' && depth == 0 && value.getOrNull(index + 1) == '}') {
                            return index + 2
                        }
                        if (depth > 0) depth--
                    }
                }
            }
            index++
        }
        return value.length
    }
}
