package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.ktor.http.parseServerSetCookieHeader
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.util.currentTimeMillis

internal fun httpCookieUrl(url: String): Url? = runCatching { Url(url) }.getOrNull()
    ?.takeIf { it.protocol.name in setOf("http", "https") && it.host.isNotBlank() }

internal fun cookieHost(host: String): String = host.lowercase().removePrefix("[").removeSuffix("]")

internal fun cookieDomainMatches(host: String, domain: String): Boolean =
    host == domain || (!host.isCookieIpAddress() && !domain.isCookieIpAddress() && host.endsWith(".$domain"))

internal fun StoredHttpCookie.matchesHost(host: String): Boolean =
    if (hostOnly) host == domain else cookieDomainMatches(host, domain)

internal fun StoredHttpCookie.matchesUrl(url: Url): Boolean {
    if (!matchesHost(cookieHost(url.host)) || (secure && url.protocol.name != "https")) return false
    val requestPath = url.encodedPath.ifBlank { "/" }
    return requestPath == path || (requestPath.startsWith(path) &&
        (path.endsWith('/') || requestPath.getOrNull(path.length) == '/'))
}

internal fun StoredHttpCookie.shadowsSecureCookie(existing: StoredHttpCookie): Boolean =
    existing.secure && name == existing.name &&
        (cookieDomainMatches(domain, existing.domain) || cookieDomainMatches(existing.domain, domain)) &&
        (path == existing.path || path.startsWith(existing.path) &&
            (existing.path.endsWith('/') || path.getOrNull(existing.path.length) == '/'))

internal fun StoredHttpCookie.normalizedForHost(host: String): StoredHttpCookie? {
    val normalizedDomain = cookieHost(domain.trim().removePrefix("."))
    if (!validCookieName(name) || !validCookieValue(value) || normalizedDomain.isBlank() ||
        normalizedDomain.endsWith('.') || normalizedDomain.any { it.isWhitespace() || it in "/\\;|" }
    ) return null
    if (hostOnly) {
        if (normalizedDomain != host) return null
    } else {
        if (!cookieDomainMatches(host, normalizedDomain)) return null
        if (!normalizedDomain.isCookieIpAddress()) {
            // Accept IDNs in their ASCII/Punycode form, failing closed on uncanonicalized
            // Unicode Domain attributes rather than guessing IDNA equivalence in commonMain.
            if (normalizedDomain.any { it !in 'a'..'z' && it !in '0'..'9' && it != '-' && it != '.' }) return null
            if (CookiePublicSuffixes.registrableDomain(normalizedDomain) == null) return null
        }
    }
    if (!path.startsWith('/') || path.any { it < ' ' || it == '\u007f' }) return null
    return copy(domain = normalizedDomain)
}

internal fun parseStoredSetCookie(
    url: String,
    header: String,
    now: Long = currentTimeMillis()
): StoredHttpCookie? {
    val requestUrl = httpCookieUrl(url) ?: return null
    val firstPair = header.substringBefore(';').trim()
    if (firstPair.indexOf('=') <= 0) return null
    val parsed = runCatching { parseServerSetCookieHeader(header) }.getOrNull() ?: return null
    if (parsed.name != firstPair.substringBefore('=').trim()) return null
    val requestPath = requestUrl.encodedPath
    val defaultPath = requestPath.substringBeforeLast('/', "").ifBlank { "/" }
    val expiry = parsed.maxAge?.let { seconds ->
        if (seconds <= 0) 0L else {
            val millis = seconds.toLong() * 1000L
            if (now > Long.MAX_VALUE - millis) Long.MAX_VALUE else now + millis
        }
    } ?: parsed.expires?.timestamp
    val cookie = StoredHttpCookie(
        name = parsed.name,
        value = parsed.value,
        domain = parsed.domain ?: requestUrl.host,
        path = parsed.path?.takeIf { it.startsWith('/') } ?: defaultPath,
        hostOnly = parsed.domain == null,
        secure = parsed.secure,
        httpOnly = parsed.httpOnly,
        expiresAtMillis = expiry,
        sameSite = parsed.extensions.entries.firstOrNull { it.key.equals("SameSite", ignoreCase = true) }?.value,
        creationTimeMillis = now
    ).normalizedForHost(cookieHost(requestUrl.host)) ?: return null
    if (cookie.secure && requestUrl.protocol.name != "https") return null
    if (cookie.name.startsWith("__Secure-") && !cookie.secure) return null
    if (cookie.name.startsWith("__Host-") && (!cookie.secure || !cookie.hostOnly || cookie.path != "/")) return null
    return cookie
}

/** Legacy rows are opaque request strings, not Set-Cookie values with inferred attributes. */
internal fun legacyCookieMatchesHost(key: String, host: String): Boolean {
    val parsed = httpCookieUrl(key)
    if (parsed != null) return cookieHost(parsed.host) == host
    if (key.isBlank() || key.any { it.isWhitespace() || it in "/\\;|" }) return false
    val domain = cookieHost(key.removePrefix("."))
    if (domain == host) return true
    val site = CookiePublicSuffixes.registrableDomain(host) ?: host
    return (domain == site || domain.endsWith(".$site")) && cookieDomainMatches(host, domain)
}

internal fun cookieScopeHost(url: String): String? = httpCookieUrl(url)?.let { cookieHost(it.host) }
    ?: url.takeIf { it.isNotBlank() && it.none { char -> char.isWhitespace() || char in "/\\;|" } }
        ?.let { cookieHost(it.removePrefix(".")) }

internal val storedCookieRequestOrder: Comparator<StoredHttpCookie> =
    compareByDescending<StoredHttpCookie> { it.path.length }
        .thenBy { it.creationTimeMillis }
        .thenBy { it.domain }
        .thenBy { it.name }

private fun validCookieName(value: String): Boolean = value.isNotEmpty() &&
    value.all { it > ' ' && it < '\u007f' && it !in "()<>@,;:\\\"/[]?={} " }

private fun validCookieValue(value: String): Boolean = value.none { it < ' ' || it == '\u007f' || it == ';' }

private fun String.isCookieIpAddress(): Boolean = contains(':') ||
    (split('.').size == 4 && split('.').all { it.toIntOrNull()?.let { part -> part in 0..255 } == true })
