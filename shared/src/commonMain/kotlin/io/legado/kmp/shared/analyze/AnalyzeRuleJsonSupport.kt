package io.legado.kmp.shared.analyze

import io.legado.kmp.shared.analyze.parser.JsonPathParser
import io.legado.kmp.shared.analyze.parser.JsonPathRetainedValue
import io.legado.kmp.shared.scripting.toJsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull

internal enum class JsonPathResultMode {
    STRING, STRING_LIST, RAW
}

internal class AnalyzeRuleJsonSupport(private val getContent: () -> Any?) {
    private var contentParser: JsonPathParser? = null

    fun reset() {
        contentParser = null
    }

    fun getParser(input: Any?): JsonPathParser {
        val content = getContent()
        // Compare original inputs before serialization: equal JSON text need not mean equal inputs.
        if (input != content) return createParser(input)
        return contentParser ?: createParser(content).also { contentParser = it }
    }

    private fun createParser(input: Any?): JsonPathParser {
        val raw = if (input is AnalyzeResult) input.jsonPathRawInput() else input
        return JsonPathRetainedValue.fromInput(raw)?.let(::JsonPathParser) ?: JsonPathParser(jsonPathInput(raw))
    }
}

// A JSON array is not an element-selection wrapper, even when it has one item.
internal class AnalyzeJsonArrayValues(values: List<Any?>) : AbstractList<Any>() {
    private val elements = values.map { it ?: JsonNull }

    override val size: Int get() = elements.size

    override fun get(index: Int): Any = elements[index]
}

// JSONPath string-list results must not be reparsed as objects by the legacy JS adapter.
internal class AnalyzeJsonStringValues(private val values: List<String>) : AbstractList<String>() {
    override val size: Int get() = values.size

    override fun get(index: Int): String = values[index]
}

internal fun List<*>.isStructuredArray(): Boolean {
    return this is AnalyzeJsArrayValues || this is AnalyzeJsonArrayValues || this is JsonArray
}

internal fun jsonPathInput(value: Any?): String {
    return when (value) {
        is AnalyzeResult -> value.jsonPathInput()
        is String -> value
        is JsonElement -> value.toString()
        is Map<*, *>, is List<*> -> value.toJsonElement().toString()
        else -> value?.toString().orEmpty()
    }
}

internal fun AnalyzeResult.jsonPathInput(): String {
    return jsonPathInput(jsonPathRawInput())
}

internal fun AnalyzeResult.jsonPathRawInput(): Any? {
    return when (this) {
        is AnalyzeResult.Elements -> {
            if (values.isStructuredArray()) values else values.singleOrNull() ?: values
        }
        is AnalyzeResult.StringList -> values
        is AnalyzeResult.StringVal -> value
        is AnalyzeResult.IntVal -> value
        is AnalyzeResult.LongVal -> value
        is AnalyzeResult.FloatVal -> value
        is AnalyzeResult.BoolVal -> value
        is AnalyzeResult.Null -> null
    }
}
