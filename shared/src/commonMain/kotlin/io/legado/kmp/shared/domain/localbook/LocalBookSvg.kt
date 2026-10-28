package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Comment
import com.fleeksoft.ksoup.nodes.DataNode
import com.fleeksoft.ksoup.nodes.Document
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.nodes.Entities
import com.fleeksoft.ksoup.nodes.Node
import com.fleeksoft.ksoup.nodes.TextNode
import com.fleeksoft.ksoup.nodes.XmlDeclaration
import com.fleeksoft.ksoup.parser.Parser
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

/** Static, self-contained SVG bytes. Rasterization belongs to the platform image consumer. */
internal object LocalBookSvg {
    const val MAX_DOCUMENT_BYTES = 8 * 1024 * 1024
    private const val MAX_NODES = 100_000
    private const val MAX_DEPTH = 128
    private const val SVG_NS = "http://www.w3.org/2000/svg"
    private const val XLINK_NS = "http://www.w3.org/1999/xlink"
    private const val XML_NS = "http://www.w3.org/XML/1998/namespace"
    private val unsafeDeclaration = Regex("<!\\s*(?:DOCTYPE|ENTITY)\\b", RegexOption.IGNORE_CASE)
    private val scheme = Regex("^[A-Za-z][A-Za-z0-9+.-]*:")
    private val localSchemes = listOf("epub-resource:///", "mobi-resource:///", "kindle:embed:", "kindle:flow:", "recindex:")
    private val selector = Regex("[A-Za-z0-9_.*#,:>+~\\[\\]=\"'\\s-]+")
    private val tagCase = listOf(
        "svg", "g", "defs", "symbol", "use", "path", "rect", "circle", "ellipse", "line", "polyline",
        "polygon", "text", "tspan", "textPath", "image", "title", "desc", "style", "linearGradient",
        "radialGradient", "stop", "clipPath", "mask", "pattern", "marker", "filter", "feBlend",
        "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting",
        "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB", "feFuncG",
        "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset",
        "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "view", "switch", "a",
    ).associateBy { it.lowercase() }
    private val attributeCase = listOf(
        "viewBox", "preserveAspectRatio", "gradientUnits", "gradientTransform", "spreadMethod", "clipPathUnits",
        "patternUnits", "patternContentUnits", "patternTransform", "maskUnits", "maskContentUnits",
        "markerUnits", "markerWidth", "markerHeight", "refX", "refY", "textLength", "lengthAdjust",
        "pathLength", "startOffset", "filterUnits", "primitiveUnits", "filterRes", "stdDeviation",
        "baseFrequency", "numOctaves", "stitchTiles", "kernelMatrix", "kernelUnitLength", "preserveAlpha",
        "targetX", "targetY", "edgeMode", "surfaceScale", "diffuseConstant", "specularConstant",
        "specularExponent", "limitingConeAngle", "pointsAtX", "pointsAtY", "pointsAtZ", "xChannelSelector",
        "yChannelSelector", "tableValues", "requiredExtensions", "requiredFeatures", "systemLanguage",
        "externalResourcesRequired", "baseProfile", "zoomAndPan", "viewTarget",
    ).associateBy { it.lowercase() }
    private val removedTags = setOf(
        "script", "foreignobject", "animate", "animatemotion", "animatetransform", "animatecolor", "set",
        "discard", "handler", "listener", "metadata",
    )
    private val staticProperties = ("alignment-baseline baseline-shift clip clip-path clip-rule color " +
        "color-interpolation color-interpolation-filters color-rendering direction display dominant-baseline " +
        "fill fill-opacity fill-rule filter flood-color flood-opacity font font-family font-size font-size-adjust " +
        "font-stretch font-style font-variant font-weight glyph-orientation-horizontal glyph-orientation-vertical " +
        "image-rendering isolation kerning letter-spacing lighting-color line-height marker marker-end marker-mid " +
        "marker-start mask mix-blend-mode opacity overflow paint-order pointer-events shape-rendering stop-color " +
        "stop-opacity stroke stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit " +
        "stroke-opacity stroke-width text-anchor text-decoration text-rendering transform transform-box " +
        "transform-origin unicode-bidi vector-effect visibility white-space word-spacing writing-mode " +
        "x y cx cy r rx ry width height inline-size block-size").trim().split(' ').toSet()
    private val safeFunctions = setOf(
        "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color", "color-mix",
        "matrix", "matrix3d", "translate", "translatex", "translatey", "translatez", "translate3d", "scale",
        "scalex", "scaley", "scalez", "scale3d", "rotate", "rotatex", "rotatey", "rotatez", "rotate3d",
        "skew", "skewx", "skewy", "calc", "min", "max", "clamp",
    )

