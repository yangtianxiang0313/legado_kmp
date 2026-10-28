package io.legado.kmp.shared.model

import io.legado.kmp.shared.data.adapter.BookSourceAdapter
import io.legado.kmp.shared.model.rule.BookInfoRule
import io.legado.kmp.shared.model.rule.ContentRule
import io.legado.kmp.shared.model.rule.ExploreRule
import io.legado.kmp.shared.model.rule.ReviewRule
import io.legado.kmp.shared.model.rule.SearchRule
import io.legado.kmp.shared.model.rule.TocRule
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Represents a book source (website/app that provides books)
 *
 * @property bookSourceUrl Primary key: Book source URL
 * @property bookSourceName Book source name
 * @property bookSourceGroup Group (comma-separated)
 * @property bookSourceType Type: 0=text, 1=audio, 2=image, 3=file
 * @property bookUrlPattern Detail page URL pattern
 * @property customOrder Manual sort order
 * @property enabled Whether enabled
 * @property enabledExplore Enable discovery/explore
 * @property jsLib JS library
 * @property enabledCookieJar Enable CookieJar auto-save
 * @property concurrentRate Concurrent rate limit
 * @property header HTTP headers (JSON)
 * @property loginUrl Login URL or JS
 * @property loginUi Login UI (JSON)
 * @property loginCheckJs Login check JS
 * @property coverDecodeJs Cover decode JS
 * @property bookSourceComment Comment
 * @property variableComment Variable comment
 * @property lastUpdateTime Last update time (for sorting)
 * @property respondTime Response time (for sorting)
 * @property weight Smart sort weight
 * @property exploreUrl Explore/Discovery URL
 * @property exploreScreen Explore filter rule
 * @property ruleExplore Explore rule
 * @property searchUrl Search URL
 * @property ruleSearch Search rule
 * @property ruleBookInfo Book info rule
 * @property ruleToc Table of contents rule
 * @property ruleContent Content rule
 * @property ruleReview Review rule
 */
