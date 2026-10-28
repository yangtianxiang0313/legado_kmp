package io.legado.kmp.shared.network

import io.legado.kmp.shared.preferences.AppPreferencesStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

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

    private fun parseHeaderContent(content: String): Map<String, String> {
        val trimmed = content.trim()
        if (trimmed.isEmpty()) return emptyMap()
        return parseJsonHeaders(trimmed) ?: emptyMap()
    }

    private fun parseJsonHeaders(content: String): Map<String, String>? {
        if (!content.startsWith("{")) return null
        return runCatching {
            val root = json.parseToJsonElement(content) as? JsonObject ?: return null
            root.entries.mapNotNull { entry ->
                entry.value.jsonPrimitive.contentOrNull?.let { contentValue ->
                    entry.key to contentValue
                }
            }.toMap(LinkedHashMap())
        }.getOrNull()
    }

    private companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
    }
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
