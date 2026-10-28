package io.legado.kmp.shared.model

import io.legado.kmp.shared.util.md5Hex
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.encodeToString

/**
 * Represents a book in the library
 *
 * @property bookUrl Detail page URL (for local books, stores full file path) - Primary Key
 * @property tocUrl Table of contents URL
 * @property origin Book source URL (default: local book type)
 * @property originName Book source name or local book file name
 * @property name Book name (from book source)
 * @property author Author name (from book source)
 * @property kind Category info (from book source)
 * @property customTag Category info (user modified)
 * @property coverUrl Cover URL (from book source)
 * @property customCoverUrl Cover URL (user modified)
 * @property intro Introduction (from book source)
 * @property customIntro Introduction (user modified)
 * @property charset Custom character set name (for local books only)
 * @property type Book type (see BookType constants)
 * @property group Custom group index
 * @property latestChapterTitle Latest chapter title
 * @property latestChapterTime Latest chapter title update time
 * @property lastCheckTime Last book info update time
 * @property lastCheckCount Number of new chapters found last time
 * @property totalChapterNum Total chapter count
 * @property durChapterTitle Current chapter title
 * @property durChapterIndex Current chapter index
 * @property durChapterPos Current reading progress (first line character index)
 * @property durChapterTime Last read time (time opening content)
 * @property wordCount Word count
 * @property canUpdate Whether to update book info when refreshing bookshelf
 * @property order Manual sort order
 * @property originOrder Book source sort order
 * @property variable Custom book variable info (for book source rule search)
 * @property readConfig Reading settings
 * @property syncTime Sync time
 */
