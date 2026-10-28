package io.legado.kmp.shared.domain.localbook

internal data class MobiMarkupTag(val start: Int, val end: Int, val name: String, val closing: Boolean)

/** Finds ASCII markup byte positions; actual HTML interpretation remains in Ksoup. */
internal object MobiMarkupScanner {
    fun scan(
        bytes: ByteArray,
        start: Int,
        end: Int,
        checkActive: () -> Unit,
        visit: (MobiMarkupTag) -> Boolean,
    ) {
        var cursor = start
        var tags = 0
        while (cursor < end) {
            if (cursor and 0x3fff == 0) checkActive()
            if (bytes.mobiU8(cursor) != '<'.code) {
                cursor++
                continue
            }
            val tagStart = cursor++
            if (matches(bytes, tagStart, end, "<!--")) {
                cursor = find(bytes, cursor + 3, end, "-->", checkActive)?.plus(3)
                    ?: throw IllegalArgumentException("MOBI HTML 注释未闭合")
                continue
            }
            while (cursor < end && isSpace(bytes.mobiU8(cursor))) cursor++
            val closing = cursor < end && bytes.mobiU8(cursor) == '/'.code
            if (closing) cursor++
            val nameStart = cursor
            if (cursor >= end || !isFirstName(bytes.mobiU8(cursor))) continue
            while (cursor < end && isName(bytes.mobiU8(cursor))) cursor++
            if (cursor == nameStart) continue
            val name = bytes.mobiAscii(nameStart, cursor - nameStart).lowercase()
            if (cursor < end && !isSpace(bytes.mobiU8(cursor)) && bytes.mobiU8(cursor) !in listOf('/'.code, '>'.code)) {
                continue
            }
            var quote = 0
            var closed = false
            while (cursor < end && cursor - tagStart <= MAX_TAG_BYTES) {
                val value = bytes.mobiU8(cursor++)
                if (quote != 0) {
                    if (value == quote) quote = 0
                } else if (value == '\''.code || value == '"'.code) {
                    quote = value
                } else if (value == '>'.code) {
                    closed = true
                    break
                }
            }
            require(closed) { "MOBI HTML 标签被截断或超过 32 KiB 限制" }
            if (!closing && name in RAW_TAGS && bytes.mobiU8(cursor - 2) != '/'.code) {
                val closeStart = findRawClose(bytes, cursor, end, name, checkActive)
                    ?: throw IllegalArgumentException("MOBI HTML $name 元素未闭合")
                val closeEnd = find(bytes, closeStart + name.length + 2, end, ">", checkActive)
                    ?: throw IllegalArgumentException("MOBI HTML $name 结束标签被截断")
                cursor = closeEnd + 1
            }
            require(++tags <= MAX_MARKUP_TAGS) { "MOBI HTML 标签数量超过限制" }
            if (!visit(MobiMarkupTag(tagStart, cursor, name, closing))) return
        }
    }

    private fun findRawClose(
        bytes: ByteArray,
        start: Int,
        end: Int,
        name: String,
        checkActive: () -> Unit,
    ): Int? {
        val needle = "</$name"
        var cursor = start
        while (cursor < end) {
            val found = find(bytes, cursor, end, needle, checkActive) ?: return null
            val next = found + needle.length
            if (next < end && (isSpace(bytes.mobiU8(next)) || bytes.mobiU8(next) == '>'.code)) return found
            cursor = next
        }
        return null
    }

    private fun find(
        bytes: ByteArray,
        start: Int,
        end: Int,
        needle: String,
        checkActive: () -> Unit,
    ): Int? {
        var cursor = start
        while (cursor <= end - needle.length) {
            if (cursor and 0x3fff == 0) checkActive()
            if (matches(bytes, cursor, end, needle)) return cursor
            cursor++
        }
        return null
    }

    private fun matches(bytes: ByteArray, start: Int, end: Int, value: String): Boolean =
        start >= 0 && start <= end - value.length && value.indices.all { index ->
            val byte = bytes.mobiU8(start + index)
            (if (byte in 'A'.code..'Z'.code) byte + 32 else byte) == value[index].code
        }

    private fun isSpace(value: Int): Boolean = value == 9 || value == 10 || value == 12 || value == 13 || value == 32
    private fun isFirstName(value: Int): Boolean = value in 'A'.code..'Z'.code || value in 'a'.code..'z'.code
    private fun isName(value: Int): Boolean = isFirstName(value) ||
        value in '0'.code..'9'.code || value == ':'.code || value == '-'.code || value == '_'.code

    private const val MAX_TAG_BYTES = 32 * 1024
    private const val MAX_MARKUP_TAGS = 2_000_000
    private val RAW_TAGS = setOf("script", "style")
}
