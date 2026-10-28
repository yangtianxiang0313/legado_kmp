package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.core.JsonPathQuery
import at.asitplus.jsonpath.core.JsonPathSelector
import at.asitplus.jsonpath.core.NodeList
import at.asitplus.jsonpath.core.NodeListEntry
import at.asitplus.jsonpath.core.NormalizedJsonPath
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

internal class JsonPathFunctionSelectionLimitation(message: String) : IllegalArgumentException(message)

/** Jayway result shaping over the public selectors compiled by JsonPath4K's ANTLR core. */
internal object JsonPathQuerySupport {
    data class FunctionSelection(
        val selectors: List<JsonPathSelector>,
        val terminal: Boolean,
        val definite: Boolean,
        val scanTail: JsonPathScanTail = JsonPathScanTail.NONE,
    ) {
        // Selections belong to one function evaluation, never to the cached query AST.
        internal val scanSupport = JsonPathScanSupport(selectors, terminal, scanTail)
        internal val cacheIdentity = Any()
    }

    fun functionSelection(
        query: JsonPathQuery,
        terminal: Boolean,
        scanTail: JsonPathScanTail = JsonPathScanTail.NONE,
    ): FunctionSelection {
        require(query.selectors.firstOrNull() == JsonPathSelector.RootSelector)
        val selectors = query.selectors.drop(1)
        selectors.forEach(::validateSlices)
        return FunctionSelection(
            selectors,
            terminal,
            scanTail == JsonPathScanTail.NONE && selectors.withIndex().all { (index, selector) ->
                isDefinite(selector, terminal && index == selectors.lastIndex)
            },
            scanTail,
        )
    }

    /** A fragment starts at a function result, while filter $ still refers to the document. */
    fun functionMatches(
        selection: FunctionSelection,
        current: JsonElement,
        root: JsonElement,
        upstreamDefinite: Boolean,
        currentIsKeySet: Boolean = false,
        isKeySet: (JsonElement) -> Boolean = { false },
    ): List<JsonElement> = buildList {
        forEachFunctionMatch(
            selection, current, { root }, upstreamDefinite, currentIsKeySet,
            currentValue = { it }, onMatch = { add(it) },
            isKeySet = isKeySet,
        )
    }

    fun forEachFunctionMatch(
        selection: FunctionSelection,
        current: JsonElement,
        rootSupplier: () -> JsonElement,
        upstreamDefinite: Boolean,
        currentIsKeySet: Boolean = false,
        currentValue: (JsonElement) -> JsonElement,
        onMatch: (JsonElement) -> Unit,
        isKeySet: (JsonElement) -> Boolean = { false },
    ): Unit {
        if (selection.selectors.isEmpty() && selection.scanTail == JsonPathScanTail.NONE) {
            onMatch(currentValue(current))
            return
        }
        selection.scanSupport.forEachMatch(
            current, rootSupplier, upstreamDefinite, currentValue, onMatch,
            isKeySet = { value -> isKeySet(value) || (currentIsKeySet && value === current) },
        )
    }

    internal fun selectKeySet(selector: JsonPathSelector, upstreamDefinite: Boolean) {
        // JsonSmart exposes neither array nor map selectors on a Set.
        when (val first = unwrap(selector)) {
            JsonPathSelector.WildCardSelector, is JsonPathSelector.DescendantSelector -> Unit
            is JsonPathSelector.MemberSelector,
            is JsonPathSelector.IndexSelector,
            is JsonPathSelector.SliceSelector -> if (upstreamDefinite) {
                throw JsonPathMissingPathException("Property/array selectors cannot be applied to a key set")
            }
            is JsonPathSelector.BracketedSelector -> {
                if (memberUnion(first) == null && !first.selectors.all { it is JsonPathSelector.IndexSelector }) {
                    throw JsonPathFunctionSelectionLimitation("Mixed selector unions are not Jayway property/index tokens")
                }
                if (upstreamDefinite) {
                    throw JsonPathMissingPathException("Property/array unions cannot be applied to a key set")
                }
            }
            is JsonPathSelector.FilterSelector -> if (upstreamDefinite) {
                throw JsonPathPredicatePathException("Filters cannot be applied to a key set")
            }
            else -> require(!upstreamDefinite)
        }
    }

