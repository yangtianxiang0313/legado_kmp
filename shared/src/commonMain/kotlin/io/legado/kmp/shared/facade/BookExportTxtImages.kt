package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book

/** Reuses cache-only/local export, actual image sniffing and cross-chapter source deduplication. */
internal class BookExportTxtImages(
    book: Book,
    images: BookImageFacade,
    private val budget: BookExportBudget,
    private val checkActive: () -> Unit,
) {
    private val collector = BookExportImages(book, images, budget, reservedEntries = 1, checkActive = checkActive)
    var missingCount: Int = 0
        private set

    suspend fun paths(document: BookExportDocument): Map<String, String> {
        checkActive()
        repeat(document.imageCount) { budget.imageOccurrence() }
        missingCount += document.imageCount - document.imageSources.size
        val paths = linkedMapOf<String, String>()
        for (source in document.imageSources) {
            checkActive()
            val path = collector.bodyPath(source)
            checkActive()
            if (path == null) {
                missingCount++
            } else {
                // Collector paths are relative to EPUB Text/; TXT lives at the ZIP root.
                requireBookExport(path.startsWith("../Images/"), "导出图片路径无效")
                val relative = path.removePrefix("../")
                validateExportArchivePath(relative)
                paths[source] = relative
            }
        }
        checkActive()
        return paths
    }

    fun entries(): List<ZipEntryData> = collector.entries.map { entry ->
        checkActive()
        requireBookExport(entry.path.startsWith("OEBPS/Images/"), "导出图片路径无效")
        val relative = entry.path.removePrefix("OEBPS/")
        validateExportArchivePath(relative)
        ZipEntryData(relative, entry.data)
    }
}
