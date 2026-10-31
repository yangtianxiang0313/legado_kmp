package io.legado.kmp.shared.domain.localbook

import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.util.md5Hex

/** Pure directory identity helpers; no repository reads, cache migration or persistence. */
object TxtChapterIdentity {
    /**
     * With no old directory, preserve the parser's legacy URLs for import compatibility.
     * Retain URLs only for unique old/new physical spans with the same title and reading markers.
     * When rebuilding an existing directory, new or ambiguous spans use deterministic range URLs.
     * Old chapters without valid offsets cannot identify a newly parsed chapter.
     */
    fun retain(
        previous: List<BookChapter>,
        chapters: List<BookChapter>,
        checkActive: () -> Unit
    ): List<BookChapter> {
        checkActive()
        if (previous.isEmpty()) return chapters
        val oldUrls = mutableSetOf<String>()
        val oldByIdentity = mutableMapOf<Identity, MutableList<BookChapter>>()
        for (chapter in previous) {
            checkActive()
            require(oldUrls.add(chapter.url)) { "TXT 原目录包含重复章节标识" }
            identityOf(chapter)?.let { identity ->
                oldByIdentity.getOrPut(identity) { mutableListOf() }.add(chapter)
            }
        }
        val identities = chapters.map { chapter ->
            checkActive()
            requireNotNull(identityOf(chapter)) { "TXT 章节正文范围无效" }
        }
        val counts = mutableMapOf<Identity, Int>()
        for (identity in identities) {
            checkActive()
            counts[identity] = (counts[identity] ?: 0) + 1
        }
        val usedUrls = mutableSetOf<String>()
        val retained = chapters.mapIndexed { index, chapter ->
            checkActive()
            val identity = identities[index]
            val old = oldByIdentity[identity]?.singleOrNull()?.takeIf { counts[identity] == 1 }
            val url = old?.url?.takeIf { it.isNotBlank() } ?: newAddress(identity, index)
            check(usedUrls.add(url)) { "TXT 目录包含重复章节标识" }
            chapter.copy(url = url)
        }
        checkActive()
        return retained
    }

    /** Unlike BookChapter.equals, compares every physical reading boundary and volume/fragment marker. */
    fun sameReadingSpan(previous: BookChapter, next: BookChapter): Boolean {
        val old = spanOf(previous) ?: return false
        return old == spanOf(next)
    }

    private fun identityOf(chapter: BookChapter): Identity? =
        spanOf(chapter)?.let { Identity(it, chapter.title) }

    private fun spanOf(chapter: BookChapter): ReadingSpan? {
        val start = chapter.start ?: return null
        val end = chapter.end ?: return null
        if (start < 0 || end < start) return null
        return ReadingSpan(start, end, chapter.isVolume, chapter.startFragmentId, chapter.endFragmentId)
    }

    private fun newAddress(identity: Identity, ordinal: Int): String {
        val span = identity.span
        val fingerprint = buildString {
            append(identity.title.length).append(':').append(identity.title)
            for (fragment in listOf(span.startFragmentId, span.endFragmentId)) {
                if (fragment == null) append("-:") else append(fragment.length).append(':').append(fragment)
            }
        }.md5Hex()
        return "txt:range:${span.start}:${span.end}:${if (span.volume) 1 else 0}:$ordinal:$fingerprint"
    }

    private data class Identity(val span: ReadingSpan, val title: String)

    private data class ReadingSpan(
        val start: Long,
        val end: Long,
        val volume: Boolean,
        val startFragmentId: String?,
        val endFragmentId: String?
    )
}
