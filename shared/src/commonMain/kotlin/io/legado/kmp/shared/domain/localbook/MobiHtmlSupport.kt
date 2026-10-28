package io.legado.kmp.shared.domain.localbook

import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element

internal data class MobiTextSection(
    val start: Int,
    val end: Int,
    val title: String,
    val isVolume: Boolean = false,
)

internal object MobiHtmlSupport {
    private const val MAX_TOC_ENTRIES = 50000
    private const val PREVIEW_BYTES = 32 * 1024
    private const val MAX_CHAPTER_BYTES = 512 * 1024
    private val htmlMarker = Regex(
        "<\\s*(?:html|head|body|p|div|h[1-6]|mbp:pagebreak|!doctype)(?:\\s|/?>)",
        RegexOption.IGNORE_CASE,
    )
    private val hiddenStyle = Regex(
        "(?:^|;)\\s*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden)\\s*(?:!important)?\\s*(?:;|$)",
        RegexOption.IGNORE_CASE,
    )

    fun isHtml(bytes: ByteArray): Boolean =
        htmlMarker.containsMatchIn(bytes.mobiAscii(0, minOf(bytes.size, PREVIEW_BYTES)))

    fun metadataText(text: String): String = Ksoup.parse(html = text).text().trim()

    fun isHidden(element: Element): Boolean = element.hasAttr("hidden") || hiddenStyle.containsMatchIn(element.attr("style"))

    fun format(html: String, flows: MobiFlowResources? = null, checkActive: () -> Unit = {}): String {
        checkActive()
        val document = Ksoup.parse(html = html)
        checkActive()
        document.outputSettings().prettyPrint(false)
        removeNonBodySubtrees(document, checkActive)
        MobiEmbeddedImage.formatImages(document, flows, checkActive)
        return LocalBookHtmlFormatter.formatKeepImg(document.body()?.html().orEmpty()).also { checkActive() }
    }

    private fun removeNonBodySubtrees(root: Element, checkActive: () -> Unit) {
        val pending = ArrayDeque<Element>()
        pending.addLast(root)
        while (pending.isNotEmpty()) {
            checkActive()
            val element = pending.removeLast()
            when (element.epubName()) {
                in NON_BODY_TAGS -> element.remove()
                // SVG styles, titles and definitions must reach the existing SVG image handling intact.
                "svg" -> Unit
                else -> element.children().reversed().forEach(pending::addLast)
            }
        }
    }

    fun sections(
        bytes: ByteArray,
        encoding: MobiTextEncoding,
        isHtml: Boolean,
        navigation: List<MobiTocEntry>,
        checkActive: () -> Unit,
    ): List<MobiTextSection> {
        checkActive()
        val ranges = if (navigation.isNotEmpty()) {
            fromNavigation(bytes, encoding, navigation, checkActive)
        } else {
            fallbackRanges(bytes, isHtml, checkActive)
        }
        val result = mutableListOf<MobiTextSection>()
        var readableSections = 0
        ranges.forEach { range ->
            checkActive()
            if (range.isVolume) {
                result.addBounded(range)
            } else {
                val chunks = splitLargeRange(bytes, encoding, isHtml, range, checkActive)
                chunks.forEachIndexed { partIndex, chunk ->
                    checkActive()
                    val previewEnd = previewEnd(bytes, encoding, chunk.start, chunk.end)
                    val preview = encoding.decode(bytes, chunk.start, previewEnd)
                    if (previewEnd == chunk.end &&
                        (if (isHtml) format(preview, checkActive = checkActive) else preview).isBlank()) return@forEachIndexed
                    val baseTitle = chunk.title.takeIf { it.isNotBlank() }
                        ?: (if (isHtml) extractTitle(preview) else null)
                        ?: "第${readableSections + 1}章"
                    val title = if (chunks.size > 1) "$baseTitle (${partIndex + 1}/${chunks.size})" else baseTitle
                    result.addBounded(chunk.copy(title = title))
                    readableSections++
                }
            }
        }
        return result.also { checkActive() }
    }

    private fun fromNavigation(
        bytes: ByteArray,
        encoding: MobiTextEncoding,
        navigation: List<MobiTocEntry>,
        checkActive: () -> Unit,
    ): List<MobiTextSection> {
        require(navigation.size <= MAX_TOC_ENTRIES) { "MOBI 目录条目过多" }
        val offsets = mutableSetOf<Int>()
        navigation.forEach { entry ->
            checkActive()
            require(entry.offset in bytes.indices && encoding.isBoundary(bytes, entry.offset)) {
                "MOBI NCX 章节位置越界或落在多字节字符中间"
            }
            offsets.add(entry.offset)
        }
        // Physical boundaries define body ownership, but never reorder the logical NCX traversal.
        val physicalStarts = offsets.sorted()
        checkActive()
        val endByStart = mutableMapOf<Int, Int>()
        physicalStarts.forEachIndexed { index, start ->
            checkActive()
            endByStart[start] = physicalStarts.getOrNull(index + 1) ?: bytes.size
        }
        val result = mutableListOf<MobiTextSection>()
        val firstStart = physicalStarts.first()
        if (firstStart > 0) result.addBounded(MobiTextSection(0, firstStart, "卷首"))
        navigation.forEachIndexed { index, entry ->
            checkActive()
            // Only an actual parent sharing its immediate successor's target may skip its body.
            // Leaf aliases still own the entire physical interval, even with identical targets/titles.
            val isVolume = entry.hasChildren && navigation.getOrNull(index + 1)?.offset == entry.offset
            result.addBounded(MobiTextSection(
                start = entry.offset,
                end = if (isVolume) entry.offset else endByStart.getValue(entry.offset),
                title = entry.title,
                isVolume = isVolume,
            ))
        }
        return result
    }

