package io.legado.kmp.shared.analyze

import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.select.Elements
import io.legado.kmp.shared.scripting.JsResult
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull

internal fun analyzeResultFromJs(
    result: JsResult,
    onError: (JsResult.JsError) -> AnalyzeResult
): AnalyzeResult {
    return when (result) {
        is JsResult.JsString -> AnalyzeResult.StringVal(result.value)
        is JsResult.JsNumber -> analyzeResultFromJsNumber(result.value)
        is JsResult.JsBoolean -> AnalyzeResult.BoolVal(result.value)
        is JsResult.JsArray -> analyzeResultFromRaw(AnalyzeJsArrayValues(result.value))
        is JsResult.JsObject -> analyzeResultFromRaw(preserveJsResultValue(result.value))
        is JsResult.JsNativeValue -> analyzeResultFromRaw(preserveJsResultValue(result.value))
        is JsResult.JsNull, is JsResult.JsUndefined -> AnalyzeResult.StringVal("")
        is JsResult.JsError -> onError(result)
    }
}

private fun analyzeResultFromJsNumber(value: Double): AnalyzeResult {
    // Keep negative zero and non-integral/non-finite numbers as Double, not Float.
    val negativeZero = value == 0.0 && value.toBits() == Long.MIN_VALUE
    if (value.isFinite() && !negativeZero && value % 1.0 == 0.0) {
        if (value >= Int.MIN_VALUE.toDouble() && value <= Int.MAX_VALUE.toDouble()) {
            return AnalyzeResult.IntVal(value.toInt())
        }
        // Long.MAX_VALUE rounds to 2^63 as Double, so the upper bound is exclusive.
        if (value >= Long.MIN_VALUE.toDouble() && value < Long.MAX_VALUE.toDouble()) {
            return AnalyzeResult.LongVal(value.toLong())
        }
    }
    return analyzeResultFromRaw(value)
}

// Elements stays flat for element consumers, while JS arrays retain their shape on re-entry.
internal class AnalyzeJsArrayValues(values: List<Any?>) : AbstractList<Any>() {
    private val elements = values.map { preserveJsResultValue(it) ?: JsonNull }

    override val size: Int get() = elements.size

    override fun get(index: Int): Any = elements[index]
}

private fun preserveJsResultValue(value: Any?): Any? {
    return when (value) {
        // Element and Elements must precede List: DOM is not a JavaScript array.
        is Element, is Elements, is AnalyzeHtmlElementValues -> value
        is AnalyzeJsArrayValues, is AnalyzeJsonArrayValues -> value
        is JsonElement -> preserveJsResultValue(toJsCompatibleValue(value))
        is Map<*, *> -> LinkedHashMap<String, Any?>().apply {
            value.forEach { (key, child) ->
                key?.toString()?.let { put(it, preserveJsResultValue(child)) }
            }
        }
        is List<*> -> AnalyzeJsArrayValues(value)
        else -> value
    }
}
