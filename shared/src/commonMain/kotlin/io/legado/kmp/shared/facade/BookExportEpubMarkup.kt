package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Comment
import com.fleeksoft.ksoup.nodes.DataNode
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.DocumentType
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Entities
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.nodes.TextNode
import com.fleeksoft.ksoup.nodes.XmlDeclaration
import com.fleeksoft.ksoup.parser.Parser
import io.legado.kmp.shared.domain.localbook.LocalBookSvg
import io.ktor.http.decodeURLPart

internal fun epubTemplateDocument(input: String, checkActive: () -> Unit): Document {
    checkActive()
    require(input.length <= EPUB_TEMPLATE_MAX_BYTES && input.encodeToByteArray().size <= EPUB_TEMPLATE_MAX_BYTES) {
        "EPUB 模板文档超过 16 MiB"
    }
    return Ksoup.parse(input.epubXmlCharacters()).also { cleanEpubTemplate(it, checkActive) }
}

internal fun epubTemplateHasContentSlot(template: String, checkActive: () -> Unit): Boolean =
    epubTemplateContentSlots(epubTemplateDocument(template, checkActive), checkActive).isNotEmpty()

/** The document has already been cleaned; foreign/raw-text/inert contexts cannot carry chapter XHTML. */
internal fun epubTemplateContentSlots(document: Document, checkActive: () -> Unit): List<TextNode> {
    val slots = mutableListOf<TextNode>()
    val pending = ArrayDeque<Node>()
    pending.addLast(document.body())
    while (pending.isNotEmpty()) {
        checkActive()
        val node = pending.removeLast()
        when (node) {
            is Element -> {
                if (node.tagName().substringAfter(':').lowercase() !in EPUB_NON_CONTENT_CONTEXTS) {
                    node.childNodes().reversed().forEach(pending::addLast)
                }
            }
            is TextNode -> if ("{content}" in node.getWholeText()) slots += node
        }
    }
    return slots
}

internal fun epubTemplateNodes(root: Node, checkActive: () -> Unit): List<Node> {
    val nodes = mutableListOf<Node>()
    val pending = ArrayDeque<Pair<Node, Int>>()
    pending.addLast(root to 0)
    while (pending.isNotEmpty()) {
        checkActive()
        val (node, depth) = pending.removeLast()
        require(nodes.size < 100_000 && depth <= 128) { "EPUB 模板节点超过 100000 项或嵌套超过 128 层" }
        nodes += node
        node.childNodes().reversed().forEach { pending.addLast(it to depth + 1) }
    }
    return nodes
}

internal fun epubTemplateXhtml(document: Document, checkActive: () -> Unit): String {
    cleanEpubTemplate(document, checkActive)
    val html = document.select("html").first() ?: error("EPUB 模板缺少 html 根节点")
    html.attr("xmlns", "http://www.w3.org/1999/xhtml")
    html.attr("xmlns:epub", "http://www.idpf.org/2007/ops")
    html.attr("xmlns:xlink", "http://www.w3.org/1999/xlink")
    if (!html.hasAttr("lang")) html.attr("lang", html.attr("xml:lang").ifBlank { "zh-CN" })
    if (!html.hasAttr("xml:lang")) html.attr("xml:lang", html.attr("lang"))
    // Restore SVG's case-sensitive foreign names after the tolerant HTML parser.
    document.select("svg").filter { svg -> svg.parents().none { it.tagName().equals("svg", true) } }.forEach { svg ->
        checkActive()
        svg.attr("xmlns", "http://www.w3.org/2000/svg")
        val restored = Ksoup.parse(html = LocalBookSvg.serialize(svg), parser = Parser.xmlParser()).child(0)
        svg.replaceWith(restored)
    }
    document.select("math").forEach { it.attr("xmlns", "http://www.w3.org/1998/Math/MathML") }
    xmlOutput(document)
    return boundedEpubOutput("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE html>\n${html.outerHtml()}\n", checkActive)
}

