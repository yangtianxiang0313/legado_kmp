package io.legado.kmp.shared.domain.localbook

internal object UmdLimits {
    const val MAX_FILE_BYTES = 64 * 1024 * 1024
    const val MAX_TEXT_BYTES = 64 * 1024 * 1024
    const val MAX_TEXT_CHARS = 32 * 1024 * 1024
    const val MAX_BLOCK_BYTES = 8 * 1024 * 1024
    const val MAX_CHAPTER_BYTES = 8 * 1024 * 1024
    const val MAX_COVER_BYTES = 8 * 1024 * 1024
    const val MAX_CHAPTERS = 100_000
    const val MAX_CONTENT_BLOCKS = 65_536
    const val MAX_SECTIONS = 262_144
}

internal class UmdBinaryReader(
    val bytes: ByteArray,
    val start: Int = 0,
    val end: Int = bytes.size,
) {
    var position: Int = start
        private set
    val size: Int get() = end - start
    val remaining: Int get() = end - position
    val exhausted: Boolean get() = position == end

    init {
        require(start >= 0 && end >= start && end <= bytes.size) { "UMD 数据范围无效" }
    }

    fun peekByte(): Int {
        requireRemaining(1)
        return bytes[position].toInt() and 255
    }

    fun byte(): Int = peekByte().also { position++ }

    fun shortLe(): Int = byte() or (byte() shl 8)

    fun intLe(): Int = shortLe() or (shortLe() shl 16)

    fun uintLe(): Long = intLe().toLong() and 0xffffffffL

    fun section(length: Int): UmdBinaryReader {
        requireRemaining(length)
        return UmdBinaryReader(bytes, position, position + length).also { position += length }
    }

    fun copyBytes(): ByteArray = bytes.copyOfRange(start, end)

    fun skipRemaining() {
        position = end
    }

    fun requireSize(expected: Int, label: String) {
        require(size == expected) { "UMD $label 长度错误：$size，预期 $expected" }
    }

    fun requireExhausted(label: String) {
        require(exhausted) { "UMD $label 存在多余数据" }
    }

    private fun requireRemaining(count: Int) {
        require(count >= 0 && count <= remaining) { "UMD 数据截断，偏移 $position" }
    }
}
