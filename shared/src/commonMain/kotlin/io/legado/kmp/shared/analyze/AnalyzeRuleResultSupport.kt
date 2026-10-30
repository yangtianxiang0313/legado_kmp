package io.legado.kmp.shared.analyze

import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.select.Elements
import io.legado.kmp.shared.analyze.parser.JsonPathRetainedValue
import io.legado.kmp.shared.scripting.LEGACY_NATIVE_DOM_INPUT_BINDING
import io.legado.kmp.shared.scripting.LegacyJsDomInputs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull

/**
 * Result type from rule analysis
 */
sealed class AnalyzeResult {
    data class StringVal(val value: kotlin.String) : AnalyzeResult()
    data class StringList(val values: List<kotlin.String>) : AnalyzeResult()
    data class IntVal(val value: kotlin.Int) : AnalyzeResult()
    data class LongVal(val value: kotlin.Long) : AnalyzeResult()
    data class FloatVal(val value: kotlin.Float) : AnalyzeResult()
    data class BoolVal(val value: kotlin.Boolean) : AnalyzeResult()
    data class Elements(val values: List<Any>) : AnalyzeResult()
    object Null : AnalyzeResult()

    fun asString(): kotlin.String = when (this) {
        is StringVal -> value
        is IntVal -> value.toString()
        is LongVal -> value.toString()
        is FloatVal -> value.toString()
        is BoolVal -> if (value) "true" else "false"
        is StringList -> values.joinToString("\n")
        is Elements -> values.firstOrNull()?.toString() ?: ""
        is Null -> ""
    }
}

internal const val LEGACY_HTML_RESULT_KIND_BINDING = "__legacyHtmlResultKind"
internal const val LEGACY_DOM_INPUT_DESCRIPTORS_BINDING = "__legacyDomInputDescriptors"

internal enum class LegacyHtmlResultKind(val bindingValue: String) {
    ELEMENT("element"),
    ELEMENTS("elements")
}

// AnalyzeResult.Elements also holds scalar objects; keep native HTML provenance separate.
internal class AnalyzeHtmlElementValues private constructor(
    private val elements: List<Element>,
    val kind: LegacyHtmlResultKind
) : AbstractList<Any>() {
    override val size: Int get() = elements.size

    override fun get(index: Int): Any = elements[index]

    companion object {
        fun element(value: Element): AnalyzeHtmlElementValues =
            AnalyzeHtmlElementValues(listOf(value), LegacyHtmlResultKind.ELEMENT)

        fun elements(values: List<Element>): AnalyzeHtmlElementValues =
            AnalyzeHtmlElementValues(values.toList(), LegacyHtmlResultKind.ELEMENTS)
    }
}

internal fun legacyHtmlResultKind(value: Any?): LegacyHtmlResultKind? {
    return when (value) {
        is AnalyzeResult.Elements -> legacyHtmlResultKind(value.values)
        is AnalyzeHtmlElementValues -> value.kind
        is Element -> LegacyHtmlResultKind.ELEMENT
        is Elements -> LegacyHtmlResultKind.ELEMENTS
        is List<*> -> if (!value.isStructuredArray() && value.isNotEmpty() && value.all { it is Element }) {
            LegacyHtmlResultKind.ELEMENTS
        } else {
            null
        }
        else -> null
    }
}