@Serializable
data class BookSource(
    val bookSourceUrl: String = "",
    val bookSourceName: String = "",
    val bookSourceGroup: String? = null,
    val bookSourceType: Int = BookSourceType.TEXT,
    val bookUrlPattern: String? = null,
    val customOrder: Int = 0,
    val enabled: Boolean = true,
    val enabledExplore: Boolean = true,
    val jsLib: String? = null,
    val enabledCookieJar: Boolean = true,
    val concurrentRate: String? = null,
    val header: String? = null,
    val loginUrl: String? = null,
    val loginUi: String? = null,
    val loginCheckJs: String? = null,
    val coverDecodeJs: String? = null,
    val bookSourceComment: String? = null,
    val variableComment: String? = null,
    val lastUpdateTime: Long = 0,
    val respondTime: Long = 180000L,
    val weight: Int = 0,
    val exploreUrl: String? = null,
    val exploreScreen: String? = null,
    val ruleExplore: ExploreRule? = null,
    val searchUrl: String? = null,
    val ruleSearch: SearchRule? = null,
    val ruleBookInfo: BookInfoRule? = null,
    val ruleToc: TocRule? = null,
    val ruleContent: ContentRule? = null,
    val ruleReview: ReviewRule? = null
) {
    /**
     * Check if this is a text book source
     */
    val isText: Boolean
        get() = bookSourceType == BookSourceType.TEXT

    /**
     * Check if this is an audio book source
     */
    val isAudio: Boolean
        get() = bookSourceType == BookSourceType.AUDIO

    /**
     * Check if this is an image book source
     */
    val isImage: Boolean
        get() = bookSourceType == BookSourceType.IMAGE

    /**
     * Check if this is a file book source
     */
    val isFile: Boolean
        get() = bookSourceType == BookSourceType.FILE

    /**
     * Check if has login URL
     */
    val hasLoginUrl: Boolean
        get() = !loginUrl.isNullOrBlank()

    /**
     * Check if has explore URL
     */
    val hasExploreUrl: Boolean
        get() = !exploreUrl.isNullOrBlank()

    /**
     * Check if has book URL pattern
     */
    val hasBookUrlPattern: Boolean
        get() = !bookUrlPattern.isNullOrBlank() && bookUrlPattern != "NONE"

    /**
     * Get display name with group
     */
    val displayNameGroup: String
        get() = if (bookSourceGroup.isNullOrBlank()) {
            bookSourceName
        } else {
            "$bookSourceName ($bookSourceGroup)"
        }

    /**
     * Get the search rule or create a default one
     */
    fun getSearchRule(): SearchRule {
        return ruleSearch ?: SearchRule()
    }

    /**
     * Get the explore rule or create a default one
     */
    fun getExploreRule(): ExploreRule {
        return ruleExplore ?: ExploreRule()
    }

    /**
     * Get the book info rule or create a default one
     */
    fun getBookInfoRule(): BookInfoRule {
        return ruleBookInfo ?: BookInfoRule()
    }

    /**
     * Get the TOC rule or create a default one
     */
    fun getTocRule(): TocRule {
        return ruleToc ?: TocRule()
    }

    /**
     * Get the content rule or create a default one
     */
    fun getContentRule(): ContentRule {
        return ruleContent ?: ContentRule()
    }

    /**
     * Get the review rule or create a default one
     */
    fun getReviewRule(): ReviewRule {
        return ruleReview ?: ReviewRule()
    }

    /**
     * Get the check keyword for search validation
     */
    fun getCheckKeyword(default: String): String {
        val keyword = ruleSearch?.checkKeyWord
        return if (keyword.isNullOrBlank()) default else keyword
    }

    /**
     * Check if has a specific group
     */
    fun hasGroup(group: String): Boolean {
        return SourceGroups.contains(bookSourceGroup, group)
    }

    /**
     * Add groups to this book source
     */
    fun addGroups(groups: String): BookSource {
        return copy(bookSourceGroup = SourceGroups.add(bookSourceGroup, groups))
    }

    /**
     * Remove groups from this book source
     */
    fun removeGroups(groups: String): BookSource {
        return copy(bookSourceGroup = SourceGroups.remove(bookSourceGroup, groups))
    }

    /**
     * Get validation failure groups written by source checking.
     */
    fun getInvalidGroupNames(): String {
        return SourceGroups.split(bookSourceGroup)
            .filter { "失效" in it || it == "校验超时" }
            .joinToString()
    }

    /**
     * Remove validation failure groups written by source checking.
     */
    fun removeInvalidGroups(): BookSource {
        return removeGroups(getInvalidGroupNames())
    }

    /**
     * Remove source-check error comments, preserving user comments.
     */
    fun removeErrorComment(): BookSource {
        val cleanedComment = bookSourceComment
            ?.split("\n\n")
            ?.filterNot { it.startsWith("// Error: ") }
            ?.joinToString("\n")
            ?.takeUnless(String::isBlank)
        return copy(bookSourceComment = cleanedComment)
    }

    /**
     * Add a source-check error comment above any existing comment.
     */
    fun addErrorComment(message: String?): BookSource {
        val normalizedMessage = message?.takeIf(String::isNotBlank) ?: return this
        return copy(
            bookSourceComment = listOfNotNull(
                "// Error: $normalizedMessage",
                bookSourceComment?.takeIf(String::isNotBlank),
            ).joinToString("\n\n")
        )
    }

    /**
     * Check if equals another book source by URL
     */
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BookSource) return false
        return bookSourceUrl == other.bookSourceUrl
    }

    override fun hashCode(): Int {
        return bookSourceUrl.hashCode()
    }

    companion object {
        private val ruleJson = Json {
            ignoreUnknownKeys = true
            isLenient = true
        }

        /**
         * Deserialize BookSource from database row
         */
        fun from(
            book_source_url: String,
            book_source_name: String,
            book_source_group: String?,
            book_source_type: Long,
            book_url_pattern: String?,
            custom_order: Long,
            enabled: Long,
            enabled_explore: Long,
            js_lib: String?,
            enabled_cookie_jar: Long,
            concurrent_rate: String?,
            header_json: String?,
            login_url: String?,
            login_ui: String?,
            login_check_js: String?,
            cover_decode_js: String?,
            book_source_comment: String?,
            variable_comment: String?,
            last_update_time: Long,
            respond_time: Long,
            weight: Long,
            explore_url: String?,
            explore_screen: String?,
            rule_explore: String?,
            search_url: String?,
            rule_search: String?,
            rule_book_info: String?,
            rule_toc: String?,
            rule_content: String?,
            rule_review: String?
        ): BookSource = BookSource(
            bookSourceUrl = book_source_url,
            bookSourceName = book_source_name,
            bookSourceGroup = book_source_group,
            bookSourceType = book_source_type.toInt(),
            bookUrlPattern = book_url_pattern,
            customOrder = custom_order.toInt(),
            enabled = enabled == 1L,
            enabledExplore = enabled_explore == 1L,
            jsLib = js_lib,
            enabledCookieJar = enabled_cookie_jar == 1L,
            concurrentRate = concurrent_rate,
            header = header_json,
            loginUrl = login_url,
            loginUi = login_ui,
            loginCheckJs = login_check_js,
            coverDecodeJs = cover_decode_js,
            bookSourceComment = book_source_comment,
            variableComment = variable_comment,
            lastUpdateTime = last_update_time,
            respondTime = respond_time,
            weight = weight.toInt(),
            exploreUrl = explore_url,
            exploreScreen = explore_screen,
            ruleExplore = rule_explore?.let { decodeJsonOrNull<ExploreRule>(it) },
            searchUrl = search_url,
            ruleSearch = rule_search?.let { decodeJsonOrNull<SearchRule>(it) },
            ruleBookInfo = rule_book_info?.let { decodeJsonOrNull<BookInfoRule>(it) },
            ruleToc = rule_toc?.let { decodeJsonOrNull<TocRule>(it) },
            ruleContent = rule_content?.let { decodeJsonOrNull<ContentRule>(it) },
            ruleReview = rule_review?.let { decodeJsonOrNull<ReviewRule>(it) }
        )

        private inline fun <reified T : Any> decodeJsonOrNull(json: String): T? {
            return try {
                ruleJson.decodeFromString<T>(json)
            } catch (e: Exception) {
                null
            }
        }
    }
}

