@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.analyze.parser

import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import io.legado.kmp.shared.libxml2.LEGADO_XML_ATTRIBUTE_NODE
import io.legado.kmp.shared.libxml2.LEGADO_XML_CDATA_SECTION_NODE
import io.legado.kmp.shared.libxml2.LEGADO_XML_COMMENT_NODE
import io.legado.kmp.shared.libxml2.LEGADO_XML_ELEMENT_NODE
import io.legado.kmp.shared.libxml2.LEGADO_XML_TEXT_NODE
import io.legado.kmp.shared.libxml2.LEGADO_XPATH_BOOLEAN
import io.legado.kmp.shared.libxml2.LEGADO_XPATH_NODESET
import io.legado.kmp.shared.libxml2.LEGADO_XPATH_NUMBER
import io.legado.kmp.shared.libxml2.LEGADO_XPATH_STRING
import io.legado.kmp.shared.libxml2.legado_xml_element_path
import io.legado.kmp.shared.libxml2.legado_xml_free_doc
import io.legado.kmp.shared.libxml2.legado_xml_free_ptr
import io.legado.kmp.shared.libxml2.legado_xml_free_xpath
import io.legado.kmp.shared.libxml2.legado_xml_node_content
import io.legado.kmp.shared.libxml2.legado_xml_node_dump
import io.legado.kmp.shared.libxml2.legado_xml_node_inner_dump
import io.legado.kmp.shared.libxml2.legado_xml_node_type
import io.legado.kmp.shared.libxml2.legado_xpath_bool_value
import io.legado.kmp.shared.libxml2.legado_xpath_eval_at_path
import io.legado.kmp.shared.libxml2.legado_xpath_node_at
import io.legado.kmp.shared.libxml2.legado_xpath_nodes_count
import io.legado.kmp.shared.libxml2.legado_xpath_number_value
import io.legado.kmp.shared.libxml2.legado_xpath_read_document
import io.legado.kmp.shared.libxml2.legado_xpath_result_type
import io.legado.kmp.shared.libxml2.legado_xpath_string_value
import io.legado.kmp.shared.libxml2.xmlDocPtr
import io.legado.kmp.shared.libxml2.xmlNodePtr
import io.legado.kmp.shared.libxml2.xmlXPathObjectPtr
import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.toKString

/**
 * JsoupXPath extension function type detected during pre-processing.
 * When the XPath ends with one of these pseudo-functions, we strip it
 * before passing to libxml2 and post-process the results accordingly.
 */
private enum class JsoupXPathExtension {
    ALL_TEXT,
    TIDY_TEXT,
    HTML,
    OUTER_HTML,
    NONE
}

/**
 * Result of pre-processing an XPath expression:
 * [cleanXPath] is the XPath with JsoupXPath extensions removed (safe for libxml2),
 * [extension] indicates what post-processing to apply.
 */
private data class PreProcessedXPath(
    val cleanXPath: String,
    val extension: JsoupXPathExtension
)

/**
 * Regex to detect and strip JsoupXPath extension pseudo-functions at the end of an XPath.
 * Matches: /allText(), /tidyText(), /html(), /outerHtml()
 */
private val extensionSuffixRegex = Regex("""/(allText|tidyText|html|outerHtml)\(\)\s*$""")

/**
 * Regex to detect JsoupXPath node()[m:n] range syntax.
 * Matches: node()[1:5], child::node()[2:10], etc.
 */
private val nodeRangeRegex = Regex("""node\(\)\s*\[\s*(\d+)\s*:\s*(\d+)\s*]""")

// Keep only immutable text and a stable locator; native document ownership stays inside evaluate().
private class IosXPathElement(
    val document: String,
    val path: String,
    private val markup: String,
) {
    override fun toString(): String = markup
}

private class IosXPathBackend : XPathBackend {