internal fun legacyDomInputDescriptors(rawResult: Any?): List<Map<String, Any?>> {
    val descriptors = mutableListOf<Map<String, Any?>>()

    fun addDescriptor(path: List<Any>, kind: LegacyHtmlResultKind) {
        descriptors += linkedMapOf("path" to path, "kind" to kind.bindingValue)
    }

    fun scan(value: Any?, path: List<Any>) {
        when (value) {
            is AnalyzeResult -> scan(jsPipelineValue(value), path)
            is AnalyzeHtmlElementValues -> addDescriptor(path, value.kind)
            is Element -> addDescriptor(path, LegacyHtmlResultKind.ELEMENT)
            is Elements -> addDescriptor(path, LegacyHtmlResultKind.ELEMENTS)
            is Map<*, *> -> value.forEach { (key, child) ->
                key?.toString()?.let { scan(child, path + it) }
            }
            is List<*> -> value.forEachIndexed { index, child -> scan(child, path + index) }
        }
    }

    // Preserve the legacy root List<Element> contract, never infer DOM from payload fields.
    val rootKind = legacyHtmlResultKind(rawResult)
    if (rootKind != null) {
        addDescriptor(emptyList(), rootKind)
    } else {
        scan(rawResult, emptyList())
    }
    return descriptors
}

internal fun legacyNativeDomInputs(rawResult: Any?): LegacyJsDomInputs? {
    val descriptors = legacyDomInputDescriptors(rawResult)
    if (descriptors.isEmpty()) return null
    fun unwrap(value: Any?): Any? = if (value is AnalyzeResult) jsPipelineValue(value) else value
    val inputs = descriptors.map { descriptor ->
        val path = (descriptor["path"] as List<*>).map { requireNotNull(it) }
        var value = unwrap(rawResult)
        for (key in path) {
            value = unwrap(when (val parent = value) {
                is Map<*, *> -> parent.entries.firstOrNull { it.key?.toString() == key }?.value
                is List<*> -> parent[(key as Number).toInt()]
                else -> error("Invalid native DOM input path")
            })
        }
        val elements = when (val selected = value) {
            is Element -> listOf(selected)
            is Elements -> selected.toList()
            is List<*> -> selected.map { it as Element }
            else -> error("Invalid native DOM input")
        }
        LegacyJsDomInputs.Input(path, elements, descriptor["kind"] == LegacyHtmlResultKind.ELEMENT.bindingValue)
    }
    return LegacyJsDomInputs(inputs)
}

internal fun analyzeResultFromRaw(raw: Any?): AnalyzeResult {
    return when (raw) {
        null -> AnalyzeResult.Null
        is AnalyzeResult -> raw
        is JsonPathRetainedValue -> AnalyzeResult.Elements(raw.arrayValues() ?: listOf(raw))
        is kotlin.String -> AnalyzeResult.StringVal(raw)
        is AnalyzeHtmlElementValues -> AnalyzeResult.Elements(raw)
        is Element -> AnalyzeResult.Elements(AnalyzeHtmlElementValues.element(raw))
        is Elements -> AnalyzeResult.Elements(AnalyzeHtmlElementValues.elements(raw.toList()))
        is AnalyzeJsArrayValues -> AnalyzeResult.Elements(raw)
        is AnalyzeJsonArrayValues -> AnalyzeResult.Elements(raw)
        is JsonArray -> AnalyzeResult.Elements(AnalyzeJsonArrayValues(raw))
        is List<*> -> AnalyzeResult.Elements(raw.filterNotNull())
        else -> AnalyzeResult.Elements(listOf(raw))
    }
}

internal fun AnalyzeResult.asElementValues(): List<Any> {
    return when (this) {
        is AnalyzeResult.Elements -> values
        is AnalyzeResult.StringList -> values.map { it as Any }
        is AnalyzeResult.StringVal -> listOf(value)
        is AnalyzeResult.IntVal -> listOf(value)
        is AnalyzeResult.LongVal -> listOf(value)
        is AnalyzeResult.FloatVal -> listOf(value)
        is AnalyzeResult.BoolVal -> listOf(value)
        is AnalyzeResult.Null -> emptyList()
    }
}

