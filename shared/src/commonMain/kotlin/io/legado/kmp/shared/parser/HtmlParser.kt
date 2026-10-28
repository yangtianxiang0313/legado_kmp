package io.legado.kmp.shared.parser

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.select.Elements

/**
 * HTML Parser based on ksoup for cross-platform HTML parsing.
 * Provides CSS selector support and DOM manipulation.
 */
class HtmlParser {

    /**
     * Parse HTML string into a Document
     * @param html HTML content
     * @return Document object
     */
    fun parse(html: String): Document {
        return Ksoup.parse(html = html)
    }

    /**
     * Parse HTML with base URI for resolving relative URLs
     * @param html HTML content
     * @param baseUri Base URL for resolving relative links
     * @return Document object
     */
    fun parse(html: String, baseUri: String): Document {
        return Ksoup.parse(html = html, baseUri = baseUri)
    }

    /**
     * Query a single element by CSS selector
     * @param document Document to query
     * @param selector CSS selector
     * @return First matching element or null
     */
    fun querySelector(document: Document, selector: String): Element? {
        return document.selectFirst(selector)
    }

    /**
     * Query all elements matching CSS selector
     * @param document Document to query
     * @param selector CSS selector
     * @return All matching elements
     */
    fun querySelectorAll(document: Document, selector: String): Elements {
        return document.select(selector)
    }

    /**
     * Query a single element from a parent element
     * @param element Parent element
     * @param selector CSS selector
     * @return First matching element or null
     */
    fun querySelector(element: Element, selector: String): Element? {
        return element.selectFirst(selector)
    }

    /**
     * Query all elements from a parent element
     * @param element Parent element
     * @param selector CSS selector
     * @return All matching elements
     */
    fun querySelectorAll(element: Element, selector: String): Elements {
        return element.select(selector)
    }


    companion object {
        val Default: HtmlParser = HtmlParser()
    }
}
