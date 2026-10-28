package io.legado.kmp.shared.domain.rss

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.DocumentType
import com.fleeksoft.ksoup.parser.Parser

internal fun parseDefaultRssXml(xml: String, baseUrl: String): Document {
    val input = xml.removePrefix("\uFEFF")
    require(input.isNotBlank()) { "Invalid RSS/Atom XML: empty document" }
    val parser = Parser.xmlParser().setTrackErrors(1)
    val document = Ksoup.parse(html = input, baseUri = baseUrl, parser = parser)
    require(parser.getErrors().isEmpty()) { "Invalid RSS/Atom XML: ${parser.getErrors().first()}" }
    require(document.childrenSize() == 1) { "Invalid RSS/Atom XML: expected one root element" }
    require(document.textNodes().all { it.getWholeText().isBlank() }) {
        "Invalid RSS/Atom XML: text outside root element"
    }
    require(document.childNodes().none { it is DocumentType }) { "Unsupported RSS/Atom XML: DTD" }

    return document
}