internal fun jsPipelineValue(result: AnalyzeResult): Any? {
    return when (result) {
        is AnalyzeResult.Elements -> if (result.values.isStructuredArray() ||
            legacyHtmlResultKind(result) == LegacyHtmlResultKind.ELEMENTS
        ) {
            result.values
        } else {
            result.values.singleOrNull() ?: result.values
        }
        is AnalyzeResult.StringList -> result.values
        is AnalyzeResult.StringVal -> result.value
        is AnalyzeResult.IntVal -> result.value
        is AnalyzeResult.LongVal -> result.value
        is AnalyzeResult.FloatVal -> result.value
        is AnalyzeResult.BoolVal -> result.value
        is AnalyzeResult.Null -> null
    }
}

internal fun legacyJsElementPayload(value: Any?): Map<String, Any?>? {
    val payload = when (value) {
        null -> null
        is com.fleeksoft.ksoup.select.Elements -> linkedMapOf(
            "elements" to value.map { element ->
                linkedMapOf(
                    "text" to element.text(),
                    "innerHtml" to element.html(),
                    "outerHtml" to element.outerHtml(),
                    "tag" to element.tagName(),
                    "document" to (element is Document),
                    "baseUri" to element.baseUri(),
                    "attrs" to element.attributes().associate { it.key to it.value }
                )
            }
        )
        is com.fleeksoft.ksoup.nodes.Element -> linkedMapOf(
            "text" to value.text(),
            "innerHtml" to value.html(),
            "outerHtml" to value.outerHtml(),
            "tag" to value.tagName(),
            "document" to (value is Document),
            "baseUri" to value.baseUri(),
            "attrs" to value.attributes().associate { it.key to it.value }
        )
        is List<*> -> {
            val elementPayloads = value.mapNotNull { item ->
                (item as? com.fleeksoft.ksoup.nodes.Element)?.let { element ->
                    linkedMapOf(
                        "text" to element.text(),
                        "innerHtml" to element.html(),
                        "outerHtml" to element.outerHtml(),
                        "tag" to element.tagName(),
                        "document" to (element is Document),
                        "baseUri" to element.baseUri(),
                        "attrs" to element.attributes().associate { it.key to it.value }
                    )
                }
            }
            if (elementPayloads.isNotEmpty()) {
                linkedMapOf("elements" to elementPayloads)
            } else {
                linkedMapOf(
                    "elements" to value.map { item ->
                        val text = item?.toString().orEmpty()
                        linkedMapOf(
                            "text" to text,
                            "innerHtml" to text,
                            "outerHtml" to text,
                            "attrs" to emptyMap<String, String>()
                        )
                    }
                )
            }
        }
        else -> linkedMapOf(
            "text" to value.toString(),
            "innerHtml" to value.toString(),
            "outerHtml" to value.toString(),
            "attrs" to emptyMap<String, String>()
        )
    } ?: return null
    val elements = when (value) {
        is Element -> listOf(value)
        is Elements -> value.toList()
        is List<*> -> value.filterIsInstance<Element>()
        else -> emptyList()
    }
    if (value !is Element && value !is Elements && elements.isEmpty()) return payload
    return LinkedHashMap(payload).apply {
        put(LEGACY_NATIVE_DOM_INPUT_BINDING, LegacyJsDomInputs(listOf(
            LegacyJsDomInputs.Input(emptyList(), elements, value is Element)
        )))
    }
}

internal fun jsValueFromAnalyzeResult(previousResult: AnalyzeResult): Any? {
    return when (previousResult) {
        is AnalyzeResult.StringVal -> previousResult.value
        is AnalyzeResult.StringList -> previousResult.values
        is AnalyzeResult.IntVal -> previousResult.value
        is AnalyzeResult.LongVal -> previousResult.value
        is AnalyzeResult.FloatVal -> previousResult.value
        is AnalyzeResult.BoolVal -> previousResult.value
        is AnalyzeResult.Elements -> previousResult.toJsElementValue(::toJsCompatibleValue)
        is AnalyzeResult.Null -> null
    }
}

