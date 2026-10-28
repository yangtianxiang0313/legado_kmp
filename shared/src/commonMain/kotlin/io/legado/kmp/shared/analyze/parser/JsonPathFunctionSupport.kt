package io.legado.kmp.shared.analyze.parser

import kotlin.math.sqrt
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull

internal data class JsonPathFunctionResult(
    val value: JsonElement?,
    val isKeySet: Boolean = false,
    val limitation: String? = null,
    val failure: Exception? = null,
)

/**
 * Jayway 2.10.0's registered functions and result events, not a JSONPath evaluator.
 *
 * The callback must preserve definite values versus indefinite result arrays, and
 * re-enter this adapter for function prefixes/arguments. JsonNull is a successful
 * null result; a null value means evaluation failed, with its cause in failure.
 * keys() retains its Set kind.
 *
 * Nested Set projections retain their document-scoped kind through selections,
 * parameters and result events. Scan/function boundaries preserve the original
 * token relationship, including a leaf scan created by root inversion.
 * append() shares copy-on-write aliases across branches and nested arguments of
 * one evaluation; prefix and continuation hits invoke functions during traversal.
 * The backend retains mutations only for explicit sessions, never on caller-owned JSON.
 */
internal object JsonPathFunctionSupport {
    fun resolve(
        path: String,
        root: JsonElement,
        resolvePath: (String, JsonElement) -> JsonElement?,
        current: JsonElement = root,
    ): JsonPathFunctionResult? = JsonPathBackend.withFunctionDocument { document ->
        val syntax = JsonPathFunctionSyntax.inspect(path.trim()) ?: return@withFunctionDocument null
        if (syntax.calls.isEmpty()) return@withFunctionDocument null
        try {
            evaluate(Evaluation(syntax), root, resolvePath, document, current)
        } catch (failure: CancellationException) {
            throw failure
        } catch (failure: JsonPathFunctionSelectionLimitation) {
            JsonPathFunctionResult(null, limitation = failure.message, failure = failure)
        } catch (failure: JsonPathFunctionDocumentLimitation) {
            JsonPathFunctionResult(null, limitation = failure.message, failure = failure)
        } catch (failure: Exception) {
            JsonPathFunctionResult(null, failure = failure)
        }
    }

    /** Parameter state belongs to a compiled occurrence, including nested PATH functions. */
    private class Evaluation(val syntax: JsonPathFunctionSyntax.Inspection) {
        val prefix = syntax.calls.first().prefix.ifEmpty { "$" }
        val prefixSyntax = requireNotNull(JsonPathFunctionSyntax.inspect(prefix))
        // CompiledPath only inverts a root scan when the WHOLE path ends in a function.
        val invertedScan = syntax.rootScan && syntax.tail != null
        val scanBefore = syntax.calls.first().scanBefore
        val prefixSelection = if (invertedScan) null else JsonPathBackend.functionPrefix(
            prefix, if (scanBefore) JsonPathScanTail.FUNCTION else JsonPathScanTail.NONE,
        )
        val parameters = syntax.calls.mapIndexed { index, call ->
            // PathCompiler compiles supplied PATH parameters before inversion,
            // even when a false scan predicate will never invoke the function.
            val supplied = JsonPathFunctionSyntax.parameters(call.arguments).map { Argument(it) }
            if (invertedScan && index == 0) {
                // CompiledPath replaces ALL first-function arguments with the scan path.
                listOf(Argument(
                    JsonPathFunctionSyntax.Parameter(prefix, isPath = true),
                    if (scanBefore) JsonPathScanTail.LEAF else JsonPathScanTail.NONE,
                ))
            } else {
                supplied
            }
        }
        val continuations = syntax.continuations
        val selections = continuations.mapIndexed { index, fragment ->
            if (fragment.isEmpty()) null else {
                JsonPathBackend.functionSelection(
                    fragment, terminal = index == syntax.calls.lastIndex,
                    scanTail = if (syntax.calls.getOrNull(index + 1)?.scanBefore == true) {
                        JsonPathScanTail.FUNCTION
                    } else JsonPathScanTail.NONE,
                )
            }
        }
        val multiple = !invertedScan && (prefixSyntax.indefinite || prefixSyntax.propertyUnion || scanBefore)
        val definite = !multiple && selections.all { it == null || it.definite }
    }

    private fun evaluate(
        evaluation: Evaluation,
        root: JsonElement,
        resolvePath: (String, JsonElement) -> JsonElement?,
        document: JsonPathFunctionDocument,
        current: JsonElement = root,
    ): JsonPathFunctionResult = JsonPathBackend.withLiveDocument(
        root = { document.current(root) }, currentValue = document::current,
    ) {
        evaluateScoped(evaluation, root, resolvePath, document, current)
    }