@Serializable
data class Book(
    val bookUrl: String = "",
    val tocUrl: String = "",
    val origin: String = BookType.LOCAL_TAG,
    val originName: String = "",
    val name: String = "",
    val author: String = "",
    val kind: String? = null,
    val customTag: String? = null,
    val coverUrl: String? = null,
    val customCoverUrl: String? = null,
    val intro: String? = null,
    val customIntro: String? = null,
    val charset: String? = null,
    val type: Int = BookType.TEXT,
    val group: Long = 0,
    val latestChapterTitle: String? = null,
    val latestChapterTime: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val lastCheckTime: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val lastCheckCount: Int = 0,
    val totalChapterNum: Int = 0,
    val durChapterTitle: String? = null,
    val durChapterIndex: Int = 0,
    val durChapterPos: Int = 0,
    val durChapterTime: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val wordCount: String? = null,
    val canUpdate: Boolean = true,
    val order: Int = 0,
    val originOrder: Int = 0,
    val variable: String? = null,
    val readConfig: ReadConfig? = null,
    val syncTime: Long = 0
) {
    @Transient
    var infoHtml: String? = null

    @Transient
    var tocHtml: String? = null

    @Transient
    var downloadUrls: List<String>? = null

    /**
     * Check if this is a local book
     */
    val isLocal: Boolean
        get() {
            return hasType(BookType.LOCAL) ||
                BookType.isLocalOrigin(origin) ||
                type == BookType.LEGACY_LOCAL ||
                type == BookType.LEGACY_EPUB
        }

    /**
     * Check if this is an image book
     */
    val isImage: Boolean
        get() = hasType(BookType.IMAGE) || type == BookType.LEGACY_IMAGE

    /**
     * Check if this is an epub book
     */
    val isEpub: Boolean
        get() {
            val format = type and BookType.NOT_SHELF.inv()
            return format == BookType.EPUB || format == BookType.LEGACY_EPUB
        }

    /**
     * Check if this is an audio book
     */
    val isAudio: Boolean
        get() = hasType(BookType.AUDIO) || type == BookType.LEGACY_AUDIO

    /**
     * Check if this is an online text book (not local, text type).
     * Aligned with legado BookExtensions.isOnLineTxt.
     */
    val isOnLineTxt: Boolean
        get() = !isLocal && (hasType(BookType.TEXT) || type == BookType.LEGACY_TEXT)

    /**
     * Check if this is a web file book (download-only source).
     * Aligned with legado BookExtensions.isWebFile.
     * D036: isWebFile property.
     */
    val isWebFile: Boolean
        get() = hasType(BookType.WEB_FILE) || type == BookType.LEGACY_WEB_FILE

    /**
     * Check if this book is excluded from the bookshelf.
     * Aligned with legado BookExtensions.isNotShelf.
     */
    val isNotShelf: Boolean
        get() = hasType(BookType.NOT_SHELF)

    /**
     * Get the display cover URL (prefer custom cover)
     */
    val displayCoverUrl: String?
        get() = customCoverUrl ?: coverUrl

    /**
     * Get the display intro (prefer custom intro)
     */
    val displayIntro: String?
        get() = customIntro ?: intro

    /**
     * Get the last chapter index
     */
    val lastChapterIndex: Int
        get() = (totalChapterNum - 1).coerceAtLeast(0)

    /**
     * Get unread chapter count
     */
    val unreadChapterCount: Int
        get() = (totalChapterNum - durChapterIndex - 1).coerceAtLeast(0)

    /**
     * Get the read config or create a default one
     */
    val config: ReadConfig
        get() = readConfig ?: ReadConfig()

    /**
     * Parse variable string to map
     */
    val variableMap: Map<String, String>
        get() = parseVariableMap(variable)

    /**
     * Get the author name without special characters
     */
    fun getRealAuthor(): String {
        return author.replace(Regex("[/\\|?]"), "")
    }

    /**
     * Update the reading progress
     */
    fun updateReadingProgress(
        chapterIndex: Int,
        chapterTitle: String?,
        chapterPos: Int = 0
    ): Book {
        return copy(
            lastCheckCount = 0,
            durChapterIndex = chapterIndex,
            durChapterTitle = chapterTitle,
            durChapterPos = chapterPos,
            durChapterTime = io.legado.kmp.shared.util.currentTimeMillis()
        )
    }

    /**
     * Update the latest chapter info
     */
    fun updateLatestChapter(title: String?): Book {
        return copy(
            latestChapterTitle = title,
            latestChapterTime = io.legado.kmp.shared.util.currentTimeMillis()
        )
    }

    /**
     * Check if book can be updated
     */
    fun shouldUpdate(): Boolean {
        return canUpdate && !isLocal
    }

    /**
     * Check if this book equals another by comparing bookUrl
     */
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Book) return false
        return bookUrl == other.bookUrl
    }

    override fun hashCode(): Int {
        return bookUrl.hashCode()
    }

    companion object {
        /**
         * Deserialize Book from database row
         */
        fun from(
            book_url: String,
            toc_url: String,
            origin: String,
            origin_name: String,
            name: String,
            author: String,
            kind: String?,
            custom_tag: String?,
            cover_url: String?,
            custom_cover_url: String?,
            intro: String?,
            custom_intro: String?,
            charset: String?,
            type: Long,
            group: Long,
            latest_chapter_title: String?,
            latest_chapter_time: Long,
            last_check_time: Long,
            last_check_count: Long,
            total_chapter_num: Long,
            dur_chapter_title: String?,
            dur_chapter_index: Long,
            dur_chapter_pos: Long,
            dur_chapter_time: Long,
            word_count: String?,
            can_update: Long,
            order: Long,
            origin_order: Long,
            variable: String?,
            read_config: String?,
            sync_time: Long
        ): Book = Book(
            bookUrl = book_url,
            tocUrl = toc_url,
            origin = origin,
            originName = origin_name,
            name = name,
            author = author,
            kind = kind,
            customTag = custom_tag,
            coverUrl = cover_url,
            customCoverUrl = custom_cover_url,
            intro = intro,
            customIntro = custom_intro,
            charset = charset,
            type = type.toInt(),
            group = group,
            latestChapterTitle = latest_chapter_title,
            latestChapterTime = latest_chapter_time,
            lastCheckTime = last_check_time,
            lastCheckCount = last_check_count.toInt(),
            totalChapterNum = total_chapter_num.toInt(),
            durChapterTitle = dur_chapter_title,
            durChapterIndex = dur_chapter_index.toInt(),
            durChapterPos = dur_chapter_pos.toInt(),
            durChapterTime = dur_chapter_time,
            wordCount = word_count,
            canUpdate = can_update == 1L,
            order = order.toInt(),
            originOrder = origin_order.toInt(),
            variable = variable,
            readConfig = ReadConfig.fromJson(read_config),
            syncTime = sync_time
        )
    }
}

