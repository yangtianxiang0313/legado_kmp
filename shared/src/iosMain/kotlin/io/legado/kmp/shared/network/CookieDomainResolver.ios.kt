package io.legado.kmp.shared.network

internal actual fun effectiveTopPrivateDomain(host: String): String? {
    val normalized = host.trim('.')
    if (normalized.isBlank()) return null
    val parts = normalized.split('.').filter { it.isNotBlank() }
    if (parts.size < 2) return normalized

    val multiPartSuffixes = setOf(
        "ac.cn", "com.cn", "edu.cn", "gov.cn", "mil.cn", "net.cn", "org.cn",
        "co.uk", "org.uk", "gov.uk", "ac.uk",
        "com.hk", "com.tw", "com.au", "net.au", "org.au", "co.jp", "co.kr",
    )

    val lastTwo = parts.takeLast(2).joinToString(".")
    if (lastTwo in multiPartSuffixes && parts.size >= 3) {
        return parts.takeLast(3).joinToString(".")
    }

    val lastThree = parts.takeLast(3).joinToString(".")
    if (lastThree in multiPartSuffixes && parts.size >= 4) {
        return parts.takeLast(4).joinToString(".")
    }

    return parts.takeLast(2).joinToString(".")
}