internal fun legacyJsValueFromAnalyzeResult(previousResult: AnalyzeResult): Any? {
    return when (previousResult) {
        is AnalyzeResult.StringVal -> previousResult.value
        is AnalyzeResult.StringList -> if (previousResult.values is AnalyzeJsonStringValues) {
            previousResult.values
        } else {
            previousResult.values.map(::legacyStructuredStringOrSelf)
        }
        is AnalyzeResult.Elements -> {
            previousResult.toJsElementValue {
                when (it) {
                    is String -> if (previousResult.values.isStructuredArray()) {
                        it
                    } else {
                        legacyStructuredStringOrSelf(it)
                    }
                    else -> toJsCompatibleValue(it)
                }
            }
        }
        else -> jsValueFromAnalyzeResult(previousResult)
    }
}

private fun AnalyzeResult.Elements.toJsElementValue(convert: (Any) -> Any?): Any? {
    // JsonNull is an array slot, not a missing element; converting it must not shift indexes.
    val converted = values.map(convert)
    if (values.isStructuredArray() || legacyHtmlResultKind(this) == LegacyHtmlResultKind.ELEMENTS) {
        return converted
    }
    return when (converted.size) {
        0 -> null
        1 -> converted.first()
        else -> converted
    }
}

private fun legacyStructuredStringOrSelf(value: String): Any? {
    val trimmed = value.trim()
    if (!looksLikeJsonPayload(trimmed)) {
        return value
    }
    return runCatching { Json.parseToJsonElement(trimmed) }
        .getOrNull()
        ?.let(::toJsCompatibleValue)
        ?: value
}

private fun looksLikeJsonPayload(value: String): Boolean {
    return (value.startsWith("{") && value.endsWith("}")) ||
        (value.startsWith("[") && value.endsWith("]"))
}

internal fun toJsCompatibleValue(value: Any?): Any? {
    return when (value) {
        null -> null
        is AnalyzeResult -> jsValueFromAnalyzeResult(value)
        is JsonPathRetainedValue -> toJsCompatibleValue(value.element)
        is JsonNull -> null
        is JsonPrimitive -> if (value.isString) {
            value.content
        } else {
            value.booleanOrNull
                ?: value.longOrNull
                ?: value.doubleOrNull
                ?: value.contentOrNull
                ?: value.toString()
        }
        is JsonObject -> LinkedHashMap<String, Any?>().apply {
            value.forEach { (key, child) ->
                put(key, toJsCompatibleValue(child))
            }
        }
        is JsonArray -> value.map(::toJsCompatibleValue)
        is AnalyzeHtmlElementValues -> if (value.kind == LegacyHtmlResultKind.ELEMENT) {
            toJsCompatibleValue(value.single())
        } else {
            value.map(::toJsCompatibleValue)
        }
        is com.fleeksoft.ksoup.select.Elements -> value.map(::toJsCompatibleValue)
        is com.fleeksoft.ksoup.nodes.Element -> elementToJsCompatibleValue(value)
        is Map<*, *> -> LinkedHashMap<String, Any?>().apply {
            value.forEach { (key, child) ->
                key?.toString()?.let { put(it, toJsCompatibleValue(child)) }
            }
        }
        is List<*> -> value.map(::toJsCompatibleValue)
        is String, is Number, is Boolean -> value
        else -> value.toString()
    }
}

private fun elementToJsCompatibleValue(element: com.fleeksoft.ksoup.nodes.Element): Map<String, Any?> {
    val attrs = linkedMapOf<String, Any?>().apply {
        element.attributes().forEach { attribute ->
            put(attribute.key, attribute.value)
        }
    }
    return linkedMapOf<String, Any?>().apply {
        putAll(attrs)
        put("text", element.text())
        put("innerHtml", element.html())
        put("outerHtml", element.outerHtml())
        put("html", element.html())
        put("tag", element.tagName())
        put("attrs", attrs)
        put("document", element is Document)
        put("baseUri", element.baseUri())
    }
}
