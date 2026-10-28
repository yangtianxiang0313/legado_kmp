package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.core.JsonPathSelector
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** Streams the existing selector AST one continuation at a time, without eager sibling matches. */
internal class JsonPathScanSelectorSupport(
    private val root: () -> JsonElement,
    private val currentValue: (JsonElement) -> JsonElement,
    private val budget: JsonPathScanTraversalBudget,
    private val isKeySet: (JsonElement) -> Boolean = { false },
) {
    fun forEachMatch(
        selector: JsonPathSelector,
        model: JsonElement,
        terminal: Boolean,
        upstreamDefinite: Boolean,
        onMatch: (JsonElement) -> Unit,
    ) {
        if (isKeySet(currentValue(model))) {
            if (selector == JsonPathSelector.RootSelector || selector == JsonPathSelector.CurrentNodeSelector) {
                onMatch(currentValue(model))
            } else {
                JsonPathQuerySupport.selectKeySet(selector, upstreamDefinite)
            }
            return
        }
        when (val unwrapped = JsonPathQuerySupport.unwrap(selector)) {
            JsonPathSelector.WildCardSelector -> wildcard(model, onMatch)
            is JsonPathSelector.FilterSelector -> {
                val current = currentValue(model)
                if (current !is JsonArray && current !is JsonObject && upstreamDefinite) {
                    throw JsonPathPredicatePathException("Filters cannot be applied to primitives on a definite path")
                }
                when (current) {
                    is JsonArray -> forEachArrayElement(model, failFast = true) { index, child ->
                        if (accepts(unwrapped, child)) {
                            // Predicate evaluation may itself change the document. Read the
                            // hit again, as PredicatePathToken.handleArrayIndex does.
                            single(JsonPathSelector.IndexSelector(index), model, terminal, false, onMatch)
                        }
                    }
                    is JsonObject -> if (accepts(unwrapped, model)) onMatch(currentValue(model))
                    else -> Unit
                }
            }
            is JsonPathSelector.BracketedSelector -> {
                val current = currentValue(model)
                val members = JsonPathQuerySupport.memberUnion(unwrapped)
                when {
                    members != null -> if (current !is JsonObject && upstreamDefinite) {
                        throw JsonPathMissingPathException("Property unions require an object on a definite path")
                    }
                    unwrapped.selectors.all { it is JsonPathSelector.IndexSelector } -> {
                        if (current !is JsonArray && upstreamDefinite) {
                            throw JsonPathMissingPathException("Index unions require an array on a definite path")
                        }
                    }
                    else -> throw JsonPathFunctionSelectionLimitation(
                        "Mixed selector unions after functions are not Jayway property/index tokens"
                    )
                }
                if (terminal && members != null) {
                    single(unwrapped, model, terminal, upstreamDefinite, onMatch)
                } else {
                    unwrapped.selectors.forEach { member ->
                        // A non-leaf property union is an indefinite token, including
                        // missing properties on an otherwise definite upstream path.
                        forEachMatch(member, model, terminal, upstreamDefinite && members == null, onMatch)
                    }
                }
            }
            is JsonPathSelector.SliceSelector -> slice(unwrapped, model, terminal, upstreamDefinite, onMatch)
            is JsonPathSelector.DescendantSelector -> error("Scan selectors require token continuation")
            else -> single(unwrapped, model, terminal, upstreamDefinite, onMatch)
        }
    }

    fun accepts(selector: JsonPathSelector.FilterSelector, model: JsonElement): Boolean =
        JsonPathQuerySupport.acceptsFilter(selector, currentValue(model), root())

    fun forEachArrayElement(
        model: JsonElement,
        failFast: Boolean,
        onElement: (Int, JsonElement) -> Unit,
    ) {
        val expectedSize = (currentValue(model) as JsonArray).size
        var observedSize = expectedSize
        var index = 0
        while (true) {
            val current = currentValue(model) as JsonArray
            if (index >= current.size) return
            if (failFast && current.size != expectedSize) {
                throw ConcurrentModificationException("Array appended during live filter/scan iteration")
            }
            if (!failFast) budget.growth(current.size - observedSize)
            observedSize = current.size
            onElement(index, currentValue(current[index]))
            index++
        }
    }

    private fun wildcard(model: JsonElement, onMatch: (JsonElement) -> Unit) {
        when (val current = currentValue(model)) {
            is JsonArray -> forEachArrayElement(model, failFast = false) { index, _ ->
                single(JsonPathSelector.IndexSelector(index), model, true, false, onMatch)
            }
            is JsonObject -> current.keys.forEach { property ->
                single(JsonPathSelector.MemberSelector(property), model, true, false, onMatch)
            }
            else -> Unit
        }
    }

    private fun slice(
        selector: JsonPathSelector.SliceSelector,
        model: JsonElement,
        terminal: Boolean,
        upstreamDefinite: Boolean,
        onMatch: (JsonElement) -> Unit,
    ) {
        val current = currentValue(model)
        if (current !is JsonArray && upstreamDefinite) {
            throw JsonPathMissingPathException("Array selectors require an array on a definite path")
        }
        if (current !is JsonArray) return
        val start = selector.startInclusive
        val end = selector.endExclusive
        require(start != null || end != null)
        val size = current.size
        // Jayway captures slice bounds once, ignores step, and only normalizes
        // negative bounds for FROM/TO. BETWEEN keeps its raw negative indices.
        val lower = when {
            start == null -> 0
            end == null -> (if (start < 0) size + start else start).coerceAtLeast(0)
            else -> start.coerceAtLeast(-size)
        }
        val upper = when {
            end == null -> size
            start == null -> (if (end < 0) size + end else end).coerceAtMost(size)
            else -> end.coerceAtMost(size)
        }
        for (index in lower until upper) {
            single(JsonPathSelector.IndexSelector(index), model, terminal, upstreamDefinite, onMatch)
        }
    }

    private fun single(
        selector: JsonPathSelector,
        model: JsonElement,
        terminal: Boolean,
        upstreamDefinite: Boolean,
        onMatch: (JsonElement) -> Unit,
    ) {
        val current = currentValue(model)
        JsonPathQuerySupport.selectFunctionNode(
            selector, current, root(), terminal, upstreamDefinite, isKeySet(current),
        ).forEach { onMatch(it.value) }
    }
}