internal fun epubTemplateSvg(input: String, checkActive: () -> Unit): String {
    checkActive()
    require(input.length <= EPUB_TEMPLATE_MAX_BYTES && input.encodeToByteArray().size <= EPUB_TEMPLATE_MAX_BYTES) {
        "EPUB 模板 SVG 超过 16 MiB"
    }
    val document = Ksoup.parse(html = input.epubXmlCharacters(), parser = Parser.xmlParser())
    val root = document.children().singleOrNull()
    require(root != null && root.tagName().substringAfter(':').equals("svg", true)) { "EPUB 模板 SVG 根节点无效" }
    cleanEpubTemplate(document, checkActive)
    root.attr("xmlns", "http://www.w3.org/2000/svg")
    root.attr("xmlns:xlink", "http://www.w3.org/1999/xlink")
    xmlOutput(document)
    return boundedEpubOutput("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n${root.outerHtml()}\n", checkActive)
}

/** XML data, SMIL, PLS and MathML stay XML. Active constructs are rejected rather than silently changing data. */
internal fun epubTemplateXml(input: String, checkActive: () -> Unit): String {
    checkActive()
    require(input.length <= EPUB_TEMPLATE_MAX_BYTES && input.encodeToByteArray().size <= EPUB_TEMPLATE_MAX_BYTES) {
        "EPUB 模板 XML 超过 16 MiB"
    }
    val document = Ksoup.parse(html = input.epubXmlCharacters(), parser = Parser.xmlParser())
    val root = document.children().singleOrNull() ?: error("EPUB 模板 XML 必须只有一个根节点")
    epubTemplateNodes(document, checkActive).forEach { node ->
        checkActive()
        when (node) {
            is Element -> {
                if (node is Document) return@forEach
                val name = node.tagName().substringAfter(':').lowercase()
                require(EPUB_XML_NAME.matches(node.tagName()) && name !in EPUB_ACTIVE_ELEMENTS &&
                    !(name in EPUB_SVG_ACTIVE_ELEMENTS && node.inEpubSvg())) { "EPUB 模板 XML 包含主动内容或无效标签" }
                node.attributes().forEach { attribute ->
                    val key = attribute.key.lowercase()
                    val local = key.substringAfter(':')
                    require(EPUB_XML_NAME.matches(attribute.key) && !local.startsWith("on") &&
                        key !in setOf("srcdoc", "xml:base", "ping", "action", "formaction", "codebase", "archive", "xmlns:xmlns") &&
                        !(':' in key && local in setOf("event", "handler", "observer"))) { "EPUB 模板 XML 包含主动属性" }
                    require(local !in EPUB_URI_ATTRIBUTES || epubTemplateReferenceSafe(attribute.value)) {
                        "EPUB 模板 XML 包含危险资源地址"
                    }
                    require(local != "style" || epubCssSafe(attribute.value, checkActive)) { "EPUB 模板 XML 包含主动样式" }
                    require(key != "xmlns:xml" || attribute.value == "http://www.w3.org/XML/1998/namespace") {
                        "EPUB 模板 XML 命名空间无效"
                    }
                }
                require(name != "style" || epubCssSafe(node.wholeEpubStyle(), checkActive)) { "EPUB 模板 XML 包含主动样式" }
                require(name != "meta" || !node.attr("http-equiv").trim().equals("refresh", true)) {
                    "EPUB 模板 XML 不支持自动跳转"
                }
                require(name != "link" || node.attr("rel").lowercase().split(Regex("\\s+")).none { it in setOf("import", "modulepreload") }) {
                    "EPUB 模板 XML 不支持主动导入"
                }
            }
            is DocumentType -> error("EPUB 模板 XML 不支持 DTD")
            is XmlDeclaration -> require(node.parent() === document && node.outerHtml().startsWith("<?xml ", true)) {
                "EPUB 模板 XML 不支持处理指令"
            }
            is DataNode -> node.replaceWith(TextNode(node.getWholeData().epubXmlCharacters()))
            is TextNode -> node.replaceWith(TextNode(node.getWholeText().epubXmlCharacters()))
            is Comment -> node.remove()
        }
    }
    checkEpubNamespaces(document, setOf("xml"), checkActive)
    xmlOutput(document)
    return boundedEpubOutput("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n${root.outerHtml()}\n", checkActive)
}

