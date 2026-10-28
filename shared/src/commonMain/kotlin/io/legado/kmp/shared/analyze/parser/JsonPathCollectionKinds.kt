package io.legado.kmp.shared.analyze.parser

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** JSON projections of Jayway key sets retain their kind by identity, never by array contents. */
internal class JsonPathCollectionKinds {
    private class Key(val value: JsonElement) {
        private val hash = jsonPathIdentityHashCode(value)
        override fun hashCode(): Int = hash
        override fun equals(other: Any?): Boolean = other is Key && value === other.value
    }

    private val keySets = mutableSetOf<Key>()

    fun keySet(model: JsonObject): JsonArray = JsonArray(model.keys.map(::JsonPrimitive)).also {
        keySets.add(Key(it))
    }

    fun isKeySet(value: JsonElement): Boolean = value is JsonArray && Key(value) in keySets

    fun markKeySet(value: JsonArray) {
        keySets.add(Key(value))
    }

    /** Only document-reachable sets survive a public-read checkpoint, not temporary result events. */
    fun retaining(root: JsonElement): JsonPathCollectionKinds {
        val result = JsonPathCollectionKinds()
        if (keySets.isEmpty()) return result
        val pending = ArrayDeque<JsonElement>()
        val seen = mutableSetOf<Key>()
        pending.add(root)
        while (pending.isNotEmpty()) {
            val value = pending.removeLast()
            if (value !is JsonArray && value !is JsonObject) continue
            val key = Key(value)
            if (!seen.add(key)) continue
            if (key in keySets) result.keySets.add(key)
            else when (value) {
                is JsonArray -> value.forEach(pending::add)
                is JsonObject -> value.values.forEach(pending::add)
                else -> Unit
            }
        }
        return result
    }
}
