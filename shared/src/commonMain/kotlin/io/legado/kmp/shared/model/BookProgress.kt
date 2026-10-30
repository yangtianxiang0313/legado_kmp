package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

/**
 * Snapshot of a book's reading progress used by sync and history flows.
 */
@Serializable
data class BookProgress(
    val name: String,
    val author: String,
    val durChapterIndex: Int,
    val durChapterPos: Int,
    val durChapterTime: Long,
    val durChapterTitle: String? = null
) {
    constructor(book: Book) : this(
        name = book.name,
        author = book.author,
        durChapterIndex = book.durChapterIndex,
        durChapterPos = book.durChapterPos,
        durChapterTime = book.durChapterTime,
        durChapterTitle = book.durChapterTitle
    )
}
