package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.core.JsonPathFunctionExtension
import kotlinx.serialization.json.JsonElement

/** Jayway filter syntax adapters; query parsing and evaluation stay in JsonPath4K. */
internal object JsonPathFilterSupport {
    fun normalize(path: String): String = JsonPathFilterNormalizer.normalize(path)

    fun function(name: String): JsonPathFunctionExtension? = JsonPathFilterFunctions.function(name)

    /** The backend must hold its recursive compiler/evaluation lock for the complete scope. */
    fun <T> withRoot(root: JsonElement, block: () -> T): T = JsonPathFilterFunctions.withRoot(root, block)

    /** One evaluation cache across live traversal branches; nested evaluations need a new scope. */
    fun <T> withLiveRoot(
        root: () -> JsonElement,
        currentValue: (JsonElement) -> JsonElement,
        block: () -> T,
    ): T = JsonPathFilterFunctions.withLiveRoot(root, currentValue, block)

    fun <T> withOccurrence(occurrence: Any, block: () -> T): T =
        JsonPathFilterFunctions.withOccurrence(occurrence, block)
}