    internal fun selectFunctionNode(
        selector: JsonPathSelector,
        current: JsonElement,
        root: JsonElement,
        terminal: Boolean,
        upstreamDefinite: Boolean,
        currentIsKeySet: Boolean = false,
    ): NodeList {
        if (currentIsKeySet && selector != JsonPathSelector.RootSelector &&
            selector != JsonPathSelector.CurrentNodeSelector
        ) {
            selectKeySet(selector, upstreamDefinite)
            return emptyList()
        }
        when (val unwrapped = unwrap(selector)) {
            is JsonPathSelector.MemberSelector -> {
                if (current !is JsonObject && upstreamDefinite) {
                    throw JsonPathMissingPathException("Expected an object for property '${unwrapped.memberName}'")
                }
                if (current is JsonObject && !terminal && upstreamDefinite) {
                    if (unwrapped.memberName !in current) {
                        throw JsonPathMissingPathException("Missing property '${unwrapped.memberName}' in definite path")
                    }
                }
            }
            is JsonPathSelector.IndexSelector, is JsonPathSelector.SliceSelector -> {
                if (current !is JsonArray && upstreamDefinite) {
                    throw JsonPathMissingPathException("Array selectors require an array on a definite path")
                }
            }
            is JsonPathSelector.BracketedSelector -> {
                if (memberUnion(unwrapped) != null) {
                    if (current !is JsonObject && upstreamDefinite) {
                        throw JsonPathMissingPathException("Property unions require an object on a definite path")
                    }
                } else if (unwrapped.selectors.all { it is JsonPathSelector.IndexSelector }) {
                    if (current !is JsonArray && upstreamDefinite) {
                        throw JsonPathMissingPathException("Index unions require an array on a definite path")
                    }
                } else {
                    throw JsonPathFunctionSelectionLimitation("Mixed selector unions after functions are not Jayway property/index tokens")
                }
            }
            is JsonPathSelector.FilterSelector -> {
                if (current !is JsonArray && current !is JsonObject && upstreamDefinite) {
                    throw JsonPathPredicatePathException("Filters cannot be applied to primitives on a definite path")
                }
                return when (current) {
                    is JsonArray -> buildList {
                        current.forEachIndexed { index, candidate ->
                            if (acceptsFilter(unwrapped, candidate, root)) {
                                add(NodeListEntry(NormalizedJsonPath() + index.toUInt(), candidate))
                            }
                        }
                    }
                    is JsonObject -> if (acceptsFilter(unwrapped, current, root)) {
                        // Jayway filters a map itself, not its property values.
                        listOf(NodeListEntry(NormalizedJsonPath(), current))
                    } else emptyList()
                    else -> emptyList()
                }
            }
            else -> Unit
        }
        return select(selector, current, root, terminal)
    }

    internal fun acceptsFilter(
        selector: JsonPathSelector.FilterSelector,
        current: JsonElement,
        root: JsonElement,
    ): Boolean = try {
        // The compiled predicate is private; a singleton wrapper evaluates exactly
        // one candidate. Only Jayway path failures reject that candidate.
        selector.invoke(currentNode = JsonArray(listOf(current)), rootNode = root).isNotEmpty()
    } catch (_: JsonPathPredicatePathException) {
        false
    }

    fun evaluate(
        query: JsonPathQuery,
        root: JsonElement,
        forFunctionContinuation: Boolean = false,
        isKeySet: (JsonElement) -> Boolean = { false },
    ): JsonElement? {
        query.selectors.forEach(::validateSlices)
        return if (query.selectors.isEmpty()) {
            null
        } else if (query.selectors.any { unwrap(it) is JsonPathSelector.DescendantSelector }) {
            JsonArray(buildList {
                JsonPathScanSupport(query.selectors, terminal = !forFunctionContinuation).forEachMatch(
                    root, { root }, upstreamDefinite = true, currentValue = { it },
                    onMatch = { add(it) }, isKeySet = isKeySet,
                )
            })
        } else {
            var matches: NodeList = listOf(NodeListEntry(NormalizedJsonPath(), root))
            var definite = true
            query.selectors.forEachIndexed { index, selector ->
                val mergeMembers = index == query.selectors.lastIndex && !forFunctionContinuation
                val upstreamDefinite = definite
                definite = definite && isDefinite(selector, mergeMembers)
                matches = matches.flatMap { match ->
                    selectFunctionNode(
                        selector, match.value, root, mergeMembers, upstreamDefinite, isKeySet(match.value),
                    ).map { next ->
                        NodeListEntry(match.normalizedJsonPath + next.normalizedJsonPath, next.value)
                    }
                }
            }
            if (definite) matches.singleOrNull()?.value else JsonArray(matches.map { it.value })
        }
    }

