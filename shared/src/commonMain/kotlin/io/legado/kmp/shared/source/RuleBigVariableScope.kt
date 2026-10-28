package io.legado.kmp.shared.source

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive

/** Exact, versioned identities; neither URLs nor variable names are SQL LIKE patterns. */
data class RuleBigVariableScope(
    val sourceKey: String,
    val bookUrl: String? = null,
    val chapterUrl: String? = null
) {
    init {
        require(sourceKey.isNotBlank()) { "A rule variable requires a source identity" }
        require(bookUrl == null || bookUrl.isNotBlank()) { "A book variable requires a book URL" }
        require(chapterUrl == null || bookUrl != null) { "A chapter variable requires a book URL" }
        require(chapterUrl == null || chapterUrl.isNotBlank()) { "A chapter variable requires a chapter URL" }
    }

    internal val prefix: String
        get() = sourcePrefix(sourceKey) + JsonArray(
            listOf(JsonPrimitive(bookUrl), JsonPrimitive(chapterUrl))
        ) + ":"

    internal fun key(name: String): String = prefix + JsonPrimitive(name)

    internal companion object {
        fun sourcePrefix(sourceKey: String): String = "ruleBigData:v1:${JsonPrimitive(sourceKey)}:"
    }
}
