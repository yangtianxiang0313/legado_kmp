package io.legado.kmp.shared.network

import io.legado.kmp.shared.analyze.parser.JsonPathJsonReader
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

@Serializable
internal data class ParsedUrlOption(
    val method: String? = null,
    val charset: String? = null,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
    val rawBody: Boolean = false,
    val retry: Int = 0,
    val type: String? = null,
    val useWebView: Boolean = false,
    val webJs: String? = null,
    val sourceRegex: String? = null,
    val js: String? = null,
    val serverId: Long? = null,
    val proxy: String? = null,
    val webViewDelayTime: Long? = null
)

internal fun JsonObject.urlOptionString(vararg keys: String): String? {
    return firstUrlOptionElement(keys)?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
}

internal fun JsonObject.urlOptionBooleanLike(vararg keys: String): Boolean {
    val element = firstUrlOptionElement(keys) ?: return false
    return when (element) {
        JsonNull -> false
        is JsonPrimitive -> element.booleanOrNull ?: element.contentOrNull?.let {
            it.isNotBlank() && !it.equals("false", ignoreCase = true)
        } ?: false
        else -> true
    }
}

internal fun JsonObject.urlOptionMap(vararg keys: String): Map<String, String> {
    val element = firstUrlOptionElement(keys) ?: return emptyMap()
    val obj = when (element) {
        is JsonObject -> element
        is JsonPrimitive -> element.contentOrNull
            ?.takeIf { it.isNotBlank() }
            ?.let(::decodeLegacyUrlOptionObject)
        else -> null
    } ?: return emptyMap()
    return obj.mapValuesNotNull { (_, value) ->
        when (value) {
            JsonNull -> null
            is JsonPrimitive -> value.contentOrNull
            else -> value.toString()
        }
    }
}

internal fun JsonObject.urlOptionValueToString(vararg keys: String): String? {
    val element = firstUrlOptionElement(keys) ?: return null
    return when (element) {
        JsonNull -> null
        is JsonPrimitive -> element.contentOrNull
        is JsonObject, is JsonArray -> element.toString()
        else -> element.toString()
    }
}

internal fun JsonObject.urlOptionIntLike(vararg keys: String): Int? {
    val primitive = firstUrlOptionElement(keys) as? JsonPrimitive ?: return null
    return primitive.intOrNull ?: primitive.contentOrNull?.takeIf { it.isNotBlank() }?.toIntOrNull()
}

internal fun JsonObject.urlOptionLongLike(vararg keys: String): Long? {
    val primitive = firstUrlOptionElement(keys) as? JsonPrimitive ?: return null
    return primitive.longOrNull ?: primitive.contentOrNull?.takeIf { it.isNotBlank() }?.toLongOrNull()
}

private fun JsonObject.firstUrlOptionElement(keys: Array<out String>): JsonElement? {
    for (key in keys) {
        this[key]?.let { return it }
    }
    return null
}

// Android tries strict Gson, then its lenient reader. Never evaluate a URL option as JavaScript.
internal fun decodeLegacyUrlOptionObject(content: String): JsonObject? {
    runCatching { urlOptionJson.parseToJsonElement(content) as? JsonObject }.getOrNull()?.let { return it }
    require(content.length <= 1024 * 1024) { "Nonstandard URL options exceed the parser budget" }
    return runCatching { JsonPathJsonReader.parseComplete(content) as? JsonObject }.getOrNull()
}

private val urlOptionJson = Json {
    ignoreUnknownKeys = true
    isLenient = false
}

private inline fun <K, V, R : Any> Map<K, V>.mapValuesNotNull(transform: (Map.Entry<K, V>) -> R?): Map<K, R> {
    val result = LinkedHashMap<K, R>()
    for (entry in entries) {
        val value = transform(entry) ?: continue
        result[entry.key] = value
    }
    return result
}
