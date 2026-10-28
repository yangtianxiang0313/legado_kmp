package io.legado.kmp.shared.scripting

internal object LegacyFontLimits {
    const val MAX_BYTES = 32 * 1024 * 1024
    const val MAX_TABLES = 256
    const val MAX_CMAP_RECORDS = 256
    const val MAX_MAPPINGS = 262_144
    const val MAX_CMAP_OPERATIONS = 2_000_000
    const val MAX_POINTS = 8_000_000
    const val MAX_COMPONENTS = 1024
    const val MAX_OUTLINE_CHARS = 32 * 1024 * 1024
    const val MAX_GLYPH_QUERY_CHARS = 1024 * 1024
    const val MAX_EXPORT_CHARS = 8 * 1024 * 1024
    const val MAX_FONTS = 16
    const val MAX_SESSION_BYTES = 192L * 1024 * 1024
    const val MAX_TEXT_CHARS = 4 * 1024 * 1024
}

class LegacyFontException(message: String) : IllegalArgumentException("[queryTTF] $message")

internal fun fontRequire(condition: Boolean, message: String) {
    if (!condition) throw LegacyFontException(message)
}

internal data class LegacyFontTable(val offset: Int, val length: Int)

/** Every reader is restricted to its own table or glyph, never the rest of the file. */
internal class LegacyFontReader(
    private val bytes: ByteArray,
    private val start: Int = 0,
    private val end: Int = bytes.size,
) {
    var position: Int = start
        private set

    val remaining: Int get() = end - position

    init {
        fontRequire(start >= 0 && end >= start && end <= bytes.size, "Invalid font data range")
    }

    fun seek(offset: Int) {
        fontRequire(offset in start..end, "Font offset outside table")
        position = offset
    }

    fun skip(count: Int) {
        fontRequire(count >= 0 && count <= remaining, "Truncated font data")
        position += count
    }

    fun u8(): Int {
        fontRequire(remaining >= 1, "Truncated font data")
        return bytes[position++].toInt() and 0xff
    }

    fun i8(): Int = u8().let { if (it >= 128) it - 256 else it }
    fun u16(): Int = (u8() shl 8) or u8()
    fun i16(): Int = u16().let { if (it >= 32768) it - 65536 else it }
    fun u32(): Long = (u16().toLong() shl 16) or u16().toLong()

    fun offset32(): Int {
        val value = u32()
        fontRequire(value <= Int.MAX_VALUE, "Font offset is too large")
        return value.toInt()
    }

    fun tag(): String = buildString(4) { repeat(4) { append(u8().toChar()) } }

    fun slice(offset: Int, length: Int): LegacyFontReader {
        fontRequire(offset >= start && length >= 0 && offset <= end && length <= end - offset,
            "Font data outside table")
        return LegacyFontReader(bytes, offset, offset + length)
    }

    fun u16At(offset: Int): Int = slice(offset, 2).u16()
}

internal class LegacyFontDirectory(bytes: ByteArray) {
    private val reader = LegacyFontReader(bytes)
    private val tables = LinkedHashMap<String, LegacyFontTable>()

    init {
        fontRequire(bytes.size in 12..LegacyFontLimits.MAX_BYTES, "Invalid font size (maximum 32 MiB)")
        val version = reader.u32()
        fontRequire(version == 0x00010000L || version == 0x74727565L,
            "Only TrueType sfnt fonts with glyf outlines are supported (not WOFF/CFF/TTC)")
        val count = reader.u16()
        fontRequire(count in 1..LegacyFontLimits.MAX_TABLES, "Invalid font table count")
        reader.skip(6)
        fontRequire(count * 16 <= reader.remaining, "Truncated font directory")
        repeat(count) {
            val tag = reader.tag()
            reader.skip(4)
            val offset = reader.offset32()
            val length = reader.offset32()
            fontRequire(offset <= bytes.size && length <= bytes.size - offset, "Invalid $tag table range")
            fontRequire(tag !in tables, "Duplicate $tag table")
            tables[tag] = LegacyFontTable(offset, length)
        }
    }

    fun table(tag: String): LegacyFontReader {
        val table = tables[tag] ?: throw LegacyFontException("Missing $tag table")
        return reader.slice(table.offset, table.length)
    }
}
