package io.legado.kmp.shared.data.adapter

import io.legado.kmp.shared.model.rule.BookInfoRule
import io.legado.kmp.shared.model.rule.ContentRule
import io.legado.kmp.shared.model.rule.ExploreRule
import io.legado.kmp.shared.model.rule.ReviewRule
import io.legado.kmp.shared.model.rule.SearchRule
import io.legado.kmp.shared.model.rule.TocRule
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer

/**
 * SQLDelight adapters for BookSource entity
 *
 * NOTE: SQLDelight 2.0 doesn't support nullable types in ColumnAdapter.
 * Rule objects (ExploreRule, SearchRule, etc.) are stored as TEXT in the database
 * and serialized/deserialized in the BookSource model using extension functions.
 *
 * See BookSource.kt for:
 * - toInsertMap() - converts BookSource to database parameters
 * - from() - factory method to create BookSource from database row
 */
object BookSourceAdapter {
    /**
     * JSON serialization helper for rule objects
     * Used by BookSource extensions for database conversion
     */
    val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = false
    }

    /**
     * Encode rule object to JSON string
     */
    fun encodeRule(rule: Any?): String {
        return when (rule) {
            null -> ""
            is ExploreRule -> json.encodeToString(ExploreRule.serializer(), rule)
            is SearchRule -> json.encodeToString(SearchRule.serializer(), rule)
            is BookInfoRule -> json.encodeToString(BookInfoRule.serializer(), rule)
            is TocRule -> json.encodeToString(TocRule.serializer(), rule)
            is ContentRule -> json.encodeToString(ContentRule.serializer(), rule)
            is ReviewRule -> json.encodeToString(ReviewRule.serializer(), rule)
            else -> ""
        }
    }

    /**
     * Decode JSON string to specific rule type using serializer
     */
    fun <T : Any> decodeRule(serializer: KSerializer<T>, jsonString: String?, default: T): T {
        return if (jsonString.isNullOrBlank()) {
            default
        } else {
            try {
                json.decodeFromString(serializer, jsonString)
            } catch (e: Exception) {
                default
            }
        }
    }

    /**
     * Decode ExploreRule from JSON
     */
    fun decodeExploreRule(jsonString: String?): ExploreRule =
        decodeRule(ExploreRule.serializer(), jsonString, ExploreRule())

    /**
     * Decode SearchRule from JSON
     */
    fun decodeSearchRule(jsonString: String?): SearchRule =
        decodeRule(SearchRule.serializer(), jsonString, SearchRule())

    /**
     * Decode BookInfoRule from JSON
     */
    fun decodeBookInfoRule(jsonString: String?): BookInfoRule =
        decodeRule(BookInfoRule.serializer(), jsonString, BookInfoRule())

    /**
     * Decode TocRule from JSON
     */
    fun decodeTocRule(jsonString: String?): TocRule =
        decodeRule(TocRule.serializer(), jsonString, TocRule())

    /**
     * Decode ContentRule from JSON
     */
    fun decodeContentRule(jsonString: String?): ContentRule =
        decodeRule(ContentRule.serializer(), jsonString, ContentRule())

    /**
     * Decode ReviewRule from JSON
     */
    fun decodeReviewRule(jsonString: String?): ReviewRule =
        decodeRule(ReviewRule.serializer(), jsonString, ReviewRule())
}
