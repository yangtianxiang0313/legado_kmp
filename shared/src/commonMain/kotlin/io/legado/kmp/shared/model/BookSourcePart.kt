package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class BookSourcePart(
    val bookSourceUrl: String = "",
    val bookSourceName: String = "",
    val bookSourceGroup: String? = null,
    val customOrder: Int = 0,
    val enabled: Boolean = true,
    val enabledExplore: Boolean = true,
    val hasLoginUrl: Boolean = false,
    val lastUpdateTime: Long = 0L,
    val respondTime: Long = 180000L,
    val weight: Int = 0,
    val hasExploreUrl: Boolean = false,
    val hasBookUrlPattern: Boolean = false,
) {
    val displayNameGroup: String
        get() = if (bookSourceGroup.isNullOrBlank()) {
            bookSourceName
        } else {
            "$bookSourceName ($bookSourceGroup)"
        }

    val projectionKey: String
        get() = bookSourceUrl

    fun hasGroup(group: String): Boolean {
        return SourceGroups.contains(bookSourceGroup, group)
    }

    companion object {
        fun from(source: BookSource): BookSourcePart {
            return BookSourcePart(
                bookSourceUrl = source.bookSourceUrl,
                bookSourceName = source.bookSourceName,
                bookSourceGroup = source.bookSourceGroup,
                customOrder = source.customOrder,
                enabled = source.enabled,
                enabledExplore = source.enabledExplore,
                hasLoginUrl = source.hasLoginUrl,
                lastUpdateTime = source.lastUpdateTime,
                respondTime = source.respondTime,
                weight = source.weight,
                hasExploreUrl = source.hasExploreUrl,
                hasBookUrlPattern = source.hasBookUrlPattern,
            )
        }
    }
}
