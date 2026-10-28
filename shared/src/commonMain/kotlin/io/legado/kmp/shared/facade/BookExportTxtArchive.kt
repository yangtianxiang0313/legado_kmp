package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

internal data class BookExportTxtChapter(val chapter: BookChapter, val body: String, val hasContent: Boolean) {
    override fun toString(): String = "BookExportTxtChapter(redacted)"
}

/** Android exportTxt/getExportData semantics, delivered as one TXT plus images in a portable ZIP. */
internal class BookExportTxtArchive(
    private val book: Book,
    images: BookImageFacade,
    private val budget: BookExportBudget,
    private val batchBudget: BookExportBatchBudget,
    private val checkActive: () -> Unit,
) {
    private val images = BookExportTxtImages(book, images, budget, checkActive)

    suspend fun prepare(
        directory: List<BookChapter>,
        fileName: String,
        options: BookExportOptions,
        onProgress: (BookExportProgress) -> Unit,
        readChapter: suspend (BookChapter) -> BookExportTxtChapter,
    ): BookExportResult {
        checkActive()
        // The safe outer name has already evaluated the filename script exactly once.
        requireBookExport(fileName.endsWith(".zip"), "TXT 图片导出文件名必须使用 ZIP 扩展名")
        val txtName = fileName.removeSuffix(".zip") + ".txt"
        validateExportArchivePath(txtName)
        val output = StringBuilder()
        var outputBytes = 0L
        var readableChapters = 0
        var missingChapters = 0
        fun append(text: String) {
            checkActive()
            outputBytes += budget.rendered(text)
            requireBookExport(outputBytes <= BookExportLimits.PACKAGE_BYTES, "导出文件超过 128 MiB 限制")
            output.append(text)
            checkActive()
        }
        try {
            append("${book.name}\n作者：${book.author}\n")
            book.displayIntro?.takeIf { it.isNotBlank() }?.let { intro ->
                val chapter = BookChapter(bookUrl = book.bookUrl, url = book.bookUrl)
                val document = BookExportDocument.parse(chapter, intro, checkActive = checkActive)
                val paths = images.paths(document)
                append("\n简介：\n")
                append(document.renderText(imagePaths = paths, missingImageText = IMAGE_MISSING, checkActive = checkActive))
                append("\n")
            }
            directory.forEachIndexed { index, originalChapter ->
                checkActive()
                val source = readChapter(originalChapter)
                checkActive()
                val chapter = source.chapter
                val document = BookExportDocument.parse(chapter, source.body, imageBook = book.isImage, checkActive = checkActive)
                val paths = images.paths(document)
                val readable = source.hasContent && (document.hasReadableText || paths.isNotEmpty())
                val emptyVolume = !readable && chapter.isVolume && chapter.title.isNotBlank() && document.imageCount == 0
                when {
                    readable -> readableChapters++
                    !emptyVolume -> missingChapters++
                }
                append(if (options.includeChapterTitle) "\n\n${chapter.title}\n" else "\n\n")
                append(document.renderText(imagePaths = paths, missingImageText = IMAGE_MISSING, checkActive = checkActive))
                if (!readable && !emptyVolume) append(if (book.isLocal) {
                    "\n[正文缺失：本地章节内容不可用]\n"
                } else "\n[正文未缓存]\n")
                checkActive()
                onProgress(BookExportProgress(index + 1, directory.size))
                checkActive()
            }
            requireBookExport(readableChapters > 0, "全部正文或正文图片缺失，请检查本地文件或已有缓存后重试")
            checkActive()
            val text = output.toString()
            budget.textBytes(text, BookExportLimits.PACKAGE_BYTES)
            val bytes = encodeBookExportText(text, options.charset, checkActive)
            checkActive()
            output.clear()
            requireBookExport(bytes.isNotEmpty(), "导出文件为空，无法导出")
            val entries = listOf(ZipEntryData(txtName, bytes)) + images.entries()
            budget.archive(entries)
            batchBudget.archive(entries)
            checkActive()
            val archive = buildStoredZip(entries, checkActive)
            checkActive()
            return BookExportResult(
                data = archive,
                fileExtension = "zip",
                chapterCount = directory.size,
                readableChapterCount = readableChapters,
                missingChapterCount = missingChapters,
                missingImageCount = images.missingCount,
            )
        } finally {
            output.clear()
        }
    }

    private companion object {
        const val IMAGE_MISSING = "[图片缺失：未缓存或本地资源不可用]"
    }
}
