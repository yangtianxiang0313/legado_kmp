package io.legado.kmp.shared.analyze

import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.select.Elements
import io.legado.kmp.shared.analyze.parser.JsonPathNumberTypes
import io.legado.kmp.shared.analyze.parser.JsonPathRetainedValue
import io.legado.kmp.shared.analyze.parser.JsonPathValueStrings
import io.legado.kmp.shared.scripting.LegacyJsDomNodeValues
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

internal const val LEGACY_JSON_INPUT_DESCRIPTORS_BINDING = "__legacyJsonInputDescriptors"

internal fun legacyJsonInputDescriptors(rawResult: Any?): List<Map<String, Any?>> {
    val descriptors = mutableListOf<Map<String, Any?>>()
    fun scalar(key: Any, input: Any?, inheritedNumbers: JsonPathNumberTypes): Map<String, Any?>? {
        val value = if (input is JsonPathRetainedValue) input.element else input
        val numbers = if (input is JsonPathRetainedValue) input.numbers else inheritedNumbers
        if (value !is JsonPrimitive) return null
        // Retain native spelling (e.g. Double 6.0) only while the JS field is unchanged.
        return linkedMapOf(
            "key" to key,
            "value" to toJsCompatibleValue(value),
            "java" to JsonPathValueStrings.javaString(value, numbers),
            "json" to JsonPathValueStrings.json(value, numbers)
        )
    }

    fun scan(value: Any?, path: List<Any>, numbers: JsonPathNumberTypes) {
        when (value) {
            is AnalyzeResult -> scan(jsPipelineValue(value), path, numbers)
            is JsonPathRetainedValue -> scan(value.element, path, value.numbers)
            // DOM wrappers must stay opaque, including those implementing List.
            is AnalyzeHtmlElementValues, is Node, is Elements, is LegacyJsDomNodeValues -> Unit
            is JsonObject -> {
                descriptors += linkedMapOf(
                    "path" to path,
                    "kind" to "map",
                    "keys" to value.keys.toList(),
                    "scalars" to value.mapNotNull { (key, child) -> scalar(key, child, numbers) }
                )
                value.forEach { (key, child) -> scan(child, path + key, numbers) }
            }
            is JsonArray, is AnalyzeJsonArrayValues -> {
                val children = value as List<*>
                // Jayway's JSON-smart JSONArray prints compact JSON, not Java List.toString.
                descriptors += linkedMapOf(
                    "path" to path,
                    "kind" to "jsonArray",
                    "scalars" to children.mapIndexedNotNull { index, child -> scalar(index, child, numbers) }
                )
                children.forEachIndexed { index, child -> scan(child, path + index, numbers) }
            }
            // Traverse ordinary containers without assigning native JSON provenance.
            is Map<*, *> -> value.forEach { (key, child) ->
                key?.toString()?.let { scan(child, path + it, numbers) }
            }
            is List<*> -> value.forEachIndexed { index, child -> scan(child, path + index, numbers) }
        }
    }

    scan(rawResult, emptyList(), JsonPathNumberTypes())
    return descriptors
}