    /** Sniffs the root only; prepare performs the structural and security validation. */
    fun isSvg(bytes: ByteArray): Boolean {
        if (bytes.isEmpty()) return false
        val head = bytes.take(4).map { it.toInt() and 0xff }
        val xmlEncoding = head.take(2) in listOf(listOf(0xff, 0xfe), listOf(0xfe, 0xff), listOf(0, 60), listOf(60, 0))
        if (!xmlEncoding) {
            var first = if (head.take(3) == listOf(0xef, 0xbb, 0xbf)) 3 else 0
            while (first < bytes.size && bytes[first].toInt().toChar() in " \t\r\n") first++
            if (first == bytes.size || bytes[first] != '<'.code.toByte()) return false
        }
        val xml = decodeEpubText(bytes.copyOfRange(0, minOf(bytes.size, MAX_DOCUMENT_BYTES)))
        var cursor = 0
        while (cursor < xml.length) {
            while (cursor < xml.length && xml[cursor].isWhitespace()) cursor++
            val end = when {
                xml.startsWith("<!--", cursor) -> xml.indexOf("-->", cursor + 4).takeIf { it >= 0 }?.plus(3)
                xml.startsWith("<?", cursor) -> xml.indexOf("?>", cursor + 2).takeIf { it >= 0 }?.plus(2)
                xml.regionMatches(cursor, "<!DOCTYPE", 0, 9, true) -> xml.indexOf('>', cursor + 9).takeIf { it >= 0 }?.plus(1)
                else -> {
                    if (cursor >= xml.length || xml[cursor] != '<') return false
                    val name = xml.substring(cursor + 1).takeWhile { !it.isWhitespace() && it !in "/>" }
                    return name.substringAfter(':').equals("svg", true)
                }
            } ?: return false
            cursor = end
        }
        return false
    }

    /** Also used before MOBI resource readers are available; this does not resolve or sanitize resources. */
    fun serialize(root: Element): String = serialize(root, {})

    fun prepare(
        xml: String,
        resolveImage: (String) -> ByteArray?,
        checkActive: () -> Unit = {},
    ): ByteArray = prepare(xml, resolveImage, checkActive, Budget(), 0)

    @OptIn(ExperimentalEncodingApi::class)
    fun toDataUrl(bytes: ByteArray): String {
        require(bytes.isNotEmpty() && bytes.size <= MAX_DOCUMENT_BYTES) { "SVG 数据为空或超过 8 MiB" }
        return "data:image/svg+xml;base64," + Base64.encode(bytes)
    }