private fun cleanEpubTemplate(document: Document, checkActive: () -> Unit) {
    epubTemplateNodes(document, checkActive).forEach { node ->
        checkActive()
        if (node !== document && node.parent() == null) return@forEach
        when (node) {
            is Element -> {
                if (node is Document) return@forEach
                val name = node.tagName().substringAfter(':').lowercase()
                if (name in EPUB_ACTIVE_ELEMENTS || name in EPUB_SVG_ACTIVE_ELEMENTS && node.inEpubSvg() ||
                    !EPUB_XML_NAME.matches(node.tagName())) {
                    node.remove()
                    return@forEach
                }
                if (name == "meta" && node.attr("http-equiv").trim().equals("refresh", true) ||
                    name == "link" && node.attr("rel").lowercase().split(Regex("\\s+")).any { it in setOf("import", "modulepreload") }) {
                    node.remove()
                    return@forEach
                }
                node.attributes().toList().forEach { attribute ->
                    val key = attribute.key.lowercase()
                    val local = key.substringAfter(':')
                    val value = attribute.value.epubXmlCharacters()
                    when {
                        !EPUB_XML_NAME.matches(attribute.key) || local.startsWith("on") ||
                            key in setOf("srcdoc", "xml:base", "ping", "action", "formaction", "codebase", "archive", "xmlns:xmlns", "autoplay") ||
                            ':' in key && local in setOf("event", "handler", "observer") ->
                            node.removeAttr(attribute.key)
                        key == "xmlns:xml" -> node.attr(attribute.key, "http://www.w3.org/XML/1998/namespace")
                        local == "style" -> {
                            if (!epubCssSafe(value, checkActive)) node.removeAttr(attribute.key)
                            else node.attr(attribute.key, value)
                        }
                        local == "srcset" -> {
                            if (!epubSrcsetSafe(value)) node.removeAttr(attribute.key)
                            else node.attr(attribute.key, value)
                        }
                        local in EPUB_URI_ATTRIBUTES && !epubTemplateReferenceSafe(value) -> node.removeAttr(attribute.key)
                        else -> node.attr(attribute.key, value)
                    }
                }
                if (name == "style") {
                    val css = node.wholeEpubStyle()
                    if (!epubCssSafe(css, checkActive)) node.remove()
                    else node.empty().appendChild(TextNode(css.epubXmlCharacters()))
                }
                // Missing or rejected image URLs must not become broken-image placeholders.
                if (name == "img" && node.attr("src").isBlank() && node.attr("srcset").isBlank() ||
                    name == "image" && node.attr("href").isBlank() && node.attr("xlink:href").isBlank()) node.remove()
            }
            is DataNode -> node.replaceWith(TextNode(node.getWholeData().epubXmlCharacters()))
            is TextNode -> node.replaceWith(TextNode(node.getWholeText().epubXmlCharacters()))
            is Comment, is DocumentType, is XmlDeclaration -> node.remove()
        }
    }
    checkEpubNamespaces(document, setOf("xml", "epub", "xlink"), checkActive)
}

private fun checkEpubNamespaces(document: Document, implicit: Set<String>, checkActive: () -> Unit) {
    // Reject unbound/ambiguous XML prefixes instead of emitting an unparseable XHTML document.
    document.getAllElements().filterNot { it is Document }.forEach { element ->
        checkActive()
        val declarations = implicit.toMutableSet()
        (listOf(element) + element.parents()).forEach { ancestor ->
            ancestor.attributes().filter { it.key.startsWith("xmlns:") }.forEach { declarations += it.key.substringAfter(':') }
        }
        val names = listOf(element.tagName()) + element.attributes().map { it.key }.filterNot { it.startsWith("xmlns:") }
        require(names.all { ':' !in it || it.count { char -> char == ':' } == 1 && it.substringBefore(':') in declarations }) {
            "EPUB 模板包含未声明的 XML 命名空间"
        }
    }
}

