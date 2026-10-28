package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.usecase.LoadEpubLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadMobiLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadTxtLocalChapterContentUseCase
import io.legado.kmp.shared.domain.usecase.LoadUmdLocalChapterContentUseCase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.hasType
import io.legado.kmp.shared.model.isTxtLocalBook
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal enum class BookExportLocalFormat { TXT, EPUB, UMD, MOBI }

internal fun bookExportLocalFormat(book: Book): BookExportLocalFormat? {
    if (!book.isLocal) return null
    val extension = book.bookUrl.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase()
    return when (extension) {
        "pdf" -> null
        "txt" -> BookExportLocalFormat.TXT
        "epub" -> BookExportLocalFormat.EPUB
        "umd" -> BookExportLocalFormat.UMD
        "mobi", "azw", "azw3" -> BookExportLocalFormat.MOBI
        else -> when {
            book.isTxtLocalBook -> BookExportLocalFormat.TXT
            book.isEpub -> BookExportLocalFormat.EPUB
            else -> null
        }
    }
}

internal fun requireBookExportFormat(book: Book) {
    // Mask the shelf flag before checking legacy discriminator values.
    val type = book.type and BookType.NOT_SHELF.inv()
    requireBookExport(!book.hasType(BookType.AUDIO) && type != BookType.LEGACY_AUDIO, "音频书籍不支持正文导出")
    requireBookExport(book.isLocal || (!book.hasType(BookType.WEB_FILE) && type != BookType.LEGACY_WEB_FILE),
        "在线文件书籍请使用原文件下载，不支持正文导出")
    val extension = book.bookUrl.substringBefore('?').substringBefore('#').substringAfterLast('.', "").lowercase()
    requireBookExport(extension != "pdf", "PDF 书籍不支持正文导出")
    requireBookExport(!book.isLocal || bookExportLocalFormat(book) != null, "此本地书籍格式不支持正文导出")
}

internal class BookExportLocalContent(
    private val txt: LoadTxtLocalChapterContentUseCase,
    private val epub: LoadEpubLocalChapterContentUseCase,
    private val umd: LoadUmdLocalChapterContentUseCase,
    private val mobi: LoadMobiLocalChapterContentUseCase,
) {
    suspend fun read(book: Book, chapter: BookChapter): String {
        currentCoroutineContext().ensureActive()
        // Only the retained file is eligible. Resolver recovery must not download a WebDAV book
        // or restore an archive during export. These are in-memory copies, never repository writes.
        val local = book.copy(origin = BookType.LOCAL_TAG)
        return when (bookExportLocalFormat(book)) {
            BookExportLocalFormat.TXT -> {
                val start = chapter.start
                val end = chapter.end
                if (chapter.isVolume && chapter.title.isNotBlank() && start == null && end == null) return ""
                requireBookExport(start != null && end != null && start >= 0 && end >= start,
                    "本地 TXT 章节边界不可用，请先在阅读页显式更新目录")
                requireBookExport(end!! - start!! <= BookExportLimits.RESOURCE_BYTES,
                    "单章原始内容超过 32 MiB 导出限制")
                txt(local, chapter)
            }
            BookExportLocalFormat.EPUB -> epub(local, chapter)
            BookExportLocalFormat.UMD -> umd(local, chapter)
            BookExportLocalFormat.MOBI -> mobi(local, chapter)
            null -> throw BookExportFailure("此本地书籍格式不支持正文导出")
        }.also { currentCoroutineContext().ensureActive() }
    }
}
