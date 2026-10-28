package io.legado.kmp.shared.model

import kotlinx.datetime.Instant
import kotlinx.serialization.Serializable

/**
 * Represents a bookmark in a book
 * Stores user bookmarks with position information and optional notes
 *
 * @property time The timestamp when the bookmark was created (primary key)
 * @property bookName The name of the book
 * @property bookAuthor The author of the book
 * @property chapterIndex The index of the chapter where the bookmark is placed
 * @property chapterPos The character position within the chapter
 * @property chapterName The name of the chapter
 * @property bookText Text snippet around the bookmark position
 * @property content User's note content for this bookmark
 */
@Serializable
data class Bookmark(
    val time: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val bookName: String = "",
    val bookAuthor: String = "",
    val chapterIndex: Int = 0,
    val chapterPos: Int = 0,
    val chapterName: String = "",
    val bookText: String = "",
    val content: String = ""
) {
    companion object {
        /**
         * Create a Bookmark from SQLDelight generated mapping
         * This factory method is used by the repository to convert database results
         */
        fun from(
            time: Long,
            book_name: String,
            book_author: String,
            chapter_index: Long,
            chapter_pos: Long,
            chapter_name: String,
            book_text: String,
            content: String
        ): Bookmark = Bookmark(
            time = time,
            bookName = book_name,
            bookAuthor = book_author,
            chapterIndex = chapter_index.toInt(),
            chapterPos = chapter_pos.toInt(),
            chapterName = chapter_name,
            bookText = book_text,
            content = content
        )
    }
}

/**
 * Extension to convert Bookmark to SQLDelight parameter map
 * Used for insert and update operations
 */
fun Bookmark.toInsertMap(): Map<String, Any?> = mapOf(
    "time" to time,
    "book_name" to bookName,
    "book_author" to bookAuthor,
    "chapter_index" to chapterIndex.toLong(),
    "chapter_pos" to chapterPos.toLong(),
    "chapter_name" to chapterName,
    "book_text" to bookText,
    "content" to content
)

/**
 * Check if this bookmark belongs to a specific book
 */
fun Bookmark.belongsToBook(bookName: String, bookAuthor: String): Boolean {
    return this.bookName == bookName && this.bookAuthor == bookAuthor
}

/**
 * Check if this bookmark has a user note
 */
val Bookmark.hasNote: Boolean
    get() = content.isNotBlank()

/**
 * Get the instant representation of the bookmark time
 */
val Bookmark.instant: Instant
    get() = Instant.fromEpochMilliseconds(time)

/**
 * Check if this bookmark is valid (has basic required information)
 */
val Bookmark.isValid: Boolean
    get() = bookName.isNotBlank() && chapterIndex >= 0
