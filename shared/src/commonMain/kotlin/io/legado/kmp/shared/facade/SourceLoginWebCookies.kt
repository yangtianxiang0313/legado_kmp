package io.legado.kmp.shared.facade

import io.ktor.http.Url
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.CookieHostSnapshot
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.network.cookieHost
import io.legado.kmp.shared.network.normalizedForHost

data class SourceLoginCookieSeed(
    val ownerUrl: String,
    val cookies: List<StoredHttpCookie>,
    val cookieHeader: String?,
)

/** Only the native, isolated browser supplies these owners; script-facing source scopes stay strict. */
internal class SourceLoginWebCookies(private val repository: CookieRepository) {
    suspend fun seed(targetUrl: String): SourceLoginCookieSeed {
        val owner = owner(targetUrl)
        return SourceLoginCookieSeed(owner, repository.getCookiesForHost(owner), repository.requestCookieHeader(owner))
    }

    suspend fun save(snapshots: List<CookieHostSnapshot>) {
        require(snapshots.isNotEmpty() && snapshots.size <= 32) { "Invalid browser cookie owners" }
        require(snapshots.sumOf { it.cookies.size } <= 2048) { "Too many browser cookies" }
        val normalized = snapshots.map { snapshot ->
            val owner = owner(snapshot.ownerUrl)
            val host = cookieHost(Url(owner).host)
            CookieHostSnapshot(owner, snapshot.cookies.mapNotNull { cookie -> cookie.normalizedForHost(host) })
        }
        repository.replaceCookiesForHosts(normalized, persistSession = true)
    }

    private fun owner(raw: String): String {
        require(raw.length <= 32768 && raw.none { it.code <= 0x20 || it.code == 0x7f }) { "Invalid browser cookie owner" }
        val url = Url(raw)
        require(url.protocol.name in listOf("http", "https") && url.host.isNotBlank() &&
            url.user.isNullOrEmpty() && url.password.isNullOrEmpty() && !url.host.endsWith('.')) {
            "Invalid browser cookie owner"
        }
        val host = cookieHost(url.host)
        val literal = if (':' in host) "[$host]" else host
        return "${url.protocol.name}://$literal:${url.port}/"
    }
}
