package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class HttpTTS(
    val id: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val name: String = "",
    val url: String = "",
    val contentType: String? = null,
    val concurrentRate: String? = "0",
    val loginUrl: String? = null,
    val loginUi: String? = null,
    val header: String? = null,
    val jsLib: String? = null,
    val enabledCookieJar: Boolean = false,
    val loginCheckJs: String? = null,
    val lastUpdateTime: Long = io.legado.kmp.shared.util.currentTimeMillis(),
) {
    val key: String
        get() = "httpTts:$id"
}
