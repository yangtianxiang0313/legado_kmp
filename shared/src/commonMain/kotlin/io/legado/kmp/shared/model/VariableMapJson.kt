package io.legado.kmp.shared.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

internal val variableMapJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
}

internal fun parseVariableMap(variable: String?): Map<String, String> {
    if (variable.isNullOrBlank()) return emptyMap()
    return runCatching {
        val root = variableMapJson.parseToJsonElement(variable)
        val obj = root as? JsonObject ?: return emptyMap()
        obj.mapValues { (_, value) ->
            when (value) {
                JsonNull -> ""
                is JsonPrimitive -> value.contentOrNull ?: value.toString()
                else -> value.toString()
            }
        }
    }.getOrDefault(emptyMap())
}

/**
 * Serialize a variable map to JSON string.
 * Aligned with legado's variable JSON serialization for RuleDataInterface.
 * D3: getVariable serialize support.
 */
internal fun serializeVariableMap(variableMap: Map<String, String>): String {
    if (variableMap.isEmpty()) return ""
    return runCatching {
        JsonObject(variableMap.mapValues { (_, v) -> JsonPrimitive(v) }).toString()
    }.getOrDefault("")
}
