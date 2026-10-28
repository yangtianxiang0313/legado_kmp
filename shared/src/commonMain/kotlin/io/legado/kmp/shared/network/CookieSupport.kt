package io.legado.kmp.shared.network

import io.ktor.http.Url
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

fun extractCookieDomain(url: String): String {
    if (url.isBlank()) return url
    val host = runCatching { Url(url).host }.getOrDefault(url).ifBlank { url }
    if (host.isBlank()) return url
    if (host.isIpAddress()) return host
    return CookiePublicSuffixes.registrableDomain(cookieHost(host)) ?: host
}

fun mergeCookieStrings(vararg cookies: String?): String? {
    val cookieMap = LinkedHashMap<String, String>()
    cookies.filterNotNull().forEach { cookie ->
        cookieToMap(cookie).forEach { (name, value) ->
            cookieMap[name] = value
        }
    }
    return mapToCookieString(cookieMap)
}

fun cookieToMap(cookie: String): Map<String, String> {
    if (cookie.isBlank()) return emptyMap()
    return cookie.split(';')
        .mapNotNull { item ->
            val pair = item.trim()
            val separator = pair.indexOf('=')
            if (separator <= 0) {
                null
            } else {
                pair.substring(0, separator).trim() to pair.substring(separator + 1).trim()
            }
        }
        .toMap(LinkedHashMap())
}

fun mapToCookieString(cookieMap: Map<String, String>): String? {
    if (cookieMap.isEmpty()) return null
    return cookieMap.entries.joinToString("; ") { (name, value) -> "$name=$value" }
}

/** Explicit names override jar names without flattening other same-name/path entries. */
internal fun mergeRequestCookieHeader(jar: String?, explicit: String?): String? {
    fun pairs(header: String?): List<Pair<String, String>> = header.orEmpty().split(';').mapNotNull { item ->
        val pair = item.trim()
        val separator = pair.indexOf('=')
        if (separator <= 0 || pair.any { it < ' ' || it == '\u007f' }) null
        else pair.substring(0, separator).trim() to pair.substring(separator + 1).trim()
    }
    val overrides = pairs(explicit)
    val overriddenNames = overrides.mapTo(mutableSetOf()) { it.first }
    return (pairs(jar).filterNot { it.first in overriddenNames } + overrides)
        .joinToString("; ") { (name, value) -> "$name=$value" }.ifBlank { null }
}

/** Only opaque legacy session strings live here; attributed cookies belong to the repository. */
internal object SessionCookieStore {
    private val lock = Mutex()
    private val cookies = LinkedHashMap<String, String>()

    fun get(domain: String): String? = locked { cookies[domain] }

    fun getForHost(host: String): String? = locked {
        cookies.entries.filter { legacyCookieMatchesHost(it.key, host) }.sortedBy { it.key.length }
            .fold(null as String?) { header, entry -> mergeRequestCookieHeader(header, entry.value) }
    }

    fun put(domain: String, cookie: String?) = locked {
        if (cookie.isNullOrBlank()) {
            cookies.remove(domain)
        } else {
            val merged = mergeCookieStrings(cookies[domain], cookie)
            if (merged.isNullOrBlank()) {
                cookies.remove(domain)
            } else {
                cookies[domain] = merged
            }
        }
        Unit
    }

    fun remove(domain: String) {
        val host = cookieScopeHost(domain)
        if (host == null) locked { cookies.remove(domain) }
        else removeForHost(host, includeSubdomains = true)
    }

    fun removeForHost(host: String, includeSubdomains: Boolean = false) = locked {
        cookies.keys.removeAll { key ->
            legacyCookieMatchesHost(key, host) || (includeSubdomains &&
                cookieScopeHost(key)?.let { cookieDomainMatches(it, host) } == true)
        }
        Unit
    }

    fun clear() = locked { cookies.clear() }

    private fun <T> locked(block: () -> T): T = runBlocking { lock.withLock { block() } }
}

private fun String.isIpAddress(): Boolean {
    if (contains(':')) return true
    val segments = split('.')
    if (segments.size != 4) return false
    return segments.all { segment ->
        segment.toIntOrNull()?.let { it in 0..255 } == true
    }
}
