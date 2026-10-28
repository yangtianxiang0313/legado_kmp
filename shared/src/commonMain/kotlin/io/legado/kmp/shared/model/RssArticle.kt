package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class RssArticle(
    val origin: String = "",
    val sort: String = "",
    val title: String = "",
    val order: Long = 0L,
    val link: String = "",
    val pubDate: String? = null,
    val description: String? = null,
    val content: String? = null,
    val image: String? = null,
    val group: String = DEFAULT_GROUP,
    val read: Boolean = false,
    val variable: String? = null
) {
    val variableMap: Map<String, String>
        get() = parseVariableMap(variable)

    fun toStar(starTime: Long = io.legado.kmp.shared.util.currentTimeMillis()): RssStar {
        return RssStar(
            origin = origin,
            sort = sort,
            title = title,
            starTime = starTime,
            link = link,
            pubDate = pubDate,
            description = description,
            content = content,
            image = image,
            group = group,
            variable = variable
        )
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RssArticle) return false
        return origin == other.origin && link == other.link
    }

    override fun hashCode(): Int = 31 * origin.hashCode() + link.hashCode()

    companion object {
        const val DEFAULT_GROUP = "默认分组"
    }
}
