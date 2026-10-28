package io.legado.kmp.shared.facade

/** Counts final filenames and stored ZIP overhead across every part of one atomic batch. */
internal class BookExportBatchBudget(
    private val budget: BookExportBudget,
    private val checkActive: () -> Unit,
) {
    private val fileNames = mutableSetOf<String>()
    private var packageBytes = 0L
    private var archiveEntries = 0

    fun reserveFileName(fileName: String) {
        checkActive()
        budget.textBytes(fileName, BookExportLimits.IDENTITY_BYTES)
        requireBookExport(fileName.isNotBlank(), "导出文件名为空，无法导出")
        requireBookExport(fileNames.size < 1000, "分卷数量超过 1000 卷导出限制")
        requireBookExport(fileNames.add(fileName.lowercase()), "分卷文件名重名，请调整命名脚本")
    }

    fun archive(entries: List<ZipEntryData>) {
        budget.resourceCount(archiveEntries + entries.size)
        var bytes = 22L
        for (entry in entries) {
            checkActive()
            val nameBytes = budget.textBytes(entry.path, BookExportLimits.IDENTITY_BYTES)
            bytes += 76L + nameBytes * 2 + entry.data.size
            requireBookExport(bytes <= BookExportLimits.PACKAGE_BYTES - packageBytes,
                "整批导出文件超过 128 MiB 限制")
        }
        archiveEntries += entries.size
    }

    fun accept(bytes: ByteArray) {
        checkActive()
        requireBookExport(bytes.isNotEmpty(), "导出文件为空，无法导出")
        requireBookExport(bytes.size.toLong() <= BookExportLimits.PACKAGE_BYTES - packageBytes,
            "整批导出文件超过 128 MiB 限制")
        packageBytes += bytes.size
        checkActive()
    }
}
