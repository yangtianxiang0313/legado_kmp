package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.ktor.http.parseServerSetCookieHeader
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.util.currentTimeMillis

internal fun httpCookieUrl(url: String): Url? {
    val prefixLength = when {
        url.startsWith("http://", true) -> 7
        url.startsWith("https://", true) -> 8
        else -> return null
    }
    if (url.any { it < ' ' || it == '\u007f' || it == '\\' }) return null
    val authority = url.substring(prefixLength).substringBefore('/').substringBefore('?').substringBefore('#')
    val host = cookieAuthorityHost(authority.substringAfterLast('@'), allowBareIpv6 = false, allowDomainDot = false)
        ?: return null
    return runCatching { Url(url) }.getOrNull()?.takeIf {
        it.protocol.name in setOf("http", "https") && cookieHost(it.host) == host
    }
}

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
    val domain = cookieScopeHost(key) ?: return false
    if (domain == host) return true
    val site = CookiePublicSuffixes.registrableDomain(host) ?: host
    return (domain == site || domain.endsWith(".$site")) && cookieDomainMatches(host, domain)
}

internal fun cookieScopeHost(url: String): String? = httpCookieUrl(url)?.let { cookieHost(it.host) }
    ?: cookieAuthorityHost(url)

// A bare cookie label is an authority, never a relative URL (Ktor defaults those to localhost).
private fun cookieAuthorityHost(
    value: String,
    allowBareIpv6: Boolean = true,
    allowDomainDot: Boolean = true,
): String? {
    if (value.isEmpty()) return null
    if (value.startsWith('[')) {
        val end = value.indexOf(']')
        if (end < 0) return null
        val host = value.substring(1, end).lowercase()
        if (!host.isCookieIpv6Address() || !validCookiePortSuffix(value.substring(end + 1))) return null
        return host
    }
    if (value.count { it == ':' } > 1) {
        return value.lowercase().takeIf { allowBareIpv6 && it.isCookieIpv6Address() }
    }
    val separator = value.indexOf(':')
    val rawHost = if (separator < 0) value else {
        if (!validCookiePortSuffix(value.substring(separator))) return null
        value.substring(0, separator)
    }
    val host = (if (allowDomainDot) rawHost.removePrefix(".") else rawHost).lowercase()
    if (host.isEmpty() || host.length > 253) return null
    if (host.all { it in '0'..'9' || it == '.' }) return host.takeIf { it.isCookieIpv4Address() }
    return host.takeIf {
        it.removeSuffix(".").split('.').all { label ->
            label.isNotEmpty() && label.length <= 63 && label.first().isCookieHostLetterOrDigit() &&
                label.last().isCookieHostLetterOrDigit() && label.all { char ->
                    char.isCookieHostLetterOrDigit() || char == '-'
                }
        }
    }
}

private fun validCookiePortSuffix(value: String): Boolean = value.isEmpty() ||
    (value.startsWith(':') && value.length > 1 && value.drop(1).all { it in '0'..'9' } &&
        value.drop(1).toIntOrNull()?.let { it in 0..65535 } == true)

private fun Char.isCookieHostLetterOrDigit(): Boolean = this in 'a'..'z' || this in '0'..'9' ||
    (code > 127 && isLetterOrDigit())

private fun String.isCookieIpv4Address(): Boolean = split('.').let { parts ->
    parts.size == 4 && parts.all { part ->
        part.isNotEmpty() && part.length <= 3 && part.all { it in '0'..'9' } &&
            part.toIntOrNull()?.let { it in 0..255 } == true
    }
}

private fun String.isCookieIpv6Address(): Boolean {
    if (":::" in this || indexOf("::") != lastIndexOf("::")) return false
    if (startsWith(':') && !startsWith("::") || endsWith(':') && !endsWith("::")) return false
    val compressed = "::" in this
    if (!compressed && (startsWith(':') || endsWith(':'))) return false
    val parts = split(':').filter { it.isNotEmpty() }
    var groups = 0
    for ((index, part) in parts.withIndex()) {
        if ('.' in part) {
            if (index != parts.lastIndex || endsWith(':') || !part.isCookieIpv4Address()) return false
            groups += 2
        } else {
            if (part.length !in 1..4 || part.any { it !in '0'..'9' && it !in 'a'..'f' }) return false
            groups++
        }
    }
    return if (compressed) groups < 8 else groups == 8
}

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
