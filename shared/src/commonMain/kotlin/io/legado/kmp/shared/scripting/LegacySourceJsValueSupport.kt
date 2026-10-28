package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.model.BookSource
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal fun buildVariablesCode(variables: Map<String, Any?>): String {
    if (variables.isEmpty()) return ""
    val literals = LinkedHashMap<String, Any?>().apply {
        putAll(variables)
    }.map { (key, value) ->
        toJsLiteral(key) to toJsLiteral(value)
    }
    return buildString {
        append("globalThis.__legacyRuleSeed = {")
        literals.forEachIndexed { index, (key, value) ->
            if (index > 0) append(", ")
            append(key)
            append(": ")
            append(value)
        }
        appendLine("};")
        // Reuse text, not JS objects; both copies must be evaluated independently.
        literals.forEach { (key, value) ->
            append("globalThis[")
            append(key)
            append("] = ")
            append(value)
            appendLine(";")
        }
    }
}

internal fun buildSourceSnapshotCode(source: BookSource?): String {
    if (source == null) return ""
    return buildString {
        append("globalThis.__legacySourceSnapshot = ")
        append(
            toJsLiteral(
                linkedMapOf<String, Any?>(
                    "bookSourceUrl" to source.bookSourceUrl,
                    "bookSourceName" to source.bookSourceName,
                    "bookSourceGroup" to source.bookSourceGroup,
                    "bookSourceType" to source.bookSourceType,
                    "bookUrlPattern" to source.bookUrlPattern,
                    "bookSourceComment" to source.bookSourceComment,
                    "header" to source.header,
                    "loginUrl" to source.loginUrl,
                    "loginUi" to source.loginUi,
                    "loginCheckJs" to source.loginCheckJs,
                    "coverDecodeJs" to source.coverDecodeJs,
                    "variableComment" to source.variableComment,
                    "enabledCookieJar" to source.enabledCookieJar,
                    "concurrentRate" to source.concurrentRate,
                    "enabled" to source.enabled,
                    "enabledExplore" to source.enabledExplore,
                    "customOrder" to source.customOrder,
                    "lastUpdateTime" to source.lastUpdateTime,
                    "respondTime" to source.respondTime,
                    "weight" to source.weight,
                    "exploreUrl" to source.exploreUrl,
                    "exploreScreen" to source.exploreScreen
                )
            )
        )
        appendLine(";")
    }
}

private fun toJsLiteral(value: Any?): String = buildString {
    appendJsLiteral(value)
}

private fun StringBuilder.appendJsLiteral(value: Any?) {
    when (value) {
        null -> append("null")
        is String -> appendJsString(value)
        is Int, is Long, is Float, is Double -> append(value.toString())
        is Boolean -> append(value.toString())
        is ByteArray -> {
            append('[')
            value.forEachIndexed { index, byte ->
                if (index > 0) append(", ")
                append(byte.toInt() and 0xff)
            }
            append(']')
        }
        is Map<*, *> -> {
            append('{')
            var first = true
            value.entries.forEach { (key, nestedValue) ->
                if (!first) append(", ")
                first = false
                appendJsString(key.toString())
                append(": ")
                appendJsLiteral(nestedValue)
            }
            append('}')
        }
        is List<*> -> {
            append('[')
            value.forEachIndexed { index, nestedValue ->
                if (index > 0) append(", ")
                appendJsLiteral(nestedValue)
            }
            append(']')
        }
        else -> appendJsString(value.toString())
    }
}

private fun StringBuilder.appendJsString(value: String) {
    append('"')
    value.forEach { char ->
        when (char) {
            '\\' -> append("\\\\")
            '"' -> append("\\\"")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> append(char)
        }
    }
    append('"')
}

internal fun Any?.toJsonElement(): JsonElement {
    return when (this) {
        null -> JsonNull
        is JsonElement -> this
        // DOM elements iterate from their own root; they are markup, not JSON arrays.
        is com.fleeksoft.ksoup.nodes.Node -> JsonPrimitive(outerHtml())
        is String -> JsonPrimitive(this)
        is Boolean -> JsonPrimitive(this)
        is Int -> JsonPrimitive(this)
        is Long -> JsonPrimitive(this)
        is Float -> JsonPrimitive(this)
        is Double -> JsonPrimitive(this)
        is Number -> JsonPrimitive(this.toDouble())
        is Map<*, *> -> JsonObject(
            entries.associate { (key, value) -> key.toString() to value.toJsonElement() }
        )
        is Iterable<*> -> JsonArray(map { it.toJsonElement() })
        is Array<*> -> JsonArray(map { it.toJsonElement() })
        is ByteArray -> JsonArray(map { JsonPrimitive(it.toInt() and 0xff) })
        else -> JsonPrimitive(toString())
    }
}
