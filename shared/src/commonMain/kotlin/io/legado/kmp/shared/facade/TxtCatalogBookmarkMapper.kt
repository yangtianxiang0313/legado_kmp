package io.legado.kmp.shared.facade

import io.legado.kmp.shared.domain.localbook.LocalBookByteSource
import io.legado.kmp.shared.domain.localbook.TxtBookParser
import io.legado.kmp.shared.domain.localbook.TxtSourceSpan
import io.legado.kmp.shared.domain.repository.TxtCatalogBookmarkLocation
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.Bookmark

/** Computes locations only; callers own source lifetime, cache validation and the atomic write. */
class TxtCatalogBookmarkMapper(
    private val source: LocalBookByteSource,
    private val parser: TxtBookParser,
    private val current: Book,
    private val replacement: Book,
    private val previous: List<BookChapter>,
    private val chapters: List<BookChapter>,
    private val process: suspend (Book, BookChapter, String) -> String,
    private val displayTitle: suspend (BookChapter) -> String,
    private val checkActive: () -> Unit,
) {
    suspend fun map(bookmarks: List<Bookmark>): List<TxtCatalogBookmarkLocation> {
        checkActive()
        if (bookmarks.isEmpty()) return emptyList()
        return Mapping().map(bookmarks)
    }

    private inner class Mapping {
        private val oldByIndex = HashMap<Int, BookChapter>()
        private val oldCounts = HashMap<Identity, Int>()
        private val newByIdentity = HashMap<Identity, BookChapter>()
        private val newCounts = HashMap<Identity, Int>()
        private val titles = HashMap<Int, String>()
        private var targets: List<BookChapter>? = null
        // Single-entry caches bound retained text independently of the number of bookmarks.
        private var oldProjection: Pair<Int, Projection>? = null
        private var newProjection: Pair<Int, Projection>? = null

        init {
            for (chapter in previous) {
                checkActive()
                require(chapter.index >= 0 && oldByIndex.put(chapter.index, chapter) == null) {
                    "TXT original chapter indices are ambiguous"
                }
                identity(chapter)?.let { oldCounts[it] = (oldCounts[it] ?: 0) + 1 }
            }
            val indices = HashSet<Int>()
            for (chapter in chapters) {
                checkActive()
                require(chapter.index >= 0 && indices.add(chapter.index)) { "TXT target chapter indices are ambiguous" }
                identity(chapter)?.let {
                    newCounts[it] = (newCounts[it] ?: 0) + 1
                    newByIdentity[it] = chapter
                }
            }
        }

        suspend fun map(bookmarks: List<Bookmark>): List<TxtCatalogBookmarkLocation> {
            val times = HashSet<Long>()
            val result = ArrayList<TxtCatalogBookmarkLocation>(bookmarks.size)
            for (bookmark in bookmarks) {
                checkActive()
                require(times.add(bookmark.time)) { "TXT bookmark timestamps are ambiguous" }
                require(bookmark.chapterPos >= 0) { "TXT bookmark position must not be negative" }
                val old = requireNotNull(oldByIndex[bookmark.chapterIndex]) { "TXT bookmark original chapter is missing" }
                val key = requireNotNull(identity(old)) { "TXT bookmark original physical span is invalid" }
                val unchanged = newByIdentity[key]?.takeIf { oldCounts[key] == 1 && newCounts[key] == 1 }
                val target: BookChapter
                val position: Int
                if (unchanged != null) {
                    // No body read: edited cache content remains addressed by the retained chapter URL.
                    target = unchanged
                    position = bookmark.chapterPos
                } else {
                    val from = projection(old, old = true)
                    val coordinate = from.processed.coordinate(bookmark.chapterPos)
                    val directPosition = from.direct.position(
                        from.suffixStart + coordinate.ordinal, coordinate.whitespaceToNext,
                        minimumPosition = from.rawSourceStart,
                    )
                    val byteOffset = from.span.byteOffset(directPosition)
                    target = targetAt(byteOffset)
                    val to = projection(target, old = false)
                    val targetPosition = to.span.sourcePosition(byteOffset)
                    position = if (targetPosition < to.rawSourceStart) {
                        0
                    } else {
                        val directCoordinate = to.direct.coordinate(targetPosition)
                        if (directCoordinate.ordinal < to.suffixStart) 0 else {
                            to.processed.position(
                                directCoordinate.ordinal - to.suffixStart, directCoordinate.whitespaceToNext,
                            )
                        }
                    }
                }
                checkActive()
                val title = titles[target.index] ?: displayTitle(target).also {
                    checkActive()
                    titles[target.index] = it
                }
                result.add(TxtCatalogBookmarkLocation(bookmark.time, target.index, position, title))
            }
            checkActive()
            return result
        }

        private suspend fun projection(chapter: BookChapter, old: Boolean): Projection {
            val cached = if (old) oldProjection else newProjection
            if (cached != null && cached.first == chapter.index) return cached.second
            // Do not accumulate full-span projections across chapters.
            if (old) oldProjection = null else newProjection = null
            val book = if (old) current else replacement
            val other = if (old) replacement else current
            val charset = requireNotNull(book.charset?.takeIf { it.isNotBlank() }
                ?: other.charset?.takeIf { it.isNotBlank() }) { "TXT bookmark source charset is not known" }
            val key = requireNotNull(identity(chapter)) { "TXT bookmark chapter physical span is invalid" }
            val span = TxtSourceSpan(source, charset, key.start, key.end, checkActive)
            val raw = parser.readSourceContent(source, chapter, charset, checkActive)
            requireTextBudget(raw)
            val processed = process(book, chapter, raw)
            checkActive()
            requireTextBudget(processed)
            val rawIndex = ReaderSearchTextIndex.create(raw, checkActive)
            val processedText = IndexedText(processed)
            requireEqual(rawIndex.normalizedText, processedText.index.normalizedText)
            val direct = IndexedText(span.content)
            val suffixStart = direct.index.normalizedText.length - rawIndex.normalizedText.length
            require(suffixStart >= 0) { "TXT reader body is not a suffix of its original source span" }
            requireEqual(rawIndex.normalizedText, direct.index.normalizedText, suffixStart)
            require(TxtSourceSpan.isBoundary(direct.index.normalizedText, suffixStart)) {
                "TXT reader body suffix splits a surrogate pair"
            }
            // This is substringAfter's exact prefix, not a title/sentence search for a bookmark.
            checkActive()
            val titleStart = span.content.indexOf(chapter.title)
            checkActive()
            val rawStart = if (titleStart >= 0) titleStart + chapter.title.length else 0
            require(TxtSourceSpan.isBoundary(span.content, rawStart)) { "TXT removed title splits a surrogate pair" }
            return Projection(span, direct, processedText, suffixStart, rawStart).also {
                if (old) oldProjection = chapter.index to it else newProjection = chapter.index to it
            }
        }

        private fun targetAt(byteOffset: Long): BookChapter {
            val physical = targets ?: physicalTargets().also { targets = it }
            require(physical.isNotEmpty()) { "TXT target catalog has no nonempty physical spans" }
            if (byteOffset == source.size) {
                return physical.last().also {
                    require(it.end == source.size) { "TXT target catalog does not cover EOF" }
                }
            }
            // Upper bound selects the following physical span at a shared boundary, regardless of TOC order.
            var low = 0
            var high = physical.size
            while (low < high) {
                checkActive()
                val middle = low + (high - low) / 2
                if (physical[middle].start!! <= byteOffset) low = middle + 1 else high = middle
            }
            val target = requireNotNull(physical.getOrNull(low - 1)) { "TXT bookmark precedes the target physical catalog" }
            require(byteOffset < target.end!!) { "TXT bookmark falls in a gap in the target physical catalog" }
            return target
        }

        private fun physicalTargets(): List<BookChapter> {
            val physical = ArrayList<BookChapter>()
            for (chapter in chapters) {
                checkActive()
                val key = requireNotNull(identity(chapter)) { "TXT target physical span is invalid" }
                if (key.start < key.end) physical.add(chapter)
            }
            physical.sortWith(Comparator { left, right ->
                checkActive()
                left.start!!.compareTo(right.start!!)
            })
            var previousEnd = -1L
            for (chapter in physical) {
                checkActive()
                require(chapter.start!! >= previousEnd) { "TXT target physical spans overlap or are ambiguous" }
                previousEnd = chapter.end!!
            }
            return physical
        }
    }

    private inner class IndexedText(val content: String) {
        val index = ReaderSearchTextIndex.create(content, checkActive)

        fun coordinate(position: Int): Coordinate {
            require(position in 0..content.length && TxtSourceSpan.isBoundary(content, position)) {
                "TXT bookmark position is outside the reader body or splits a surrogate pair"
            }
            var low = 0
            var high = index.normalizedText.length
            while (low < high) {
                checkActive()
                val middle = low + (high - low) / 2
                if (index.sourcePosition(middle)!! < position) low = middle + 1 else high = middle
            }
            val anchor = index.sourcePosition(low) ?: content.length
            require(TxtSourceSpan.isBoundary(index.normalizedText, low)) {
                "TXT visible bookmark ordinal splits a surrogate pair"
            }
            requireWhitespace(position, anchor)
            return Coordinate(low, anchor - position)
        }

        fun position(ordinal: Int, whitespaceToNext: Int, minimumPosition: Int = 0): Int {
            require(ordinal in 0..index.normalizedText.length && whitespaceToNext >= 0 &&
                TxtSourceSpan.isBoundary(index.normalizedText, ordinal)
            ) { "TXT visible bookmark ordinal is invalid or splits a surrogate pair" }
            val anchor = index.sourcePosition(ordinal) ?: content.length
            require(minimumPosition in 0..anchor) { "TXT body projection precedes its exact reader prefix" }
            val previousEnd = if (ordinal > 0) index.sourcePosition(ordinal - 1)!! + 1 else 0
            val position = maxOf(minimumPosition, previousEnd, anchor - whitespaceToNext)
            require(TxtSourceSpan.isBoundary(content, position)) { "TXT whitespace projection splits a surrogate pair" }
            requireWhitespace(position, anchor)
            return position
        }

        private fun requireWhitespace(start: Int, end: Int) {
            for (position in start until end) {
                if (position % 4096 == 0) checkActive()
                require(content[position].isWhitespace()) {
                    "TXT bookmark falls inside hidden markup rather than a provable whitespace gap"
                }
            }
        }
    }

    private fun identity(chapter: BookChapter): Identity? {
        val start = chapter.start ?: return null
        val end = chapter.end ?: return null
        if (start < 0 || end < start || end > source.size) return null
        return Identity(start, end, chapter.title)
    }

    private fun requireTextBudget(content: String) {
        checkActive()
        require(content.length <= TxtSourceSpan.MAX_TEXT_UNITS) {
            "TXT bookmark reader body exceeds the 4 Mi UTF-16 unit limit"
        }
    }

    private fun requireEqual(actual: String, expected: String, start: Int = 0) {
        checkActive()
        require(start >= 0 && actual.length == expected.length - start) {
            "TXT bookmark cannot be preserved: normalized reader body changed or is not an exact source suffix"
        }
        for (index in actual.indices) {
            if (index % 4096 == 0) checkActive()
            require(actual[index] == expected[start + index]) {
                "TXT bookmark cannot be preserved: non-whitespace reader content changed; no approximate diff is allowed"
            }
        }
        checkActive()
    }

    private data class Identity(val start: Long, val end: Long, val title: String)
    private data class Coordinate(val ordinal: Int, val whitespaceToNext: Int)
    private class Projection(
        val span: TxtSourceSpan,
        val direct: IndexedText,
        val processed: IndexedText,
        val suffixStart: Int,
        val rawSourceStart: Int,
    )
}
