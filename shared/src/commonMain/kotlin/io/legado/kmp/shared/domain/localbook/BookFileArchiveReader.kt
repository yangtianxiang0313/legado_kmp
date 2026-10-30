package io.legado.kmp.shared.domain.localbook

/** Sessions borrow [LocalBookByteSource]; only its caller may close the source. */
internal interface BookFileArchiveReader {
    fun entries(): List<BookArchiveMember>

    /** Writes bounded chunks through entry EOF/CRC; a failure invalidates any partial output. */
    fun extract(path: String, write: (ByteArray) -> Unit): Long

    /** Reads every file through EOF/CRC in one sequential native session. */
    fun validateAll()

    fun close()
}

internal expect class NativeBookFileArchiveReader(
    source: LocalBookByteSource,
    format: String,
    checkCancelled: () -> Unit,
) : BookFileArchiveReader {
    override fun entries(): List<BookArchiveMember>
    override fun extract(path: String, write: (ByteArray) -> Unit): Long
    override fun validateAll()
    override fun close()
}

/** Independent of the legacy, memory-backed [BookArchiveLimits]. */
internal object BookFileArchiveLimits {
    const val ARCHIVE_BYTES = 16L * 1024 * 1024 * 1024
    const val ENTRY_BYTES = 2L * 1024 * 1024 * 1024
    const val TOTAL_BYTES = 16L * 1024 * 1024 * 1024
    const val ENTRIES = 10_000
    const val PATH_BYTES = 1024
    const val TOTAL_PATH_BYTES = 4 * 1024 * 1024
    const val PATH_NODES = 100_000
    const val TOTAL_NODE_BYTES = 8 * 1024 * 1024
    const val READ_BYTES = 64 * 1024
}
