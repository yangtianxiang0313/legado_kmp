package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class RssStar(
    val origin: String = "",
    val sort: String = "",
    val title: String = "",
    val starTime: Long = 0L,
    val link: String = "",
    val pubDate: String? = null,
    val description: String? = null,
    val content: String? = null,
    val image: String? = null,
    val group: String = RssArticle.DEFAULT_GROUP,
    val variable: String? = null
) {
    val variableMap: Map<String, String>
        get() = parseVariableMap(variable)

    fun toRssArticle(read: Boolean = false): RssArticle {
        return RssArticle(
            origin = origin,
            sort = sort,
            title = title,
            link = link,
            pubDate = pubDate,
            description = description,
            content = content,
            image = image,
            group = group,
            read = read,
            variable = variable
        )
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RssStar) return false
        return origin == other.origin && link == other.link
    }

    override fun hashCode(): Int = 31 * origin.hashCode() + link.hashCode()
}