    /** Decodes image data without preparing SVG; its caller still supplies the resource resolver. */
    @OptIn(ExperimentalEncodingApi::class)
    fun readDataUrl(value: String, checkActive: () -> Unit = {}): ByteArray? {
        if (!value.startsWith("data:", true)) return null
        val input = value.substringBefore('#')
        val comma = input.indexOf(',')
        require(comma in 5..256) { "SVG 图片 data 地址头无效" }
        val parts = input.substring(5, comma).lowercase().split(';')
        val svg = parts.first() == "image/svg+xml"
        require(svg || parts.first() in bitmapTypes) { "SVG 引用了不支持的图片 MIME" }
        val options = parts.drop(1)
        val base64 = options.lastOrNull() == "base64"
        require(options.count { it == "base64" } <= 1 && ("base64" !in options || base64) &&
            options.filterNot { it == "base64" }.let { it.isEmpty() || svg && it == listOf("charset=utf-8") }) {
            "SVG 图片 data 地址参数不支持"
        }
        val length = input.length - comma - 1
        checkActive()
        val bytes = if (base64) {
            require(length <= (MAX_DOCUMENT_BYTES.toLong() + 2) / 3 * 4) { "SVG 内嵌图片超过 8 MiB" }
            Base64.decode(buildString(length) {
                for (index in comma + 1 until input.length) {
                    if (index and 0x3fff == 0) checkActive()
                    if (input[index] !in " \t\r\n") append(input[index])
                }
            })
        } else {
            require(svg && length <= MAX_DOCUMENT_BYTES * 3) { "SVG 位图 data 地址必须使用 base64，或数据过大" }
            val output = ByteArray(minOf(length.toLong() * 3, MAX_DOCUMENT_BYTES.toLong()).toInt())
            var written = 0
            var cursor = comma + 1
            while (cursor < input.length) {
                checkActive()
                if (input[cursor] == '%') {
                    require(cursor + 2 < input.length && written < output.size) { "SVG data 编码无效或过大" }
                    val high = input[cursor + 1].digitToIntOrNull(16)
                    val low = input[cursor + 2].digitToIntOrNull(16)
                    require(high != null && low != null) { "SVG data 百分号编码无效" }
                    output[written++] = ((high shl 4) or low).toByte()
                    cursor += 3
                } else {
                    val end = input.indexOf('%', cursor).takeIf { it >= 0 } ?: input.length
                    val part = input.substring(cursor, end).encodeToByteArray()
                    require(part.size <= output.size - written) { "SVG data 超过 8 MiB" }
                    part.copyInto(output, written)
                    written += part.size
                    cursor = end
                }
            }
            output.copyOf(written)
        }
        checkActive()
        require(bytes.isNotEmpty() && bytes.size <= MAX_DOCUMENT_BYTES) { "SVG 内嵌图片为空或超过 8 MiB" }
        if (svg) require(isSvg(bytes)) { "SVG data 内容与 MIME 不符" }
        return bytes
    }

    private fun serialize(root: Element, checkActive: () -> Unit): String {
        require(root.epubName() == "svg") { "SVG 根节点无效" }
        boundedNodes(root, checkActive)
        val copy = root.clone()
        // HTML parsing lowercases foreign attributes. XML serialization must restore their SVG spelling.
        var ancestor = root.parent()
        while (ancestor != null) {
            ancestor.attributes().filter { it.key.startsWith("xmlns:") }.forEach {
                if (!copy.hasAttr(it.key)) copy.attr(it.key, it.value)
            }
            ancestor = ancestor.parent()
        }
        if (!copy.hasAttr("xmlns") && ':' !in copy.tagName()) copy.attr("xmlns", SVG_NS)
        if (!copy.hasAttr("xmlns:xlink")) copy.attr("xmlns:xlink", XLINK_NS)
        val document = Ksoup.parse(html = "", parser = Parser.xmlParser())
        document.outputSettings().syntax(Document.OutputSettings.Syntax.xml).prettyPrint(false)
            .escapeMode(Entities.EscapeMode.xhtml)
        document.appendChild(copy)
        boundedNodes(copy, checkActive).forEach { node ->
            when (node) {
                is Element -> {
                    val prefix = node.tagName().substringBefore(':', "")
                    val name = tagCase[node.epubName()] ?: node.tagName().substringAfter(':')
                    node.tagName(if (prefix.isEmpty()) name else "$prefix:$name")
                    node.attributes().toList().forEach { attribute ->
                        val key = attributeCase[attribute.key.lowercase()] ?: attribute.key
                        if (key != attribute.key) {
                            node.removeAttr(attribute.key)
                            node.attr(key, attribute.value)
                        }
                    }
                }
                is DataNode -> node.replaceWith(TextNode(node.getWholeData()))
            }
        }
        return copy.outerHtml().also {
            checkActive()
            require(it.encodeToByteArray().size <= MAX_DOCUMENT_BYTES) { "SVG 文档超过 8 MiB" }
        }
    }