private fun Element.inEpubSvg(): Boolean = tagName().substringAfter(':').equals("svg", true) ||
    parents().any { it.tagName().substringAfter(':').equals("svg", true) }

private fun Element.wholeEpubStyle(): String = childNodes().joinToString("") {
    when (it) {
        is DataNode -> it.getWholeData()
        is TextNode -> it.getWholeText()
        else -> ""
    }
}

/** Keep legal CSS byte-for-byte. Reject executable legacy CSS without rewriting selectors or font faces. */
internal fun epubTemplateCss(input: String, checkActive: () -> Unit): String {
    require(input.length <= EPUB_TEMPLATE_MAX_BYTES && input.encodeToByteArray().size <= EPUB_TEMPLATE_MAX_BYTES) {
        "EPUB 模板 CSS 超过 16 MiB"
    }
    require(epubCssSafe(input, checkActive)) { "EPUB 模板 CSS 包含主动内容或危险资源地址" }
    return input
}

internal fun epubXhtmlManifestProperties(
    content: String,
    path: String? = null,
    resourceProperties: Map<String, Set<String>> = emptyMap(),
): Set<String> {
    if (content.isBlank()) return emptySet()
    val inspection = epubInspectMarkup(content)
    return inspection.properties.toMutableSet().apply {
        if (path != null && inspection.references.any { reference ->
                epubLocalResourcePath(path, reference)?.let { "remote-resources" in resourceProperties[it].orEmpty() } == true
            }) add("remote-resources")
    }
}

private data class EpubMarkupInspection(val properties: MutableSet<String>, val references: MutableList<String>)

private fun epubInspectMarkup(content: String, checkActive: () -> Unit = {}): EpubMarkupInspection {
    val document = Ksoup.parse(content)
    val properties = mutableSetOf<String>()
    val references = mutableListOf<String>()
    document.getAllElements().forEach { element ->
        checkActive()
        val name = element.tagName().substringAfter(':').lowercase()
        if (name == "svg") properties += "svg"
        if (name == "math") properties += "mathml"
        val embeddedAttributes = when (name) {
            "img", "audio", "video", "source", "track", "embed", "text", "textref", "ref" -> listOf("src", "poster", "srcset")
            "image", "use", "textpath" -> listOf("href", "xlink:href")
            "object" -> listOf("data")
            "link" -> if (element.attr("rel").split(Regex("\\s+")).any { it.equals("stylesheet", true) }) listOf("href") else emptyList()
            else -> emptyList()
        }
        embeddedAttributes.forEach { attribute ->
            val value = element.attr(attribute)
            if (attribute == "srcset") references += value.split(',').map { it.trim().substringBefore(' ') }
            else if (value.isNotBlank()) references += value
        }
        val css = if (name == "style") element.wholeEpubStyle() else element.attr("style")
        if (css.isNotBlank()) references += epubCssReferences(epubCssTokens(css, checkActive)).map { it.value }
    }
    if (references.any(::epubReferenceRemote)) properties += "remote-resources"
    return EpubMarkupInspection(properties, references)
}

