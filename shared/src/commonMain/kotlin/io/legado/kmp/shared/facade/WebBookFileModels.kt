package io.legado.kmp.shared.facade

data class WebBookFileOption(
    val urlRule: String,
    val fileName: String,
    val suffix: String,
) {
    override fun toString(): String = "WebBookFileOption(redacted)"
}

/** Sensitive HTTP intent. The loader must disable automatic redirects and automatic cookie injection. */
data class WebBookFileRequest(
    val url: String,
    val method: String,
    val headers: Map<String, String>,
    val bodyBase64: String?,
    val fileName: String,
    val timeoutMillis: Long,
    val sourceUrl: String,
    val headerOriginUrl: String,
    val explicitCookie: String?,
    val enabledCookieJar: Boolean,
) {
    override fun toString(): String = "WebBookFileRequest(redacted)"
}

data class WebBookFileOptionsResult(
    val options: List<WebBookFileOption> = emptyList(),
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "WebBookFileOptionsResult(redacted)"
}

data class WebBookFileRequestResult(
    val request: WebBookFileRequest? = null,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "WebBookFileRequestResult(redacted)"
}