    internal fun unwrap(selector: JsonPathSelector): JsonPathSelector =
        if (selector is JsonPathSelector.BracketedSelector && selector.selectors.size == 1) {
            unwrap(selector.selectors.single())
        } else {
            selector
        }

    internal fun memberUnion(selector: JsonPathSelector): List<JsonPathSelector.MemberSelector>? {
        val bracketed = unwrap(selector) as? JsonPathSelector.BracketedSelector ?: return null
        return bracketed.selectors.takeIf { members ->
            members.size > 1 && members.all { it is JsonPathSelector.MemberSelector }
        }?.filterIsInstance<JsonPathSelector.MemberSelector>()
    }

    internal fun isDefinite(selector: JsonPathSelector, mergeMembers: Boolean): Boolean =
        when (val unwrapped = unwrap(selector)) {
            JsonPathSelector.RootSelector,
            JsonPathSelector.CurrentNodeSelector,
            is JsonPathSelector.MemberSelector,
            is JsonPathSelector.IndexSelector -> true
            is JsonPathSelector.BracketedSelector -> mergeMembers && memberUnion(unwrapped) != null
            else -> false
        }

    private fun select(
        selector: JsonPathSelector,
        current: JsonElement,
        root: JsonElement,
        mergeMembers: Boolean,
    ): NodeList = when (val unwrapped = unwrap(selector)) {
        is JsonPathSelector.BracketedSelector -> {
            val members = if (mergeMembers) memberUnion(unwrapped) else null
            if (members == null) {
                unwrapped.selectors.flatMap { select(it, current, root, mergeMembers) }
            } else if (current !is JsonObject) {
                emptyList()
            } else {
                // A terminal property union is one map per parent, not a flat nodelist.
                val properties = linkedMapOf<String, JsonElement>()
                members.forEach { member ->
                    member.invoke(currentNode = current, rootNode = root).forEach { match ->
                        properties[member.memberName] = match.value
                    }
                }
                listOf(NodeListEntry(NormalizedJsonPath(), JsonObject(properties)))
            }
        }
        is JsonPathSelector.SliceSelector -> slice(unwrapped, current, root)
        is JsonPathSelector.DescendantSelector -> error("Scan selectors require token continuation")
        else -> unwrapped.invoke(currentNode = current, rootNode = root)
    }

    private fun validateSlices(selector: JsonPathSelector) {
        when (selector) {
            is JsonPathSelector.SliceSelector -> {
                // Jayway ignores the third field, but still requires a start or end.
                require(selector.startInclusive != null || selector.endExclusive != null)
            }
            is JsonPathSelector.BracketedSelector -> selector.selectors.forEach(::validateSlices)
            is JsonPathSelector.DescendantSelector -> validateSlices(selector.selector)
            else -> Unit
        }
    }

    private fun slice(
        selector: JsonPathSelector.SliceSelector,
        current: JsonElement,
        root: JsonElement,
    ): NodeList {
        val start = selector.startInclusive
        val end = selector.endExclusive
        if (start == null || end == null) {
            return selector.copy(step = null).invoke(currentNode = current, rootNode = root)
        }
        if (current !is JsonArray) return emptyList()
        // SLICE_BETWEEN passes raw bounds to array indices; it does not normalize
        // a negative end. Clip only indices that the original index selector ignores.
        val lower = start.coerceAtLeast(-current.size)
        val upper = end.coerceAtMost(current.size)
        return (lower until upper).flatMap { index ->
            JsonPathSelector.IndexSelector(index).invoke(currentNode = current, rootNode = root)
        }
    }
}
