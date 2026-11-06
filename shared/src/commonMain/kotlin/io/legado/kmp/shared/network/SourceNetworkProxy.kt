package io.legado.kmp.shared.network

import io.ktor.http.Url

/** Accept both normal proxy URLs and existing Legado host:port@user@password syntax. */
internal fun parseSourceNetworkProxy(value: String): ParsedProxy = try {
    val standard = runCatching { Url(value) }.getOrNull()
    val legacy = Regex("^(http|socks4|socks5)://([^/\\s]+?):([0-9]{1,5})@([^@\\r\\n]*)@([^\\r\\n]*)$").matchEntire(value)
    val parsed = if (legacy != null) {
        ParsedProxy(legacy.groupValues[1], legacy.groupValues[2].removeSurrounding("[", "]"), legacy.groupValues[3].toInt(),
            legacy.groupValues[4].ifBlank { null }, legacy.groupValues[5].ifBlank { null })
    } else if (standard != null && standard.host.isNotBlank() && standard.port in 1..65535 &&
        standard.encodedPath in listOf("", "/") && standard.parameters.isEmpty() && standard.fragment.isEmpty()) {
        ParsedProxy(standard.protocol.name, standard.host, standard.port, standard.user, standard.password)
    } else {
        val match = Regex("^(http|socks4|socks5)://([^/\\s]+?):([0-9]{1,5})(?:@([^@\\r\\n]*)@([^\\r\\n]*))?$").matchEntire(value)
            ?: throw IllegalArgumentException()
        ParsedProxy(match.groupValues[1], match.groupValues[2].removeSurrounding("[", "]"), match.groupValues[3].toInt(),
            match.groupValues[4].ifBlank { null }, match.groupValues[5].ifBlank { null })
    }
    require(parsed.type in setOf("http", "socks4", "socks5") && parsed.host.isNotBlank() &&
        parsed.host.none { it.isWhitespace() || it in "@/\\" } && parsed.port in 1..65535)
    parsed
} catch (_: Exception) { throw IllegalArgumentException("Invalid proxy address") }
