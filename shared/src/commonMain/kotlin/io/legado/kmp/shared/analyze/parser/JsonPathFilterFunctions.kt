package io.legado.kmp.shared.analyze.parser

import at.asitplus.jsonpath.core.JsonPathFilterExpressionType.NodesType
import at.asitplus.jsonpath.core.JsonPathFilterExpressionType.ValueType
import at.asitplus.jsonpath.core.JsonPathFilterExpressionValue
import at.asitplus.jsonpath.core.JsonPathFilterExpressionValue.NodesTypeValue.FilterQueryResult.SingularQueryResult
import at.asitplus.jsonpath.core.JsonPathFilterExpressionValue.ValueTypeValue.JsonValue
import at.asitplus.jsonpath.core.JsonPathFunctionExtension
import at.asitplus.jsonpath.core.JsonPathFunctionExtension.LogicalTypeFunctionExtension
import at.asitplus.jsonpath.core.JsonPathFunctionExtension.NodesTypeFunctionExtension
import at.asitplus.jsonpath.core.JsonPathFunctionExtension.ValueTypeFunctionExtension
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

internal object JsonPathFilterFunctions {
    private data class PathCacheKey(val selection: Any, val expression: Any)

    private class RootScope(
        val root: () -> JsonElement,
        val currentValue: ((JsonElement) -> JsonElement)? = null,
    ) {
        val document = JsonPathBackend.withFunctionDocument { it }
        val numberTypes = document.numberTypes
        val literals = JsonPathFilterLiterals(numberTypes, document.collections)
        val pathValues = mutableMapOf<PathCacheKey, JsonElement>()
        var occurrence: Any = Any()
    }

    // Only query execution under the backend's recursive platform lock may enter this scope.
    private val rootStack = mutableListOf<RootScope>()

    fun <T> withRoot(root: JsonElement, block: () -> T): T = withScope(RootScope({ root }), block)

    fun <T> withLiveRoot(
        root: () -> JsonElement,
        currentValue: (JsonElement) -> JsonElement,
        block: () -> T,
    ): T = withScope(RootScope(root, currentValue), block)

    fun <T> withOccurrence(occurrence: Any, block: () -> T): T {
        val scope = checkNotNull(rootStack.lastOrNull())
        val previous = scope.occurrence
        scope.occurrence = occurrence
        return try {
            block()
        } finally {
            scope.occurrence = previous
        }
    }

    private fun <T> withScope(scope: RootScope, block: () -> T): T {
        rootStack.add(scope)
        return try {
            block()
        } finally {
            rootStack.removeAt(rootStack.lastIndex)
        }
    }

    private val scope: RootScope get() = checkNotNull(rootStack.lastOrNull())

    private fun JsonPathFilterExpressionValue.model(): JsonElement? =
        (this as? JsonValue)?.jsonElement?.let(scope.document::current)

    private fun JsonPathFilterExpressionValue.json(): JsonElement? {
        val value = model()
        check(value == null || !scope.document.collections.isKeySet(value)) {
            "A key set cannot be converted to a Jayway filter ValueNode"
        }
        return JsonPathFilterValues.requireNumber(value)
    }

    private fun binary(evaluator: (JsonElement?, JsonElement?) -> Boolean) =
        LogicalTypeFunctionExtension(ValueType, ValueType) { arguments ->
            evaluator(arguments[0].json(), arguments[1].json())
        }

    private fun matches(left: JsonElement?, right: JsonElement?): Boolean =
        JsonPathFilterValues.matches(left, right, scope.literals, scope.numberTypes)

    private fun equalValues(left: JsonElement?, right: JsonElement?, strict: Boolean = false): Boolean =
        JsonPathFilterValues.equals(left, right, scope.literals, scope.numberTypes, strict)

    private fun compareValues(left: JsonElement?, right: JsonElement?): Int? =
        if (scope.literals.isJsonNode(left) || scope.literals.isJsonNode(right)) null
        else JsonPathFilterValues.compare(left, right)

    private fun inArray(left: JsonElement?, right: JsonElement?): Boolean? {
        val values = JsonPathFilterListValues.convert(right, scope.literals)
        if (values != null) return values.any { matches(left, it) }
        return if (scope.literals.isJsonNode(right)) false else null
    }

    private fun arrays(
        left: JsonElement?,
        right: JsonElement?,
        evaluator: (List<JsonElement?>, List<JsonElement?>) -> Boolean,
    ): Boolean {
        // Jayway converts the right list first, including every element, before inspecting the left.
        val rhs = JsonPathFilterListValues.convert(right, scope.literals) ?: return false
        val lhs = JsonPathFilterListValues.convert(left, scope.literals) ?: return false
        return evaluator(lhs, rhs)
    }

