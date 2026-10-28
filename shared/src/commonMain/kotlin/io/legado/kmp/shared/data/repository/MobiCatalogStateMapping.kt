package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.localbook.MobiReadingSpan
import io.legado.kmp.shared.domain.localbook.isMobiLocalBook
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

/** A catalog reorder must move the latest reading state and bookmarks in the same SQL transaction. */
internal fun mapMobiCatalogState(
    database: LegadoDatabase,
    current: Book,
    replacement: Book,
    chapters: List<BookChapter>?,
    checkActive: () -> Unit,
): Book {
    if (!current.isMobiLocalBook() || chapters == null) return replacement
    val previous = database.bookChapterQueries.selectByBookUrl(current.bookUrl, BookChapter.Companion::from).executeAsList()
    if (previous.isEmpty()) return replacement
    val oldByIndex = previous.associateBy { it.index }
    val byUrl = chapters.groupBy { it.url }
    fun mapped(index: Long, position: Long): BookChapter {
        checkActive()
        check(index in 0..Int.MAX_VALUE.toLong() && position in 0..Int.MAX_VALUE.toLong()) {
            "MOBI 原阅读位置无效，目录与进度未改动"
        }
        val old = oldByIndex[index.toInt()] ?: error("MOBI 原阅读章节不存在，目录未改动")
        val next = byUrl[old.url]?.singleOrNull()
        check(next != null && MobiReadingSpan.of(next) == MobiReadingSpan.of(old)) {
            "MOBI 章节边界已变化，无法安全映射已有阅读位置或书签；原目录与进度未改动"
        }
        return next
    }
    val point = mapped(current.durChapterIndex.toLong(), current.durChapterPos.toLong())
    val bookmarks = database.bookmarkQueries.selectByBook(current.name, current.author).executeAsList()
    val moves = bookmarks.map { mark ->
        checkActive()
        mark to mapped(mark.chapter_index, mark.chapter_pos)
    }
    if (moves.isNotEmpty()) {
        check(current.name == replacement.name && current.author == replacement.author) {
            "MOBI 书名或作者变化会改变已有书签归属，原目录与书签未改动"
        }
    }
    if (moves.any { (mark, chapter) -> mark.chapter_index != chapter.index.toLong() }) {
        val owners = database.bookQueries.selectAll().executeAsList().count {
            checkActive()
            it.name == current.name && it.author == current.author
        }
        check(owners == 1) { "多本同名同作者书籍共用书签，无法安全重排 MOBI 目录；原数据未改动" }
        moves.forEach { (mark, chapter) ->
            checkActive()
            database.bookmarkQueries.update(
                book_name = mark.book_name, book_author = mark.book_author,
                chapter_index = chapter.index.toLong(), chapter_pos = mark.chapter_pos,
                chapter_name = mark.chapter_name, book_text = mark.book_text, content = mark.content, time = mark.time,
            )
        }
    }
    return replacement.copy(
        durChapterIndex = point.index, durChapterTitle = point.title,
        durChapterPos = current.durChapterPos, durChapterTime = current.durChapterTime,
    ).also {
        it.infoHtml = replacement.infoHtml
        it.tocHtml = replacement.tocHtml
        it.downloadUrls = replacement.downloadUrls
    }
}
