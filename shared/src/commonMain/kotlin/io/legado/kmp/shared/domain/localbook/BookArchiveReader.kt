package io.legado.kmp.shared.domain.localbook

internal data class BookArchiveMember(val path: String, val size: Long)

internal interface BookArchiveReader {
    fun entries(): List<BookArchiveMember>
    fun read(path: String): ByteArray
}

internal object BookArchiveLimits {
    const val ARCHIVE_BYTES = 128 * 1024 * 1024
    const val ENTRY_BYTES = 64 * 1024 * 1024
    const val TOTAL_BYTES = 256 * 1024 * 1024
    const val ENTRIES = 4096
}

internal fun openBookArchive(bytes: ByteArray, format: String, checkCancelled: () -> Unit): BookArchiveReader =
    when (format) {
        "zip" -> object : BookArchiveReader {
            private val zip = BookArchiveZipReader(bytes, checkCancelled)
            override fun entries(): List<BookArchiveMember> = zip.entries().map { BookArchiveMember(it.path, it.size.toLong()) }
            override fun read(path: String): ByteArray = zip.read(path)
        }
        "rar", "7z" -> NativeBookArchiveReader(bytes, format, checkCancelled)
        else -> error("仅支持 ZIP、RAR 和 7z 压缩包")
    }

internal expect class NativeBookArchiveReader(
    bytes: ByteArray,
    format: String,
    checkCancelled: () -> Unit,
) : BookArchiveReader {
    override fun entries(): List<BookArchiveMember>
    override fun read(path: String): ByteArray
}
