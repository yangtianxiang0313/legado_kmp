@file:OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)

package io.legado.kmp.shared.image

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.DocumentType
import com.fleeksoft.ksoup.parser.Parser
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlin.io.encoding.Base64
import kotlin.math.min
import kotlin.math.sqrt

internal data class LocalBookSvgDocument(val html: String, val width: Int, val height: Int)

internal suspend fun prepareLocalBookSvg(bytes: ByteArray): LocalBookSvgDocument {
    require(bytes.isNotEmpty() && bytes.size <= MAX_SVG_BYTES) { "Local book SVG exceeds the 32 MiB input limit" }
    val context = currentCoroutineContext()
    context.ensureActive()
    val xml = bytes.decodeToString(throwOnInvalidSequence = true).removePrefix("\uFEFF")
    require('\u0000' !in xml) { "Local book SVG contains NUL" }
    // Ksoup does not resolve external entities. Reject DTDs rather than passing them to WebKit.
    require(!FORBIDDEN_DECLARATION.containsMatchIn(xml)) { "Local book SVG must not contain DTDs or entities" }
    val parser = Parser.xmlParser().setTrackErrors(1)
    val document = Ksoup.parse(html = xml, parser = parser)
    require(parser.getErrors().isEmpty() && document.childrenSize() == 1 &&
        document.childNodes().none { it is DocumentType } &&
        document.textNodes().all { it.getWholeText().isBlank() }
    ) { "Local book SVG is not a single well-formed XML document" }
    val root = requireNotNull(document.children().firstOrNull()) { "Local book SVG has no root element" }
    require(root.tagName().substringAfter(':') == "svg") { "Local book image is not SVG" }
    val namespace = if (':' in root.tagName()) "xmlns:${root.tagName().substringBefore(':')}" else "xmlns"
    require(root.attr(namespace).ifEmpty { SVG_NAMESPACE } == SVG_NAMESPACE) { "Invalid local book SVG namespace" }
    root.attr(namespace, SVG_NAMESPACE)

    val viewBox = root.attr("viewBox").takeIf { it.isNotBlank() }?.let(::parseViewBox)
    val explicitWidth = svgLength(root.attr("width"))
    val explicitHeight = svgLength(root.attr("height"))
    // Unresolved relative/percentage lengths use the viewBox, then the SVG default object size.
    val ratio = viewBox?.let { it[2] / it[3] }
    val naturalWidth = explicitWidth ?: if (explicitHeight != null && ratio != null) explicitHeight * ratio
        else viewBox?.get(2) ?: 300.0
    val naturalHeight = explicitHeight ?: if (explicitWidth != null && ratio != null) explicitWidth / ratio
        else viewBox?.get(3) ?: 150.0
    require(naturalWidth.isFinite() && naturalHeight.isFinite() && naturalWidth > 0.0 && naturalHeight > 0.0) {
        "Local book SVG has invalid intrinsic dimensions"
    }
    val aspect = naturalWidth / naturalHeight
    require(aspect.isFinite() && aspect > 0.0) { "Local book SVG has an invalid aspect ratio" }
    var width = TARGET_WIDTH.toDouble()
    var height = width / aspect
    val edgeScale = min(1.0, MAX_EDGE / maxOf(width, height))
    width *= edgeScale
    height *= edgeScale
    val areaScale = min(1.0, sqrt(MAX_PIXELS / (width * height)))
    width *= areaScale
    height *= areaScale
    // Do not stretch a subpixel short edge into a different aspect ratio to fit the budget.
    require(width.isFinite() && height.isFinite() && width >= 1.0 && height >= 1.0) {
        "Local book SVG aspect ratio cannot fit within the raster limits"
    }
    val pixelWidth = width.toInt().coerceAtMost(MAX_EDGE)
    val pixelHeight = height.toInt().coerceAtMost(MAX_EDGE)

    // A synthetic viewBox scales absolute-coordinate SVGs instead of clipping them at 1600px.
    if (viewBox == null) root.attr("viewBox", "0 0 $naturalWidth $naturalHeight")
    root.attr("width", width.toString())
    root.attr("height", height.toString())
    root.attr("style", root.attr("style") +
        ";width:${width}px!important;height:${height}px!important;" +
        "min-width:0!important;min-height:0!important;max-width:none!important;max-height:none!important;")
    context.ensureActive()
    val encodedSvg = Base64.encode(root.outerHtml().encodeToByteArray())
    context.ensureActive()
    val html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none';
        connect-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src 'none';
        media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none';
        worker-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>
        :root{color-scheme:only light}html,body{margin:0;padding:0;width:100%;height:100%;
        background:transparent!important;overflow:hidden}img{display:block;width:100%;height:100%;
        object-fit:contain;object-position:center;pointer-events:none}
        </style></head><body><img alt="" decoding="sync" draggable="false"
        src="data:image/svg+xml;base64,$encodedSvg"></body></html>
    """.trimIndent()
    return LocalBookSvgDocument(html, pixelWidth, pixelHeight)
}

private fun parseViewBox(value: String): List<Double> {
    val tokens = value.trim().split(Regex("[\\s,]+"))
    require(tokens.size == 4) { "Local book SVG has an invalid viewBox" }
    val values = tokens.map { token ->
        requireNotNull(token.toDoubleOrNull()?.takeIf { it.isFinite() }) { "Local book SVG has an invalid viewBox" }
    }
    require(values[2] > 0.0 && values[3] > 0.0) { "Local book SVG has a non-positive viewBox" }
    return values
}

private fun svgLength(value: String): Double? {
    if (value.isBlank()) return null
    val match = SVG_LENGTH.matchEntire(value.trim()) ?: return null
    val number = requireNotNull(match.groupValues[1].toDoubleOrNull()) { "Invalid SVG length" }
    require(number.isFinite() && number > 0.0) { "Local book SVG has a non-positive or infinite length" }
    val factor = when (match.groupValues[2].lowercase()) {
        "", "px" -> 1.0
        "pt" -> 96.0 / 72.0
        "pc" -> 16.0
        "mm" -> 96.0 / 25.4
        "cm" -> 96.0 / 2.54
        "in" -> 96.0
        else -> return null
    }
    return (number * factor).also { require(it.isFinite()) { "Local book SVG length overflows" } }
}

private const val MAX_SVG_BYTES = 32 * 1024 * 1024
private const val TARGET_WIDTH = 1600
private const val MAX_EDGE = 4096
private const val MAX_PIXELS = 10_000_000.0
private const val SVG_NAMESPACE = "http://www.w3.org/2000/svg"
private val FORBIDDEN_DECLARATION = Regex("<!\\s*(?:DOCTYPE|ENTITY)\\b", RegexOption.IGNORE_CASE)
private val SVG_LENGTH = Regex(
    "([+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\\s*(px|pt|pc|mm|cm|in|%)?",
    RegexOption.IGNORE_CASE,
)
