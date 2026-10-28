package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.source.SourceStateStore
import io.legado.kmp.shared.util.md5Hex
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject

/**
 * Resolves jsLib text and its existing source-scoped persistent URL cache.
 * No additional in-memory library cache: preamble reuse/invalidation stays in
 * LegacySourceJsRuntime, and removing scopes leaves persisted downloads intact.
 */
internal class LegacySourceJsLibrarySupport(
    private val sourceStateStore: SourceStateStore?,
) {
    suspend fun load(
        jsLib: String,
        sourceKey: String?,
        host: LegacyJsHostSurface,
    ): String {
        val trimmed = jsLib.trim()
        val remoteScripts = parseLegacyJsLibUrls(trimmed)
            ?: return normalizeLegacyJavascriptSyntax(trimmed)
        val resolvedScripts = ArrayList<String>(remoteScripts.size)
        for (url in remoteScripts) {
            resolvedScripts += normalizeLegacyJavascriptSyntax(loadRemoteScript(sourceKey, url, host))
        }
        return resolvedScripts.joinToString("\n")
    }

    suspend fun loadRemoteScript(
        sourceKey: String?,
        url: String,
        host: LegacyJsHostSurface,
        saveTimeSeconds: Int = 0,
    ): String {
        val cacheKey = "__legacy_js_script__${url.md5Hex()}"
        if (!sourceKey.isNullOrBlank()) {
            sourceStateStore?.getStoredValue(sourceKey, cacheKey)?.takeIf { it.isNotBlank() }?.let { return it }
        }
        val script = host.cacheFile(url)
        if (!sourceKey.isNullOrBlank() && script.isNotBlank()) {
            sourceStateStore?.putStoredValue(sourceKey, cacheKey, script, saveTimeSeconds = saveTimeSeconds)
        }
        return script
    }

    // Null means inline JS; an empty list is still the JSON library branch.
    private fun parseLegacyJsLibUrls(jsLib: String): List<String>? {
        if (!jsLib.startsWith("{") || !jsLib.endsWith("}")) return null
        // SharedJsScope parses the whole Map before loading anything; failures
        // must propagate without caching a preamble or evaluating the object text.
        val root = json.parseToJsonElement(jsLib).jsonObject
        return root.values.mapNotNull { value ->
            // Android's GSON StringJsonDeserializer stringifies composite values.
            val text = if (value is JsonPrimitive) value.contentOrNull else value.toString()
            text?.takeIf {
                it.startsWith("http://", ignoreCase = true) || it.startsWith("https://", ignoreCase = true)
            }
        }
    }

    private companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }
    }
}
