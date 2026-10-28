package io.legado.kmp.shared.scripting

/** Fingerprints deliberately follow QueryTTF.java at Android 5f5d314, not rendered paths. */
internal class LegacyFontOutlines(
    private val glyf: LegacyFontReader,
    private val locations: IntArray,
    private val maxContours: Int,
) {
    var characterCount: Int = 0
        private set
    private var pointCount = 0

    fun read(): Array<String?> {
        val base = glyf.position
        return Array(locations.size - 1) { glyph ->
            val offset = locations[glyph]
            val length = locations[glyph + 1] - offset
            if (length == 0) null else {
                val reader = glyf.slice(base + offset, length)
                val contours = reader.i16()
                // Android treats zero-contour and excessive-contour glyphs as absent.
                if (contours == 0 || contours > maxContours) null else {
                    reader.skip(8)
                    val result = if (contours > 0) readSimple(reader, contours) else readComposite(reader)
                    fontRequire(result.length <= LegacyFontLimits.MAX_OUTLINE_CHARS - characterCount,
                        "Font outline storage limit exceeded")
                    characterCount += result.length
                    result
                }
            }
        }
    }

    private fun readSimple(reader: LegacyFontReader, contours: Int): String {
        var previousEnd = -1
        repeat(contours) {
            val end = reader.u16()
            fontRequire(end > previousEnd, "Invalid glyf contour endpoints")
            previousEnd = end
        }
        val count = previousEnd + 1
        fontRequire(count <= LegacyFontLimits.MAX_POINTS - pointCount, "Font point limit exceeded")
        pointCount += count
        reader.skip(reader.u16())
        val flags = IntArray(count)
        var index = 0
        while (index < count) {
            val flag = reader.u8()
            val copies = if ((flag and 8) != 0) reader.u8() + 1 else 1
            fontRequire(copies <= count - index, "Invalid repeated glyf flags")
            repeat(copies) { flags[index++] = flag }
        }
        val x = IntArray(count) { coordinate(reader, flags[it], 2, 16) }
        val y = IntArray(count) { coordinate(reader, flags[it], 4, 32) }
        // Android ignores endpoints, on-curve bits, bbox and hinting in its signature.
        return buildString {
            for (point in 0 until count) {
                if (point != 0) append('|')
                append(x[point])
                append(',')
                append(y[point])
            }
        }
    }

    private fun coordinate(reader: LegacyFontReader, flags: Int, short: Int, same: Int): Int {
        return if ((flags and short) != 0) {
            val value = reader.u8()
            if ((flags and same) != 0) value else -value
        } else if ((flags and same) != 0) 0 else reader.i16()
    }

    private fun readComposite(reader: LegacyFontReader): String = buildString {
        append('[')
        var components = 0
        var flags: Int
        do {
            fontRequire(components < LegacyFontLimits.MAX_COMPONENTS, "Composite glyph component limit exceeded")
            if (components++ > 0) append(',')
            flags = reader.u16()
            val glyph = reader.u16()
            fontRequire(glyph < locations.size - 1, "Composite glyph index outside maxp range")
            val words = (flags and 1) != 0
            val signed = (flags and 2) != 0
            fun argument(): Int = when {
                words && signed -> reader.i16()
                words -> reader.u16()
                signed -> reader.i8()
                else -> reader.u8()
            }
            val arg1 = argument()
            val arg2 = argument()
            var xScale = 0
            var yScale = 0
            var scale01 = 0
            var scale10 = 0
            // Keep Android's unsigned F2DOT14 and zero defaults, including component IDs.
            when (flags and 0xc8) {
                0x08 -> {
                    xScale = reader.u16()
                    yScale = xScale
                }
                0x40 -> {
                    xScale = reader.u16()
                    yScale = reader.u16()
                }
                0x80 -> {
                    xScale = reader.u16()
                    scale01 = reader.u16()
                    scale10 = reader.u16()
                    yScale = reader.u16()
                }
                0 -> Unit
                else -> throw LegacyFontException("Invalid composite glyph transform flags")
            }
            append("{flags:").append(flags)
            append(",glyphIndex:").append(glyph)
            append(",arg1:").append(arg1)
            append(",arg2:").append(arg2)
            append(",xScale:").append(legacyFontScaleString(xScale))
            append(",scale01:").append(legacyFontScaleString(scale01))
            append(",scale10:").append(legacyFontScaleString(scale10))
            append(",yScale:").append(legacyFontScaleString(yScale)).append('}')
        } while ((flags and 0x20) != 0)
        if ((flags and 0x100) != 0) reader.skip(reader.u16())
        append(']')
    }
}

private fun legacyFontScaleString(numerator: Int): String {
    if (numerator == 0) return "0.0"
    // F2DOT14 is exact in Float. Select its shortest round-tripping decimal without
    // Native Float.toString, whose formatting need not match Android's Java output.
    val value = numerator / 16384f
    val exact = numerator * 6_103_515_625L // numerator / 2^14, scaled by 10^14.
    val length = exact.toString().length
    var divisor = 1L
    repeat(length - 1) { divisor *= 10 }
    for (precision in 1..9) {
        var rounded = exact / divisor
        val remainder = exact % divisor
        if (remainder * 2 > divisor || (remainder * 2 == divisor && rounded % 2 != 0L)) rounded++
        val power = length - precision - 14
        if ((rounded.toString() + "e" + power).toFloat() == value) {
            val raw = rounded.toString()
            val exponent = raw.length - 1 + power
            val digits = raw.trimEnd('0')
            return if (exponent < -3) {
                digits.take(1) + "." + digits.drop(1).ifEmpty { "0" } + "E" + exponent
            } else {
                val point = exponent + 1
                when {
                    point <= 0 -> "0." + "0".repeat(-point) + digits
                    point >= digits.length -> digits + "0".repeat(point - digits.length) + ".0"
                    else -> digits.substring(0, point) + "." + digits.substring(point)
                }
            }
        }
        divisor /= 10
    }
    throw LegacyFontException("Cannot encode composite glyph scale")
}
