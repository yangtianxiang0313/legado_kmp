package io.legado.kmp.shared.scripting

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.Cookie
import io.legado.kmp.shared.network.SessionCookieStore
import io.legado.kmp.shared.network.cookieScopeHost
import io.legado.kmp.shared.network.extractCookieDomain
import io.legado.kmp.shared.network.httpCookieUrl
import io.legado.kmp.shared.network.legacyCookieMatchesHost
import io.legado.kmp.shared.network.mergeCookieStrings
import io.legado.kmp.shared.network.mergeRequestCookieHeader
import io.legado.kmp.shared.network.storedCookieRequestOrder

/** Script-only tag compatibility; HTTP transport must keep using requestCookieHeader(realUrl). */
internal class LegacyCookieLookup(private val repository: CookieRepository) {
    suspend fun getCookie(tag: String): String {
        if (!validTag(tag)) return ""
        if (tag.isHttpUrlTag()) {
            if (httpCookieUrl(tag) == null) return ""
            // Never retry a URL as a host lookup: doing so would discard path and Secure scope.
            return repository.requestCookieHeader(tag).orEmpty()
        }
        val host = cookieScopeHost(tag)
            ?: return mergeRequestCookieHeader(repository.get(tag)?.cookie, SessionCookieStore.get(tag)).orEmpty()

        // A bare host intentionally has no path/scheme. This is a script inspection view, not a request.
        var header = repository.getCookiesForHost(host).sortedWith(storedCookieRequestOrder)
            .joinToString("; ") { "${it.name}=${it.value}" }.ifBlank { null }
        repository.getAll().filter { legacyCookieMatchesHost(it.url, host) }.sortedBy { it.url.length }
            .forEach { header = mergeRequestCookieHeader(header, it.cookie) }
        return mergeRequestCookieHeader(header, SessionCookieStore.getForHost(host)).orEmpty()
    }

    suspend fun getKey(tag: String, key: String): String {
        if (key.isBlank()) return ""
        return getCookie(tag).split(';').firstNotNullOfOrNull { part ->
            val separator = part.indexOf('=')
            if (separator > 0 && part.substring(0, separator).trim() == key) part.substring(separator + 1) else null
        }.orEmpty()
    }

    suspend fun setCookie(tag: String, cookie: String) {
        val key = storageKey(tag) ?: return
        repository.insert(Cookie(key, cookie))
    }

    suspend fun replaceCookie(tag: String, cookie: String) {
        if (cookie.isBlank()) return
        val key = storageKey(tag) ?: return
        // Merge only the persisted legacy row; never promote sessions or attributed cookies to it.
        val merged = mergeCookieStrings(repository.get(key)?.cookie, cookie)
        if (!merged.isNullOrBlank()) repository.insert(Cookie(key, merged))
    }

    suspend fun removeCookie(tag: String) {
        val key = storageKey(tag) ?: return
        repository.delete(key)
        SessionCookieStore.remove(key)
    }

    private fun storageKey(tag: String): String? {
        if (!validTag(tag) || tag.isHttpUrlTag() && httpCookieUrl(tag) == null) return null
        // Non-host tags retain exact-key compatibility only; no synthetic HTTPS URL or host fallback.
        return extractCookieDomain(tag)
    }

    private fun validTag(tag: String): Boolean = tag.isNotBlank() && tag.none { it < ' ' || it == '\u007f' }

    private fun String.isHttpUrlTag(): Boolean = startsWith("http://", true) || startsWith("https://", true)
}