/**
 * Book source type constants
 */
object BookSourceType {
    const val TEXT = 0    // Text books
    const val AUDIO = 1   // Audio books
    const val IMAGE = 2   // Image books
    const val FILE = 3    // File download books
}

/**
 * Extension to convert BookSource to database parameter map
 * Used for insert and update operations
 */
fun BookSource.toInsertMap(): Map<String, Any?> = mapOf(
    "book_source_url" to bookSourceUrl,
    "book_source_name" to bookSourceName,
    "book_source_group" to bookSourceGroup,
    "book_source_type" to bookSourceType.toLong(),
    "book_url_pattern" to bookUrlPattern,
    "custom_order" to customOrder.toLong(),
    "enabled" to if (enabled) 1L else 0L,
    "enabled_explore" to if (enabledExplore) 1L else 0L,
    "js_lib" to jsLib,
    "enabled_cookie_jar" to if (enabledCookieJar) 1L else 0L,
    "concurrent_rate" to concurrentRate,
    "header_json" to header,
    "login_url" to loginUrl,
    "login_ui" to loginUi,
    "login_check_js" to loginCheckJs,
    "cover_decode_js" to coverDecodeJs,
    "book_source_comment" to bookSourceComment,
    "variable_comment" to variableComment,
    "last_update_time" to lastUpdateTime,
    "respond_time" to respondTime,
    "weight" to weight.toLong(),
    "explore_url" to exploreUrl,
    "explore_screen" to exploreScreen,
    "rule_explore" to ruleExplore?.let { encodeRuleToJson(it) },
    "search_url" to searchUrl,
    "rule_search" to ruleSearch?.let { encodeRuleToJson(it) },
    "rule_book_info" to ruleBookInfo?.let { encodeRuleToJson(it) },
    "rule_toc" to ruleToc?.let { encodeRuleToJson(it) },
    "rule_content" to ruleContent?.let { encodeRuleToJson(it) },
    "rule_review" to ruleReview?.let { encodeRuleToJson(it) }
)

private fun encodeRuleToJson(rule: Any): String = BookSourceAdapter.encodeRule(rule)
