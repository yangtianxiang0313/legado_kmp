package io.legado.kmp.shared.data.repository

import io.legado.kmp.data.database.schema.Books
import io.legado.kmp.data.database.schema.Chapters
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

internal suspend fun relinkLocalBookFileIfUnchanged(
    database: LegadoDatabase,
    expected: Book,
    expectedChapters: List<BookChapter>,
    variable: String,
    chapters: List<BookChapter>,
    fileModified: Long,
    mapToBook: (Books) -> Book,
): Book? {
    val context = currentCoroutineContext()
    context.ensureActive()
    val expectedReverseToc = expected.config.reverseToc
    val snapshot = expectedChapters.sortedBy { it.index }
    val localChapters = chapters.sortedBy { it.index }
    return database.bookQueries.transactionWithResult(noEnclosing = true) {
        context.ensureActive()
        if (!expected.isLocal) return@transactionWithResult null
        val row = database.bookQueries.selectByBookUrl(expected.bookUrl).executeAsOneOrNull()
        context.ensureActive()
        if (row == null) return@transactionWithResult null
        val latest = mapToBook(row)
        if (!latest.isLocal || !row.matchesRelinkSnapshot(expected) ||
            latest.config.reverseToc != expectedReverseToc
        ) return@transactionWithResult null

        val existing = database.bookChapterQueries.selectByBookUrl(row.book_url).executeAsList()
        context.ensureActive()
        if (existing.size != snapshot.size) return@transactionWithResult null
        existing.forEachIndexed { index, chapter ->
            context.ensureActive()
            if (!chapter.matchesRelinkSnapshot(snapshot[index])) return@transactionWithResult null
        }

        require(localChapters.isNotEmpty()) { "Local chapter list must not be empty" }
        val urls = HashSet<String>()
        localChapters.forEachIndexed { index, chapter ->
            context.ensureActive()
            require(chapter.bookUrl == row.book_url) { "Chapter book URL must match the local book" }
            require(chapter.index == index) { "Chapter indices must be unique and complete from zero" }
            require(chapter.url.isNotBlank() && urls.add(chapter.url)) { "Chapter URLs must be nonblank and unique" }
        }
        require(row.dur_chapter_index in 0L..localChapters.lastIndex.toLong()) {
            "Local reading progress must refer to a chapter"
        }
        if (existing.isNotEmpty()) {
            if (existing.size != localChapters.size) return@transactionWithResult null
            existing.forEachIndexed { index, chapter ->
                context.ensureActive()
                if (!chapter.matchesRelinkSnapshot(localChapters[index])) return@transactionWithResult null
            }
        }

        val updated = row.copy(
            variable = variable,
            total_chapter_num = localChapters.size.toLong(),
            latest_chapter_time = fileModified,
        )
        context.ensureActive()
        database.bookQueries.updateLocalFileBinding(
            variable = updated.variable,
            total_chapter_num = updated.total_chapter_num,
            latest_chapter_time = updated.latest_chapter_time,
            book_url = row.book_url,
        )
        if (existing.isEmpty()) {
            localChapters.forEach { chapter ->
                context.ensureActive()
                database.insertBookChapter(chapter)
            }
        }
        context.ensureActive()
        val persisted = database.bookQueries.selectByBookUrl(row.book_url).executeAsOne()
        check(persisted == updated) { "Local file relink did not persist the expected book state" }
        val result = mapToBook(persisted)
        context.ensureActive()
        result
    }
}

private fun Books.matchesRelinkSnapshot(expected: Book): Boolean =
    book_url == expected.bookUrl && origin == expected.origin && type == expected.type.toLong() &&
        toc_url == expected.tocUrl && name == expected.name && author == expected.author &&
        charset == expected.charset && variable == expected.variable &&
        dur_chapter_title == expected.durChapterTitle && dur_chapter_index == expected.durChapterIndex.toLong() &&
        dur_chapter_pos == expected.durChapterPos.toLong() && dur_chapter_time == expected.durChapterTime

// BookChapter.equals compares URLs only; compare every raw column without narrowing row values.
private fun Chapters.matchesRelinkSnapshot(expected: BookChapter): Boolean =
    url == expected.url && title == expected.title && is_volume == (if (expected.isVolume) 1L else 0L) &&
        base_url == expected.baseUrl && book_url == expected.bookUrl && chapter_index == expected.index.toLong() &&
        is_vip == (if (expected.isVip) 1L else 0L) && is_pay == (if (expected.isPay) 1L else 0L) &&
        resource_url == expected.resourceUrl && tag == expected.tag && word_count == expected.wordCount &&
        start == expected.start && end == expected.end && start_fragment_id == expected.startFragmentId &&
        end_fragment_id == expected.endFragmentId && variable == expected.variable
