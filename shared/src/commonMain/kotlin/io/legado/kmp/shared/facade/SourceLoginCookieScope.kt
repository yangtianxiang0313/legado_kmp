package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.network.CookiePublicSuffixes
import io.legado.kmp.shared.network.cookieHost
import io.legado.kmp.shared.network.matchesHost
import io.legado.kmp.shared.network.normalizedForHost

internal class SourceLoginCookieScope(sourceUrl: String) {
    private val sourceHost = host(sourceUrl)
    private val sourceSite = site(sourceHost)

    fun relatedTargetHost(targetUrl: String): String? {
        val targetHost = host(targetUrl)
        return targetHost.takeIf { site(it) == sourceSite }
    }

    fun accepts(cookie: StoredHttpCookie, targetHost: String = sourceHost): Boolean {
        val normalized = cookie.normalizedForHost(sourceHost) ?: return false
        if (site(normalized.domain) != sourceSite) return false
        // Matching the source host is essential: a sibling's host-only cookie is not this source's cookie.
        return normalized.matchesHost(targetHost)
    }

    private fun site(host: String): String = CookiePublicSuffixes.registrableDomain(host) ?: host

    private fun host(raw: String): String {
        require(raw.startsWith("http://", true) || raw.startsWith("https://", true)) { "Invalid login URL" }
        val url = Url(raw)
        require(url.protocol.name in listOf("http", "https") && url.host.isNotBlank()) { "Invalid login URL" }
        require(url.user.isNullOrEmpty() && url.password.isNullOrEmpty()) { "Invalid login URL" }
        return cookieHost(url.host).removeSuffix(".")
    }
}
