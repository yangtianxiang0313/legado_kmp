package io.legado.kmp.shared.domain.webBook

import io.legado.kmp.shared.network.AnalyzeUrl

internal fun resolveLegacyAbsoluteUrl(baseUrl: String, rawUrl: String): String {
    val cleaned = rawUrl.trim()
    if (cleaned.isBlank()) return ""
    if (cleaned.startsWith("javascript", ignoreCase = true)) return ""
    if (cleaned.startsWith("data:", ignoreCase = true)) return cleaned
    if (cleaned.startsWith("http://", ignoreCase = true) ||
        cleaned.startsWith("https://", ignoreCase = true)
    ) {
        return cleaned
    }
    val normalizedBase = baseUrl.substringBefore(",").trim()
    if (normalizedBase.isBlank()) return cleaned
    return runCatching { AnalyzeUrl.join(normalizedBase, cleaned) }.getOrDefault(cleaned)
}
