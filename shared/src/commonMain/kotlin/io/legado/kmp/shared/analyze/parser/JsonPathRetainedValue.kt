package io.legado.kmp.shared.analyze.parser

import io.legado.kmp.shared.analyze.AnalyzeJsonArrayValues
import io.legado.kmp.shared.scripting.toJsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Internal pipeline value: JSON snapshots plus the Java kinds JSON text cannot express. */
internal class JsonPathRetainedValue private constructor(
    val element: JsonElement,
    val numbers: JsonPathNumberTypes,
    private val collections: JsonPathCollectionKinds,
) {
    val isKeySet: Boolean get() = collections.isKeySet(element)

    fun arrayValues(): AnalyzeJsonArrayValues? =
        if (element is JsonArray && !isKeySet) {
            AnalyzeJsonArrayValues(element.map { capture(it, numbers, collections) })
        } else null

    fun newSession(): JsonPathDocumentSession {
        val numbersCopy = JsonPathNumberTypes()
        val collectionsCopy = JsonPathCollectionKinds()
        copyKinds(numbersCopy, collectionsCopy)
        return JsonPathDocumentSession(element, numbersCopy, collectionsCopy)
    }

    private fun copyKinds(targetNumbers: JsonPathNumberTypes, targetCollections: JsonPathCollectionKinds) {
        val pending = ArrayDeque<JsonElement>()
        val seen = mutableSetOf<IdentityKey>()
        pending.add(element)
        while (pending.isNotEmpty()) {
            val value = pending.removeLast()
            if (!seen.add(IdentityKey(value))) continue
            when (value) {
                is JsonArray -> {
                    if (collections.isKeySet(value)) targetCollections.markKeySet(value)
                    value.forEach(pending::add)
                }
                is JsonObject -> value.values.forEach(pending::add)
                is JsonPrimitive -> targetNumbers.register(value, numbers.kind(value))
            }
        }
    }

    override fun toString(): String = element.toString()

    private class IdentityKey(val value: JsonElement) {
        private val hash = jsonPathIdentityHashCode(value)
        override fun hashCode(): Int = hash
        override fun equals(other: Any?): Boolean = other is IdentityKey && value === other.value
    }

    companion object {
        fun capture(value: JsonElement, document: JsonPathFunctionDocument): JsonPathRetainedValue =
            capture(document.current(value), document.numberTypes, document.collections)

        private fun capture(
            value: JsonElement,
            numbers: JsonPathNumberTypes,
            collections: JsonPathCollectionKinds,
        ): JsonPathRetainedValue = JsonPathRetainedValue(
            value, numbers.retaining(value), collections.retaining(value),
        )

        /** Preserve child provenance when selection wrappers become a new JSONPath root. */
        fun fromInput(input: Any?): JsonPathRetainedValue? {
            if (input is JsonPathRetainedValue) return input
            if (input !is Map<*, *> && input !is List<*>) return null
            val numbers = JsonPathNumberTypes()
            val collections = JsonPathCollectionKinds()
            var retained = false
            fun convert(value: Any?): JsonElement = when (value) {
                is JsonPathRetainedValue -> {
                    retained = true
                    value.copyKinds(numbers, collections)
                    value.element
                }
                null -> JsonNull
                is JsonElement -> value
                is Map<*, *> -> JsonObject(buildMap {
                    value.forEach { (key, child) -> if (key != null) put(key.toString(), convert(child)) }
                })
                is List<*> -> JsonArray(value.map(::convert))
                else -> value.toJsonElement()
            }
            val root = convert(input)
            return if (retained) JsonPathRetainedValue(root, numbers, collections) else null
        }
    }
}
