package io.legado.kmp.shared.data.repository

import io.legado.kmp.data.database.schema.Bookmarks
import io.legado.kmp.data.database.schema.Books
import io.legado.kmp.data.database.schema.Chapters
import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.domain.repository.TxtCatalogBookmarkLocation
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.Bookmark
import io.legado.kmp.shared.model.ReadConfig
import io.legado.kmp.shared.model.isTxtLocalBook
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json

private val txtCatalogConfigJson = Json { ignoreUnknownKeys = true }

internal suspend fun replaceTxtBookCatalogIfUnchanged(
    database: LegadoDatabase,
    expected: Book,
    expectedChapters: List<BookChapter>,
    replacement: Book,
    chapters: List<BookChapter>,
    expectedBookmarks: List<Bookmark>,
    bookmarkLocations: List<TxtCatalogBookmarkLocation>,
    mapToBook: (Books) -> Book,
): Book? {
    val context = currentCoroutineContext()
    context.ensureActive()
    val expectedConfig = expected.config.copy()
    val snapshot = expectedChapters.sortedBy { it.index }
    val localChapters = chapters.sortedBy { it.index }
    val bookmarkSnapshot = expectedBookmarks.toList()
    val locations = bookmarkLocations.toList()
    return database.bookQueries.transactionWithResult(noEnclosing = true) {
        context.ensureActive()
        if (!expected.isLocal || !expected.isTxtLocalBook) return@transactionWithResult null
        val row = database.bookQueries.selectByBookUrl(expected.bookUrl).executeAsOneOrNull()
        context.ensureActive()
        if (row == null || !row.matchesTxtCatalogSnapshot(expected)) return@transactionWithResult null
        val latest = mapToBook(row)
        if (!latest.isLocal || !latest.isTxtLocalBook || !row.matchesTxtCatalogConfig(expectedConfig)) {
            return@transactionWithResult null
        }

        val existing = database.bookChapterQueries.selectByBookUrl(row.book_url).executeAsList()
        context.ensureActive()
        if (existing.size != snapshot.size) return@transactionWithResult null
        existing.forEachIndexed { index, chapter ->
            context.ensureActive()
            if (!chapter.matchesTxtCatalogSnapshot(snapshot[index])) return@transactionWithResult null
        }

        val expectedByTime = HashMap<Long, Bookmark>()
        bookmarkSnapshot.forEach { bookmark ->
            context.ensureActive()
            require(bookmark.bookName == row.name && bookmark.bookAuthor == row.author) {
                "Expected bookmarks must belong to the same name and author"
            }
            require(expectedByTime.put(bookmark.time, bookmark) == null) { "Expected bookmark times must be unique" }
        }
        val bookmarks = database.bookmarkQueries.selectByBook(row.name, row.author).executeAsList()
        context.ensureActive()
        if (bookmarks.size != expectedByTime.size) return@transactionWithResult null
        bookmarks.forEach { bookmark ->
            context.ensureActive()
            val original = expectedByTime[bookmark.time] ?: return@transactionWithResult null
            if (!bookmark.matchesTxtCatalogSnapshot(original)) return@transactionWithResult null
        }

        require(replacement.bookUrl.isNotBlank() && replacement.bookUrl == row.book_url &&
            replacement.origin == row.origin && replacement.originName == row.origin_name &&
            replacement.type.toLong() == row.type && replacement.name == row.name && replacement.author == row.author
        ) { "TXT catalog replacement must retain the book identity" }
        require(localChapters.isNotEmpty()) { "TXT chapter list must not be empty" }
        require(replacement.totalChapterNum == localChapters.size) { "Book chapter count must match the chapter list" }
        val urls = HashSet<String>()
        localChapters.forEachIndexed { index, chapter ->
            context.ensureActive()
            require(chapter.bookUrl == row.book_url) { "Chapter book URL must match the logical book URL" }
            require(chapter.index == index) { "Chapter indices must be unique and complete from zero" }
            require(chapter.url.isNotBlank() && urls.add(chapter.url)) { "Chapter URLs must be nonblank and unique" }
        }
        require(replacement.durChapterIndex in localChapters.indices && replacement.durChapterPos >= 0) {
            "TXT reading progress must refer to a chapter and a nonnegative position"
        }
        val locationsByTime = HashMap<Long, TxtCatalogBookmarkLocation>()
        locations.forEach { location ->
            context.ensureActive()
            require(location.time in expectedByTime) { "Bookmark location must refer to an expected bookmark" }
            require(locationsByTime.put(location.time, location) == null) { "Bookmark location times must be unique" }
            require(location.chapterIndex in localChapters.indices && location.chapterPosition >= 0) {
                "Bookmark location must refer to a chapter and a nonnegative position"
            }
        }
        require(locationsByTime.size == expectedByTime.size) { "Every expected bookmark must have a location" }
        val movedBookmarks = bookmarks.mapNotNull { bookmark ->
            context.ensureActive()
            val location = locationsByTime.getValue(bookmark.time)
            if (bookmark.chapter_index == location.chapterIndex.toLong() &&
                bookmark.chapter_pos == location.chapterPosition.toLong() && bookmark.chapter_name == location.chapterTitle
            ) null else bookmark to location
        }
        if (movedBookmarks.isNotEmpty()) {
            val owners = database.bookQueries.selectByExactNameAndAuthor(row.name, row.author).executeAsList()
            context.ensureActive()
            if (owners.singleOrNull()?.book_url != row.book_url) return@transactionWithResult null
        }

        // Copy the raw row and update only catalog columns; never reserialize unrelated state.
        val updated = row.copy(
            toc_url = replacement.tocUrl,
            charset = replacement.charset,
            word_count = replacement.wordCount,
            total_chapter_num = replacement.totalChapterNum.toLong(),
            latest_chapter_title = replacement.latestChapterTitle,
            latest_chapter_time = replacement.latestChapterTime,
            dur_chapter_index = replacement.durChapterIndex.toLong(),
            dur_chapter_title = replacement.durChapterTitle,
            dur_chapter_pos = replacement.durChapterPos.toLong(),
        )
        context.ensureActive()
        database.bookQueries.updateTxtCatalogSelection(
            toc_url = updated.toc_url,
            charset = updated.charset,
            word_count = updated.word_count,
            total_chapter_num = updated.total_chapter_num,
            latest_chapter_title = updated.latest_chapter_title,
            latest_chapter_time = updated.latest_chapter_time,
            dur_chapter_index = updated.dur_chapter_index,
            dur_chapter_title = updated.dur_chapter_title,
            dur_chapter_pos = updated.dur_chapter_pos,
            book_url = row.book_url,
        )
        context.ensureActive()
        database.bookChapterQueries.deleteByBookUrl(row.book_url)
        localChapters.forEach { chapter ->
            context.ensureActive()
            database.insertBookChapter(chapter)
        }
        movedBookmarks.forEach { (bookmark, location) ->
            context.ensureActive()
            database.bookQueries.updateTxtCatalogBookmarkLocation(
                chapter_index = location.chapterIndex.toLong(),
                chapter_pos = location.chapterPosition.toLong(),
                chapter_name = location.chapterTitle,
                time = bookmark.time,
                book_name = bookmark.book_name,
                book_author = bookmark.book_author,
            )
        }
        context.ensureActive()
        val persisted = database.bookQueries.selectByBookUrl(row.book_url).executeAsOne()
        check(persisted == updated) { "TXT catalog selection did not persist the expected book state" }
        val result = mapToBook(persisted)
        context.ensureActive()
        result
    }
}

