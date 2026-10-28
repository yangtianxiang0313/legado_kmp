package io.legado.kmp.shared.scripting

/** Android processes all records, but only formats 0/4/6; its unused pps list is not a priority. */
internal class LegacyFontCmap(private val reader: LegacyFontReader, private val glyphCount: Int) {
    private val mappings = LinkedHashMap<Int, Int>()
    private var operations = 0

    fun read(): Map<Int, Int> {
        val start = reader.position
        fontRequire(reader.u16() == 0, "Unsupported cmap version")
        val count = reader.u16()
        fontRequire(count in 1..LegacyFontLimits.MAX_CMAP_RECORDS, "Invalid cmap record count")
        fontRequire(count * 8 <= reader.remaining, "Truncated cmap records")
        val offsets = LinkedHashSet<Int>()
        repeat(count) {
            reader.skip(4)
            offsets += reader.offset32()
        }
        for (offset in offsets) {
            fontRequire(offset <= Int.MAX_VALUE - start, "Invalid cmap offset")
            val subtableStart = start + offset
            reader.seek(subtableStart)
            val format = reader.u16()
            if (format != 0 && format != 4 && format != 6) continue
            val length = reader.u16()
            val subtable = reader.slice(subtableStart, length)
            subtable.skip(6)
            when (format) {
                0 -> readByteMap(subtable)
                4 -> readSegments(subtable)
                6 -> readTrimmed(subtable)
            }
        }
        return mappings.toMap()
    }

    private fun put(unicode: Int, glyph: Int, includeMissing: Boolean = false) {
        operations++
        fontRequire(operations <= LegacyFontLimits.MAX_CMAP_OPERATIONS, "cmap work limit exceeded")
        if (unicode !in 0..0x10ffff || (glyph == 0 && !includeMissing)) return
        fontRequire(glyph in 0 until glyphCount, "cmap glyph index outside maxp range")
        if (unicode !in mappings) {
            fontRequire(mappings.size < LegacyFontLimits.MAX_MAPPINGS, "cmap mapping limit exceeded")
        }
        mappings[unicode] = glyph
    }

    private fun readByteMap(table: LegacyFontReader) {
        repeat(table.remaining) { put(it, table.u8()) }
    }

    private fun readSegments(table: LegacyFontReader) {
        val countX2 = table.u16()
        fontRequire(countX2 > 0 && countX2 % 2 == 0, "Invalid format 4 segment count")
        val count = countX2 / 2
        table.skip(6)
        fontRequire(count * 8 + 2 <= table.remaining, "Truncated format 4 cmap")
        val ends = IntArray(count) { table.u16() }
        table.skip(2)
        val starts = IntArray(count) { table.u16() }
        val deltas = IntArray(count) { table.i16() }
        val rangePositions = table.position
        val ranges = IntArray(count) { table.u16() }
        for (segment in 0 until count) {
            fontRequire(starts[segment] <= ends[segment], "Invalid cmap segment")
            fontRequire(ranges[segment] % 2 == 0, "Unaligned cmap glyph offset")
            for (unicode in starts[segment]..ends[segment]) {
                val glyph = if (ranges[segment] == 0) {
                    (unicode + deltas[segment]) and 0xffff
                } else {
                    val position = rangePositions + segment * 2 + ranges[segment] + (unicode - starts[segment]) * 2
                    val raw = table.u16At(position)
                    // QueryTTF.java adds idDelta directly here, even for zero array entries.
                    raw + deltas[segment]
                }
                put(unicode, glyph)
            }
        }
    }

    private fun readTrimmed(table: LegacyFontReader) {
        val first = table.u16()
        val count = table.u16()
        fontRequire(count <= table.remaining / 2, "Truncated trimmed cmap")
        repeat(count) { put(first + it, table.u16(), includeMissing = true) }
    }
}
