package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.util.md5Hex

internal data class MobiReadingSpan(val start: Long, val end: Long, val volume: Boolean) {
    companion object {
        fun of(chapter: BookChapter): MobiReadingSpan {
            val start = requireNotNull(chapter.start) { "MOBI 章节缺少正文起点" }
            val end = requireNotNull(chapter.end) { "MOBI 章节缺少正文终点" }
            require(start in 0..64L * 1024 * 1024 && end in start..64L * 1024 * 1024) {
                "MOBI 章节正文范围无效"
            }
            return MobiReadingSpan(start, end, chapter.isVolume)
        }
    }
}

internal fun Book.isMobiLocalBook(): Boolean = isLocal &&
    LocalBookFileBinding.format(this) in setOf("mobi", "azw", "azw3")

/** An index in a legacy URL is an identity, not the current position after a directory reorder. */
internal object MobiChapterIdentity {
    private val legacy = Regex("mobi:([0-9]{1,5}):filepos:([0-9]{1,8})")
    private val range = Regex("mobi:range:([0-9]{1,8}):([0-9]{1,8}):[01]:[0-9]{1,5}:[0-9a-f]{32}")

    fun accepts(chapter: BookChapter): Boolean {
        val span = MobiReadingSpan.of(chapter)
        legacy.matchEntire(chapter.url)?.let {
            return it.groupValues[1].toInt() < 50000 && it.groupValues[2].toLong() == span.start
        }
        val match = range.matchEntire(chapter.url) ?: return false
        return match.groupValues[1].toLong() == span.start && match.groupValues[2].toLong() == span.end
    }

    fun newAddress(chapter: BookChapter, ordinal: Int): String {
        val span = MobiReadingSpan.of(chapter)
        return "mobi:range:${span.start}:${span.end}:${if (span.volume) 1 else 0}:$ordinal:${chapter.title.md5Hex()}"
    }

    fun retain(previous: List<BookChapter>, chapters: List<BookChapter>, checkActive: () -> Unit): List<BookChapter> {
        require(previous.map { it.url }.toSet().size == previous.size) { "MOBI 原目录包含重复章节标识" }
        val oldBySpan = previous.groupBy {
            checkActive()
            MobiReadingSpan.of(it)
        }
        val oldByName = previous.groupBy {
            checkActive()
            MobiReadingSpan.of(it) to it.title
        }
        val newBySpan = chapters.groupBy {
            checkActive()
            MobiReadingSpan.of(it)
        }
        val used = mutableSetOf<String>()
        return chapters.mapIndexed { index, chapter ->
            checkActive()
            val span = MobiReadingSpan.of(chapter)
            val candidates = oldBySpan[span].orEmpty()
            val named = oldByName[span to chapter.title].orEmpty()
            val old = named.singleOrNull() ?: candidates.singleOrNull()?.takeIf { newBySpan[span]?.size == 1 }
            val url = old?.url?.takeIf { accepts(old) && it !in used } ?: newAddress(chapter, index)
            check(used.add(url)) { "MOBI 目录包含重复章节标识" }
            chapter.copy(url = url)
        }
    }
}