internal fun epubStaticResourceProperties(
    resources: List<EpubResourceEntry>,
    content: Map<String, String>,
    checkActive: () -> Unit,
): Map<String, Set<String>> {
    val properties = mutableMapOf<String, MutableSet<String>>()
    val dependents = mutableMapOf<String, MutableSet<String>>()
    resources.forEach { resource ->
        checkActive()
        val text = content[resource.path] ?: return@forEach
        val inspection = if (resource.mediaType == "text/css") {
            val references = epubCssReferences(epubCssTokens(text, checkActive)).map { it.value }.toMutableList()
            EpubMarkupInspection(mutableSetOf(), references).also {
                if (references.any(::epubReferenceRemote)) it.properties += "remote-resources"
            }
        } else epubInspectMarkup(text, checkActive).also {
            // SVG/MathML media types already identify independent documents, not inline XHTML markup.
            if (resource.mediaType != "application/xhtml+xml" && resource.mediaType != "text/html") {
                it.properties.remove("svg")
                it.properties.remove("mathml")
            }
        }
        properties[resource.path] = inspection.properties
        inspection.references.forEach { reference ->
            epubLocalResourcePath(resource.path, reference)?.let { target ->
                dependents.getOrPut(target) { mutableSetOf() } += resource.path
            }
        }
    }
    // A stylesheet/image that depends on a remote resource makes its referencing document remote too.
    val pending = ArrayDeque(properties.filterValues { "remote-resources" in it }.keys)
    while (pending.isNotEmpty()) {
        checkActive()
        dependents[pending.removeFirst()].orEmpty().forEach { path ->
            if (properties.getValue(path).add("remote-resources")) pending.addLast(path)
        }
    }
    return properties.mapValues { it.value.toSet() }.filterValues { it.isNotEmpty() }
}

private fun epubLocalResourcePath(from: String, reference: String): String? {
    val href = reference.trim().substringBefore('#').substringBefore('?')
    if (href.isEmpty() || href.startsWith("//") || URI_SCHEME.containsMatchIn(href)) return null
    val decoded = runCatching { href.decodeURLPart() }.getOrNull() ?: return null
    val parts = if (decoded.startsWith('/')) mutableListOf() else from.split('/').dropLast(1).toMutableList()
    decoded.split('/').forEach { part ->
        when (part) {
            "", "." -> Unit
            ".." -> if (parts.isEmpty()) return null else parts.removeAt(parts.lastIndex)
            else -> parts += part
        }
    }
    return parts.joinToString("/")
}

private data class EpubCssToken(val kind: Char, val value: String)

/** Small CSS lexer, not an HTML parser: comments, strings and CSS escapes cannot hide executable URLs. */
private fun epubCssTokens(input: String, checkActive: () -> Unit): List<EpubCssToken> {
    val tokens = mutableListOf<EpubCssToken>()
    var cursor = 0
    fun escape(): String {
        cursor++
        if (cursor >= input.length) return ""
        val start = cursor
        while (cursor < input.length && cursor - start < 6 && input[cursor].digitToIntOrNull(16) != null) cursor++
        if (cursor > start) {
            val code = input.substring(start, cursor).toInt(16)
            if (cursor < input.length && input[cursor].isWhitespace()) {
                if (input[cursor++] == '\r' && input.getOrNull(cursor) == '\n') cursor++
            }
            return when {
                code == 0 || code > 0x10ffff || code in 0xd800..0xdfff -> "\uFFFD"
                code <= 0xffff -> code.toChar().toString()
                else -> "${((code - 0x10000) / 1024 + 0xd800).toChar()}${((code - 0x10000) % 1024 + 0xdc00).toChar()}"
            }
        }
        return when (val char = input[cursor++]) {
            '\r' -> { if (input.getOrNull(cursor) == '\n') cursor++; "" }
            '\n', '\u000C' -> ""
            else -> char.toString()
        }
    }
    while (cursor < input.length) {
        checkActive()
        require(tokens.size < 500_000) { "EPUB 模板 CSS 标记超过 500000 项" }
        val char = input[cursor]
        when {
            char.isWhitespace() -> cursor++
            input.startsWith("/*", cursor) -> {
                val end = input.indexOf("*/", cursor + 2)
                cursor = if (end < 0) input.length else end + 2
            }
            char == '\'' || char == '"' -> {
                cursor++
                val text = buildString {
                    while (cursor < input.length && input[cursor] != char) {
                        if (input[cursor] == '\\') append(escape()) else append(input[cursor++])
                    }
                }
                if (cursor < input.length) cursor++
                tokens += EpubCssToken('s', text)
            }
            char.isLetterOrDigit() || char in "_-\\" || char.code >= 128 -> {
                val text = buildString {
                    while (cursor < input.length) {
                        val current = input[cursor]
                        if (current == '\\') append(escape())
                        else if (current.isLetterOrDigit() || current in "_-" || current.code >= 128) append(input[cursor++])
                        else break
                    }
                }
                tokens += EpubCssToken('i', text)
            }
            else -> { tokens += EpubCssToken('p', char.toString()); cursor++ }
        }
    }
    return tokens
}

