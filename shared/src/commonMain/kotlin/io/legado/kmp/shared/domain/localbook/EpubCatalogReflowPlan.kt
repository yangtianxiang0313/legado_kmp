package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.BookType
import io.legado.kmp.shared.model.ReadConfig

public data class EpubReflowLocation(
    val chapterIndex: Int,
    val chapterPosition: Int,
    val chapterTitle: String,
)

/** An immutable, archive-independent proof prepared before the catalog transaction. */
public class EpubCatalogReflowPlan internal constructor(
    private val signature: EpubReflowSignature,
    private val sources: Map<Int, EpubReflowSource>,
    private val regions: List<EpubReflowRegion>,
) {
    public fun mapLocation(chapterIndex: Int, chapterPosition: Int): EpubReflowLocation? {
        if (chapterPosition < 0) return null
        val source = sources[chapterIndex] ?: return null
        source.identity?.let {
            return EpubReflowLocation(it.chapterIndex, chapterPosition, it.chapterTitle)
        }
        val projection = source.projection ?: return null
        if (chapterPosition > projection.textLength) return null
        val region = regions.getOrNull(source.region) ?: return null
        val ordinal = projection.offsets.lowerBound(chapterPosition)
        val coordinate = projection.visibleStart + ordinal
        val whitespaceToNext = (projection.offsets.getOrNull(ordinal) ?: projection.textLength) - chapterPosition
        // Upper bound deliberately selects the following chapter at an exact boundary.
        var low = 0
        var high = region.targets.size
        while (low < high) {
            val middle = low + (high - low) / 2
            if (region.targets[middle].start <= coordinate) low = middle + 1 else high = middle
        }
        val target = region.targets.getOrNull(low - 1) ?: return null
        if (coordinate > target.end) return null
        target.identity?.let { identity ->
            return if (coordinate == target.start) identity else null
        }
        val destination = target.projection ?: return null
        val offset = coordinate - destination.visibleStart
        var position = when {
            offset <= 0 -> 0
            offset < destination.offsets.size -> destination.offsets[offset]
            offset == destination.offsets.size -> destination.textLength
            else -> return null
        }
        if (whitespaceToNext > 0 && offset >= 0) {
            val previous = destination.offsets.getOrNull(offset - 1)
            // Keep a point inside the corresponding whitespace gap, without entering a removed title.
            position = maxOf((previous?.plus(1) ?: 0), position - whitespaceToNext)
        }
        return EpubReflowLocation(target.chapterIndex, position, target.chapterTitle)
    }

    internal fun matches(
        current: Book,
        replacement: Book,
        previous: List<BookChapter>,
        chapters: List<BookChapter>,
    ): Boolean = signature.matches(current, replacement, previous, chapters)
}

internal data class EpubReflowText(val content: String, val displayTitle: String)

internal class EpubReflowProjection(
    val visibleStart: Int,
    val textLength: Int,
    val offsets: IntArray,
)

internal class EpubReflowSource(
    val identity: EpubReflowLocation? = null,
    val region: Int = -1,
    val projection: EpubReflowProjection? = null,
)

internal class EpubReflowTarget(
    val start: Int,
    val end: Int,
    val chapterIndex: Int,
    val chapterTitle: String,
    val identity: EpubReflowLocation? = null,
    val projection: EpubReflowProjection? = null,
)

internal class EpubReflowRegion(val targets: List<EpubReflowTarget>)

internal fun IntArray.lowerBound(value: Int): Int {
    var low = 0
    var high = size
    while (low < high) {
        val middle = low + (high - low) / 2
        if (this[middle] < value) low = middle + 1 else high = middle
    }
    return low
}

internal class EpubReflowSignature(
    current: Book,
    replacement: Book,
    previous: List<BookChapter>,
    chapters: List<BookChapter>,
) {
    private val currentBook = BookSignature(current)
    private val replacementBook = BookSignature(replacement)
    private val oldChapters = previous.map { it.copy() }
    private val newChapters = chapters.map { it.copy() }

    fun matches(current: Book, replacement: Book, previous: List<BookChapter>, chapters: List<BookChapter>): Boolean =
        currentBook == BookSignature(current) && replacementBook == BookSignature(replacement) &&
            sameChapters(oldChapters, previous) && sameChapters(newChapters, chapters)

    private class BookSignature(book: Book) {
        private val bookUrl = book.bookUrl
        private val tocUrl = book.tocUrl
        private val origin = book.origin
        private val originName = book.originName
        private val name = book.name
        private val author = book.author
        private val charset = book.charset
        private val type = book.type and BookType.NOT_SHELF.inv()
        private val variable = book.variable
        private val config: ReadConfig? = book.readConfig?.copy()

        override fun equals(other: Any?): Boolean = other is BookSignature &&
            bookUrl == other.bookUrl && tocUrl == other.tocUrl && origin == other.origin &&
            originName == other.originName && name == other.name && author == other.author &&
            charset == other.charset && type == other.type && variable == other.variable && config == other.config

        override fun hashCode(): Int = bookUrl.hashCode()
    }

    private fun sameChapters(left: List<BookChapter>, right: List<BookChapter>): Boolean =
        left.size == right.size && left.indices.all { index ->
            val a = left[index]
            val b = right[index]
            // BookChapter.equals intentionally compares URL only; it cannot validate a proof.
            a.url == b.url && a.title == b.title && a.isVolume == b.isVolume && a.baseUrl == b.baseUrl &&
                a.bookUrl == b.bookUrl && a.index == b.index && a.isVip == b.isVip && a.isPay == b.isPay &&
                a.resourceUrl == b.resourceUrl && a.tag == b.tag && a.wordCount == b.wordCount &&
                a.start == b.start && a.end == b.end && a.startFragmentId == b.startFragmentId &&
                a.endFragmentId == b.endFragmentId && a.variable == b.variable
        }
}
