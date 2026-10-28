package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element

/**
 * Basic HTML formatting: collapse whitespace, decode entities.
 * Aligned with legado's HtmlFormatter.format() behavior.
 */
internal fun legacyHtmlFormat(html: String): String {
    if (html.isBlank()) return ""
    return try {
        Ksoup.parse(html).body().text()
    } catch (_: Exception) {
        html
    }
}

internal fun legacyHtmlSelect(html: String, selector: String): List<Map<String, Any?>> {
    if (html.isBlank() || selector.isBlank()) return emptyList()
    return try {
        Ksoup.parse(html).select(selector).map(::legacyHtmlElementMap)
    } catch (_: Exception) {
        emptyList()
    }
}

private fun legacyHtmlElementMap(element: Element): Map<String, Any?> {
    return linkedMapOf(
        "text" to element.text(),
        "innerHtml" to element.html(),
        "outerHtml" to element.outerHtml(),
        "attrs" to element.attributes().associate { it.key to it.value }
    )
}
