package io.legado.kmp.shared.network

import io.legado.kmp.shared.analyze.parser.JsonPathJsonReader
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

// Null means no usable explicit map; an empty result is still an explicit replacement.
internal fun decodeLegacyRequestHeaderJson(content: String): Map<String, String>? {
    val root = runCatching { requestHeaderJson.parseToJsonElement(content) }.getOrNull()
        ?: runCatching {
            require(content.length <= 1024 * 1024) { "Nonstandard request headers exceed the parser budget" }
            JsonPathJsonReader.parseComplete(content)
        }.getOrNull()
        ?: return null
    val entries: List<Pair<String, JsonElement>> = when (root) {
        is JsonObject -> root.entries.map { it.key to it.value }
        // Gson also accepts maps represented as arrays of two-element entries.
        is JsonArray -> root.map { element ->
            val pair = element as? JsonArray ?: return null
            if (pair.size != 2) return null
            val key = pair[0].requestHeaderValue() ?: return null
            key to pair[1]
        }
        else -> return null
    }
    val values = LinkedHashMap<String, String?>()
    for ((key, value) in entries) {
        // Gson's Map adapter rejects a duplicate when the replaced value was non-null.
        if (values[key] != null) return null
        values[key] = value.requestHeaderValue()
    }
    return values.mapNotNull { (key, value) -> value?.let { key to it } }.toMap(LinkedHashMap())
}

// The pinned Android GsonExtensions.StringJsonDeserializer is registered for String,
// including Map values. This is not the conversion used by the raw Java Map overloads.
private fun JsonElement.requestHeaderValue(): String? = when (this) {
    JsonNull -> null
    is JsonPrimitive -> contentOrNull
    is JsonObject, is JsonArray -> toString()
}

private val requestHeaderJson = Json {
    isLenient = false
}