private data class EpubCssReference(val value: String, val fontSource: Boolean = false)

private fun epubCssReferences(tokens: List<EpubCssToken>): List<EpubCssReference> = buildList {
    val fontBlocks = ArrayDeque<Boolean>()
    var fontRule = false
    var fontSource = false
    var parentheses = 0
    tokens.forEachIndexed { index, token ->
        if (token.kind == 'p') when (token.value) {
            "@" -> if (tokens.getOrNull(index + 1)?.value.equals("font-face", true)) fontRule = true
            "(" -> parentheses++
            ")" -> if (parentheses > 0) parentheses--
            "{" -> if (parentheses == 0) { fontBlocks.addLast(fontRule); fontRule = false; fontSource = false }
            "}" -> if (parentheses == 0) { if (fontBlocks.isNotEmpty()) fontBlocks.removeLast(); fontSource = false }
            ";" -> if (parentheses == 0) { fontSource = false; fontRule = false }
        }
        if (parentheses == 0 && fontBlocks.lastOrNull() == true && token.kind == 'i' && token.value.equals("src", true) &&
            tokens.getOrNull(index + 1)?.value == ":") fontSource = true
        if (token.kind == 'i' && token.value.equals("url", true) && tokens.getOrNull(index + 1)?.value == "(") {
            val reference = buildString {
                var next = index + 2
                while (next < tokens.size && tokens[next].value != ")") append(tokens[next++].value)
            }
            add(EpubCssReference(reference, fontSource))
        }
        if (token.value == "@" && tokens.getOrNull(index + 1)?.value.equals("import", true) &&
            tokens.getOrNull(index + 2)?.kind == 's') add(EpubCssReference(tokens[index + 2].value))
        if (token.kind == 'i' && token.value.lowercase() in setOf("image-set", "-webkit-image-set") &&
            tokens.getOrNull(index + 1)?.value == "(") {
            var next = index + 2
            var depth = 1
            while (next < tokens.size && depth > 0) {
                val current = tokens[next++]
                if (current.value == "(") depth++ else if (current.value == ")") depth--
                if (current.kind == 's') add(EpubCssReference(current.value))
            }
        }
    }
}

private fun epubCssSafe(input: String, checkActive: () -> Unit): Boolean {
    val tokens = epubCssTokens(input, checkActive)
    var parentheses = 0
    tokens.forEachIndexed { index, token ->
        if (token.kind == 'p') when (token.value) {
            "(" -> parentheses++
            ")" -> if (parentheses > 0) parentheses--
        }
        if (token.kind == 'i' && (token.value.equals("expression", true) && tokens.getOrNull(index + 1)?.value == "(" ||
                parentheses == 0 && token.value.lowercase() in setOf("behavior", "-ms-behavior", "-moz-binding") &&
                tokens.getOrNull(index + 1)?.value == ":")) return false
    }
    return epubCssReferences(tokens).all { reference ->
        epubTemplateReferenceSafe(reference.value) || reference.fontSource && epubFontFallbackSafe(reference.value)
    }
}

private fun epubFontFallbackSafe(value: String): Boolean {
    val compact = value.filterNot { it.isWhitespace() || it.isISOControl() }
    return '\\' !in compact && URI_SCHEME.find(compact)?.groupValues?.get(1)?.lowercase() in setOf("file", "res")
}

