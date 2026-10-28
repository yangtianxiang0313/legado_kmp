package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.MangaPage

/** A prepared chapter; positions count images, never title/loading rows or text offsets. */
data class MangaReaderChapter(
    val book: Book,
    val chapters: List<BookChapter>,
    val chapterIndex: Int,
    val chapterTitle: String,
    val chapterPosition: Int,
    val pages: List<MangaPage>,
    val isVolume: Boolean,
)