    private val extensions: Map<String, JsonPathFunctionExtension> = mapOf(
        "legadojson" to ValueTypeFunctionExtension(ValueType) { arguments ->
            val encoded = arguments.single().json() as? JsonPrimitive
            require(encoded?.isString == true) { "legadojson requires encoded JSON" }
            Json.parseToJsonElement(encoded.content)
        },
        "legadopathvalue" to ValueTypeFunctionExtension(NodesType) { arguments ->
            val nodes = arguments.single() as JsonPathFilterExpressionValue.NodesTypeValue
            if (nodes is SingularQueryResult) nodes.nodeList.firstOrNull() else JsonArray(nodes.nodeList)
        },
        "legadopathsinglevalue" to ValueTypeFunctionExtension(NodesType) { arguments ->
            val nodes = arguments.single() as JsonPathFilterExpressionValue.NodesTypeValue
            nodes.nodeList.singleOrNull()
        },
        "legadopathexists" to LogicalTypeFunctionExtension(ValueType) { arguments ->
            // Only undefined is absent; JsonNull and other false-like JSON values still exist.
            arguments.single() is JsonValue
        },
        "legadorelativevalue" to ValueTypeFunctionExtension(ValueType, ValueType) { arguments ->
            val model = arguments[0].model()
            val path = requiredString(arguments[1].json())
            model?.let { JsonPathBackend.resolveFrom(path, it, scope.root()) }
        },
        "legadorelativenodes" to NodesTypeFunctionExtension(ValueType, ValueType) { arguments ->
            val model = arguments[0].model()
            val path = requiredString(arguments[1].json())
            val value = model?.let { JsonPathBackend.resolveFrom(path, it, scope.root()) }
            when {
                value == null -> emptyList()
                JsonPathFilterNormalizer.isDefinitePath(path) -> listOf(value)
                value is JsonArray && !scope.document.collections.isKeySet(value) -> value.toList()
                else -> listOf(value)
            }
        },
        "legadorootexists" to LogicalTypeFunctionExtension(ValueType, ValueType) { arguments ->
            val model = arguments[0].model()
            val path = requiredString(arguments[1].json())
            val scope = checkNotNull(rootStack.lastOrNull())
            // PathNode's exists branch passes ctx.item() as document even for '$'.
            val value = model?.let { JsonPathBackend.resolveFrom(path, it, scope.root()) }
            if (value == null) false else {
                val prefix = JsonPathFilterNormalizer.terminalFilterPrefix(path)
                if (prefix == null) true else JsonPathBackend.resolveFrom(prefix, checkNotNull(model), scope.root()).let {
                    it is JsonObject || (it is JsonArray && !scope.document.collections.isKeySet(it))
                }
            }
        },
        "legadoeq" to binary { left, right -> equalValues(left, right) },
        "legadone" to binary { left, right -> !equalValues(left, right) },
        "legadostricteq" to binary { left, right -> equalValues(left, right, strict = true) },
        "legadostrictne" to binary { left, right -> !equalValues(left, right, strict = true) },
        "legadolt" to binary { left, right -> compareValues(left, right)?.let { it < 0 } == true },
        "legadole" to binary { left, right -> compareValues(left, right)?.let { it <= 0 } == true },
        "legadogt" to binary { left, right -> compareValues(left, right)?.let { it > 0 } == true },
        "legadoge" to binary { left, right -> compareValues(left, right)?.let { it >= 0 } == true },
        "legadofilterexists" to LogicalTypeFunctionExtension(NodesType, NodesType) { arguments ->
            val prefix = arguments[0] as JsonPathFilterExpressionValue.NodesTypeValue
            prefix.nodeList.any { it is JsonObject || (it is JsonArray && !scope.document.collections.isKeySet(it)) }
        },
        "legadoin" to binary { left, right -> inArray(left, right) == true },
        "legadonin" to binary { left, right -> inArray(left, right)?.not() == true },
        "legadosubsetof" to binary { left, right ->
            arrays(left, right) { lhs, rhs -> lhs.all { value -> rhs.any { matches(value, it) } } }
        },
        "legadoanyof" to binary { left, right ->
            arrays(left, right) { lhs, rhs -> lhs.any { value -> rhs.any { matches(value, it) } } }
        },
        "legadononeof" to binary { left, right ->
            arrays(left, right) { lhs, rhs -> lhs.none { value -> rhs.any { matches(value, it) } } }
        },
        "legadocontains" to binary { left, right ->
            if (scope.literals.isJsonNode(left)) {
                JsonPathFilterListValues.convert(left, scope.literals)?.any { matches(right, it) } == true
            } else left is JsonPrimitive && left.isString && right is JsonPrimitive && right.isString &&
                !scope.literals.isLiteral(right) && left.content.contains(right.content)
        },
        "legadosize" to binary { left, right ->
            val expected = JsonPathFilterValues.numberIntValue(right)
            val actual = when (val value = if (expected == null) null else scope.literals.parse(left)) {
                is JsonArray -> value.size
                is JsonObject -> -1 // JsonNode.length() returns -1 for maps.
                is JsonPrimitive -> if (value.isString) value.content.length else null
                else -> null
            }
            expected != null && actual != null && expected == actual
        },
        "legadoempty" to binary { left, right ->
            when (val value = scope.literals.parse(left)) {
                is JsonArray -> boolean(right)?.let { value.isEmpty() == it } == true
                is JsonObject -> throw IllegalArgumentException("Jayway empty does not support map values")
                is JsonPrimitive -> value.isString && !scope.literals.isLiteral(right) &&
                    boolean(right)?.let { value.content.isEmpty() == it } == true
                else -> false
            }
        },
        "legadoregex" to LogicalTypeFunctionExtension(ValueType, ValueType, ValueType) { arguments ->
            val pattern = requiredString(arguments[1].json())
            val flags = requiredString(arguments[2].json())
            // Android uses ICU, including its Unicode classes and full-string matching semantics.
            val regex = JsonPathFilterValues.regex(pattern, flags)
            val input = arguments[0].json()
            val parsed = scope.literals.parse(input)
            if (parsed is JsonArray) {
                checkNotNull(JsonPathFilterListValues.convert(input, scope.literals)).any { regex.matches(regexInput(it)) }
            } else if (scope.literals.isJsonNode(input)) regex.matches("")
            else regex.matches(regexInput(input))
        },
        "legadopathcall" to ValueTypeFunctionExtension(ValueType, ValueType) { arguments ->
            pathFunction(arguments[0].model(), requiredString(arguments[1].json()))
        },
        "legadopathprojectcall" to ValueTypeFunctionExtension(ValueType, ValueType) { arguments ->
            pathFunction(arguments[0].model(), requiredString(arguments[1].json()), projected = true)
        },
    ) + JsonPathFilterNormalizer.pathFunctions.associate { name ->
        "legadopath$name" to ValueTypeFunctionExtension(ValueType) { arguments ->
            pathFunction(arguments.single().model(), "$name()")
        }
    }

