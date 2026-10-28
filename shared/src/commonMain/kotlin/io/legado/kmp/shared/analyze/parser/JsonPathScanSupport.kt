package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.core.JsonPathSelector
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/** A scan split from its following function, or left as a leaf by CompiledPath inversion. */
internal enum class JsonPathScanTail { NONE, FUNCTION, LEAF }

/** Jayway 2.10.0 ScanPathToken continuation over JsonPath4K's compiled selectors. */
internal class JsonPathScanSupport(
    selectors: List<JsonPathSelector>,
    private val terminal: Boolean,
    scanTail: JsonPathScanTail = JsonPathScanTail.NONE,
) {
    private sealed class Token {
        class Scan : Token()
        class FunctionTarget : Token()
        class Selection(val selector: JsonPathSelector) : Token() {
            var upstreamArrayIndex: Int = -1
        }
    }

    private val tokens: List<Token> = buildList {
        fun append(selector: JsonPathSelector) {
            val unwrapped = JsonPathQuerySupport.unwrap(selector)
            if (unwrapped is JsonPathSelector.DescendantSelector) {
                add(Token.Scan())
                append(unwrapped.selector)
            } else {
                add(Token.Selection(unwrapped))
            }
        }
        selectors.forEach(::append)
        if (scanTail != JsonPathScanTail.NONE) add(Token.Scan())
        if (scanTail == JsonPathScanTail.FUNCTION) add(Token.FunctionTarget())
    }

    fun matches(
        current: JsonElement,
        root: JsonElement,
        upstreamDefinite: Boolean,
    ): List<JsonElement> = buildList {
        forEachMatch(current, { root }, upstreamDefinite, currentValue = { it }, onMatch = { add(it) })
    }

    fun forEachMatch(
        current: JsonElement,
        root: () -> JsonElement,
        upstreamDefinite: Boolean,
        currentValue: (JsonElement) -> JsonElement,
        onMatch: (JsonElement) -> Unit,
        isKeySet: (JsonElement) -> Boolean = { false },
    ): Unit = Evaluation(root, upstreamDefinite, currentValue, onMatch, isKeySet).run(current)

    private fun isLeaf(index: Int): Boolean = terminal && index == tokens.lastIndex

    private inner class Evaluation(
        private val root: () -> JsonElement,
        upstreamDefinite: Boolean,
        private val currentValue: (JsonElement) -> JsonElement,
        private val onMatch: (JsonElement) -> Unit,
        private val isKeySet: (JsonElement) -> Boolean,
    ) {
        private val budget = JsonPathScanTraversalBudget()
        private val selection = JsonPathScanSelectorSupport(root, currentValue, budget, isKeySet)
        private val definiteBefore = tokens.mapIndexed { index, token ->
            token is Token.Selection && JsonPathQuerySupport.isDefinite(token.selector, isLeaf(index))
        }.let { definiteTokens ->
            var definite = upstreamDefinite
            definiteTokens.map { tokenDefinite ->
                definite.also { definite = definite && tokenDefinite }
            }
        }

        fun run(current: JsonElement) {
            visit(0, current)
        }

        private fun visit(index: Int, model: JsonElement): Unit = budget.frame {
            val current = currentValue(model)
            if (index == tokens.size) {
                onMatch(current)
                return@frame
            }
            when (val token = tokens[index]) {
                is Token.Scan -> {
                    // ScanPathToken calls next() before inspecting even a primitive model.
                    check(index < tokens.lastIndex) { "Current path token is a leaf" }
                    walk(index + 1, model)
                }
                is Token.FunctionTarget -> Unit // createScanPredicate(FunctionPathToken) is always false.
                is Token.Selection -> {
                    if (suppressesProperty(index, token, current)) return@frame
                    selection.forEachMatch(
                        token.selector, model, isLeaf(index), definiteBefore[index],
                    ) { visit(index + 1, it) }
                }
            }
        }

        private fun walk(targetIndex: Int, model: JsonElement): Unit = budget.frame {
            val current = currentValue(model)
            if (isKeySet(current)) return@frame
            if (current !is JsonObject && current !is JsonArray) return@frame
            if (accepts(targetIndex, model)) {
                if (currentValue(model) is JsonArray && !isLeaf(targetIndex)) {
                    // walkArray skips its target, even for an out-of-range index or
                    // a predicate that accepts the array but rejects its elements.
                    selection.forEachArrayElement(model, failFast = true) { index, child ->
                        (tokens.getOrNull(targetIndex + 1) as? Token.Selection)?.upstreamArrayIndex = index
                        visit(targetIndex + 1, child)
                    }
                } else {
                    visit(targetIndex, model)
                }
            }
            // Complete the continuation before descending, without deduplicating
            // hits reached again by an inner scan or by the outer traversal.
            when (val latest = currentValue(model)) {
                is JsonArray -> selection.forEachArrayElement(model, failFast = true) { _, child ->
                    walk(targetIndex, child)
                }
                is JsonObject -> latest.keys.forEach { property ->
                    (currentValue(model) as JsonObject)[property]?.let { walk(targetIndex, it) }
                }
                else -> Unit
            }
        }

        private fun accepts(index: Int, model: JsonElement): Boolean {
            val current = currentValue(model)
            val selector = (tokens[index] as? Token.Selection)?.selector ?: return false
            return when (selector) {
                is JsonPathSelector.MemberSelector -> current is JsonObject && selector.memberName in current
                is JsonPathSelector.IndexSelector, is JsonPathSelector.SliceSelector -> current is JsonArray
                JsonPathSelector.WildCardSelector -> true
                is JsonPathSelector.FilterSelector -> selection.accepts(selector, model)
                is JsonPathSelector.BracketedSelector -> {
                    val members = JsonPathQuerySupport.memberUnion(selector)
                    when {
                        members != null -> current is JsonObject &&
                            (!isLeaf(index) || members.all { it.memberName in current })
                        selector.selectors.all { it is JsonPathSelector.IndexSelector } -> current is JsonArray
                        else -> false
                    }
                }
                else -> false
            }
        }

        private fun suppressesProperty(index: Int, token: Token.Selection, model: JsonElement): Boolean {
            if (!isLeaf(index) || token.upstreamArrayIndex == -1 || model !is JsonObject) return false
            if (token.selector !is JsonPathSelector.MemberSelector &&
                token.selector != JsonPathSelector.WildCardSelector
            ) return false
            // PathToken.handleObjectProperty compares the raw preceding token
            // fragment to [idx], not a normalized/negative index or a union member.
            // This state intentionally survives subsequent walkObject branches.
            val previous = (tokens.getOrNull(index - 1) as? Token.Selection)?.selector
            return previous !is JsonPathSelector.IndexSelector || previous.index != token.upstreamArrayIndex
        }
    }
}
