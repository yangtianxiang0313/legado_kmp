package io.legado.kmp.shared.analyze.parser

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Scope-owned raw compound literals, parsed only when a predicate needs their JSON value. */
internal class JsonPathFilterLiterals(
    private val numberTypes: JsonPathNumberTypes,
    private val collections: JsonPathCollectionKinds,
) {
    private class Key(val value: Any) {
        private val hash = jsonPathIdentityHashCode(value)
        override fun hashCode(): Int = hash
        override fun equals(other: Any?): Boolean = other is Key && value === other.value
    }

    private val literals = mutableMapOf<Key, JsonPrimitive>()
    private val sources = mutableMapOf<Key, String>()

    fun literal(source: String, occurrence: Any): JsonElement = literals.getOrPut(Key(occurrence)) {
        JsonPrimitive(source).also { sources[Key(it)] = source }
    }

    fun isLiteral(value: JsonElement?): Boolean = value != null && sources.containsKey(Key(value))

    fun isKeySet(value: JsonElement): Boolean = collections.isKeySet(value)

    fun isJsonNode(value: JsonElement?): Boolean =
        isLiteral(value) || value is JsonObject || (value is JsonArray && !isKeySet(value))

    fun parse(value: JsonElement?): JsonElement? {
        if (value == null) return null
        val source = sources[Key(value)] ?: return value
        return JsonPathJsonReader.parse(source, numberTypes::register)
    }
}
