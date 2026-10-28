package io.legado.kmp.shared.facade

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.nodes.TextNode
import com.fleeksoft.ksoup.parser.Parser
import io.legado.kmp.shared.model.BookChapter

/** An inert, ordered snapshot; original markup and URLs never reach the exported XHTML. */
internal class BookExportDocument private constructor(private val parts: List<Part>) {
    val imageSources: List<String> = parts.mapNotNull { (it as? Part.Image)?.source }
    val imageCount: Int = parts.count { it is Part.Image }
    val hasReadableText: Boolean = parts.any { it is Part.Text && it.value.isNotBlank() }

    fun renderText(missingImageText: String = "[图片未导出]"): String = buildString {
        for (part in parts) {
            when (part) {
                is Part.Text -> append(part.value)
                is Part.Image -> append(missingImageText)
                Part.LineBreak -> append('\n')
                Part.Boundary -> if (isNotEmpty() && last() != '\n') append('\n')
            }
        }
    }

    fun render(imagePaths: Map<String, String>, missingImageText: String = "[图片未缓存]"): String = buildString {
        var paragraphOpen = false
        fun openParagraph() {
            if (!paragraphOpen) {
                append("<p style=\"white-space: pre-wrap;\">")
                paragraphOpen = true
            }
        }
        fun closeParagraph() {
            if (paragraphOpen) {
                append("</p>\n")
                paragraphOpen = false
            }
        }
        parts.forEach { part ->
            when (part) {
                is Part.Text -> {
                    openParagraph()
                    append(part.value.xmlEscaped())
                }
                is Part.Image -> {
                    openParagraph()
                    val path = part.source?.let(imagePaths::get)?.takeIf(::isExportImageReference)
                    if (path == null) append(missingImageText.xmlEscaped()) else {
                        append("<img src=\"").append(path.xmlEscaped()).append("\" alt=\"")
                            .append(part.alt.xmlEscaped()).append("\"/>")
                    }
                }
                Part.LineBreak -> {
                    openParagraph()
                    append("<br/>")
                }
                Part.Boundary -> closeParagraph()
            }
            require(length <= MAX_CONTENT_BYTES * 2) { "导出章节 XHTML 超过 32 MiB 字符" }
        }
        closeParagraph()
        if (isEmpty()) append("<p></p>\n")
    }

    private sealed interface Part {
        data class Text(val value: String) : Part
        data class Image(val source: String?, val alt: String) : Part
        data object LineBreak : Part
        data object Boundary : Part
    }

    companion object {
        private const val MAX_CONTENT_BYTES = 16 * 1024 * 1024
        private const val MAX_NODES = 100_000
        private const val MAX_DEPTH = 128
        private val removedTags = setOf(
            "script", "style", "head", "title", "link", "meta", "base", "iframe", "frame", "frameset",
            "object", "embed", "applet", "audio", "video", "source", "track", "svg", "math", "canvas",
            "form", "input", "button", "textarea", "select", "option", "template", "noscript",
        )
        private val blockTags = setOf(
            "p", "div", "section", "article", "main", "aside", "header", "footer", "blockquote", "pre",
            "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "dl", "dt", "dd", "table", "tr",
            "figure", "figcaption", "address", "hr",
        )
        private val inlineTags = setOf(
            "img", "br", "span", "a", "b", "i", "em", "strong", "u", "s", "small", "sub", "sup",
            "ruby", "rt", "rp", "code", "tt", "font", "center", "td", "th", "picture", "wbr",
        )
        private val legacyOptions = Regex("""\s*,\s*(?=\{)""")

        fun parse(chapter: BookChapter, content: String, imageBook: Boolean = false): BookExportDocument {
            require(content.length <= MAX_CONTENT_BYTES && content.encodeToByteArray().size <= MAX_CONTENT_BYTES) {
                "导出章节超过 16 MiB"
            }
            val document = Ksoup.parse(content)
            val body = document.body()
            val elements = document.getAllElements()
            require(elements.size <= MAX_NODES) { "导出章节节点超过 100000 项" }
            // Unknown angle-bracket prose and ordinary ampersands are not HTML.
            val html = elements.any { element ->
                val name = element.tagName().lowercase()
                name in blockTags || name in inlineTags || name in removedTags && name != "head"
            } || Ksoup.parse(html = content, parser = Parser.xmlParser()).getAllElements().any {
                it.tagName().lowercase() in setOf("html", "head", "body")
            }
            if (!html) {
                if (imageBook) {
                    val sources = MangaChapterParser.imageSources(chapter, content)
                    if (sources.isNotEmpty()) return BookExportDocument(sources.flatMap {
                        listOf(Part.Image(it, ""), Part.Boundary)
                    })
                }
                val parts = mutableListOf<Part>()
                content.replace("\r\n", "\n").replace('\r', '\n').split('\n').forEach { line ->
                    parts += Part.Text(line)
                    parts += Part.Boundary
                }
                return BookExportDocument(parts)
            }

            // Reuse the reader's legacy ,{options} repair rather than a second HTML regex parser.
            // Ksoup still determines node order, paragraph boundaries and which subtrees are inert.
            val images = body.select("img[src]").toList()
            val repaired = if (legacyOptions.containsMatchIn(content)) {
                MangaChapterParser.imageSources(chapter, content).takeIf { it.size == images.size }
            } else null
            val repairedSources = if (repaired == null) emptyMap() else images.zip(repaired).toMap()
            val result = mutableListOf<Part>()
            val pending = ArrayDeque<Visit>()
            body.childNodes().reversed().forEach { pending.addLast(Visit(it, 0)) }
            var count = 0
            while (pending.isNotEmpty()) {
                val visit = pending.removeLast()
                require(++count <= MAX_NODES && visit.depth <= MAX_DEPTH) { "导出章节节点过多或嵌套超过 128 层" }
                if (visit.closeBlock) {
                    result += Part.Boundary
                    continue
                }
                when (val node = visit.node) {
                    is TextNode -> result += Part.Text(node.getWholeText())
                    is Element -> {
                        val name = node.tagName().lowercase()
                        if (name in removedTags || isHidden(node)) continue
                        when (name) {
                            "img" -> {
                                val source = repairedSources[node] ?: MangaChapterParser.imageSources(chapter, node.outerHtml()).firstOrNull()
                                result += Part.Image(source, node.attr("alt"))
                            }
                            "br", "wbr" -> result += Part.LineBreak
                            else -> {
                                if (name in blockTags) {
                                    result += Part.Boundary
                                    pending.addLast(visit.copy(closeBlock = true))
                                }
                                node.childNodes().reversed().forEach { pending.addLast(Visit(it, visit.depth + 1)) }
                            }
                        }
                    }
                }
            }
            return BookExportDocument(result)
        }

        private data class Visit(val node: Node, val depth: Int, val closeBlock: Boolean = false)

        private fun isHidden(element: Element): Boolean = element.hasAttr("hidden") ||
            element.attr("style").split(';').any { declaration ->
                val property = declaration.substringBefore(':').trim().lowercase()
                val value = declaration.substringAfter(':', "").substringBefore('!').trim().lowercase()
                property == "display" && value == "none" || property == "visibility" && value == "hidden"
            }
    }
}

/** One parent step is allowed from Text/, never an absolute, encoded or external URI. */
private fun isExportImageReference(path: String): Boolean {
    val local = path.removePrefix("../")
    return path.isNotEmpty() && path.length <= 8192 && !path.startsWith('/') &&
        path.none { it.isISOControl() || it.isWhitespace() || it in "\\:%?#\"'<>" } &&
        local.split('/').all { it.isNotEmpty() && it != "." && it != ".." }
}