    private fun prepare(
        xml: String,
        resolveImage: (String) -> ByteArray?,
        checkActive: () -> Unit,
        budget: Budget,
        depth: Int,
    ): ByteArray {
        checkActive()
        require(depth < 8) { "SVG 图片嵌套超过 8 层" }
        require(xml.length <= MAX_DOCUMENT_BYTES && xml.encodeToByteArray().size <= MAX_DOCUMENT_BYTES) {
            "SVG 文档超过 8 MiB"
        }
        require(!unsafeDeclaration.containsMatchIn(xml)) { "SVG 不支持 DTD 或自定义实体" }
        require(!xml.contains(Regex("<\\?xml-stylesheet\\b", RegexOption.IGNORE_CASE))) {
            "SVG 不支持外部 XML 样式表"
        }
        val document = parseEpubXml(xml.removePrefix("\uFEFF"))
        val root = document.child(0)
        require(root.epubName() == "svg") { "图片不是 SVG 根文档" }
        val nodes = boundedNodes(root, checkActive)
        budget.nodes += nodes.size
        require(budget.nodes <= MAX_NODES) { "SVG 展开节点超过 100000 项" }
        val references = mutableSetOf<String>()
        val kept = mutableListOf<Element>()
        val pending = ArrayDeque<Element>()
        pending.addLast(root)
        var expandedSize = xml.encodeToByteArray().size.toLong()
        while (pending.isNotEmpty()) {
            checkActive()
            val element = pending.removeLast()
            val name = element.epubName()
            if (name in removedTags) {
                element.remove()
                continue
            }
            require(name in tagCase) { "SVG 包含不支持的节点：$name" }
            val elementNamespace = namespace(element, element.tagName().substringBefore(':', ""))
            require(elementNamespace == null || elementNamespace == SVG_NS) { "SVG 包含非 SVG 命名空间节点" }
            val hrefs = mutableListOf<String>()
            element.attributes().toList().forEach { attribute ->
                checkActive()
                val key = attribute.key.lowercase()
                val local = key.substringAfter(':')
                when {
                    key == "xmlns" || key.startsWith("xmlns:") -> Unit
                    local.startsWith("on") || local in setOf("contentscripttype", "contentstyletype") -> element.removeAttr(attribute.key)
                    key == "xml:base" -> error("SVG 不支持 xml:base 外部资源上下文")
                    local in setOf("src", "srcset", "data", "poster") -> error("SVG 含不支持的外部资源属性：$key")
                    local == "href" -> {
                        require(':' !in key || namespace(element, attribute.key.substringBefore(':')) == XLINK_NS) {
                            "SVG href 命名空间无效"
                        }
                        hrefs += attribute.value.trim()
                        element.removeAttr(attribute.key)
                    }
                    ':' in key -> {
                        val uri = namespace(element, attribute.key.substringBefore(':'))
                        element.removeAttr(attribute.key)
                        if (uri == XML_NS && local in setOf("space", "lang")) element.attr("xml:$local", attribute.value)
                    }
                    key == "style" -> element.attr(attribute.key, sanitizeCss(attribute.value, false, references, checkActive))
                    key in staticProperties -> validateValue(cleanCss(attribute.value), references)
                    key.startsWith("animation") || key.startsWith("transition") -> element.removeAttr(attribute.key)
                    attribute.value.contains(Regex("url\\s*\\(", RegexOption.IGNORE_CASE)) ->
                        validateValue(cleanCss(attribute.value), references)
                }
            }
            require(hrefs.distinct().size <= 1) { "SVG 同一节点包含冲突的 href" }
            val href = hrefs.firstOrNull()
            if (name in setOf("image", "feimage")) {
                require(!href.isNullOrBlank()) { "SVG 图片缺少本地资源引用" }
                require(++budget.images <= 4096) { "SVG 图片引用超过 4096 项" }
                val fragment = href.substringAfter('#', "").takeIf { '#' in href }
                if (fragment != null) requireFragment("#$fragment")
                val reference = href.substringBefore('#')
                val data = readDataUrl(reference, checkActive) ?: run {
                    require(reference.length <= 8192 && !reference.startsWith("//") &&
                        (!scheme.containsMatchIn(reference) || localSchemes.any { reference.startsWith(it, true) }) &&
                        reference.none { it.isISOControl() || it == '\\' }) { "SVG 仅支持本地图片资源" }
                    requireNotNull(resolveImage(reference)) { "SVG 图片资源不存在：$reference" }
                }
                budget.bytes += data.size
                require(budget.bytes <= 32L * 1024 * 1024) { "SVG 图片资源展开超过 32 MiB" }
                require(data.isNotEmpty() && data.size <= MAX_DOCUMENT_BYTES) { "SVG 图片资源为空或超过 8 MiB" }
                val prepared = if (isSvg(data)) {
                    prepare(decodeEpubText(data), resolveImage, checkActive, budget, depth + 1)
                } else data
                val source = if (isSvg(prepared)) toDataUrl(prepared) else bitmapDataUrl(prepared)
                expandedSize += source.length.toLong() - href.length + (fragment?.length?.plus(1) ?: 0)
                require(expandedSize <= MAX_DOCUMENT_BYTES) { "SVG 自包含文档超过 8 MiB" }
                // Use SVG 1.1 xlink as well as SVG 2 href for platform renderer compatibility.
                element.attr("xlink:href", source + (fragment?.let { "#$it" } ?: ""))
            } else if (href != null && name != "a") {
                requireFragment(href)
                references += href.drop(1)
                element.attr("xlink:href", href)
            }
            if (name == "style") {
                require(element.attr("type").let { it.isBlank() || it.equals("text/css", true) }) { "SVG 样式类型不支持" }
                val css = element.childNodes().joinToString("") { node ->
                    when (node) {
                        is TextNode -> node.getWholeText()
                        is DataNode -> node.getWholeData()
                        is Comment -> ""
                        else -> error("SVG 样式表包含非文本节点")
                    }
                }
                element.empty().appendChild(TextNode(sanitizeCss(css, true, references, checkActive)))
            }
            element.childNodes().filter { it is XmlDeclaration || it is Comment }.forEach { it.remove() }
            kept.add(element)
            element.children().reversed().forEach(pending::addLast)
        }
        checkActive()
        val byId = mutableMapOf<String, Element>()
        kept.forEach { element ->
            element.attr("id").takeIf { it.isNotEmpty() }?.let { id ->
                require(byId.put(id, element) == null) { "SVG 包含重复 ID：$id" }
            }
        }
        references.forEach { require(it in byId) { "SVG 内部引用不存在：#$it" } }
        validateExpansion(root, byId, checkActive)
        // Namespace aliases are no longer needed after all inherited namespaces have been inspected.
        kept.forEach { element ->
            element.tagName(requireNotNull(tagCase[element.epubName()]))
            element.attributes().filter { it.key == "xmlns" || it.key.startsWith("xmlns:") }
                .map { it.key }.forEach { element.removeAttr(it) }
        }
        root.attr("xmlns", SVG_NS).attr("xmlns:xlink", XLINK_NS)
        return serialize(root, checkActive).encodeToByteArray().also { checkActive() }
    }

