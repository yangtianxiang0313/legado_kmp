package io.legado.kmp.shared.data.repository

import io.legado.kmp.shared.data.database.LegadoDatabase
import io.legado.kmp.shared.model.BookChapter

internal fun LegadoDatabase.insertBookChapter(chapter: BookChapter) {
    bookChapterQueries.insert(
        url = chapter.url,
        title = chapter.title,
        is_volume = if (chapter.isVolume) 1L else 0L,
        base_url = chapter.baseUrl,
        book_url = chapter.bookUrl,
        chapter_index = chapter.index.toLong(),
        is_vip = if (chapter.isVip) 1L else 0L,
        is_pay = if (chapter.isPay) 1L else 0L,
        resource_url = chapter.resourceUrl,
        tag = chapter.tag,
        word_count = chapter.wordCount,
        start = chapter.start,
        end = chapter.end,
        start_fragment_id = chapter.startFragmentId,
        end_fragment_id = chapter.endFragmentId,
        variable = chapter.variable
    )
}
