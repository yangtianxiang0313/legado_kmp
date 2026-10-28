package io.legado.kmp.shared.domain.localbook

/** A read-only, bounded byte source. The caller owns it and must close it. */
interface LocalBookByteSource {
    /** Byte length captured when opened; remains available after closing. */
    val size: Long

    /**
     * Reads up to [length] bytes at [offset], without changing a shared cursor.
     * Returns fewer bytes at EOF, or an empty array for zero length or an offset
     * at/past EOF. Negative arguments and reads after closing are rejected.
     * Implementations must not allocate or read the whole source implicitly.
     */
    @Throws(Exception::class)
    fun read(offset: Long, length: Int): ByteArray

    /** Releases the source. Repeated calls have no effect. */
    @Throws(Exception::class)
    fun closeSource()
}

/** Retains [bytes] without copying it; each read copies only the requested range. */
class ByteArrayLocalBookByteSource(bytes: ByteArray) : LocalBookByteSource {
    private var content: ByteArray? = bytes

    override val size: Long = bytes.size.toLong()

    override fun read(offset: Long, length: Int): ByteArray {
        require(offset >= 0L) { "Byte offset must not be negative: $offset" }
        require(length >= 0) { "Byte length must not be negative: $length" }
        val bytes = checkNotNull(content) { "Local book byte source is closed" }
        if (length == 0 || offset >= size) return ByteArray(0)

        val start = offset.toInt()
        val count = minOf(length.toLong(), size - offset).toInt()
        return bytes.copyOfRange(start, start + count)
    }

    override fun closeSource() {
        content = null
    }
}