private fun epubReferenceRemote(value: String): Boolean =
    REMOTE_EPUB_REFERENCE.containsMatchIn(value.filterNot { it.isISOControl() })

private fun epubTemplateReferenceSafe(value: String): Boolean {
    val compact = value.filterNot { it.isWhitespace() || it.isISOControl() }
    if ('\\' in compact) return false
    val scheme = URI_SCHEME.find(compact)?.groupValues?.get(1)?.lowercase() ?: return true
    if (scheme in setOf("http", "https", "mailto", "tel")) return true
    return scheme == "data" && compact.substringBefore(',').lowercase() in EPUB_STATIC_DATA_TYPES
}

private fun epubSrcsetSafe(value: String): Boolean = value.split(Regex("\\s+")).all { part ->
    // Commas separate candidates, except inside a raster data URL's base64 payload.
    if (part.startsWith("data:", true)) epubTemplateReferenceSafe(part)
    else part.split(',').all(::epubTemplateReferenceSafe)
}

private fun String.epubXmlCharacters(): String = buildString(length) {
    var index = 0
    while (index < this@epubXmlCharacters.length) {
        val char = this@epubXmlCharacters[index++]
        when {
            char in '\uD800'..'\uDBFF' -> {
                val next = this@epubXmlCharacters.getOrNull(index)
                if (next != null && next in '\uDC00'..'\uDFFF') { append(char).append(next); index++ }
                else append('\uFFFD')
            }
            char in '\uDC00'..'\uDFFF' || char == '\uFFFE' || char == '\uFFFF' || char < ' ' && char !in "\t\r\n" -> append('\uFFFD')
            else -> append(char)
        }
    }
}

private fun xmlOutput(document: Document) {
    document.outputSettings().syntax(Document.OutputSettings.Syntax.xml).prettyPrint(false).escapeMode(Entities.EscapeMode.xhtml)
}

private fun boundedEpubOutput(output: String, checkActive: () -> Unit): String {
    checkActive()
    require(output.length <= EPUB_TEMPLATE_MAX_BYTES * 2 && output.encodeToByteArray().size <= EPUB_TEMPLATE_MAX_BYTES * 2) {
        "EPUB 模板渲染结果超过 32 MiB"
    }
    return output
}

private const val EPUB_TEMPLATE_MAX_BYTES = 16 * 1024 * 1024
private val EPUB_XML_NAME = Regex("[A-Za-z_][A-Za-z0-9_.:-]*")
private val URI_SCHEME = Regex("^([A-Za-z][A-Za-z0-9+.-]*):")
private val REMOTE_EPUB_REFERENCE = Regex("(?:^|[,\\s])(?:https?:)?//", RegexOption.IGNORE_CASE)
private val EPUB_URI_ATTRIBUTES = setOf("href", "src", "data", "poster", "background", "cite", "longdesc", "profile", "manifest")
private val EPUB_ACTIVE_ELEMENTS = setOf(
    "script", "iframe", "frame", "frameset", "object", "embed", "applet", "base", "form", "input", "button",
    "textarea", "select", "option", "template", "noscript",
    "portal", "fencedframe", "bgsound", "keygen",
    "handler", "listener",
)
private val EPUB_SVG_ACTIVE_ELEMENTS = setOf("animate", "animatemotion", "animatetransform", "set", "discard")
private val EPUB_NON_CONTENT_CONTEXTS = EPUB_ACTIVE_ELEMENTS + setOf(
    "head", "title", "style", "textarea", "xmp", "plaintext", "noembed", "noframes", "svg", "math",
    "audio", "video", "picture", "select", "option",
)
private val EPUB_STATIC_DATA_TYPES = setOf(
    "data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64", "data:image/avif;base64",
    "data:font/ttf;base64", "data:font/otf;base64", "data:font/woff;base64", "data:font/woff2;base64",
    "data:application/font-woff;base64", "data:application/vnd.ms-opentype;base64",
)
