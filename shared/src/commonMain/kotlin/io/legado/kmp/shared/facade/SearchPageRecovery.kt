package io.legado.kmp.shared.facade

import io.legado.kmp.shared.model.SearchBook
import io.legado.kmp.shared.model.SearchScope

// Source updates are serialized per attempt; the facade gates checkpoint reuse by generation.
internal class SearchPageRecovery(
    val keyword: String,
    val searchScope: SearchScope,
    val page: Int,
    val seedResults: List<SearchBook>,
    val seedResultIds: Set<String>,
    val sourceUrls: List<String>,
) {
    private class SourceCheckpoint {
        // Null means pending; an empty list is still a completed success.
        var books: List<SearchBook>? = null
        var error: String? = null
    }

    private val sources = sourceUrls.associateWithTo(linkedMapOf()) { SourceCheckpoint() }

    val pendingSourceUrls: Set<String>
        get() = buildSet {
            sources.forEach { (url, checkpoint) ->
                if (checkpoint.books == null) add(url)
            }
        }

    val books: List<SearchBook>
        get() = sources.values.flatMap { it.books.orEmpty() }

    val resultIds: Set<String>
        get() = books.mapTo(linkedSetOf()) { it.primaryId }

    val hasMore: Boolean
        // Unfinished sources remain retryable, but do not indicate another page.
        get() = resultIds.any { it !in seedResultIds }

    val sourceTotalCount: Int
        get() = sources.size

    val completedSourceCount: Int
        get() = sources.values.count { it.books != null || it.error != null }

    val failedSourceCount: Int
        get() = sources.values.count { it.error != null }

    val error: String?
        get() = sources.values.firstNotNullOfOrNull { it.error }

    fun beginAttempt(sourceUrls: Set<String>) {
        sourceUrls.forEach { sources[it]?.error = null }
    }

    fun recordSuccess(sourceUrl: String, books: List<SearchBook>) {
        val checkpoint = sources[sourceUrl] ?: return
        if (checkpoint.books != null) return
        checkpoint.books = books.toList()
        checkpoint.error = null
    }

    fun recordFailure(sourceUrl: String, message: String) {
        val checkpoint = sources[sourceUrl] ?: return
        if (checkpoint.books != null) return
        checkpoint.error = message
    }

    fun retainAvailableSources(availableUrls: Set<String>) {
        sources.entries.removeAll { (url, checkpoint) ->
            checkpoint.books == null && url !in availableUrls
        }
    }
}
