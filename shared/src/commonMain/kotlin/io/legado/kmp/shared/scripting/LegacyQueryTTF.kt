package io.legado.kmp.shared.scripting

/** TrueType anti-obfuscation queries with Android-compatible glyf signatures. */
class LegacyQueryTTF(buffer: ByteArray) {
    val unicodeToGlyphId: Map<Int, Int>
    private val glyphs: Array<String?>
    val glyphToUnicode: Map<String, Int>

    val unicodeToGlyph: Map<Int, String?>
        get() = unicodeToGlyphId.mapValues { (_, glyph) -> glyphs[glyph] }

    internal val retainedBytes: Long

    init {
        val directory = LegacyFontDirectory(buffer)
        val head = directory.table("head")
        fontRequire(head.remaining >= 54, "Truncated head table")
        head.skip(12)
        fontRequire(head.u32() == 0x5f0f3cf5L, "Invalid head magic number")
        head.skip(34)
        val locationFormat = head.i16()
        fontRequire(locationFormat == 0 || locationFormat == 1, "Unsupported loca format")
        fontRequire(head.i16() == 0, "Unsupported glyph data format")

        val maxp = directory.table("maxp")
        fontRequire(maxp.u32() == 0x00010000L, "TrueType maxp version 1 is required")
        val glyphCount = maxp.u16()
        fontRequire(glyphCount > 0 && maxp.remaining >= 26, "Invalid maxp table")
        maxp.skip(2)
        val maxContours = maxp.u16()

        val glyf = directory.table("glyf")
        val loca = directory.table("loca")
        val locations = IntArray(glyphCount + 1) {
            if (locationFormat == 0) loca.u16() * 2 else loca.offset32()
        }
        for (index in locations.indices) {
            fontRequire(locations[index] <= glyf.remaining, "loca entry outside glyf table")
            fontRequire(index == 0 || locations[index] >= locations[index - 1], "Unordered loca entries")
        }
        unicodeToGlyphId = LegacyFontCmap(directory.table("cmap"), glyphCount).read()
        val outlines = LegacyFontOutlines(glyf, locations, maxContours)
        glyphs = outlines.read()
        val reverse = LinkedHashMap<String, Int>()
        val lastUnicode = IntArray(glyphCount)
        val lastOrder = IntArray(glyphCount)
        var order = 0
        for (unicode in legacyAndroidCmapOrder(unicodeToGlyphId)) {
            val glyph = unicodeToGlyphId.getValue(unicode)
            lastUnicode[glyph] = unicode
            lastOrder[glyph] = ++order
        }
        // Many Unicode aliases can share one large glyph; hash its outline only once.
        glyphs.indices.filter { lastOrder[it] != 0 }.sortedBy { lastOrder[it] }.forEach { glyph ->
            glyphs[glyph]?.let { reverse[it] = lastUnicode[glyph] }
        }
        glyphToUnicode = reverse.toMap()
        retainedBytes = outlines.characterCount * 2L + unicodeToGlyphId.size * 80L +
            glyphs.size * 32L + glyphToUnicode.size * 80L
    }

    fun getGlyfById(glyfId: Int): String? = glyphs.getOrNull(glyfId)
    fun getGlyfIdByUnicode(unicode: Int): Int = unicodeToGlyphId[unicode] ?: 0
    fun getGlyfByUnicode(unicode: Int): String? = unicodeToGlyphId[unicode]?.let { glyphs[it] }
    fun getUnicodeByGlyf(glyph: String?): Int {
        if (glyph == null) return 0
        fontRequire(glyph.length <= LegacyFontLimits.MAX_GLYPH_QUERY_CHARS, "Glyph query size limit exceeded")
        return glyphToUnicode[glyph] ?: 0
    }

    fun isBlankUnicode(unicode: Int): Boolean = when (unicode) {
        0x0009, 0x0020, 0x00a0, 0x2002, 0x2003, 0x2007,
        0x200a, 0x200b, 0x200c, 0x200d, 0x202f, 0x205f -> true
        else -> false
    }
}

fun legacyReplaceFont(
    text: String,
    errorQueryTTF: LegacyQueryTTF?,
    correctQueryTTF: LegacyQueryTTF?,
    filter: Boolean = false,
): String {
    if (errorQueryTTF == null || correctQueryTTF == null) return text
    fontRequire(text.length <= LegacyFontLimits.MAX_TEXT_CHARS, "Font replacement text limit exceeded")
    val replacements = HashMap<Int, Int>()
    return buildString(text.length) {
        var index = 0
        while (index < text.length) {
            val first = text[index]
            val second = text.getOrNull(index + 1)
            val paired = first in '\uD800'..'\uDBFF' && second != null && second in '\uDC00'..'\uDFFF'
            val width = if (paired) 2 else 1
            val unicode = if (paired) {
                0x10000 + ((first.code - 0xd800) shl 10) + (second!!.code - 0xdc00)
            } else first.code
            if (errorQueryTTF.isBlankUnicode(unicode)) {
                append(text, index, index + width)
            } else {
                val glyphId = errorQueryTTF.getGlyfIdByUnicode(unicode)
                val glyph = if (glyphId == 0) null else errorQueryTTF.getGlyfById(glyphId)
                if (!filter || glyph != null) {
                    val replacement = if (glyph == null) 0 else replacements.getOrPut(glyphId) {
                        correctQueryTTF.getUnicodeByGlyf(glyph)
                    }
                    if (replacement == 0) append(text, index, index + width)
                    else appendFontCodePoint(replacement)
                }
            }
            index += width
        }
    }
}

private fun StringBuilder.appendFontCodePoint(code: Int) {
    if (code <= 0xffff) append(code.toChar()) else {
        val supplementary = code - 0x10000
        append((0xd800 + (supplementary shr 10)).toChar())
        append((0xdc00 + (supplementary and 0x3ff)).toChar())
    }
}
