package io.legado.kmp.shared.domain.localbook

internal enum class MobiTextEncoding(val charsetName: String) {
    UTF8("UTF-8"),
    WINDOWS_1252("windows-1252");

    fun decode(bytes: ByteArray, start: Int = 0, end: Int = bytes.size, metadata: Boolean = false): String {
        bytes.mobiRange(start, end - start)
        val actualEnd = if (metadata) {
            var cursor = start
            while (cursor < end && bytes[cursor] != 0.toByte()) cursor++
            cursor
        } else end
        val result = when (this) {
            UTF8 -> bytes.decodeToString(start, actualEnd, throwOnInvalidSequence = true)
            WINDOWS_1252 -> buildString(actualEnd - start) {
                for (index in start until actualEnd) append(decodeSingleByte(bytes.mobiU8(index)))
            }
        }
        return if (metadata) result.trim() else result
    }

    fun validate(bytes: ByteArray, checkActive: () -> Unit) {
        var cursor = 0
        var nonWhitespace = false
        while (cursor < bytes.size) {
            if (cursor and 0xffff == 0) checkActive()
            val value = bytes.mobiU8(cursor)
            require(value >= 0x20 || value == 9 || value == 10 || value == 12 || value == 13) {
                "MOBI 正文含非法控制字符，文件可能损坏或加密"
            }
            if (value > 0x20) nonWhitespace = true
            cursor = nextCharacter(bytes, cursor)
        }
        require(nonWhitespace) { "MOBI 正文为空" }
    }

    fun isBoundary(bytes: ByteArray, offset: Int): Boolean = offset in 0..bytes.size &&
        (this != UTF8 || offset == bytes.size || bytes.mobiU8(offset) and 0xc0 != 0x80)

    fun nextCharacter(bytes: ByteArray, offset: Int): Int {
        val first = bytes.mobiU8(offset)
        if (this == WINDOWS_1252) {
            decodeSingleByte(first)
            return offset + 1
        }
        fun continuation(index: Int, range: IntRange = 0x80..0xbf) {
            require(offset + index < bytes.size && bytes.mobiU8(offset + index) in range) {
                "MOBI UTF-8 字符无效或被截断（字节 $offset）"
            }
        }
        val length = when (first) {
            in 0..0x7f -> 1
            in 0xc2..0xdf -> {
                continuation(1)
                2
            }
            in 0xe0..0xef -> {
                continuation(1, when (first) {
                    0xe0 -> 0xa0..0xbf
                    0xed -> 0x80..0x9f
                    else -> 0x80..0xbf
                })
                continuation(2)
                3
            }
            in 0xf0..0xf4 -> {
                continuation(1, when (first) {
                    0xf0 -> 0x90..0xbf
                    0xf4 -> 0x80..0x8f
                    else -> 0x80..0xbf
                })
                continuation(2)
                continuation(3)
                4
            }
            else -> throw IllegalArgumentException("MOBI UTF-8 起始字节无效（字节 $offset）")
        }
        return offset + length
    }

    private fun decodeSingleByte(value: Int): Char {
        if (value !in 0x80..0x9f) return value.toChar()
        return WINDOWS_SPECIAL[value - 0x80].toChar()
    }

    private companion object {
        // Match Java's windows-1252 replacement while retaining one character per byte.
        val WINDOWS_SPECIAL = intArrayOf(
            0x20ac, 0xfffd, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021,
            0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0xfffd, 0x017d, 0xfffd,
            0xfffd, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014,
            0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0xfffd, 0x017e, 0x0178,
        )
    }
}
