package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.BookChapter

/** The full directory must have passed bookExportDirectory before selecting any chapters. */
internal fun bookExportSelection(
    directory: List<BookChapter>,
    scope: String,
    checkActive: () -> Unit,
): List<BookChapter> {
    checkActive()
    BookExportBudget(checkActive).textBytes(scope, 64L * 1024, "章节范围超过 64 KiB 限制")
    if (scope.isBlank()) return directory
    val ranges = scope.split(',').map { value ->
        checkActive()
        val item = value.trim()
        requireBookExport(item.isNotEmpty(), "章节范围包含空项，无法导出")
        val separator = item.indexOf('-')
        requireBookExport(separator == item.lastIndexOf('-'), "章节范围格式无效，请使用 1-3,5")
        fun position(text: String): Int {
            val number = text.trim()
            requireBookExport(number.isNotEmpty() && number.all { it in '0'..'9' },
                "章节范围格式无效，请使用 1-3,5")
            val parsed = number.toIntOrNull() ?: throw BookExportFailure("章节范围数字溢出，无法导出")
            requireBookExport(parsed in 1..directory.size, "章节范围越界，请按现有目录从 1 开始选择")
            return parsed
        }
        val start = position(if (separator < 0) item else item.substring(0, separator))
        val end = if (separator < 0) start else position(item.substring(separator + 1))
        requireBookExport(start <= end, "章节范围不能反向，无法导出")
        start..end
    }.sortedWith(compareBy<IntRange> { it.first }.thenBy { it.last })

    // Overlapping ranges never repeatedly expand the same directory positions.
    val selected = mutableListOf<BookChapter>()
    var lastSelected = 0
    for (range in ranges) {
        checkActive()
        val start = maxOf(range.first, lastSelected + 1)
        for (position in start..range.last) {
            checkActive()
            selected += directory[position - 1]
        }
        lastSelected = maxOf(lastSelected, range.last)
    }
    requireBookExport(selected.isNotEmpty(), "章节范围未选中任何章节，无法导出")
    return selected
}

internal fun bookExportVolumes(
    selected: List<BookChapter>,
    chaptersPerFile: Int,
    extension: String,
    checkActive: () -> Unit,
): List<List<BookChapter>> {
    checkActive()
    requireBookExport(selected.isNotEmpty(), "章节范围未选中任何章节，无法导出")
    requireBookExport(chaptersPerFile >= 0, "每卷章节数不能为负数")
    requireBookExport(extension != "txt" || chaptersPerFile == 0, "TXT 不支持分卷导出，请改用 EPUB")
    if (chaptersPerFile == 0) return listOf(selected)
    val count = (selected.size - 1) / chaptersPerFile + 1
    requireBookExport(count <= 1000, "分卷数量超过 1000 卷导出限制")
    val size = minOf(chaptersPerFile, selected.size)
    return List(count) { index ->
        checkActive()
        val start = index * size
        selected.subList(start, minOf(start + size, selected.size)).toList()
    }
}
