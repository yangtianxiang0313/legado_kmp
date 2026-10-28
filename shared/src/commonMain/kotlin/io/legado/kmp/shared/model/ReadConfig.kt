package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * Reading configuration for a book
 * Serialized to JSON for database storage
 */
@Serializable
data class ReadConfig(
    /** Whether to reverse the table of contents order */
    var reverseToc: Boolean = false,

    /** Page animation style */
    var pageAnim: Int? = null,

    /** Whether to re-segment content */
    var reSegment: Boolean = false,

    /** Image display style */
    var imageStyle: String? = null,

    /** Whether to use content replacement rules */
    var useReplaceRule: Boolean? = null,

    /** Tags to remove from content (bitmask) */
    var delTag: Long = 0L,

    /** TTS engine to use */
    var ttsEngine: String? = null,

    /** Whether to split long chapters */
    var splitLongChapter: Boolean = true,

    /** Whether read simulation is enabled */
    var readSimulating: Boolean = false,

    /** Start date for read simulation */
    var startDate: kotlinx.datetime.LocalDate? = null,

    /** Starting chapter for read simulation */
    var startChapter: Int? = null,

    /** Number of chapters to read per day */
    var dailyChapters: Int = 3
) {
    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            encodeDefaults = true
        }

        /**
         * Deserialize ReadConfig from JSON string
         */
        fun fromJson(jsonString: String?): ReadConfig {
            return if (jsonString.isNullOrBlank()) {
                ReadConfig()
            } else try {
                json.decodeFromString(jsonString)
            } catch (e: Exception) {
                ReadConfig()
            }
        }

        /**
         * Image style constants
         */
        object ImageStyles {
            const val DEFAULT = "DEFAULT"
            const val FULL = "FULL"
            const val TEXT = "TEXT"
            const val SINGLE = "SINGLE"
        }

        /**
         * Delete tag constants
         */
        object DeleteTags {
            const val SAME_TITLE = 1L
            const val H_TAG = 2L
            const val RUBY_TAG = 4L
        }
    }

    /**
     * Serialize ReadConfig to JSON string
     */
    fun toJson(): String {
        return json.encodeToString(this)
    }

    /**
     * Check if a specific delete tag is set
     */
    fun hasDelTag(tag: Long): Boolean {
        return delTag and tag == tag
    }

    /**
     * Add a delete tag
     */
    fun addDelTag(tag: Long) {
        delTag = delTag or tag
    }

    /**
     * Remove a delete tag
     */
    fun removeDelTag(tag: Long) {
        delTag = delTag and tag.inv()
    }
}
