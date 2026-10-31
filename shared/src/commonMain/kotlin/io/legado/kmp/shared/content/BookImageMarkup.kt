package io.legado.kmp.shared.content

import com.fleeksoft.io.StringReader
import com.fleeksoft.ksoup.Ksoup
import com.fleeksoft.ksoup.nodes.Element
import com.fleeksoft.ksoup.parser.Parser
import io.legado.kmp.shared.network.joinUrl

internal object BookImageMarkup {
    // Inclusive UTF-16 offsets in the unchanged input; attribute values are entity-decoded once.
    data class Image(val range: IntRange, val source: String, val alt: String?, val hidden: Boolean = false)

    // Android AppPattern.imgPattern, used only for its non-HTML raw JSON suffix.
    private val androidImagePattern = Regex("""<img[^>]*src=['"]([^'"]*(?:['"][^>]+\})?)['"][^>]*>""")
    private val optionSeparator = Regex("""\s*,\s*(?=\{)""")
    private val explicitScheme = Regex("""^[A-Za-z][A-Za-z0-9+.-]*:""")

    fun images(content: String, checkActive: () -> Unit = {}): List<Image> {
        checkActive()
        if (!content.contains("<img", ignoreCase = true)) {
            checkActive()
            return emptyList()
        }
        val parser = Parser.htmlParser().setTrackPosition(true)
        val document = Ksoup.parse(reader = CheckedStringReader(content, checkActive), parser = parser)
        checkActive()
        val elements = document.select("img[src]").sortedBy {
            checkActive()
            it.sourceRange().startPos()
        }
        val images = mutableListOf<Image>()
        var previousEnd = 0
        for (element in elements) {
            checkActive()
            val range = element.sourceRange()
            val start = range.startPos()
            val end = range.endPos()
            if (!range.isTracked() || start < previousEnd || end <= start || end > content.length) continue
            if (content[start] != '<' || content[end - 1] != '>') continue
            val legacy = legacyImage(element, content, start, end, checkActive)
            images += legacy ?: Image(
                range = start until end,
                source = element.attr("src"),
                alt = element.takeIf { it.hasAttr("alt") }?.attr("alt"),
                hidden = isHidden(element),
            )
            previousEnd = end
        }
        checkActive()
        return images
    }

    fun absoluteSource(source: String, baseUrl: String): String {
        val separator = optionSeparator.find(source)
        val url = source.substring(0, separator?.range?.first ?: source.length).trim()
        if (url.isEmpty() || explicitScheme.containsMatchIn(url) || baseUrl.isBlank()) return source
        val baseSeparator = optionSeparator.find(baseUrl)
        val base = baseUrl.substring(0, baseSeparator?.range?.first ?: baseUrl.length).trim()
        if (base.isEmpty()) return source
        // These are already decoded attribute values. Do not decode or reserialize the rule suffix.
        val options = separator?.let { source.substring(it.range.first) }.orEmpty()
        return base.joinUrl(url) + options
    }

    private fun legacyImage(
        element: Element,
        content: String,
        start: Int,
        end: Int,
        checkActive: () -> Unit,
    ): Image? {
        val valueRange = element.attributes().sourceRange("src").valueRange()
        if (!valueRange.isTracked()) return null
        val valueStart = valueRange.startPos()
        val valueEnd = valueRange.endPos()
        if (valueStart <= start || valueEnd < valueStart || valueEnd >= end) return null
        val quote = content[valueStart - 1]
        if ((quote != '"' && quote != '\'') || content[valueEnd] != quote) return null
        val prefix = content.substring(valueStart, valueEnd)
        val separator = optionSeparator.find(prefix) ?: return null
        // Only an unfinished legacy options object can extend beyond Ksoup's quoted src value.
        val optionsPrefix = prefix.substring(separator.range.last + 1).trim()
        if (optionsPrefix.endsWith('}')) return null
        val firstKey = optionsPrefix.drop(1).trimStart()
        if (firstKey.isNotEmpty() && !firstKey.startsWith('"')) return null
        checkActive()
        val tag = content.substring(start, end)
        val match = androidImagePattern.matchEntire(tag) ?: return null
        val source = match.groups[1] ?: return null
        if (source.range.first != valueStart - start || source.range.last < valueEnd - start) return null
        if (tag[source.range.last + 1] != quote) return null
        // Let Ksoup read the remaining attributes; raw JSON quotes are the only repaired region.
        val repaired = Ksoup.parse(reader = CheckedStringReader(tag.replaceRange(source.range, ""), checkActive))
            .selectFirst("img") ?: return null
        checkActive()
        return Image(
            range = start until end,
            source = Parser.unescapeEntities(source.value, inAttribute = true),
            alt = repaired.takeIf { it.hasAttr("alt") }?.attr("alt"),
            hidden = isHidden(repaired),
        )
    }

    private fun isHidden(element: Element): Boolean = element.hasAttr("hidden") ||
        element.attr("style").split(';').any { declaration ->
            val property = declaration.substringBefore(':').trim().lowercase()
            val value = declaration.substringAfter(':', "").substringBefore('!').trim().lowercase()
            property == "display" && value == "none" || property == "visibility" && value == "hidden"
        }

    private class CheckedStringReader(
        content: String,
        private val checkActive: () -> Unit,
    ) : StringReader(content) {
        override fun read(cbuf: CharArray, off: Int, len: Int): Int {
            checkActive()
            return super.read(cbuf, off, minOf(len, 256))
        }
    }
}