    private fun fallbackRanges(
        bytes: ByteArray,
        isHtml: Boolean,
        checkActive: () -> Unit,
    ): List<MobiTextSection> {
        val pagebreaks = mutableListOf<Int>()
        val headings = mutableListOf<Int>()
        if (isHtml) MobiMarkupScanner.scan(bytes, 0, bytes.size, checkActive) { tag ->
            if (!tag.closing && tag.name in setOf("pagebreak", "mbp:pagebreak") && tag.end < bytes.size) {
                pagebreaks.addBounded(tag.end)
            }
            if (!tag.closing && tag.name == "h1") {
                headings.addBounded(tag.start)
            }
            true
        }
        val markers = if (pagebreaks.isNotEmpty()) pagebreaks else {
            headings.takeIf { it.size > 1 }.orEmpty()
        }
        val starts = mutableListOf(0)
        val seen = mutableSetOf(0)
        markers.forEach { start ->
            checkActive()
            if (seen.add(start)) starts.addBounded(start)
        }
        starts.sort()
        val result = mutableListOf<MobiTextSection>()
        starts.forEachIndexed { index, start ->
            checkActive()
            result.addBounded(MobiTextSection(start, starts.getOrNull(index + 1) ?: bytes.size, ""))
        }
        return result
    }

    private fun splitLargeRange(
        bytes: ByteArray,
        encoding: MobiTextEncoding,
        isHtml: Boolean,
        section: MobiTextSection,
        checkActive: () -> Unit,
    ): List<MobiTextSection> {
        if (section.end - section.start <= MAX_CHAPTER_BYTES) return listOf(section)
        val result = mutableListOf<MobiTextSection>()
        var start = section.start
        while (section.end - start > MAX_CHAPTER_BYTES) {
            checkActive()
            var split = start + MAX_CHAPTER_BYTES
            if (isHtml) {
                var blockBreak = -1
                MobiMarkupScanner.scan(bytes, start, section.end, checkActive) { tag ->
                    when {
                        tag.start <= split && tag.end > split -> {
                            split = if (tag.start > start) tag.start else tag.end
                            false
                        }
                        tag.start > split -> false
                        else -> {
                            if (!tag.closing && tag.name in BLOCK_TAGS && tag.start >= split - PREVIEW_BYTES) {
                                blockBreak = tag.start
                            }
                            true
                        }
                    }
                }
                if (blockBreak > start && blockBreak <= split) split = blockBreak
            } else {
                var candidate = split
                while (candidate > split - PREVIEW_BYTES && candidate > start) {
                    if (bytes.mobiU8(candidate - 1) in setOf(10, 13)) {
                        split = candidate
                        break
                    }
                    candidate--
                }
            }
            while (split > start && !encoding.isBoundary(bytes, split)) split--
            require(split > start && split <= section.end) { "MOBI 长章节分段位置无效" }
            result.addBounded(section.copy(start = start, end = split))
            start = split
        }
        if (start < section.end) {
            checkActive()
            result.addBounded(section.copy(start = start))
        }
        return result
    }

    private fun <T> MutableList<T>.addBounded(value: T) {
        require(size < MAX_TOC_ENTRIES) { "MOBI 目录超过 $MAX_TOC_ENTRIES 项限制" }
        add(value)
    }

    private fun previewEnd(bytes: ByteArray, encoding: MobiTextEncoding, start: Int, end: Int): Int {
        var result = minOf(end, start + PREVIEW_BYTES)
        while (result > start && !encoding.isBoundary(bytes, result)) result--
        return result
    }

    private fun extractTitle(html: String): String? {
        val document = Ksoup.parse(html = html)
        return document.selectFirst("h1, h2, h3")?.text()?.trim()?.takeIf { it.isNotBlank() }
            ?: document.title().trim().takeIf { it.isNotBlank() }
    }

    private val BLOCK_TAGS = setOf("p", "div", "h1", "h2", "h3", "section", "article", "mbp:pagebreak")
    private val NON_BODY_TAGS = setOf(
        "head", "script", "style", "title", "noscript", "link", "meta", "base",
        "template", "iframe", "noembed", "noframes", "pagebreak",
    )
}
