package io.legado.kmp.shared.analyze.parser

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

internal class JsonPathFunctionDocumentLimitation(message: String) : IllegalArgumentException(message)

/** An explicit ReadContext lifetime; the caller's immutable root is never modified. */
internal class JsonPathDocumentSession(
    root: JsonElement,
    numberTypes: JsonPathNumberTypes = JsonPathNumberTypes(),
    collections: JsonPathCollectionKinds = JsonPathCollectionKinds(),
) {
    var root: JsonElement = root
        private set
    internal var document = JsonPathFunctionDocument(numberTypes, collections)
        private set

    /** Only the backend may checkpoint, under its guard after the outer public read. */
    internal fun checkpoint() {
        // Materialize once with the old identity cache so all in-root aliases stay shared.
        val currentRoot = document.current(root)
        val nextDocument = JsonPathFunctionDocument(
            document.numberTypes.retaining(currentRoot), document.collections.retaining(currentRoot),
        )
        root = currentRoot
        document = nextDocument
    }
}

/** Copy-on-write identities shared by an outer query, or until a session's public-read checkpoint. */
internal class JsonPathFunctionDocument(
    val numberTypes: JsonPathNumberTypes = JsonPathNumberTypes(),
    val collections: JsonPathCollectionKinds = JsonPathCollectionKinds(),
) {
    private data class Snapshot(val root: JsonElement, val revision: Long, val text: String)

    private class IdentityKey(val element: JsonElement) {
        private val hash = jsonPathIdentityHashCode(element)
        override fun hashCode(): Int = hash
        override fun equals(other: Any?): Boolean = other is IdentityKey && element === other.element
    }

    private val copies = mutableMapOf<IdentityKey, JsonElement>()
    private val materialized = mutableMapOf<IdentityKey, JsonElement>()
    private val snapshots = mutableListOf<Snapshot>()
    private var revision = 0L

    fun parseJson(source: String): JsonElement = JsonPathJsonReader.parse(source, numberTypes::register)

    fun snapshot(root: JsonElement): String {
        snapshots.firstOrNull { it.root === root && it.revision == revision }?.let { return it.text }
        return JsonPathValueStrings.javaString(current(root), numberTypes, collections::isKeySet).also {
            snapshots += Snapshot(root, revision, it)
        }
    }

    fun append(model: JsonArray, additions: List<JsonElement>): JsonArray {
        val before = current(model) as JsonArray
        check(!collections.isKeySet(before)) { "A Jayway key set is not an appendable array" }
        if (additions.isEmpty()) return before
        val values = additions.map(::current)
        if (values.any { containsIdentity(it, before) }) {
            throw JsonPathFunctionDocumentLimitation(
                "append of an ancestor/self reference would create a cyclic Jayway document"
            )
        }
        return JsonArray(before.toList() + values).also {
            remember(before, it)
            revision++
            snapshots.clear()
            materialized.clear()
        }
    }

    fun current(element: JsonElement): JsonElement {
        if (collections.isKeySet(element)) return element
        if (copies.isEmpty() || (element !is JsonArray && element !is JsonObject)) return element
        val key = IdentityKey(element)
        materialized[key]?.let { return it }
        var latest = element
        val aliases = mutableListOf<JsonElement>()
        while (true) {
            val replacement = copies[IdentityKey(latest)] ?: break
            aliases += latest
            latest = replacement
        }
        val latestKey = IdentityKey(latest)
        val result = materialized[latestKey] ?: when (val value = latest) {
            is JsonArray -> {
                val items = value.map(::current)
                if (items.indices.all { items[it] === value[it] }) value else JsonArray(items)
            }
            is JsonObject -> {
                val entries = value.mapValues { current(it.value) }
                if (entries.all { (key, item) -> item === value[key] }) value else JsonObject(entries)
            }
            else -> value
        }
        // Ancestor copies are aliases too, including roots used by Length's model scope.
        if (latest !== result) remember(latest, result)
        aliases.forEach { remember(it, result) }
        materialized[key] = result
        materialized[latestKey] = result
        return result
    }

    private fun remember(source: JsonElement, copy: JsonElement) {
        copies[IdentityKey(source)] = copy
    }

    private fun containsIdentity(value: JsonElement, target: JsonElement): Boolean = when {
        value === target -> true
        value is JsonArray -> value.any { containsIdentity(it, target) }
        value is JsonObject -> value.values.any { containsIdentity(it, target) }
        else -> false
    }
}
