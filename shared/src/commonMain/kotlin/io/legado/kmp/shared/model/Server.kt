package io.legado.kmp.shared.model

import kotlinx.serialization.Serializable

@Serializable
data class Server(
    val id: Long = io.legado.kmp.shared.util.currentTimeMillis(),
    val name: String = "",
    val type: ServerType = ServerType.WEBDAV,
    val config: String? = null,
    val sortNumber: Int = 0,
) {
    @Serializable
    data class WebDavConfig(
        val url: String = "",
        val username: String = "",
        val password: String = "",
    )
}

@Serializable
enum class ServerType {
    WEBDAV,
}