    private fun boundedNodes(root: Element, checkActive: () -> Unit): List<Node> {
        val result = mutableListOf<Node>()
        val pending = ArrayDeque<Pair<Node, Int>>()
        pending.addLast(root to 0)
        var characters = 0L
        while (pending.isNotEmpty()) {
            checkActive()
            val (node, depth) = pending.removeLast()
            require(result.size < MAX_NODES && depth <= MAX_DEPTH) { "SVG 节点超过 100000 项或嵌套超过 128 层" }
            result += node
            when (node) {
                is Element -> {
                    require(node.attributesSize() <= 256) { "SVG 节点属性过多" }
                    characters += node.tagName().length + node.attributes().sumOf { it.key.length.toLong() + it.value.length }
                }
                is TextNode -> characters += node.getWholeText().length
                is DataNode -> characters += node.getWholeData().length
            }
            require(characters <= MAX_DOCUMENT_BYTES) { "SVG 文档超过 8 MiB" }
            node.childNodes().reversed().forEach { pending.addLast(it to depth + 1) }
        }
        return result
    }

    private fun namespace(element: Element, prefix: String): String? {
        if (prefix == "xml") return XML_NS
        val key = if (prefix.isEmpty()) "xmlns" else "xmlns:$prefix"
        var node: Element? = element
        while (node != null) {
            if (node.hasAttr(key)) return node.attr(key)
            node = node.parent()
        }
        return if (prefix.isEmpty()) null else error("SVG 使用了未声明的命名空间：$prefix")
    }

