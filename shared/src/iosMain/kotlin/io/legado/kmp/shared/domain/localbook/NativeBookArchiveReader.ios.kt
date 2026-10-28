package io.legado.kmp.shared.domain.localbook

internal actual class NativeBookArchiveReader actual constructor(
    private val bytes: ByteArray,
    format: String,
    private val checkCancelled: () -> Unit,
) : BookArchiveReader {
    private val nativeFormat = when (format) {
        "7z" -> 1
        "rar" -> 2
        else -> error("仅支持 RAR 和 7z 压缩包")
    }

    // Retain directories and non-book files for subsequent header comparisons.
    private val directory = withNativeBookArchiveReader(bytes, nativeFormat, checkCancelled) { archive ->
        val headers = mutableListOf<NativeBookArchiveReaderHeader>()
        val paths = NativeBookArchiveReaderPaths()
        var declaredSize = 0L
        while (true) {
            val header = archive.next() ?: break
            require(headers.size < BookArchiveLimits.ENTRIES) { "压缩包条目超过 4096 项" }
            paths.add(header)
            declaredSize += header.size
            require(declaredSize <= BookArchiveLimits.TOTAL_BYTES.toLong()) { "压缩包声明总量超过 256 MiB" }
            headers += header
            archive.skip()
            archive.recheck(header)
        }
        headers.toList()
    }

    private val members = directory.filterNot { it.directory }.map { BookArchiveMember(it.path, it.size) }

    actual override fun entries(): List<BookArchiveMember> {
        checkCancelled()
        return members.toList()
    }

    actual override fun read(path: String): ByteArray {
        checkCancelled()
        val selected = directory.indexOfFirst { !it.directory && it.path == path }
        require(selected >= 0) { "压缩包中不存在选中的书籍" }
        return withNativeBookArchiveReader(bytes, nativeFormat, checkCancelled) { archive ->
            for (index in 0..selected) {
                val expected = directory[index]
                val header = archive.next() ?: error("压缩包目录提前结束")
                require(header == expected) { "压缩包文件头与已读取的目录不一致" }
                if (index == selected) {
                    return@withNativeBookArchiveReader archive.read(expected)
                }
                archive.skip()
                archive.recheck(expected)
            }
            error("压缩包中不存在选中的书籍")
        }
    }
}
