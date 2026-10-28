package io.legado.kmp.shared.network

/**
 * Parsed proxy configuration.
 *
 * Legado proxy format: `<type>://<host>:<port>[@<username>@<password>]`
 * where type is one of: http, socks4, socks5
 */
data class ParsedProxy(
    val type: String,
    val host: String,
    val port: Int,
    val username: String? = null,
    val password: String? = null
)

private val proxyRegex = Regex("(http|socks4|socks5)://(.*):(\\d{2,5})(@.*@.*)?")

/**
 * Parse a legado-format proxy string into its components.
 *
 * @throws IllegalArgumentException if the format is not recognized
 */
fun parseProxy(proxy: String): ParsedProxy {
    val match = proxyRegex.find(proxy)
        ?: throw IllegalArgumentException("Unsupported proxy format: $proxy")
    val type = match.groupValues[1]
    val host = match.groupValues[2]
    val port = match.groupValues[3].toInt()
    val auth = match.groupValues[4]

    var username: String? = null
    var password: String? = null
    if (auth.isNotBlank()) {
        val authParts = auth.split("@")
        if (authParts.size >= 3) {
            username = authParts[1].takeIf { it.isNotBlank() }
            password = authParts[2].takeIf { it.isNotBlank() }
        }
    }
    if (username == null || password == null) {
        username = null
        password = null
    }
    return ParsedProxy(type = type, host = host, port = port, username = username, password = password)
}
