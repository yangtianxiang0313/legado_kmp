package io.legado.kmp.shared.analyze.parser

import io.legado.kmp.shared.analyze.toJsCompatibleValue
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive

internal data class JsRuleExecution(
    val script: String,
    val bindings: Map<String, Any?>
)

internal fun prepareJsRuleExecution(script: String, bindings: Map<String, Any?>): JsRuleExecution {
    val structured = bindings.filterValues { it is Map<*, *> || it is List<*> || it is JsonElement }
    if (structured.isEmpty()) return JsRuleExecution(script, bindings)

    // The source-less executor serializes only one level; seed structured values recursively.
    val executable = buildString {
        structured.forEach { (key, value) ->
            append("globalThis[")
            append(JsonPrimitive(key).toString())
            append("] = ")
            append(jsRuleValueLiteral(toJsCompatibleValue(value)))
            append(";\n")
        }
        append(script)
    }
    // Do not let the shallow serializer stringify children or emit unescaped object keys first.
    val executorBindings = bindings.mapValues { (key, value) ->
        if (structured.containsKey(key)) null else value
    }
    return JsRuleExecution(executable, executorBindings)
}

private fun jsRuleValueLiteral(value: Any?): String {
    return when (value) {
        null -> "null"
        is String -> JsonPrimitive(value).toString()
        is Number, is Boolean -> value.toString()
        is Map<*, *> -> value.entries.joinToString(prefix = "({", postfix = "})") { (key, child) ->
            "[${JsonPrimitive(key.toString())}]: ${jsRuleValueLiteral(child)}"
        }
        is List<*> -> value.joinToString(prefix = "[", postfix = "]", transform = ::jsRuleValueLiteral)
        else -> JsonPrimitive(value.toString()).toString()
    }
}
