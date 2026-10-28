package io.legado.kmp.shared.model

import io.legado.kmp.shared.network.joinUrl
import io.legado.kmp.shared.util.md5Hex
import kotlinx.serialization.Serializable
@Serializable
data class BookChapter(
    val url: String = "",
    val title: String = "",
    val isVolume: Boolean = false,
    val baseUrl: String = "",
    val bookUrl: String = "",
    val index: Int = 0,
    val isVip: Boolean = false,
    val isPay: Boolean = false,
    val resourceUrl: String? = null,
    val tag: String? = null,
    val wordCount: String? = null,
    val start: Long? = null,
    val end: Long? = null,
    val startFragmentId: String? = null,
    val endFragmentId: String? = null,
    val variable: String? = null
) {
    val variableMap: Map<String, String>
        get() = parseVariableMap(variable)

    fun primaryStr(): String = bookUrl + url

    @Suppress("UNUSED_PARAMETER")
    fun getDisplayTitle(
        replaceRules: List<ReplaceRule>? = null,
        useReplace: Boolean = true,
        chineseConvert: Boolean = true
    ): String {
        var displayTitle = title.replace(lineBreakRegex, "")
        if (useReplace && replaceRules != null) {
            replaceRules.forEach { rule ->
                val replaced = rule.applyToTitle(displayTitle)
                if (replaced.isNotBlank()) {
                    displayTitle = replaced
                }
            }
        }
        return displayTitle
    }

    fun getAbsoluteUrl(): String {
        if (url.startsWith(title) && isVolume) return baseUrl
        val match = ruleParamSeparator.find(url)
        val urlBefore = match?.let { url.substring(0, it.range.first) } ?: url
        val absoluteBefore = resolveUrl(baseUrl = baseUrl, relativeOrAbsolute = urlBefore)
        return if (match == null) {
            absoluteBefore
        } else {
            absoluteBefore + "," + url.substring(match.range.last + 1)
        }
    }

    fun getAbsoluteURL(): String = getAbsoluteUrl()

    @Suppress("unused")
    fun getFileName(suffix: String = "nb"): String {
        val titleMd5 = title.md5Hex().padEnd(16, '0').take(16)
        val indexPrefix = index.toString().padStart(5, '0')
        return "$indexPrefix-$titleMd5.$suffix"
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is BookChapter) return false
        return other.url == url
    }

    override fun hashCode(): Int = url.hashCode()

    companion object {
        private val lineBreakRegex = Regex("[\\r\\n]+")
        private val ruleParamSeparator = Regex("\\s*,\\s*(?=\\{)")
        fun from(
            url: String,
            title: String,
            is_volume: Long,
            base_url: String,
            book_url: String,
            chapter_index: Long,
            is_vip: Long,
            is_pay: Long,
            resource_url: String?,
            tag: String?,
            word_count: String?,
            start: Long?,
            end: Long?,
            start_fragment_id: String?,
            end_fragment_id: String?,
            variable: String?
        ): BookChapter = BookChapter(
            url = url,
            title = title,
            isVolume = is_volume == 1L,
            baseUrl = base_url,
            bookUrl = book_url,
            index = chapter_index.toInt(),
            isVip = is_vip == 1L,
            isPay = is_pay == 1L,
            resourceUrl = resource_url,
            tag = tag,
            wordCount = word_count,
            start = start,
            end = end,
            startFragmentId = start_fragment_id,
            endFragmentId = end_fragment_id,
            variable = variable
        )

        private fun resolveUrl(baseUrl: String, relativeOrAbsolute: String): String {
            if (relativeOrAbsolute.isBlank()) return baseUrl
            if (relativeOrAbsolute.startsWith("http://") || relativeOrAbsolute.startsWith("https://")) {
                return relativeOrAbsolute
            }
            if (relativeOrAbsolute.startsWith("//")) {
                val scheme = if (baseUrl.startsWith("https://")) "https:" else "http:"
                return scheme + relativeOrAbsolute
            }
            if (baseUrl.isBlank()) return relativeOrAbsolute
            if (relativeOrAbsolute.startsWith("/")) {
                val schemeEnd = baseUrl.indexOf("://")
                if (schemeEnd > 0) {
                    val pathStart = baseUrl.indexOf('/', schemeEnd + 3)
                    return if (pathStart > 0) {
                        baseUrl.substring(0, pathStart) + relativeOrAbsolute
                    } else {
                        baseUrl + relativeOrAbsolute
                    }
                }
            }
            return baseUrl.joinUrl(relativeOrAbsolute)
        }
    }
}

fun BookChapter.toInsertMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "title" to title,
    "is_volume" to if (isVolume) 1L else 0L,
    "base_url" to baseUrl,
    "book_url" to bookUrl,
    "chapter_index" to index.toLong(),
    "is_vip" to if (isVip) 1L else 0L,
    "is_pay" to if (isPay) 1L else 0L,
    "resource_url" to resourceUrl,
    "tag" to tag,
    "word_count" to wordCount,
    "start" to start,
    "end" to end,
    "start_fragment_id" to startFragmentId,
    "end_fragment_id" to endFragmentId,
    "variable" to variable
)

val BookChapter.isReadable: Boolean
    get() = !isVip || isPay

val BookChapter.isValid: Boolean
    get() = title.isNotBlank() && (isVolume || url.isNotBlank())