    private fun requireFragment(value: String) {
        require(value.startsWith('#') && value.length in 2..1024 &&
            value.drop(1).none { it.isWhitespace() || it.isISOControl() || it in "#\"'()<>\\" }) {
            "SVG 仅支持内部 #id 引用"
        }
    }

    private fun cleanCss(css: String): String = buildString(css.length) {
        var cursor = 0
        var quote: Char? = null
        while (cursor < css.length) {
            val char = css[cursor]
            require(char != '\\' && char != '@' && char != '<' && (!char.isISOControl() || char in "\t\r\n")) {
                "SVG 不支持 CSS 转义、外部导入、at-rule 或活动内容"
            }
            if (quote == null && css.startsWith("/*", cursor)) {
                val end = css.indexOf("*/", cursor + 2)
                require(end >= 0) { "SVG CSS 注释未闭合" }
                append(' ')
                cursor = end + 2
                continue
            }
            if (char == quote) quote = null else if (quote == null && char in "\"'") quote = char
            append(char)
            cursor++
        }
        require(quote == null) { "SVG CSS 字符串未闭合" }
    }

    private fun sanitizeCss(
        input: String,
        stylesheet: Boolean,
        references: MutableSet<String>,
        checkActive: () -> Unit,
    ): String {
        val css = cleanCss(input)
        fun declarations(value: String): String = value.split(';').mapNotNull { part ->
            checkActive()
            if (part.isBlank()) return@mapNotNull null
            val colon = part.indexOf(':')
            require(colon > 0) { "SVG CSS 声明无效" }
            val property = part.substring(0, colon).trim().lowercase()
            if (property.startsWith("animation") || property.startsWith("transition")) return@mapNotNull null
            require(property in staticProperties) { "SVG 不支持的 CSS 属性：$property" }
            val content = part.substring(colon + 1).trim()
            require(content.isNotEmpty() && content.none { it in "{}" }) { "SVG CSS 属性值无效" }
            validateValue(content, references)
            "$property:$content"
        }.joinToString(";")
        if (!stylesheet) return declarations(css)
        return buildString(css.length) {
            var cursor = 0
            var rules = 0
            while (cursor < css.length) {
                checkActive()
                while (cursor < css.length && css[cursor].isWhitespace()) cursor++
                if (cursor == css.length) break
                require(++rules <= 4096) { "SVG CSS 规则超过 4096 项" }
                val open = css.indexOf('{', cursor)
                val close = if (open >= 0) css.indexOf('}', open + 1) else -1
                require(open >= 0 && close > open && '{' !in css.substring(open + 1, close)) {
                    "SVG 不支持嵌套或损坏的 CSS 规则"
                }
                val target = css.substring(cursor, open).trim()
                require(target.isNotEmpty() && selector.matches(target)) { "SVG CSS 选择器过于复杂或不支持" }
                append(target).append('{').append(declarations(css.substring(open + 1, close))).append('}')
                cursor = close + 1
            }
        }
    }