/**
 * Book type constants
 */
object BookType {
    const val LOCAL_TAG = "loc_book"
    const val LEGACY_LOCAL_TAG = "local"
    const val WEBDAV_TAG = "webDav::"

    const val TEXT = 0b1000
    const val UPDATE_ERROR = 0b10000
    const val AUDIO = 0b100000
    const val IMAGE = 0b1000000
    /** Download-only web source. Aligned with legado BookType.webFile = 0b10000000. */
    const val WEB_FILE = 0b10000000
    const val LOCAL = 0b100000000
    const val ARCHIVE = 0b1000000000
    const val NOT_SHELF = 0b100_0000_0000

    /** KMP-only parser discriminator for EPUB local files; legado detects EPUB from file metadata. */
    const val EPUB = LOCAL or TEXT
    const val WEBDAV = LOCAL

    const val LEGACY_LOCAL = 0
    const val LEGACY_TEXT = 1
    const val LEGACY_IMAGE = 2
    const val LEGACY_AUDIO = 3
    const val LEGACY_EPUB = 4
    const val LEGACY_WEB_FILE = 6

    fun isLocalOrigin(origin: String): Boolean {
        val normalizedOrigin = origin.lowercase()
        return normalizedOrigin == LOCAL_TAG ||
            normalizedOrigin == LEGACY_LOCAL_TAG ||
            normalizedOrigin.startsWith(WEBDAV_TAG.lowercase()) ||
            normalizedOrigin.startsWith("$LOCAL_TAG::") ||
            normalizedOrigin.startsWith("$LEGACY_LOCAL_TAG::")
    }
}

private val fileNameRegex = Regex("[\\\\/:*?\"<>|.]")

fun Book.getCacheFolderName(): String {
    val normalized = name.replace(fileNameRegex, "")
    val safePrefix = normalized.take(9)
    val md5 = bookUrl.md5Hex().substring(8, 24)
    return safePrefix + md5
}

/**
 * Check if this book has the same name and author as another book.
 * Aligned with legado BookExtensions.isSameNameAuthor().
 * D048: isSameNameAuthor.
 */
fun Book.isSameNameAuthor(other: Book): Boolean {
    return name == other.name && author == other.author
}

/**
 * Check if the local book file has been modified since last parse.
 * Aligned with legado BookExtensions.isLocalModified().
 * D044: isLocalModified stub — full implementation requires platform file system access.
 * Returns false for non-local books; for local books, the platform layer should override.
 */
fun Book.isLocalModified(): Boolean {
    // Stub: platform layer should compare file last-modified time with latestChapterTime.
    // In KMP commonMain we don't have file system access, so default to false.
    return false
}

/**
 * Get the export file name for this book.
 * Aligned with legado BookExtensions.getExportFileName(suffix).
 * D045: getExportFileName.
 *
 * @param suffix file extension (e.g., "txt", "epub")
 * @return formatted file name
 */
fun Book.getExportFileName(suffix: String): String {
    return "$name 作者：${getRealAuthor()}.$suffix"
}

/**
 * Release cached HTML data (infoHtml and tocHtml) to free memory.
 * Aligned with legado BookExtensions.releaseHtmlData().
 * D049: releaseHtmlData.
 */
fun Book.releaseHtmlData() {
    infoHtml = null
    tocHtml = null
}

/**
 * Type manipulation methods aligned with legado BookExtensions.
 * D039: setType/addType/removeType.
 *
 * Book type is a legado-compatible bitmask; legacy KMP enum values are still
 * recognized by the computed properties above for existing databases.
 */

fun Book.hasType(typeFlag: Int): Boolean = type and typeFlag != 0

/**
 * Set the book type, replacing any previous type.
 * Aligned with legado BookExtensions.setType().
 */
fun Book.withType(newType: Int): Book = copy(type = newType)

/**
 * Add a type flag.
 * Aligned with legado BookExtensions.addType().
 */
fun Book.addType(newType: Int): Book = copy(type = type or newType)

/**
 * Remove a type flag.
 * Aligned with legado BookExtensions.removeType().
 */
fun Book.removeType(typeToRemove: Int): Book {
    return copy(type = type and typeToRemove.inv())
}