    fun function(name: String): JsonPathFunctionExtension? {
        if (name == "legadocompound") {
            val occurrence = Any()
            return ValueTypeFunctionExtension(ValueType) { arguments ->
                scope.literals.literal(requiredString(arguments.single().json()), occurrence)
            }
        }
        if (name != "legadorootvalue" && name != "legadorootnodes") return extensions[name]
        // JsonPath4K 3.0.1 recreates literal JsonPrimitives on evaluation, but captures
        // a separately retrieved extension in each compiled function expression.
        val occurrence = Any()
        return if (name == "legadorootvalue") {
            ValueTypeFunctionExtension(ValueType) { arguments ->
                rootValue(requiredString(arguments.single().json()), occurrence)
            }
        } else {
            NodesTypeFunctionExtension(ValueType) { arguments ->
                val path = requiredString(arguments.single().json())
                val value = rootValue(path, occurrence)
                when {
                    value == null -> emptyList()
                    JsonPathFilterNormalizer.isDefinitePath(path) -> listOf(value)
                    value is JsonArray -> value.toList()
                    else -> listOf(value)
                }
            }
        }
    }

    private fun rootValue(path: String, occurrence: Any? = null): JsonElement? {
        require(path.startsWith('$')) { "Expected an absolute JSONPath" }
        val scope = checkNotNull(rootStack.lastOrNull()) { "Root JSONPath requires withRoot during query execution" }
        val currentValue = scope.currentValue
        // PathNode's exists branch evaluates directly; fixed-root scopes keep their old behavior.
        if (occurrence == null || currentValue == null) return JsonPathBackend.resolveNested(path, scope.root())
        val key = PathCacheKey(scope.occurrence, occurrence)
        val value = scope.pathValues[key] ?: JsonPathBackend.resolveNested(path, scope.root())?.also {
            // A missing/failed path throws before Jayway inserts a documentPathCache entry.
            scope.pathValues[key] = it
        } ?: return null
        // Cache primitives by value, but retain array/map references through copy-on-write aliases.
        return if (value is JsonArray || value is JsonObject) currentValue(value) else value
    }

    private fun pathFunction(input: JsonElement?, call: String, projected: Boolean = false): JsonElement? {
        if (input == null || (projected && (input !is JsonArray || scope.document.collections.isKeySet(input)))) return null
        val prefix = if (projected) "\$[*]" else "$"
        val result = JsonPathFunctionSupport.resolve("$prefix.$call", input, JsonPathBackend::resolveFunctionPath)
        result?.failure?.let { throw it }
        // Missing bases return above; a failed function must abort the complete filter query.
        return checkNotNull(result?.value) {
            result?.limitation ?: "JSONPath filter function failed: $call"
        }
    }

    private fun requiredString(value: JsonElement?): String {
        require(value is JsonPrimitive && value.isString) { "Expected a string argument" }
        return value.content
    }

    private fun boolean(value: JsonElement?): Boolean? =
        (value as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull

    private fun regexInput(value: JsonElement?): String = when (value) {
        is JsonPrimitive -> when {
            value == JsonNull -> ""
            value.isString || value.booleanOrNull != null -> value.content
            else -> JsonPathFilterValues.numberString(value.content)
        }
        else -> ""
    }
}
