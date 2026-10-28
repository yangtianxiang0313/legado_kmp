package io.legado.kmp.shared.network

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element

/**
 * Parsed element result - wraps ksoup Element
 */
data class ParsedElement(
    val text: String,
    val html: String,
    val attributes: Map<String, String>,
    val children: List<ParsedElement> = emptyList(),
    val tagName: String = "",
    val baseUrl: String = ""
) {
    /**
     * Get attribute value
     */
    fun attr(key: String): String = attributes[key] ?: ""

    /**
     * Get absolute URL attribute
     */
    fun absUrl(key: String): String {
        val value = attributes[key] ?: return ""
        // If already absolute, return as-is
        if (value.startsWith("http://") || value.startsWith("https://")) {
            return value
        }
        // Resolve relative URL
        return if (baseUrl.isNotEmpty() && value.startsWith("/")) {
            baseUrl.trimEnd('/') + value
        } else if (baseUrl.isNotEmpty()) {
            baseUrl.trimEnd('/') + "/" + value
        } else {
            value
        }
    }
}

/**
 * HTML parsing result - wraps ksoup Document
 */
data class HtmlParseResult(
    private val document: Document,
    private val baseUrl: String = ""
) {
    val content: String get() = document.html()
    val title: String get() = document.title()
    val body: String get() = document.body()?.html() ?: ""

    /**
     * Select elements by CSS selector
     */
    fun select(cssQuery: String): List<ParsedElement> {
        return document.select(cssQuery).map { it.toParsedElement(baseUrl) }
    }

    /**
     * Select first element by CSS selector
     */
    fun selectFirst(cssQuery: String): ParsedElement? {
        return document.selectFirst(cssQuery)?.toParsedElement(baseUrl)
    }

    /**
     * Get element text by CSS selector
     */
    fun getText(cssQuery: String, defaultValue: String = ""): String {
        return document.selectFirst(cssQuery)?.text() ?: defaultValue
    }

    /**
     * Get element attribute by CSS selector
     */
    fun getAttr(cssQuery: String, attribute: String, defaultValue: String = ""): String {
        return document.selectFirst(cssQuery)?.attr(attribute) ?: defaultValue
    }

    /**
     * Extract all texts matching a CSS selector
     */
    fun extractTexts(cssQuery: String): List<String> {
        return document.select(cssQuery).map { it.text() }
    }

    /**
     * Extract all attributes matching a CSS selector
     */
    fun extractAttrs(cssQuery: String, attribute: String): List<String> {
        return document.select(cssQuery).mapNotNull { element ->
            val value = element.attr(attribute)
            if (value.isNotEmpty()) value else null
        }
    }

    fun getElements(cssQuery: String): List<ParsedElement> {
        return select(cssQuery)
    }

    /**
     * Get underlying ksoup Document for advanced operations
     */
    fun getDocument(): Document = document
}

/**
 * Extension to convert ksoup Element to ParsedElement
 */
private fun Element.toParsedElement(baseUrl: String = ""): ParsedElement {
    return ParsedElement(
        text = text(),
        html = html(),
        attributes = attributes().associate { it.key to it.value },
        children = children().map { it.toParsedElement(baseUrl) },
        tagName = tagName(),
        baseUrl = baseUrl
    )
}

/**
 * HTML parser using ksoup for cross-platform HTML parsing
 */
class HtmlParser {

    /**
     * Parse HTML string into a document
     */
    fun parse(html: String, baseUri: String = ""): HtmlParseResult {
        val document = parseDocument(html, baseUri)
        return HtmlParseResult(document, baseUri)
    }

    /**
     * Parse HTML and return ksoup Document directly
     */
    fun parseDocument(html: String, baseUri: String = ""): Document {
        return if (baseUri.isNotEmpty()) {
            Ksoup.parse(html = html, baseUri = baseUri)
        } else {
            Ksoup.parse(html = html)
        }
    }

    /**
     * Extract text from HTML using CSS selector
     */
    fun extractText(html: String, cssQuery: String, defaultValue: String = ""): String {
        val doc = parseDocument(html)
        return doc.selectFirst(cssQuery)?.text() ?: defaultValue
    }

    /**
     * Extract attribute from HTML using CSS selector
     */
    fun extractAttr(html: String, cssQuery: String, attribute: String, defaultValue: String = ""): String {
        val doc = parseDocument(html)
        return doc.selectFirst(cssQuery)?.attr(attribute) ?: defaultValue
    }

    /**
     * Convert HTML to plain text
     */
    fun toText(html: String): String {
        val doc = parseDocument(html)
        return doc.text()
    }

    /**
     * Clean HTML by removing specified selectors
     */
    fun cleanHtml(html: String, selectorsToRemove: List<String> = listOf("script", "style")): String {
        val doc = parseDocument(html)
        for (selector in selectorsToRemove) {
            doc.select(selector).remove()
        }
        return doc.html()
    }

    companion object {
        val Default: HtmlParser = HtmlParser()
    }
}

/**
 * Extension to parse HTML string
 */
fun String.parseHtml(baseUri: String = ""): HtmlParseResult {
    return HtmlParser.Default.parse(this, baseUri)
}

/**
 * Extension to extract text from HTML using CSS selector
 */
fun String.extractText(cssQuery: String, defaultValue: String = ""): String {
    return HtmlParser.Default.extractText(this, cssQuery, defaultValue)
}

/**
 * Extension to extract attribute from HTML using CSS selector
 */
fun String.extractAttr(cssQuery: String, attribute: String, defaultValue: String = ""): String {
    return HtmlParser.Default.extractAttr(this, cssQuery, attribute, defaultValue)
}

/**
 * Extension to convert HTML to plain text
 */
fun String.htmlToText(): String {
    return HtmlParser.Default.toText(this)
}

/**
 * Extension to clean HTML
 */
fun String.cleanHtml(selectorsToRemove: List<String> = listOf("script", "style")): String {
    return HtmlParser.Default.cleanHtml(this, selectorsToRemove)
}
