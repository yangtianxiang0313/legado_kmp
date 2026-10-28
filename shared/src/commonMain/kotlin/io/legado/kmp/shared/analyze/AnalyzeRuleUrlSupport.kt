package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.network.AnalyzeUrl
import io.legado.kmp.shared.util.unescapeHtml4
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

internal object AnalyzeRuleUrlSupport {
    private val lineBreakPattern = Regex("""[\r\n]+""")
    private val controlCharsPattern = Regex("""[\u0000-\u001F\u007F]+""")
    private val optionJson = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    fun getString(
        result: AnalyzeResult,
        baseUrl: String?,
        redirectUrl: String?,
        unescape: Boolean,
        fallbackToBase: Boolean = true
    ): String {
        for (rawValue in rawValues(result)) {
            val value = if (unescape && '&' in rawValue) unescapeHtml4(rawValue) else rawValue
            val (url, suffix) = splitRequestOptions(value)
            val urlLines = url.split(lineBreakPattern).map(::sanitizeUrl).filter { it.isNotEmpty() }
            // Preserve one request, but never attach its options to a preceding URL in a list.
            val candidate = if (suffix.isNotEmpty() && urlLines.size == 1) {
                urlLines.single() + suffix
            } else {
                value.split(lineBreakPattern).map(::sanitizeCandidate).firstOrNull { it.isNotEmpty() }
            }
            if (candidate != null) {
                return resolveCandidate(candidate, baseUrl, redirectUrl)
            }
        }
        return if (fallbackToBase) baseUrl ?: "" else ""
    }

    fun getStringList(result: AnalyzeResult, baseUrl: String?, redirectUrl: String?): List<String> {
        return rawValues(result)
            .flatMap { it.split(lineBreakPattern) }
            .map(::sanitizeCandidate)
            .filter { it.isNotEmpty() }
            .map { resolveCandidate(it, baseUrl, redirectUrl) }
            .filter { it.isNotBlank() }
            .distinct()
    }

    private fun rawValues(result: AnalyzeResult): List<String> = when (result) {
        is AnalyzeResult.StringVal -> listOf(result.value)
        is AnalyzeResult.StringList -> result.values
        is AnalyzeResult.Elements -> result.values.map { it.toString() }
        is AnalyzeResult.IntVal -> listOf(result.value.toString())
        is AnalyzeResult.LongVal -> listOf(result.value.toString())
        is AnalyzeResult.FloatVal -> listOf(result.value.toString())
        is AnalyzeResult.BoolVal -> listOf(if (result.value) "true" else "false")
        is AnalyzeResult.Null -> emptyList()
    }

    private fun sanitizeUrl(value: String): String = value.replace(controlCharsPattern, "").trim()

    private fun sanitizeCandidate(value: String): String {
        val (url, suffix) = splitRequestOptions(value)
        return sanitizeUrl(url) + suffix
    }

    private fun splitRequestOptions(value: String): Pair<String, String> {
        // Match AnalyzeUrl's option syntax without reserializing or cleaning the option payload.
        for (delimiter in AnalyzeUrl.paramPattern.findAll(value)) {
            val optionStart = delimiter.range.last + 1
            val isObject = runCatching {
                optionJson.parseToJsonElement(value.substring(optionStart)) is JsonObject
            }.getOrDefault(false)
            if (isObject) {
                return value.substring(0, delimiter.range.first) to value.substring(delimiter.range.first)
            }
        }
        return value to ""
    }

    private fun resolveCandidate(value: String, baseUrl: String?, redirectUrl: String?): String {
        val (url, suffix) = splitRequestOptions(value)
        val cleaned = sanitizeUrl(url)
        if (cleaned.isBlank() || cleaned.startsWith("javascript", ignoreCase = true)) return ""
        if (cleaned.startsWith("data:", ignoreCase = true) ||
            cleaned.startsWith("http://", ignoreCase = true) ||
            cleaned.startsWith("https://", ignoreCase = true)
        ) {
            return cleaned + suffix
        }
        val resolveBase = (redirectUrl ?: baseUrl)?.substringBefore(",")?.trim().orEmpty()
        if (resolveBase.isBlank()) return cleaned + suffix
        return runCatching { AnalyzeUrl.join(resolveBase, cleaned) }.getOrDefault(cleaned) + suffix
    }
}
