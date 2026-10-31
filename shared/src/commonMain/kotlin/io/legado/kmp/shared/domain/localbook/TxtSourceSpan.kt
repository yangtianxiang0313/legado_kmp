package io.legado.kmp.shared.domain.localbook

/** Bounded, original-decoder projection. Does not own or close the byte source. */
internal class TxtSourceSpan(
    source: LocalBookByteSource,
    charsetName: String,
    val start: Long,
    val end: Long,
    private val checkActive: () -> Unit,
) {
    private val reader: TxtWindowReader
    private val windows = ArrayList<Segment>()
    private var cachedWindow: TxtWindowReader.Window? = null
    val content: String

    init {
        checkActive()
        require(start >= 0 && end >= start && end <= source.size) { "Invalid TXT source span $start..$end" }
        require(end - start <= MAX_BYTES) { "TXT bookmark span exceeds the 32 MiB byte limit" }
        require(charsetName.isNotBlank()) { "TXT bookmark source charset is not known" }
        reader = TxtWindowReader(source, charsetName, WINDOW_BYTES, checkActive)
        content = buildString {
            var offset = start
            while (offset < end) {
                checkActive()
                val window = reader.window(offset, end)
                require(window.content.length <= MAX_TEXT_UNITS - length) {
                    "TXT bookmark span exceeds the 4 Mi UTF-16 unit limit"
                }
                require(window.end > offset && window.end <= end) { "TXT bookmark window did not advance" }
                validateWindow(window)
                windows.add(Segment(offset, window.end, length, window.content.length))
                append(window.content)
                offset = window.end
            }
        }
        checkActive()
    }

    fun byteOffset(position: Int): Long {
        checkActive()
        require(position in 0..content.length && isBoundary(content, position)) {
            "TXT bookmark is not on a UTF-16 code point boundary"
        }
        if (position == content.length) return end
        val segment = segmentForText(position)
        val window = reload(segment)
        val offset = requireNotNull(window.byteOffset(position - segment.textStart)) {
            "TXT bookmark UTF-16 position has no exact original byte offset"
        }
        require(offset in segment.byteStart until segment.byteEnd) { "TXT bookmark byte offset is outside its window" }
        checkActive()
        return offset
    }

    fun sourcePosition(byteOffset: Long): Int {
        checkActive()
        require(byteOffset in start..end) { "TXT bookmark byte offset is outside its source span" }
        if (byteOffset == end) return content.length
        val segment = segmentForByte(byteOffset)
        val window = reload(segment)
        var index = 0
        var iterations = 0
        var previousByte = window.start
        while (true) {
            if (iterations++ % 256 == 0) checkActive()
            val offset = requireNotNull(window.byteOffset(index)) {
                "TXT source code point has no exact original byte offset"
            }
            require(index == 0 || offset > previousByte) { "TXT decoder byte offsets are not strictly increasing" }
            if (offset == byteOffset) return segment.textStart + index
            require(offset < byteOffset && index < window.content.length) {
                "TXT bookmark falls inside an encoded character or encoding marker"
            }
            previousByte = offset
            val character = window.content[index]
            index += when {
                character.isHighSurrogate() -> {
                    require(index + 1 < window.content.length && window.content[index + 1].isLowSurrogate()) {
                        "TXT decoder returned an unpaired high surrogate"
                    }
                    2
                }
                character.isLowSurrogate() -> error("TXT decoder returned an unpaired low surrogate")
                else -> 1
            }
        }
    }

    private fun segmentForText(position: Int): Segment {
        var low = 0
        var high = windows.size
        while (low < high) {
            checkActive()
            val middle = low + (high - low) / 2
            val segment = windows[middle]
            if (segment.textStart + segment.textLength <= position) low = middle + 1 else high = middle
        }
        return requireNotNull(windows.getOrNull(low)) { "TXT bookmark text window is missing" }
    }

    private fun segmentForByte(position: Long): Segment {
        var low = 0
        var high = windows.size
        while (low < high) {
            checkActive()
            val middle = low + (high - low) / 2
            if (windows[middle].byteEnd <= position) low = middle + 1 else high = middle
        }
        return requireNotNull(windows.getOrNull(low)) { "TXT bookmark byte window is missing" }
    }

    private fun reload(segment: Segment): TxtWindowReader.Window {
        checkActive()
        cachedWindow?.let {
            if (it.start == segment.byteStart && it.end == segment.byteEnd) return it
        }
        cachedWindow = null
        val window = reader.window(segment.byteStart, segment.byteEnd)
        require(window.end == segment.byteEnd && window.content.length == segment.textLength) {
            "TXT source window changed while mapping bookmarks"
        }
        for (index in window.content.indices) {
            if (index % 4096 == 0) checkActive()
            require(window.content[index] == content[segment.textStart + index]) {
                "TXT source text changed while mapping bookmarks"
            }
        }
        validateWindow(window)
        cachedWindow = window
        return window
    }

    private fun validateWindow(window: TxtWindowReader.Window) {
        checkActive()
        require(window.byteOffset(window.content.length) == window.end) {
            "TXT decoder text length cannot be proven against the original bytes"
        }
        checkActive()
    }

    private data class Segment(val byteStart: Long, val byteEnd: Long, val textStart: Int, val textLength: Int)

    companion object {
        const val MAX_BYTES = 32L * 1024 * 1024
        const val MAX_TEXT_UNITS = 4 * 1024 * 1024
        private const val WINDOW_BYTES = 512 * 1024

        fun isBoundary(content: String, position: Int): Boolean = position in 0..content.length &&
            !(position > 0 && position < content.length &&
                content[position - 1].isHighSurrogate() && content[position].isLowSurrogate())
    }
}
