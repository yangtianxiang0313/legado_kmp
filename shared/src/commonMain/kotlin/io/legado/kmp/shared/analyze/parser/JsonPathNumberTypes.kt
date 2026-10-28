package io.legado.kmp.shared.analyze.parser

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/** JsonElement has no Number subtype information; keep it within the document, never globally. */
internal class JsonPathNumberTypes {
    private class Key(val value: JsonElement) {
        private val hash = jsonPathIdentityHashCode(value)
        override fun hashCode(): Int = hash
        override fun equals(other: Any?): Boolean = other is Key && value === other.value
    }

    private val kinds = mutableMapOf<Key, JsonPathNumberKind>()
    private var retainedRoot: JsonElement? = null

    fun register(value: JsonPrimitive, kind: JsonPathNumberKind) {
        // Only preserve types not recoverable from spelling, such as BigDecimal or
        // BigInteger tokens whose leading zeros made the original width exceed Long's.
        if (kind == fallbackKind(value)) return
        kinds[Key(value)] = kind
        retainedRoot = null
    }

    fun kind(value: JsonPrimitive): JsonPathNumberKind = kinds[Key(value)] ?: fallbackKind(value)

    private fun fallbackKind(value: JsonPrimitive): JsonPathNumberKind = when {
        value.content.any { it == '.' || it == 'e' || it == 'E' } ||
            value.content == "NaN" || value.content.contains("Infinity") -> JsonPathNumberKind.DOUBLE
        else -> JsonPathNumberSupport.integerKind(value.content)
    }

    fun string(value: JsonPrimitive): String = when {
        value.isString || value === JsonNull || value.booleanOrNull != null -> value.content
        else -> JsonPathNumberSupport.string(value, kind(value))
    }

    fun intValue(value: JsonPrimitive): Int = JsonPathNumberSupport.intValue(value, kind(value))

    fun retaining(root: JsonElement): JsonPathNumberTypes {
        if (retainedRoot === root) return this
        val result = JsonPathNumberTypes()
        if (kinds.isEmpty()) return result.also { it.retainedRoot = root }
        val pending = ArrayDeque<JsonElement>()
        val seen = mutableSetOf<Key>()
        pending.add(root)
        while (pending.isNotEmpty()) {
            when (val value = pending.removeLast()) {
                is JsonArray -> if (seen.add(Key(value))) value.forEach(pending::add)
                is JsonObject -> if (seen.add(Key(value))) value.values.forEach(pending::add)
                is JsonPrimitive -> kinds[Key(value)]?.let { result.register(value, it) }
            }
        }
        return result.also { it.retainedRoot = root }
    }
}
