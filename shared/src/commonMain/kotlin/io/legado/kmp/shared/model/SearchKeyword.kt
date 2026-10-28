package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

/**
 * Search keyword usage entry.
 */
@Serializable
data class SearchKeyword(
    val word: String = "",
    val usage: Int = 1,
    val lastUseTime: Long = io.legado.kmp.shared.util.currentTimeMillis()
) {
    companion object {
        fun from(
            word: String,
            usage: Long,
            last_use_time: Long
        ): SearchKeyword = SearchKeyword(
            word = word,
            usage = usage.toInt(),
            lastUseTime = last_use_time
        )
    }
}

fun SearchKeyword.toInsertMap(): Map<String, Any?> = mapOf(
    "word" to word,
    "usage" to usage.toLong(),
    "last_use_time" to lastUseTime
)

fun SearchKeyword.touch(now: Long = io.legado.kmp.shared.util.currentTimeMillis()): SearchKeyword = copy(
    usage = usage + 1,
    lastUseTime = now
)
