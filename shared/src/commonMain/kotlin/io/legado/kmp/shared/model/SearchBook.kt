package io.legado.kmp.shared.model

/**
 * Represents a book found through search
 * This is an in-memory model used for search results
 *
 * @property bookUrl Unique URL of the book
 * @property origin The book source URL
 * @property originName The name of the book source
 * @property type Book type (audio, text, local, etc.)
 * @property name Book title
 * @property author Book author
 * @property kind Book category/genre
 * @property coverUrl Cover image URL
 * @property intro Book introduction/description
 * @property wordCount Word count
 * @property latestChapterTitle Latest chapter name
 * @property tocUrl Table of contents URL
 * @property time Search result timestamp
 * @property variable Custom variables (JSON string)
 * @property originOrder Sort order from the source
 * @property chapterWordCountText Chapter word count as text
 * @property chapterWordCount Chapter word count
 * @property respondTime Response time in milliseconds
 */
data class SearchBook(
    val bookUrl: String = "",
    val origin: String = "",
    val originName: String = "",
    val type: Int = BookType.TEXT,
    val name: String = "",
    val author: String = "",
    val kind: String? = null,
    val coverUrl: String? = null,
    val intro: String? = null,
    val wordCount: String? = null,
    val latestChapterTitle: String? = null,
    val tocUrl: String = "",
    val time: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val variable: String? = null,
    val originOrder: Int = 0,
    val chapterWordCountText: String? = null,
    val chapterWordCount: Int = -1,
    val respondTime: Int = -1,
    val originExtras: List<String> = emptyList(),
) {
    var infoHtml: String? = null

    var tocHtml: String? = null

    /**
     * Check if this search book is valid
     */
    val isValid: Boolean
        get() = bookUrl.isNotBlank() && name.isNotBlank()

    /**
     * Check if this search book has a cover
     */
    val hasCover: Boolean
        get() = !coverUrl.isNullOrBlank()

    /**
     * Check if this search book has an introduction
     */
    val hasIntro: Boolean
        get() = !intro.isNullOrBlank()

    /**
     * Check if this search book has latest chapter info
     */
    val hasLatestChapter: Boolean
        get() = !latestChapterTitle.isNullOrBlank()

    /**
     * Get the display name for latest chapter
     */
    val displayLatestChapter: String
        get() = latestChapterTitle?.takeIf { it.isNotEmpty() } ?: "无最新章节"

    /**
     * Get the variable map from the JSON string
     */
    val variableMap: Map<String, String>
        get() = parseVariableMap(variable)

    /**
     * Get all origins this book is available from
     */
    val origins: Set<String>
        get() = buildSet {
            if (origin.isNotBlank()) add(origin)
            addAll(originExtras.filter { it.isNotBlank() })
        }

    /**
     * Check if this is a local book type
     */
    val isLocal: Boolean
        get() = type and BookType.LOCAL != 0 || type == BookType.LEGACY_LOCAL

    /**
     * Check if this is an audio book type
     */
    val isAudio: Boolean
        get() = type and BookType.AUDIO != 0 || type == BookType.LEGACY_AUDIO

    /**
     * Check if this is a text book type
     */
    val isText: Boolean
        get() = type and BookType.TEXT != 0 || type == BookType.LEGACY_TEXT

    /**
     * Primary identifier for this search result
     */
    val primaryId: String
        get() = "$origin::$bookUrl"

    /**
     * Add an origin to this search book
     * Returns a new copy with the updated origin
     */
    fun withOrigin(origin: String): SearchBook {
        return copy(origin = origin)
    }

    fun mergeOrigin(newOrigin: String): SearchBook {
        val merged = origins.toMutableList()
        if (newOrigin.isNotBlank() && newOrigin !in merged) {
            merged += newOrigin
        }
        val primary = merged.firstOrNull().orEmpty()
        return copy(
            origin = primary,
            originExtras = merged.drop(1),
        )
    }

    /**
     * Convert to Book model
     */
    fun toBook(): Book = Book(
        bookUrl = bookUrl,
        name = name,
        author = author,
        kind = kind,
        coverUrl = coverUrl,
        intro = intro,
        wordCount = wordCount,
        latestChapterTitle = latestChapterTitle,
        tocUrl = tocUrl,
        origin = origin,
        originName = originName,
        type = type,
        originOrder = originOrder,
        variable = variable
    ).apply {
        infoHtml = this@SearchBook.infoHtml
        tocHtml = this@SearchBook.tocHtml
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is SearchBook) return false
        return bookUrl == other.bookUrl
    }

    override fun hashCode(): Int {
        return bookUrl.hashCode()
    }

    /**
     * Convert from Book model
     */
    companion object {
        fun fromBook(book: Book): SearchBook = SearchBook(
            bookUrl = book.bookUrl,
            name = book.name,
            author = book.author,
            kind = book.kind,
            coverUrl = book.coverUrl,
            intro = book.intro,
            wordCount = book.wordCount,
            latestChapterTitle = book.latestChapterTitle,
            tocUrl = book.tocUrl,
            origin = book.origin,
            originName = book.originName,
            type = book.type,
            originOrder = book.originOrder,
            variable = book.variable,
            time = io.legado.kmp.shared.util.currentTimeMillis()
        ).apply {
            infoHtml = book.infoHtml
            tocHtml = book.tocHtml
        }
    }
}

/**
 * Compare search books by origin order
 */
fun SearchBook.compareTo(other: SearchBook): Int {
    return other.originOrder - this.originOrder
}

/**
 * Check if two search books are the same (by bookUrl)
 */
fun SearchBook.isSameBook(other: SearchBook?): Boolean {
    return other != null && this.bookUrl == other.bookUrl
}

/**
 * Trim intro to a reasonable length
 */
fun SearchBook.trimIntro(maxLength: Int = 200): String {
    val trimmed = intro?.trim()
    return if (trimmed.isNullOrEmpty()) {
        "暂无简介"
    } else {
        if (trimmed.length <= maxLength) trimmed
        else trimmed.take(maxLength) + "..."
    }
}
