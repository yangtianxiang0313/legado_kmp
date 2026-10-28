package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class BookChapterReview(
    val bookId: Long = 0L,
    val chapterId: Long = 0L,
    val summaryUrl: String = "",
)
