package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

internal fun requireBookExportIdentity(value: String, budget: BookExportBudget) {
    requireBookExport(value.isNotBlank(), "书籍或章节标识为空，无法导出")
    budget.textBytes(value, BookExportLimits.IDENTITY_BYTES)
}

internal fun requireBookExportMetadata(book: Book, budget: BookExportBudget) {
    requireBookExportIdentity(book.bookUrl, budget)
    budget.textBytes(book.origin, BookExportLimits.IDENTITY_BYTES)
    val size = listOf(book.name, book.author, book.displayIntro.orEmpty()).sumOf {
        budget.textBytes(it, BookExportLimits.METADATA_BYTES)
    }
    requireBookExport(size <= BookExportLimits.METADATA_BYTES, "书籍元数据超过 1 MiB 导出限制")
}

internal fun bookExportDirectory(
    book: Book,
    chapters: List<BookChapter>,
    budget: BookExportBudget,
    checkActive: () -> Unit,
): List<BookChapter> {
    requireBookExport(chapters.isNotEmpty(), "没有可导出的现有目录，请先在阅读页显式加载目录")
    requireBookExport(chapters.size <= BookExportLimits.CHAPTERS, "章节数量超过 10000 章导出限制")
    val urls = mutableSetOf<String>()
    val indices = mutableSetOf<Int>()
    var directoryBytes = 0L
    for (chapter in chapters) {
        checkActive()
        requireBookExport(chapter.bookUrl == book.bookUrl, "现有目录包含不属于此书的章节，无法导出")
        requireBookExportIdentity(chapter.url, budget)
        requireBookExport(urls.add(chapter.url) && chapter.index >= 0 && indices.add(chapter.index),
            "现有目录包含重复或无效章节身份，无法导出")
        directoryBytes += listOf(
            chapter.url, chapter.baseUrl, chapter.resourceUrl.orEmpty(),
            chapter.startFragmentId.orEmpty(), chapter.endFragmentId.orEmpty(),
        ).sumOf { budget.textBytes(it, BookExportLimits.IDENTITY_BYTES) }
        directoryBytes += budget.textBytes(chapter.title, 64L * 1024)
        directoryBytes += budget.textBytes(chapter.variable.orEmpty(), BookExportLimits.METADATA_BYTES)
        requireBookExport(directoryBytes <= BookExportLimits.DIRECTORY_BYTES, "目录数据超过 8 MiB 导出限制")
    }
    return chapters.sortedBy { it.index }.also { sorted ->
        sorted.forEachIndexed { index, chapter ->
            checkActive()
            requireBookExport(chapter.index == index, "现有目录章节序号不完整，请先在阅读页显式更新目录")
        }
    }
}