    private fun evaluateScoped(
        evaluation: Evaluation,
        root: JsonElement,
        resolvePath: (String, JsonElement) -> JsonElement?,
        document: JsonPathFunctionDocument,
        current: JsonElement,
    ): JsonPathFunctionResult {
        val syntax = evaluation.syntax
        val events = ResultEvents(document)

        fun evaluateCall(
            index: Int,
            input: Value,
            upstreamDefinite: Boolean,
        ) {
            val call = syntax.calls[index]
            val arguments = evaluation.parameters[index]
            arguments.forEach { it.bind(root, document, resolvePath) }
            // Parameter evaluation can mutate the very model passed to this function.
            val model = input.current(document)
            val result = invoke(call.name, model, arguments, resolvePath, document).current(document)
            // FunctionPathToken adds its result BEFORE evaluating its next token.
            // Keep these events even when a later selector finds nothing.
            events.add(result)
            val selection = evaluation.selections[index]
            if (selection == null) {
                if (index < syntax.calls.lastIndex) {
                    evaluateCall(index + 1, result, upstreamDefinite)
                }
            } else {
                val nextDefinite = upstreamDefinite && selection.definite
                JsonPathBackend.forEachFunctionMatch(
                    selection, result.element, { document.current(root) },
                    upstreamDefinite, result.isKeySet, document::current,
                ) { match ->
                    if (index == syntax.calls.lastIndex) {
                        events.add(Value(match))
                    } else {
                        evaluateCall(index + 1, Value(match), nextDefinite)
                    }
                }
            }
        }

        if (evaluation.invertedScan) {
            // Inversion changes next links, not the first function's original
            // prev links; its continuation still has an indefinite scan upstream.
            evaluateCall(0, Value(document.current(current)), upstreamDefinite = false)
        } else {
            JsonPathBackend.forEachFunctionMatch(
                requireNotNull(evaluation.prefixSelection), document.current(current), { document.current(root) },
                upstreamDefinite = true, currentValue = document::current,
            ) { match ->
                evaluateCall(0, Value(match), upstreamDefinite = !evaluation.multiple)
            }
        }
        val values = events.snapshot()
        if (evaluation.definite) {
            val last = values.lastOrNull() ?: return JsonPathFunctionResult(
                null, failure = JsonPathMissingPathException("No results for path: ${syntax.path}"),
            )
            return JsonPathFunctionResult(last.element, last.isKeySet)
        }
        return JsonPathFunctionResult(JsonArray(values.map { it.element }))
    }

    private data class Value(val element: JsonElement, val isKeySet: Boolean = false) {
        val array: JsonArray? get() = if (isKeySet) null else element as? JsonArray
        fun current(document: JsonPathFunctionDocument): Value = document.current(element).let {
            Value(it, isKeySet || document.collections.isKeySet(it))
        }
    }

    /** One identity/copy scope for ALL branches and result events of this evaluation. */
    private class ResultEvents(private val document: JsonPathFunctionDocument) {
        private val events = mutableListOf<Value>()

        fun add(value: Value) { events += value }

        fun snapshot(): List<Value> = events.map { it.current(document) }
    }

    private class Argument(
        val source: JsonPathFunctionSyntax.Parameter,
        val scanTail: JsonPathScanTail = JsonPathScanTail.NONE,
    ) {
        val path = if (source.isPath) PathExpression(source.text, scanTail) else null
        private var bound: Value? = null
        private var rootSnapshot: String? = null

        fun bind(
            root: JsonElement,
            document: JsonPathFunctionDocument,
            resolvePath: (String, JsonElement) -> JsonElement?,
        ) {
            val expression = path ?: return
            require(source.text == source.text.trimEnd())
            val snapshot = document.snapshot(root)
            // PathLateBindingValue snapshots BEFORE its eager evaluation. Even an
            // equal candidate must execute, but the previous result then wins.
            val candidate = expression.read(root, document, resolvePath)
            if (bound == null || snapshot != rootSnapshot) {
                rootSnapshot = snapshot
                bound = candidate
            }
        }

        fun value(document: JsonPathFunctionDocument): Value =
            (bound ?: Value(document.parseJson(source.text)).also { bound = it }).current(document)
    }

    private class PathExpression(path: String, scanTail: JsonPathScanTail = JsonPathScanTail.NONE) {
        // PATH parameters use rootDocument even when their compiled root token is '@'.
        val source = if (path.startsWith('@')) "\$${path.substring(1)}" else path
        private val evaluation = JsonPathFunctionSyntax.inspect(source.trim())
            ?.takeIf { it.calls.isNotEmpty() }?.let(::Evaluation)
        private val scanSelection = if (scanTail == JsonPathScanTail.NONE) null
            else JsonPathBackend.functionPrefix(source, scanTail)

        init {
            if (evaluation == null && scanSelection == null) {
                JsonPathBackend.functionPrefix(source)
            }
        }

        fun read(
            root: JsonElement,
            document: JsonPathFunctionDocument,
            resolvePath: (String, JsonElement) -> JsonElement?,
        ): Value {
            val currentRoot = document.current(root)
            if (scanSelection != null) {
                return Value(JsonArray(buildList {
                    JsonPathBackend.forEachFunctionMatch(
                        scanSelection, currentRoot, { document.current(root) }, upstreamDefinite = true,
                        currentValue = document::current, onMatch = { add(it) },
                    )
                }))
            }
            val function = evaluation?.let { evaluate(it, currentRoot, resolvePath, document) }
            return if (function != null) {
                val value = function.value ?: throw (
                    function.failure ?: JsonPathMissingPathException("No results for path: $source")
                )
                Value(value, function.isKeySet).current(document)
            } else {
                val value = resolvePath(source, currentRoot)
                    ?: throw JsonPathMissingPathException("No results for path: $source")
                Value(value).current(document)
            }
        }
    }

