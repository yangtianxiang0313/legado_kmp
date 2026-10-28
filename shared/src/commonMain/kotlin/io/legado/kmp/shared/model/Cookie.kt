package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

/**
 * Persisted cookie entry keyed by source URL.
 */
@Serializable
data class Cookie(
    val url: String = "",
    val cookie: String = ""
) {
    companion object {
        fun from(url: String, cookie: String): Cookie = Cookie(
            url = url,
            cookie = cookie
        )
    }
}

fun Cookie.toInsertMap(): Map<String, Any?> = mapOf(
    "url" to url,
    "cookie" to cookie
)