    override fun getElements(content: Any, xPath: String): List<Any> {
        if (xPath.isBlank()) {
            return emptyList()
        }
        if (content is List<*>) return content.filterNotNull().flatMap { getElements(it, xPath) }
        val preprocessed = preProcessXPath(xPath)
        return evaluate(content, preprocessed.cleanXPath) { document, result, source ->
            if (legado_xpath_result_type(result) != LEGADO_XPATH_NODESET.toInt()) {
                emptyList()
            } else {
                buildList {
                    val count = legado_xpath_nodes_count(result)
                    for (index in 0 until count) {
                        val node = legado_xpath_node_at(result, index) ?: continue
                        val markup = postProcessNode(document, node, preprocessed.extension, serialize = true)
                        val path = if (preprocessed.extension == JsoupXPathExtension.NONE &&
                            legado_xml_node_type(node) == LEGADO_XML_ELEMENT_NODE.toInt()
                        ) elementPath(node) else null
                        add(if (path != null) IosXPathElement(source, path, markup) else markup)
                    }
                }
            }
        }
    }

    override fun getStringList(content: Any, xPath: String): List<String> {
        if (xPath.isBlank()) {
            return emptyList()
        }
        if (content is List<*>) return content.filterNotNull().flatMap { getStringList(it, xPath) }
        val preprocessed = preProcessXPath(xPath)
        return evaluate(content, preprocessed.cleanXPath) { document, result, _ ->
            when (legado_xpath_result_type(result)) {
                LEGADO_XPATH_NODESET.toInt() -> buildList {
                    val count = legado_xpath_nodes_count(result)
                    for (index in 0 until count) {
                        val node = legado_xpath_node_at(result, index) ?: continue
                        add(postProcessNode(document, node, preprocessed.extension, serialize = false))
                    }
                }
                LEGADO_XPATH_STRING.toInt() -> listOfNotNull(
                    legado_xpath_string_value(result)?.reinterpret<ByteVar>()?.toKString()
                )
                LEGADO_XPATH_BOOLEAN.toInt() -> listOf(
                    if (legado_xpath_bool_value(result) == 0) "false" else "true"
                )
                LEGADO_XPATH_NUMBER.toInt() -> listOf(
                    legado_xpath_number_value(result).toString()
                )
                else -> emptyList()
            }
        }
    }

    // ── JsoupXPath Extension Pre-processing ──────────────────────────────

    /**
     * Pre-process an XPath expression to handle JsoupXPath extensions:
     * 1. Strip /allText(), /tidyText(), /html(), /outerHtml() suffixes
     * 2. Convert node()[m:n] range syntax to position() predicates
     */
    private fun preProcessXPath(xPath: String): PreProcessedXPath {
        var cleaned = xPath
        var extension = JsoupXPathExtension.NONE

        // Detect and strip extension suffix
        val suffixMatch = extensionSuffixRegex.find(cleaned)
        if (suffixMatch != null) {
            extension = when (suffixMatch.groupValues[1]) {
                "allText" -> JsoupXPathExtension.ALL_TEXT
                "tidyText" -> JsoupXPathExtension.TIDY_TEXT
                "html" -> JsoupXPathExtension.HTML
                "outerHtml" -> JsoupXPathExtension.OUTER_HTML
                else -> JsoupXPathExtension.NONE
            }
            cleaned = cleaned.removeRange(suffixMatch.range)
            // If stripping left us with an empty xpath, select current context
            if (cleaned.isBlank()) {
                cleaned = "."
            }
        }

        // Convert node()[m:n] range to standard XPath position() predicates
        cleaned = nodeRangeRegex.replace(cleaned) { match ->
            val start = match.groupValues[1]
            val end = match.groupValues[2]
            "node()[position()>=$start and position()<=$end]"
        }

        return PreProcessedXPath(cleaned, extension)
    }

