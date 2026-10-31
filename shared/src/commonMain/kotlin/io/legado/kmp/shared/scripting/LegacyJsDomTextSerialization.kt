package io.legado.kmp.shared.scripting

import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.nodes.TextNode

/** Standalone TextNode output moved to Ksoup's element visitor; retain Jsoup 1.16.2's Node contract. */
internal fun legacyJsDomOuterHtml(node: Node): String {
    if (node !is TextNode || node.nodeName() != "#text") return node.outerHtml()
    val settings = node.ownerDocument()?.outputSettings() ?: Document.OutputSettings()
    val parent = node.parentNode() as? Element
    val normalise = settings.prettyPrint() && !preservesLegacyWhitespace(parent)
    if (!normalise) return node.outerHtml()

    val previous = node.previousSibling()
    val next = node.nextSibling()
    val blank = node.isBlank()
    val skip = (next is Element && shouldIndentLegacyElement(next, settings)) ||
        (next is TextNode && next.isBlank()) ||
        (previous is Element && (previous.isBlock() || previous.normalName() == "br"))
    if (blank && skip) return ""

    val block = parent != null && (parent.isBlock() || legacyFormatsAsBlock(parent))
    val trimLeading = (block && node.siblingIndex() == 0) || parent is Document
    val trimTrailing = block && next == null
    val text = normaliseLegacyHtmlWhitespace(node.getWholeText(), trimLeading, trimTrailing)
    val escaped = TextNode(text)
    node.ownerDocument()?.shallowClone()?.appendChild(escaped)
    val indent = (node.siblingIndex() == 0 && parent != null && legacyFormatsAsBlock(parent) && !blank) ||
        (settings.outline() && node.siblingNodes().isNotEmpty() && !blank) ||
        (node.siblingIndex() > 0 && previous?.normalName() == "br")
    return (if (indent) "\n" else "") + escaped.outerHtml()
}

private fun preservesLegacyWhitespace(node: Element?): Boolean {
    var element = node
    repeat(6) {
        val current = element ?: return false
        if (current.tag().preserveWhitespace()) return true
        element = current.parent()
    }
    return false
}

private fun shouldIndentLegacyElement(element: Element, settings: Document.OutputSettings): Boolean {
    val previous = element.previousSibling()
    val effectivelyFirst = element.siblingIndex() == 0 ||
        (element.siblingIndex() == 1 && previous is TextNode && previous.isBlank())
    val inlineable = element.tag().isInline() && (element.parent() == null || element.parent()?.isBlock() == true) &&
        !effectivelyFirst && !settings.outline() && element.normalName() != "br"
    val block = element.isBlock() || element.parent()?.let(::legacyFormatsAsBlock) == true || settings.outline()
    return settings.prettyPrint() && block && !inlineable && !preservesLegacyWhitespace(element.parent())
}

private fun legacyFormatsAsBlock(element: Element): Boolean {
    val tag = element.tag()
    // In Ksoup 0.2.4 the old method name reads the newer InlineContainer option instead.
    return !tag.isKnownTag() || (tag.isBlock() && !tag.formatAsBlock())
}

private fun normaliseLegacyHtmlWhitespace(text: String, trimLeading: Boolean, trimTrailing: Boolean): String =
    buildString(text.length) {
        var pending = false
        for (character in text) {
            if (character == ' ' || character == '\t' || character == '\n' || character == '\r' || character == '\u000C') {
                pending = true
            } else {
                if (pending && (isNotEmpty() || !trimLeading)) append(' ')
                append(character)
                pending = false
            }
        }
        if (pending && !trimTrailing && (isNotEmpty() || !trimLeading)) append(' ')
    }