    private fun invoke(
        name: String,
        model: Value,
        arguments: List<Argument>,
        resolvePath: (String, JsonElement) -> JsonElement?,
        document: JsonPathFunctionDocument,
    ): Value = when (name) {
        "length", "size" -> length(model, arguments, resolvePath, document)
        "sum", "avg", "stddev", "min", "max" -> aggregate(name, model, arguments, document)
        "first", "last", "index" -> sequence(name, model, arguments, document)
        "keys" -> {
            val obj = model.element as? JsonObject
            if (obj == null) Value(JsonNull) else Value(document.collections.keySet(obj), true)
        }
        "concat" -> concatenate(model, arguments, document)
        "append" -> {
            val array = model.array
            if (array == null) model else {
                val additions = arguments.map { it.value(document).element }
                Value(document.append(array, additions))
            }
        }
        else -> error("Unregistered function")
    }

    private fun length(
        model: Value,
        arguments: List<Argument>,
        resolvePath: (String, JsonElement) -> JsonElement?,
        document: JsonPathFunctionDocument,
    ): Value {
        if (arguments.isNotEmpty()) {
            val first = arguments.first().source
            require(first.isPath)
            val source = first.text.trim()
            val syntax = requireNotNull(JsonPathFunctionSyntax.inspect(source))
            val query = if (arguments.first().scanTail != JsonPathScanTail.NONE) {
                "$source.[*]"
            } else if (syntax.tail != null || source == "$" || source == "@") {
                source
            } else {
                "$source[*]"
            }
            // Length re-evaluates its first path against MODEL, unlike other functions.
            require(model.element !== JsonNull)
            val expression = if (query == source) requireNotNull(arguments.first().path) else PathExpression(query)
            val inner = expression.read(model.element, document, resolvePath)
            inner.array?.let { return Value(JsonPrimitive(it.size)) }
        }
        val current = model.current(document)
        return Value(when {
            current.array != null -> JsonPrimitive(current.array!!.size)
            current.element is JsonObject -> JsonPrimitive(current.element.size)
            else -> JsonNull
        })
    }

    private fun aggregate(
        name: String,
        model: Value,
        arguments: List<Argument>,
        document: JsonPathFunctionDocument,
    ): Value {
        val values = mutableListOf<Double>()
        model.array?.forEach { it.number()?.let(values::add) }
        arguments.forEach { argument ->
            consume(argument.value(document)) { it.number()?.let(values::add) }
        }
        require(values.isNotEmpty())
        var sum = 0.0
        var sumSquares = 0.0
        var min = Double.MAX_VALUE
        // This is Double.MIN_VALUE, not a negative bound, in Jayway 2.10.0.
        var max = Double.MIN_VALUE
        for (value in values) {
            sum += value
            sumSquares += value * value
            if (min > value) min = value
            if (max < value) max = value
        }
        val count = values.size.toDouble()
        return Value(JsonPrimitive(when (name) {
            "sum" -> sum
            "avg" -> sum / count
            "stddev" -> sqrt(sumSquares / count - sum * sum / count / count)
            "min" -> min
            else -> max
        }))
    }

    private fun sequence(
        name: String,
        model: Value,
        arguments: List<Argument>,
        document: JsonPathFunctionDocument,
    ): Value {
        val array = requireNotNull(model.array)
        val index = when (name) {
            "first" -> 0
            "last" -> -1
            else -> {
                var firstNumber: JsonPrimitive? = null
                arguments.forEach { argument ->
                    consume(argument.value(document)) { value ->
                        if (firstNumber == null && value.number() != null) firstNumber = value as JsonPrimitive
                    }
                }
                document.numberTypes.intValue(requireNotNull(firstNumber))
            }
        }
        val actual = if (index >= 0) index else (array.size + index).also { require(it > 0) }
        require(actual in array.indices)
        return Value(array[actual])
    }

    private fun concatenate(
        model: Value,
        arguments: List<Argument>,
        document: JsonPathFunctionDocument,
    ): Value {
        val result = StringBuilder()
        model.array?.forEach { value ->
            if (value is JsonPrimitive && value.isString) result.append(value.content)
        }
        arguments.forEach { argument ->
            val value = argument.value(document)
            consume(value) { item ->
                if (item !== JsonNull) result.append(JsonPathValueStrings.javaString(
                    item, document.numberTypes, document.collections::isKeySet,
                ))
            }
        }
        return Value(JsonPrimitive(result.toString()))
    }

    private inline fun consume(value: Value, consumer: (JsonElement) -> Unit) {
        val array = value.array
        if (array != null) array.forEach(consumer) else consumer(value.element)
    }

    private fun JsonElement.number(): Double? {
        val primitive = this as? JsonPrimitive ?: return null
        return if (primitive.isString || primitive === JsonNull) null else primitive.doubleOrNull
    }

}
