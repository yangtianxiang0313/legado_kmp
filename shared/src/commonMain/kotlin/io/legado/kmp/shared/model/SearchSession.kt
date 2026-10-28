package io.legado.kmp.shared.model

sealed interface SearchScope {
    data class Source(val sourceUrl: String) : SearchScope
    data class Group(val group: String) : SearchScope
    data object AllEnabled : SearchScope
    data object ExploreEnabled : SearchScope
}

data class SearchSessionState(
    val keyword: String = "",
    val scope: SearchScope? = null,
    val page: Int = 0,
    val isRunning: Boolean = false,
    val isPaused: Boolean = false,
    val results: List<SearchBook> = emptyList(),
    val hasMore: Boolean = false,
    val sourceTotalCount: Int = 0,
    val completedSourceCount: Int = 0,
    val failedSourceCount: Int = 0,
    val error: String? = null,
)
