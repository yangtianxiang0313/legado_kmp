package io.legado.kmp.shared.network

import io.legado.kmp.shared.preferences.AppPreferencesStore

class SourceHeaderResolver(
    private val jsExecutor: JsExecutor = JsExecutor.Default,
    private val preferencesStore: AppPreferencesStore? = null,
) {

    suspend fun defaultUserAgent(): String = configuredUserAgent(preferencesStore)

    suspend fun resolve(
        headerRule: String?,
        variables: Map<String, Any?> = emptyMap(),
        includeDefaultUserAgent: Boolean = true
    ): Map<String, String> {
        val resolvedHeaders = LinkedHashMap<String, String>()
        val headerContent = headerRule
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?.let { resolveHeaderRule(it, variables) }

        headerContent?.let {
            resolvedHeaders.putAllUserAgentAware(parseHeaderContent(it))
        }

        if (includeDefaultUserAgent) {
            resolvedHeaders.putDefaultUserAgent(::defaultUserAgent)
        }

        return resolvedHeaders
    }

    private suspend fun resolveHeaderRule(
        headerRule: String,
        variables: Map<String, Any?>
    ): String {
        return when {
            headerRule.startsWith("@js:", ignoreCase = true) -> {
                jsExecutor.executeAsString(headerRule.substring(4), variables)
            }

            headerRule.isLegacyJsBlockRule() -> {
                jsExecutor.executeAsString(
                    headerRule.extractLegacyJsBlockScript(),
                    variables
                )
            }

            else -> headerRule
        }
    }

    private fun parseHeaderContent(content: String): Map<String, String> =
        decodeLegacyRequestHeaderJson(content.trim()).orEmpty()
}

internal fun String.isLegacyJsBlockRule(): Boolean {
    return trim().startsWith("<js>", ignoreCase = true)
}

internal fun String.extractLegacyJsBlockScript(): String {
    val trimmed = trim()
    val end = trimmed.lastIndexOf("<")
    return if (end > 4) {
        trimmed.substring(4, end)
    } else {
        trimmed.substring(4)
    }
}
