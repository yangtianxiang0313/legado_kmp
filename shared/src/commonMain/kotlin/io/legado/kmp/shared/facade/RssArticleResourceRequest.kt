package io.legado.kmp.shared.facade

data class RssArticleResourceRequest(val url: String, val headers: Map<String, String>) {
    override fun toString(): String = "RssArticleResourceRequest(redacted)"
}

data class RssArticleResourceResult(
    val request: RssArticleResourceRequest? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
)
