package io.legado.kmp.shared.facade

import io.legado.kmp.shared.content.BookImageMarkup
import okio.Buffer

public data class ReaderSearchVisibleRange(val start: Int, val length: Int)

/** Maps whitespace- and markup-independent UTF-16 coordinates to the unchanged source. */
public class ReaderSearchTextIndex private constructor(
    content: String,
    checkActive: () -> Unit,
) {
    public constructor(content: String) : this(content, {})

    public val normalizedText: String
    public val fingerprint: String
    private val sourceLength = content.length
    private val sourceOffsets: IntArray

    init {
        checkActive()
        val images = BookImageMarkup.images(content, checkActive)
        val normalized = StringBuilder()
        val offsets = IntArray(content.length)

        fun appendText(sourceStart: Int, sourceEnd: Int) {
            checkActive()
            if (sourceStart >= sourceEnd) return
            val text = content.substring(sourceStart, sourceEnd)
            val characters = text.toCharArray()

            fun hide(range: IntRange) {
                checkActive()
                for (index in range) {
                    if (index % 256 == 0) checkActive()
                    characters[index] = '\n'
                }
            }

            // Keep source offsets while matching stripSimpleHtml's line-break-before-tag order.
            for (match in lineBreakTags.findAll(text.withReaderCancellationChecks(checkActive))) {
                hide(match.range)
            }
            val tagInput = characters.concatToString().withReaderCancellationChecks(checkActive)
            for (match in htmlTags.findAll(tagInput)) {
                hide(match.range)
            }
            for (index in characters.indices) {
                if (index % 256 == 0) checkActive()
                val character = characters[index]
                if (!character.isWhitespace()) {
                    offsets[normalized.length] = sourceStart + index
                    normalized.append(character)
                }
            }
        }

        var cursor = 0
        for (image in images) {
            checkActive()
            appendText(cursor, image.range.first)
            cursor = image.range.last + 1
        }
        appendText(cursor, content.length)
        checkActive()
        normalizedText = normalized.toString()
        sourceOffsets = offsets.copyOf(normalizedText.length)

        // Encode code units directly so even unpaired surrogates have a distinct fingerprint.
        val bytes = Buffer()
        for (index in normalizedText.indices) {
            if (index % 256 == 0) checkActive()
            bytes.writeShortLe(normalizedText[index].code)
        }
        checkActive()
        fingerprint = bytes.readByteString().sha256().hex()
        checkActive()
    }

    public fun visibleRange(sourceStart: Int, sourceLength: Int): ReaderSearchVisibleRange? {
        if (sourceStart < 0 || sourceLength <= 0 || sourceStart > this.sourceLength ||
            sourceLength > this.sourceLength - sourceStart
        ) return null
        val start = lowerBound(sourceStart)
        val end = lowerBound(sourceStart + sourceLength)
        return if (start < end) ReaderSearchVisibleRange(start, end - start) else null
    }

    public fun sourcePosition(visibleIndex: Int): Int? = sourceOffsets.getOrNull(visibleIndex)

    private fun lowerBound(sourcePosition: Int): Int {
        var low = 0
        var high = sourceOffsets.size
        while (low < high) {
            val middle = low + (high - low) / 2
            if (sourceOffsets[middle] < sourcePosition) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    internal companion object {
        private val lineBreakTags = Regex("""<br\s*/?>|</p>""", RegexOption.IGNORE_CASE)
        private val htmlTags = Regex("""<[^>]+>""")

        fun create(content: String, checkActive: () -> Unit): ReaderSearchTextIndex =
            ReaderSearchTextIndex(content, checkActive)
    }
}