    /**
     * Post-process a node based on the detected JsoupXPath extension.
     */
    private fun postProcessNode(
        document: xmlDocPtr,
        node: xmlNodePtr,
        extension: JsoupXPathExtension,
        serialize: Boolean
    ): String {
        return when (extension) {
            JsoupXPathExtension.ALL_TEXT -> {
                // allText(): get all descendant text content
                val content = legado_xml_node_content(node) ?: return ""
                try {
                    content.reinterpret<ByteVar>().toKString()
                } finally {
                    legado_xml_free_ptr(content)
                }
            }
            JsoupXPathExtension.TIDY_TEXT -> {
                // tidyText(): like allText() but with whitespace normalization
                val content = legado_xml_node_content(node) ?: return ""
                try {
                    val raw = content.reinterpret<ByteVar>().toKString()
                    raw.replace(Regex("""\s+"""), " ").trim()
                } finally {
                    legado_xml_free_ptr(content)
                }
            }
            JsoupXPathExtension.HTML -> {
                // html(): inner HTML of the node
                if (legado_xml_node_type(node) != LEGADO_XML_ELEMENT_NODE.toInt()) {
                    val content = legado_xml_node_content(node) ?: return ""
                    try {
                        content.reinterpret<ByteVar>().toKString()
                    } finally {
                        legado_xml_free_ptr(content)
                    }
                } else {
                    val dumped = legado_xml_node_inner_dump(document, node) ?: return ""
                    try {
                        dumped.reinterpret<ByteVar>().toKString()
                    } finally {
                        legado_xml_free_ptr(dumped)
                    }
                }
            }
            JsoupXPathExtension.OUTER_HTML -> {
                // outerHtml(): the node itself serialized
                serializeNode(document, node)
            }
            JsoupXPathExtension.NONE -> {
                // No extension — use default behavior
                if (serialize) {
                    serializeNode(document, node)
                } else {
                    extractNodeText(document, node)
                }
            }
        }
    }

    // ── Core evaluation ──────────────────────────────────────────────────

    private inline fun <T> evaluate(
        content: Any,
        xPath: String,
        block: (document: xmlDocPtr, result: xmlXPathObjectPtr, source: String) -> List<T>
    ): List<T> {
        val element = elementContext(content)
        val normalized = element?.document ?: normalizeContent(content.toString())
        val document = legado_xpath_read_document(
            normalized,
            if (shouldParseAsXml(normalized)) 1 else 0
        ) ?: return emptyList()
        return try {
            val candidates = if (element != null) listOf(xPath) else buildXPathCandidates(normalized, xPath)
            for (candidate in candidates) {
                val result = legado_xpath_eval_at_path(document, element?.path, candidate) ?: continue
                val values = try {
                    block(document, result, normalized)
                } finally {
                    legado_xml_free_xpath(result)
                }
                if (values.isNotEmpty()) {
                    return values
                }
            }
            emptyList()
        } finally {
            legado_xml_free_doc(document)
        }
    }

    private fun elementPath(node: xmlNodePtr): String? {
        val path = legado_xml_element_path(node) ?: return null
        return try {
            path.reinterpret<ByteVar>().toKString()
        } finally {
            legado_xml_free_ptr(path)
        }
    }

    private fun elementContext(content: Any): IosXPathElement? {
        if (content is IosXPathElement) return content
        if (content !is Element || content is Document) return null
        val document = content.ownerDocument() ?: return null
        val positions = mutableListOf<Int>()
        var node: Element? = content
        while (node != null && node !is Document) {
            positions += node.elementSiblingIndex() + 1
            node = node.parent()
        }
        val path = positions.asReversed().joinToString("") { "/*[$it]" }
        return IosXPathElement(document.outerHtml(), path, content.outerHtml())
    }

    /**
     * Legacy JXNode can execute relative XPath directly on element nodes.
     * Untyped string fragments have no retained node identity. Keep the legacy
     * `./...` fallback for these inputs only; selected elements use their exact context.
     */
    private fun buildXPathCandidates(content: String, xPath: String): List<String> {
        val fallback = buildFragmentRelativeFallback(content, xPath)
        return if (fallback != null && fallback != xPath) {
            listOf(xPath, fallback)
        } else {
            listOf(xPath)
        }
    }

