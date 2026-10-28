package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class RssSource(
    val sourceUrl: String = "",
    val sourceName: String = "",
    val sourceIcon: String = "",
    val sourceGroup: String? = null,
    val sourceComment: String? = null,
    val enabled: Boolean = true,
    val variableComment: String? = null,
    val jsLib: String? = null,
    val enabledCookieJar: Boolean = true,
    val concurrentRate: String? = null,
    val header: String? = null,
    val loginUrl: String? = null,
    val loginUi: String? = null,
    val loginCheckJs: String? = null,
    val coverDecodeJs: String? = null,
    val sortUrl: String? = null,
    val singleUrl: Boolean = false,
    val articleStyle: Int = 0,
    val ruleArticles: String? = null,
    val ruleNextPage: String? = null,
    val ruleTitle: String? = null,
    val rulePubDate: String? = null,
    val ruleDescription: String? = null,
    val ruleImage: String? = null,
    val ruleLink: String? = null,
    val ruleContent: String? = null,
    val contentWhitelist: String? = null,
    val contentBlacklist: String? = null,
    val shouldOverrideUrlLoading: String? = null,
    val style: String? = null,
    val enableJs: Boolean = true,
    val loadWithBaseUrl: Boolean = true,
    val injectJs: String? = null,
    val lastUpdateTime: Long = 0L,
    val customOrder: Int = 0
) {
    val displayNameGroup: String
        get() = if (sourceGroup.isNullOrBlank()) sourceName else "$sourceName ($sourceGroup)"

    val isValid: Boolean
        get() = sourceUrl.isNotBlank() && sourceName.isNotBlank()

    fun hasGroup(group: String): Boolean {
        return SourceGroups.contains(sourceGroup, group)
    }

    fun addGroup(groups: String): RssSource {
        return copy(sourceGroup = SourceGroups.add(sourceGroup, groups))
    }

    fun removeGroup(groups: String): RssSource {
        return copy(sourceGroup = SourceGroups.remove(sourceGroup, groups))
    }

    fun getDisplayVariableComment(otherComment: String): String {
        return if (variableComment.isNullOrBlank()) otherComment else "$variableComment\n$otherComment"
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is RssSource) return false
        return sourceUrl == other.sourceUrl
    }

    override fun hashCode(): Int = sourceUrl.hashCode()

}
