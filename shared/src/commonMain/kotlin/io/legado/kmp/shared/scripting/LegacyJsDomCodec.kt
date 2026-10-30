package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import com.fleeksoft.ksoup.select.Elements
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull

/** Only the private shim exporter supplies envelopes; raw user maps are never decoded recursively. */
internal fun legacyJsDomResult(wire: Any?, session: LegacyJsDomSession? = null): JsResult {
    val decoded = decodeLegacyJsDomValue(wire, session)
    return if (decoded.containsDom) {
        JsResult.JsNativeValue(decoded.value)
    } else {
        JsResult.fromAny(decoded.value)
    }
}

internal fun legacyJsDomContent(wire: Any?, session: LegacyJsDomSession? = null): Any? =
    decodeLegacyJsDomValue(wire, session).value

private data class LegacyJsDomValue(
    val value: Any?,
    val containsDom: Boolean = false,
    val present: Boolean = true,
)

private fun decodeLegacyJsDomValue(wire: Any?, session: LegacyJsDomSession?): LegacyJsDomValue {
    val envelope = wire as? Map<*, *> ?: error("Invalid legacy DOM envelope")
    return when (envelope["kind"]) {
        "raw", "value" -> LegacyJsDomValue(envelope["value"], present = envelope.containsKey("value"))
        "element" -> LegacyJsDomValue(
            (envelope["value"] as? Map<*, *> ?: error("Invalid legacy DOM element")).let { payload ->
                val handle = payload["handle"] as? String
                if (session != null && handle != null) session.resolve(handle) else legacyJsDomElement(payload)
            },
            containsDom = true,
        )
        "array", "elements" -> {
            val children = (envelope["value"] as? List<*>)
                ?.map { decodeLegacyJsDomValue(it, session) }
                ?: error("Invalid legacy DOM array")
            val values = children.map { it.value }
            if (envelope["kind"] == "elements") {
                require(values.all { it is Element }) { "Invalid legacy DOM collection" }
                LegacyJsDomValue(Elements(values.map { it as Element }), containsDom = true)
            } else {
                LegacyJsDomValue(values, children.any { it.containsDom })
            }
        }
        "object" -> {
            val entries = envelope["value"] as? List<*> ?: error("Invalid legacy DOM object")
            var containsDom = false
            val value = linkedMapOf<String, Any?>()
            for (entry in entries) {
                val pair = entry as? List<*> ?: error("Invalid legacy DOM property")
                val key = pair.getOrNull(0) as? String ?: error("Invalid legacy DOM property name")
                val child = decodeLegacyJsDomValue(pair.getOrNull(1), session)
                if (child.present) value[key] = child.value
                containsDom = containsDom || child.containsDom
            }
            LegacyJsDomValue(value, containsDom)
        }
        else -> error("Unknown legacy DOM envelope kind")
    }
}

internal fun legacyJsDomParse(html: String, baseUri: String): Map<String, Any?> =
    legacyJsDomPayload(Ksoup.parse(html, baseUri))

internal fun legacyJsDomSelect(payload: String, selector: String): List<Map<String, Any?>> {
    if (selector.isBlank()) return emptyList()
    return runCatching {
        legacyJsDomElement(legacyJsDomPayloadFromJson(payload)).select(selector).map(::legacyJsDomPayload)
    }.getOrElse { emptyList() }
}

internal fun legacyJsDomAttribute(payload: String, name: String): String =
    legacyJsDomElement(legacyJsDomPayloadFromJson(payload)).attr(name)

private fun legacyJsDomPayload(element: Element): Map<String, Any?> = linkedMapOf(
    "text" to element.text(),
    "innerHtml" to element.html(),
    "outerHtml" to element.outerHtml(),
    "tag" to element.tagName(),
    "document" to (element is Document),
    "baseUri" to element.baseUri(),
    "attrs" to element.attributes().associate { it.key to it.value },
)

internal fun legacyJsDomElement(payload: Map<*, *>): Element {
    val baseUri = payload["baseUri"] as? String ?: ""
    val outerHtml = payload["outerHtml"] as? String ?: ""
    val tag = payload["tag"] as? String
    if (payload["document"] == true || tag == "#root") return Ksoup.parse(outerHtml, baseUri)

    // Older Analyze payloads omit tag. XML is used only to recover the outer tag/attributes,
    // not to parse HTML children (void tags and table/select contexts need the HTML parser).
    val outerNode by lazy {
        Parser.parseXmlFragment(outerHtml, baseUri).filterIsInstance<Element>().firstOrNull()
    }
    val element = Element(tag?.takeIf { it.isNotBlank() } ?: outerNode?.tagName() ?: "span")
    element.setBaseUri(baseUri)
    val attrs = payload["attrs"] as? Map<*, *>
        ?: outerNode?.attributes()?.associate { it.key to it.value }.orEmpty()
    attrs.forEach { (key, value) ->
        if (key is String && value != null) element.attr(key, value.toString())
    }
    val innerHtml = payload["innerHtml"] as? String ?: payload["html"] as? String
    if (innerHtml != null) {
        element.html(innerHtml)
    } else {
        val recovered = outerNode
        if (recovered != null) element.html(recovered.html())
        else element.text(payload["text"]?.toString() ?: outerHtml)
    }
    return element
}

internal fun legacyJsDomPayloadFromJson(payload: String): Map<*, *> =
    legacyJsDomJsonValue(Json.parseToJsonElement(payload)) as? Map<*, *>
        ?: error("Invalid legacy DOM payload")

private fun legacyJsDomJsonValue(value: JsonElement): Any? = when (value) {
    JsonNull -> null
    is JsonObject -> value.mapValues { legacyJsDomJsonValue(it.value) }
    is JsonArray -> value.map(::legacyJsDomJsonValue)
    is JsonPrimitive -> if (value.isString) value.content else value.booleanOrNull ?: value.contentOrNull
}

internal fun buildLegacyJsDomExecution(library: String?, script: String): String = buildString {
    // Capture before source jsLib/rules execute, then remove the only global exporter handle.
    appendLine("(function(exportValue, globalEval) {")
    appendLine("  delete globalThis.__legacyExportDomValue;")
    append("  return exportValue(globalEval(")
    // Keep library lexical declarations visible to the rule, without rewriting either script's completion.
    append(JsonPrimitive(if (library.isNullOrBlank()) script else "$library\n$script"))
    appendLine("));")
    appendLine("})(globalThis.__legacyExportDomValue, (0, eval));")
}