    private fun buildFragmentRelativeFallback(content: String, xPath: String): String? {
        if (!xPath.startsWith("./") && !xPath.startsWith(".//")) {
            return null
        }
        val trimmed = content.trimStart()
        if (
            trimmed.startsWith("<?xml", ignoreCase = true) ||
            trimmed.startsWith("<html", ignoreCase = true) ||
            trimmed.startsWith("<!doctype", ignoreCase = true)
        ) {
            return null
        }
        val root = Regex("""<\s*([A-Za-z_][\w:.-]*)\b""").find(trimmed)?.groupValues?.getOrNull(1)
            ?: return null
        return "//$root${xPath.removePrefix(".")}"
    }

    // ── Node text/serialization helpers ──────────────────────────────────

    private fun extractNodeText(
        document: xmlDocPtr,
        node: xmlNodePtr
    ): String {
        val nodeType = legado_xml_node_type(node)
        return when (nodeType) {
            LEGADO_XML_ELEMENT_NODE.toInt() -> {
                val dumped = legado_xml_node_dump(document, node) ?: return ""
                try {
                    dumped.reinterpret<ByteVar>().toKString()
                } finally {
                    legado_xml_free_ptr(dumped)
                }
            }
            LEGADO_XML_ATTRIBUTE_NODE.toInt(),
            LEGADO_XML_TEXT_NODE.toInt(),
            LEGADO_XML_CDATA_SECTION_NODE.toInt(),
            LEGADO_XML_COMMENT_NODE.toInt() -> {
                val content = legado_xml_node_content(node) ?: return ""
                try {
                    content.reinterpret<ByteVar>().toKString()
                } finally {
                    legado_xml_free_ptr(content)
                }
            }
            else -> {
                val content = legado_xml_node_content(node) ?: return ""
                try {
                    content.reinterpret<ByteVar>().toKString()
                } finally {
                    legado_xml_free_ptr(content)
                }
            }
        }
    }

    private fun serializeNode(
        document: xmlDocPtr,
        node: xmlNodePtr
    ): String {
        val nodeType = legado_xml_node_type(node)
        return when (nodeType) {
            LEGADO_XML_ELEMENT_NODE.toInt() -> {
                val dumped = legado_xml_node_dump(document, node) ?: return ""
                try {
                    dumped.reinterpret<ByteVar>().toKString()
                } finally {
                    legado_xml_free_ptr(dumped)
                }
            }
            else -> extractNodeText(document, node)
        }
    }

    // ── Content normalization ────────────────────────────────────────────

    private fun normalizeContent(content: String): String {
        var normalized = content
        if (normalized.endsWith("</td>")) {
            normalized = "<tr>$normalized</tr>"
        }
        if (normalized.endsWith("</tr>") || normalized.endsWith("</tbody>")) {
            normalized = "<table>$normalized</table>"
        }
        return normalized
    }

    private fun shouldParseAsXml(content: String): Boolean {
        val trimmed = content.trimStart()
        if (trimmed.startsWith("<?xml", ignoreCase = true)) {
            return true
        }
        if (trimmed.startsWith("<html", ignoreCase = true) || trimmed.startsWith("<!doctype", ignoreCase = true)) {
            return false
        }
        if (trimmed.startsWith("<rss", ignoreCase = true) || trimmed.startsWith("<feed", ignoreCase = true)) {
            return true
        }
        if (trimmed.startsWith("<channel", ignoreCase = true) || trimmed.startsWith("<item", ignoreCase = true)) {
            return true
        }
        if (Regex("""<\s*[A-Za-z_][\w.-]*:[\w.-]+""").containsMatchIn(trimmed)) {
            return true
        }
        return Regex("""\sxmlns(?::[\w.-]+)?\s*=""").containsMatchIn(trimmed)
    }
}

actual fun createXPathBackend(): XPathBackend = IosXPathBackend()
