package io.legado.kmp.shared.domain.localbook

internal data class EpubArchiveEntry(
    val path: String,
    val size: Long,
    val packedSize: Long? = null,
)

/** Archive metadata and selected resources only. The caller retains and closes the borrowed byte source. */
internal interface EpubArchiveReader {
    fun entries(): List<EpubArchiveEntry>
    fun read(path: String, maximumBytes: Int): ByteArray
    fun closeReader()
}

internal object EpubArchiveReadLimits {
    const val ARCHIVE_BYTES = 16L * 1024 * 1024 * 1024
    const val DECLARED_BYTES = 64L * 1024 * 1024 * 1024
    const val ENTRIES = 100_000
    const val READ_BYTES = 64 * 1024
}

internal expect class NativeEpubArchiveReader(
    source: LocalBookByteSource,
    checkCancelled: () -> Unit,
) : EpubArchiveReader {
    override fun entries(): List<EpubArchiveEntry>
    override fun read(path: String, maximumBytes: Int): ByteArray
    override fun closeReader()
}
