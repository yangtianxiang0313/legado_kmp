package io.legado.kmp.shared.facade

internal object BookExportLimits {
    const val PACKAGE_BYTES = 128L * 1024 * 1024
    const val BODY_BYTES = 64L * 1024 * 1024
    const val CHAPTER_BODY_BYTES = 16L * 1024 * 1024
    const val RESOURCE_BYTES = 32L * 1024 * 1024
    const val METADATA_BYTES = 1024L * 1024
    const val DIRECTORY_BYTES = 8L * 1024 * 1024
    const val IDENTITY_BYTES = 8L * 1024
    const val CHAPTERS = 10_000
    const val RESOURCES = 20_000
    const val IMAGE_OCCURRENCES = 60_000
}

internal class BookExportBudget(private val checkActive: () -> Unit) {
    private var bodyBytes = 0L
    private var renderedBytes = 0L
    private var imageBytes = 0L
    private var imageOccurrences = 0

    fun body(value: String) {
        val size = textBytes(value, BookExportLimits.CHAPTER_BODY_BYTES, "单章正文超过 16 MiB 导出限制")
        bodyBytes += size
        requireBookExport(bodyBytes <= BookExportLimits.BODY_BYTES, "正文总量超过 64 MiB 导出限制")
    }

    fun rendered(value: String): Long {
        val size = textBytes(value, BookExportLimits.RESOURCE_BYTES, "单个导出正文资源超过 32 MiB 限制")
        renderedBytes += size
        requireBookExport(renderedBytes <= BookExportLimits.BODY_BYTES, "导出正文总量超过 64 MiB 限制")
        requireBookExport(renderedBytes + imageBytes <= BookExportLimits.PACKAGE_BYTES, "导出文件超过 128 MiB 限制")
        return size
    }

    fun image(bytes: ByteArray) {
        checkActive()
        requireBookExport(bytes.size.toLong() <= BookExportLimits.RESOURCE_BYTES, "单个图片资源超过 32 MiB 导出限制")
        imageBytes += bytes.size
        requireBookExport(imageBytes + renderedBytes <= BookExportLimits.PACKAGE_BYTES, "导出文件超过 128 MiB 限制")
    }

    fun imageOccurrence() {
        checkActive()
        imageOccurrences++
        requireBookExport(imageOccurrences <= BookExportLimits.IMAGE_OCCURRENCES, "正文图片出现次数超过 60000 次导出限制")
    }

    fun resourceCount(count: Int) {
        checkActive()
        requireBookExport(count <= BookExportLimits.RESOURCES, "导出资源数量超过 20000 项限制")
    }

    fun textBytes(
        value: String,
        maximum: Long,
        failureMessage: String = "导出文本或标识超过 $maximum 字节大小限制",
    ): Long {
        requireBookExport(value.length.toLong() <= maximum, failureMessage)
        var bytes = 0L
        var index = 0
        while (index < value.length) {
            if (index % 4096 == 0) checkActive()
            val char = value[index]
            bytes += when {
                char.code < 0x80 -> 1
                char.code < 0x800 -> 2
                char.isHighSurrogate() && index + 1 < value.length && value[index + 1].isLowSurrogate() -> {
                    index++
                    4
                }
                else -> 3
            }
            requireBookExport(bytes <= maximum, failureMessage)
            index++
        }
        checkActive()
        return bytes
    }

    fun archive(entries: List<ZipEntryData>) {
        requireBookExport(entries.size <= BookExportLimits.RESOURCES, "导出资源数量超过 20000 项限制")
        val paths = mutableSetOf<String>()
        var size = 22L
        for (entry in entries) {
            checkActive()
            requireBookExport(paths.add(entry.path), "导出文档包含重复资源身份")
            val nameBytes = textBytes(entry.path, BookExportLimits.IDENTITY_BYTES)
            requireBookExport(entry.data.size.toLong() <= BookExportLimits.RESOURCE_BYTES, "单个导出资源超过 32 MiB 限制")
            size += 76L + nameBytes * 2 + entry.data.size
            requireBookExport(size <= BookExportLimits.PACKAGE_BYTES, "导出文件超过 128 MiB 限制")
        }
    }
}