    private fun validateValue(value: String, references: MutableSet<String>) {
        var cursor = 0
        var parentheses = 0
        var quote: Char? = null
        while (cursor < value.length) {
            val char = value[cursor]
            if (quote != null) {
                if (char == quote) quote = null
                cursor++
                continue
            }
            if (char in "\"'") {
                quote = char
                cursor++
                continue
            }
            if (char.isLetter() || char in "_-") {
                val start = cursor++
                while (cursor < value.length && (value[cursor].isLetterOrDigit() || value[cursor] in "_-")) cursor++
                val name = value.substring(start, cursor).lowercase()
                while (cursor < value.length && value[cursor].isWhitespace()) cursor++
                if (cursor < value.length && value[cursor] == '(') {
                    if (name == "url") {
                        val end = value.indexOf(')', cursor + 1)
                        require(end >= 0) { "SVG CSS url 未闭合" }
                        val reference = value.substring(cursor + 1, end).trim().removeSurrounding("\"").removeSurrounding("'")
                        requireFragment(reference)
                        references += reference.drop(1)
                        cursor = end + 1
                    } else {
                        require(name in safeFunctions) { "SVG 不支持的 CSS 函数：$name" }
                        require(++parentheses <= 32) { "SVG CSS 函数嵌套过深" }
                        cursor++
                    }
                }
                continue
            }
            require(char != '(') { "SVG CSS 函数无效" }
            if (char == ')') require(--parentheses >= 0) { "SVG CSS 括号无效" }
            cursor++
        }
        require(quote == null && parentheses == 0) { "SVG CSS 字符串或括号未闭合" }
    }

    private fun validateExpansion(root: Element, byId: Map<String, Element>, checkActive: () -> Unit) {
        val costs = mutableMapOf<Element, Long>()
        val visiting = mutableSetOf<Element>()
        fun cost(element: Element, depth: Int): Long {
            checkActive()
            require(depth <= MAX_DEPTH && visiting.add(element)) { "SVG 内部引用循环或嵌套过深" }
            costs[element]?.let { visiting.remove(element); return it }
            var total = 1L
            element.children().forEach { total += cost(it, depth + 1) }
            val href = element.attr("xlink:href")
            if (href.startsWith('#')) total += cost(requireNotNull(byId[href.drop(1)]), depth + 1)
            require(total <= MAX_NODES) { "SVG 内部引用展开超过 100000 项" }
            visiting.remove(element)
            costs[element] = total
            return total
        }
        cost(root, 0)
    }

    private val bitmapTypes = setOf(
        "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/bmp", "image/heic",
        "image/heif", "image/avif", "image/tiff", "image/x-icon",
    )

    @OptIn(ExperimentalEncodingApi::class)
    private fun bitmapDataUrl(bytes: ByteArray): String {
        fun magic(vararg values: Int): Boolean = bytes.size >= values.size &&
            values.indices.all { bytes[it].toInt() and 0xff == values[it] }
        fun ascii(start: Int, count: Int): String = bytes.decodeToString(start, start + count)
        require(bytes.isNotEmpty() && bytes.size <= MAX_DOCUMENT_BYTES) { "SVG 内嵌位图为空或超过 8 MiB" }
        val mime = when {
            magic(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a) -> "image/png"
            magic(0xff, 0xd8, 0xff) -> "image/jpeg"
            bytes.size >= 6 && ascii(0, 6) in setOf("GIF87a", "GIF89a") -> "image/gif"
            bytes.size >= 12 && ascii(0, 4) == "RIFF" && ascii(8, 4) == "WEBP" -> "image/webp"
            magic(0x42, 0x4d) -> "image/bmp"
            magic(0x49, 0x49, 0x2a, 0) || magic(0x4d, 0x4d, 0, 0x2a) -> "image/tiff"
            magic(0, 0, 1, 0) -> "image/x-icon"
            bytes.size >= 12 && ascii(4, 4) == "ftyp" -> when (ascii(8, 4)) {
                "avif", "avis" -> "image/avif"
                "heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1" -> "image/heic"
                else -> error("SVG 内嵌位图格式不支持")
            }
            else -> error("SVG 图片资源不是受支持的位图或 SVG")
        }
        return "data:$mime;base64," + Base64.encode(bytes)
    }

    private class Budget(var nodes: Int = 0, var images: Int = 0, var bytes: Long = 0)
}
