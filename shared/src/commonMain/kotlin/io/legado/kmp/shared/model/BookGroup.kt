package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

/**
 * Represents a book group for organizing the bookshelf
 *
 * @property groupId Primary key: Group ID (uses powers of 2 for custom groups, negative IDs for special groups)
 * @property groupName Group name
 * @property cover Cover image URL
 * @property order Display order
 * @property enableRefresh Enable auto-refresh for books in this group
 * @property show Show this group in the bookshelf
 * @property bookSort Sort order for books in this group (-1 means use default)
 */
@Serializable
data class BookGroup(
    val groupId: Long = ID_ALL,
    val groupName: String = "",
    val cover: String? = null,
    val order: Int = 0,
    val enableRefresh: Boolean = true,
    val show: Boolean = true,
    val bookSort: Int = -1
) {
    /**
     * Check if this is a special (system) group
     */
    val isSpecialGroup: Boolean
        get() = groupId < 0

    /**
     * Check if this is a custom user-created group
     */
    val isCustomGroup: Boolean
        get() = groupId >= 0

    /**
     * Check if this is the "All Books" group
     */
    val isAllGroup: Boolean
        get() = groupId == ID_ALL

    /**
     * Check if this is the "Local Books" group
     */
    val isLocalGroup: Boolean
        get() = groupId == ID_LOCAL

    /**
     * Check if this is the "Audio Books" group
     */
    val isAudioGroup: Boolean
        get() = groupId == ID_AUDIO

    /**
     * Check if this is the "Network Books without group" group
     */
    val isNetNoneGroup: Boolean
        get() = groupId == ID_NET_NONE

    /**
     * Check if this is the "Local Books without group" group
     */
    val isLocalNoneGroup: Boolean
        get() = groupId == ID_LOCAL_NONE

    /**
     * Check if this is the "Update Error" group
     */
    val isErrorGroup: Boolean
        get() = groupId == ID_ERROR

    /**
     * Get the real book sort order (use default if -1)
     */
    fun getRealBookSort(defaultSort: Int): Int {
        return if (bookSort < 0) defaultSort else bookSort
    }

    /**
     * Check if this group ID is valid (power of 2 for custom groups)
     */
    fun isValidGroupId(): Boolean {
        if (groupId < 0) return true // Special groups
        // Check if it's a power of 2
        return groupId > 0 && (groupId and (groupId - 1)) == 0L
    }

    /**
     * Check if a book belongs to this group
     */
    fun containsBook(bookGroupId: Long): Boolean {
        return when {
            isAllGroup -> true
            isLocalGroup -> (bookGroupId and BookGroupFlags.LOCAL) != 0L
            isAudioGroup -> (bookGroupId and BookGroupFlags.AUDIO) != 0L
            isCustomGroup -> (bookGroupId and groupId) != 0L
            else -> false
        }
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BookGroup) return false
        return groupId == other.groupId
                && groupName == other.groupName
                && cover == other.cover
                && bookSort == other.bookSort
                && enableRefresh == other.enableRefresh
                && show == other.show
                && order == other.order
    }

    override fun hashCode(): Int {
        var result = groupId.hashCode()
        result = 31 * result + groupName.hashCode()
        result = 31 * result + (cover?.hashCode() ?: 0)
        result = 31 * result + bookSort
        result = 31 * result + enableRefresh.hashCode()
        result = 31 * result + show.hashCode()
        result = 31 * result + order
        return result
    }

    companion object {
        // Special group IDs
        const val ID_ROOT = -100L       // Folder-style bookshelf root
        const val ID_ALL = -1L          // All books
        const val ID_LOCAL = -2L        // Local books
        const val ID_AUDIO = -3L        // Audio books
        const val ID_NET_NONE = -4L     // Network books without group
        const val ID_LOCAL_NONE = -5L   // Local books without group
        const val ID_ERROR = -11L       // Books with update error

        /**
         * Get the display name for special groups
         */
        fun getSpecialGroupName(groupId: Long, baseName: String): String {
            return when (groupId) {
                ID_ROOT -> "$baseName (根目录)"
                ID_ALL -> "$baseName (全部)"
                ID_AUDIO -> "$baseName (音频)"
                ID_LOCAL -> "$baseName (本地)"
                ID_NET_NONE -> "$baseName (网络未分组)"
                ID_LOCAL_NONE -> "$baseName (本地未分组)"
                ID_ERROR -> "$baseName (更新失败)"
                else -> baseName
            }
        }

        /**
         * Deserialize BookGroup from database row
         */
        fun from(
            group_id: Long,
            group_name: String,
            cover: String?,
            order: Long,
            enable_refresh: Long,
            show: Long,
            book_sort: Long
        ): BookGroup = BookGroup(
            groupId = group_id,
            groupName = group_name,
            cover = cover,
            order = order.toInt(),
            enableRefresh = enable_refresh == 1L,
            show = show == 1L,
            bookSort = book_sort.toInt()
        )

        /**
         * Create special system groups
         */
        fun createAllGroup(): BookGroup = BookGroup(
            groupId = ID_ALL,
            groupName = "全部",
            order = -10
        )

        fun createLocalGroup(): BookGroup = BookGroup(
            groupId = ID_LOCAL,
            groupName = "本地",
            order = -9,
            enableRefresh = false
        )

        fun createAudioGroup(): BookGroup = BookGroup(
            groupId = ID_AUDIO,
            groupName = "音频",
            order = -8
        )

        fun createNetNoneGroup(): BookGroup = BookGroup(
            groupId = ID_NET_NONE,
            groupName = "网络未分组",
            order = -7
        )

        fun createLocalNoneGroup(): BookGroup = BookGroup(
            groupId = ID_LOCAL_NONE,
            groupName = "本地未分组",
            order = -6,
            show = false
        )

        fun createErrorGroup(): BookGroup = BookGroup(
            groupId = ID_ERROR,
            groupName = "更新失败",
            order = -1
        )
    }
}

/**
 * Book group type flags for bit operations
 */
object BookGroupFlags {
    const val LOCAL = 1L    // Local book type flag
    const val AUDIO = 2L    // Audio book type flag
    const val IMAGE = 4L    // Image book type flag
    const val EPUB = 8L     // EPUB book type flag
    const val UPDATE_ERROR = 16L // Update error flag
}
