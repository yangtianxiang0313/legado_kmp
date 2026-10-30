package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.util.currentTimeMillis

/** The only persistent connection state is carried in the JSON cookieStore round trip. */
internal class LegacyJsoupCookieSession(initial: List<StoredHttpCookie>) {
    private val stored = linkedMapOf<CookieKey, StoredHttpCookie>()
    private val received = linkedMapOf<String, String>()

    init {
        require(initial.size <= MAX_COOKIES) { "Jsoup cookieStore exceeds $MAX_COOKIES cookies" }
        val now = currentTimeMillis()
        initial.forEach { cookie ->
            legacyJsoupValidateCookie(cookie.name, cookie.value)
            require(cookie.domain.length <= 253 && cookie.path.length <= 4096) { "Invalid Jsoup cookie scope" }
            val normalized = requireNotNull(cookie.normalizedForHost(cookieHost(cookie.domain.removePrefix(".")))) {
                "Invalid Jsoup stored cookie scope"
            }
            require(!normalized.name.startsWith("__Secure-") || normalized.secure) { "Invalid Jsoup secure cookie" }
            require(!normalized.name.startsWith("__Host-") ||
                normalized.secure && normalized.hostOnly && normalized.path == "/"
            ) { "Invalid Jsoup host cookie" }
            if (!normalized.expired(now)) stored[normalized.key()] = normalized
        }
    }

    fun requestHeader(url: Url, explicit: String?): String? {
        expire()
        val pairs = linkedSetOf<String>()
        explicit?.split(';')?.filter { it.isNotBlank() }?.forEach { pairs.add(it.trim()) }
        stored.values.filter { it.matchesUrl(url) }.sortedWith(storedCookieRequestOrder)
            .forEach { pairs.add("${it.name}=${it.value}") }
        return pairs.joinToString("; ").ifBlank { null }
    }

    fun receive(url: Url, headers: List<String>, check: () -> Unit = {}) {
        val now = currentTimeMillis()
        expire()
        val latest = linkedMapOf<String, String>()
        headers.forEach { field ->
            check()
            val cookieHeaders = mapOf("Set-Cookie" to listOf(field)).withSplitSetCookieHeaders()["Set-Cookie"].orEmpty()
            cookieHeaders.forEach cookie@{ header ->
                check()
                if (header.length > MAX_COOKIE_HEADER) return@cookie
                // Jsoup's flat response cookies are independent of cookie-store domain acceptance.
                val pair = header.substringBefore(';').trim()
                val separator = pair.indexOf('=')
                if (separator > 0) {
                    val name = pair.substring(0, separator).trim()
                    val value = pair.substring(separator + 1).trim()
                    if (legacyJsoupToken(name) && name.length + value.length <= 4096 &&
                        value.none { it < ' ' || it == '\u007f' || it == ';' } && !latest.containsKey(name)
                    ) latest[name] = value
                    while (latest.size > MAX_COOKIES) latest.remove(latest.keys.first())
                }
                val cookie = parseStoredSetCookie(url.toString(), header, now) ?: return@cookie
                if (cookie.name.length + cookie.value.length > 4096 || cookie.domain.length > 253 || cookie.path.length > 4096) {
                    return@cookie
                }
                if (url.protocol.name != "https" && stored.values.any { cookie.shadowsSecureCookie(it) }) return@cookie
                val key = cookie.key()
                val previous = stored[key]
                stored.remove(key)
                if (!cookie.expired(now)) {
                    stored[key] = cookie.copy(creationTimeMillis = previous?.creationTimeMillis ?: now)
                }
                while (stored.size > MAX_COOKIES) stored.remove(stored.keys.first())
            }
        }
        // Newest response wins across redirects; first occurrence wins within one response.
        latest.forEach { (name, value) ->
            received[name] = value
            while (received.size > MAX_COOKIES) received.remove(received.keys.first())
        }
        expire()
    }

    fun responseCookies(): Map<String, String> = received.toMap()

    fun snapshot(): List<StoredHttpCookie> {
        expire()
        return stored.values.toList()
    }

    private fun expire() {
        val now = currentTimeMillis()
        stored.keys.filter { stored[it]?.expired(now) != false }.forEach(stored::remove)
    }

    private fun StoredHttpCookie.expired(now: Long): Boolean = expiresAtMillis?.let { it <= now } == true
    private fun StoredHttpCookie.key(): CookieKey = CookieKey(name, domain, path)
    private data class CookieKey(val name: String, val domain: String, val path: String)

    private companion object {
        const val MAX_COOKIES = 256
        const val MAX_COOKIE_HEADER = 8192
    }
}
