package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.localbook.EpubCatalogReflowPlan
import io.legado.kmp.shared.domain.localbook.EpubNavigationUris
import io.legado.kmp.shared.domain.localbook.EpubResourcePaths
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter

/** Called inside the metadata/directory transaction, against the latest persisted reading state. */
internal fun mapEpubCatalogState(
    database: LegadoDatabase,
    current: Book,
    replacement: Book,
    chapters: List<BookChapter>?,
    reflowPlan: EpubCatalogReflowPlan?,
    checkActive: () -> Unit,
): Book {
    if (!current.isLocal || !current.isEpub || chapters == null) return replacement
    val previous = database.bookChapterQueries.selectByBookUrl(current.bookUrl, BookChapter.Companion::from).executeAsList()
    if (previous.isEmpty()) return replacement
    check(reflowPlan == null || reflowPlan.matches(current, replacement, previous, chapters)) {
        "EPUB 目录或阅读配置在准备期间发生变化，原目录与进度未改动，请重试"
    }
    val bySpan = chapters.filterNot { it.isVolume }.groupBy(::epubReadingSpan)

    fun mapped(index: Int, position: Int): CatalogLocation {
        checkActive()
        val old = previous.firstOrNull { it.index == index }
        check(old != null) { "EPUB 原阅读章节不存在，目录未改动" }
        val matches = bySpan[epubReadingSpan(old)].orEmpty()
        if (matches.size == 1) return CatalogLocation(matches.single().index, position)
        reflowPlan?.mapLocation(index, position)?.let { mapped ->
            return CatalogLocation(mapped.chapterIndex, mapped.chapterPosition, mapped.chapterTitle)
        }
        // A former whole-document chapter can safely enter its new first range only at position zero.
        if (position == 0 && old.startFragmentId == null && old.endFragmentId == null) {
            val first = chapters.filterNot { it.isVolume }.filter {
                epubChapterPath(it) == epubChapterPath(old) && it.startFragmentId == null
            }
            if (first.size == 1) return CatalogLocation(first.single().index, 0)
        }
        error("EPUB 章节边界已变化，无法安全映射已有阅读位置或书签；已保留原目录与进度")
    }

    val currentChapter = mapped(current.durChapterIndex, current.durChapterPos)
    val bookmarks = database.bookmarkQueries.selectByBook(current.name, current.author).executeAsList()
    val moves = bookmarks.map { bookmark ->
        checkActive()
        check(bookmark.chapter_index in 0..Int.MAX_VALUE.toLong() && bookmark.chapter_pos in 0..Int.MAX_VALUE.toLong()) {
            "EPUB 书签位置无效，原目录与书签未改动"
        }
        bookmark to mapped(bookmark.chapter_index.toInt(), bookmark.chapter_pos.toInt())
    }
    if (moves.any { (bookmark, point) ->
            bookmark.chapter_index != point.index.toLong() || bookmark.chapter_pos != point.position.toLong()
        }) {
        val owners = database.bookQueries.selectAll().executeAsList().count {
            checkActive()
            it.name == current.name && it.author == current.author
        }
        check(owners == 1) { "多本同名同作者书籍共用书签，无法安全重排 EPUB 目录；原数据未改动" }
        moves.forEach { (bookmark, point) ->
            checkActive()
            database.bookmarkQueries.update(
                book_name = bookmark.book_name, book_author = bookmark.book_author,
                chapter_index = point.index.toLong(), chapter_pos = point.position.toLong(),
                chapter_name = bookmark.chapter_name, book_text = bookmark.book_text,
                content = bookmark.content, time = bookmark.time,
            )
        }
    }
    return replacement.copy(
        durChapterIndex = currentChapter.index,
        durChapterTitle = currentChapter.title ?: current.durChapterTitle,
        durChapterPos = currentChapter.position, durChapterTime = current.durChapterTime,
    ).also {
        it.infoHtml = replacement.infoHtml
        it.tocHtml = replacement.tocHtml
        it.downloadUrls = replacement.downloadUrls
    }
}

private data class CatalogLocation(val index: Int, val position: Int, val title: String? = null)

private fun epubChapterPath(chapter: BookChapter): String =
    EpubResourcePaths.resolve("", chapter.url) ?: chapter.url

private fun epubReadingSpan(chapter: BookChapter): List<String?> {
    val path = epubChapterPath(chapter)
    val variables = chapter.variableMap
    if (variables["epub.singleFile"] == "true" || variables["epub.range.v1"] != "1" &&
        chapter.startFragmentId == null && chapter.endFragmentId == null) return listOf("whole", path)
    val end = variables["nextUrl"]?.let { EpubNavigationUris.resolve("", it.removePrefix("epub-resource:///")) }
    return listOf("range", path, chapter.startFragmentId, end?.path, end?.fragment)
}