private fun Books.matchesTxtCatalogSnapshot(expected: Book): Boolean =
    book_url == expected.bookUrl && origin == expected.origin && origin_name == expected.originName &&
        type == expected.type.toLong() && name == expected.name && author == expected.author &&
        charset == expected.charset && toc_url == expected.tocUrl && variable == expected.variable &&
        total_chapter_num == expected.totalChapterNum.toLong() && dur_chapter_title == expected.durChapterTitle &&
        dur_chapter_index == expected.durChapterIndex.toLong() && dur_chapter_pos == expected.durChapterPos.toLong() &&
        dur_chapter_time == expected.durChapterTime

private fun Books.matchesTxtCatalogConfig(expected: ReadConfig): Boolean {
    val raw = read_config
    val config = if (raw.isNullOrBlank()) ReadConfig() else try {
        txtCatalogConfigJson.decodeFromString<ReadConfig>(raw)
    } catch (_: IllegalArgumentException) {
        // ReadConfig.fromJson falls back to defaults, which is not a safe CAS comparison.
        return false
    }
    return config == expected
}

// Domain equality/narrowing cannot detect changed columns in a raw directory snapshot.
private fun Chapters.matchesTxtCatalogSnapshot(expected: BookChapter): Boolean =
    url == expected.url && title == expected.title && is_volume == (if (expected.isVolume) 1L else 0L) &&
        base_url == expected.baseUrl && book_url == expected.bookUrl && chapter_index == expected.index.toLong() &&
        is_vip == (if (expected.isVip) 1L else 0L) && is_pay == (if (expected.isPay) 1L else 0L) &&
        resource_url == expected.resourceUrl && tag == expected.tag && word_count == expected.wordCount &&
        start == expected.start && end == expected.end && start_fragment_id == expected.startFragmentId &&
        end_fragment_id == expected.endFragmentId && variable == expected.variable

private fun Bookmarks.matchesTxtCatalogSnapshot(expected: Bookmark): Boolean =
    time == expected.time && book_name == expected.bookName && book_author == expected.bookAuthor &&
        chapter_index == expected.chapterIndex.toLong() && chapter_pos == expected.chapterPos.toLong() &&
        chapter_name == expected.chapterName && book_text == expected.bookText && content == expected.content
