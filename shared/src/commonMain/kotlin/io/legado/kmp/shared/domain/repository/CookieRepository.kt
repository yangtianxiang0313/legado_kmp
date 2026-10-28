package io.legado.kmp.shared.domain.repository

import io.legado.kmp.shared.model.Cookie
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.model.CookieHostSnapshot

interface CookieRepository {
    /** Structured cookies matching the URL's host, path, scheme and expiry. */
    suspend fun getCookiesForUrl(url: String): List<StoredHttpCookie>
    /** All paths and schemes for this host, including applicable parent-domain cookies. */
    suspend fun getCookiesForHost(url: String): List<StoredHttpCookie>
    /** persistCookies=false keeps even expiring cookies in memory; only explicit persistSession saves sessions. */
    suspend fun saveCookies(
        url: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean = false,
        persistCookies: Boolean = true
    )
    /** Authoritative host snapshot; missing cookies (including legacy strings) are removed. */
    suspend fun replaceCookiesForHost(
        url: String,
        cookies: List<StoredHttpCookie>,
        persistSession: Boolean = false,
        persistCookies: Boolean = true
    )
    /** Commits all visited hosts together, retaining unrelated hosts and original cookie scopes. */
    suspend fun replaceCookiesForHosts(snapshots: List<CookieHostSnapshot>, persistSession: Boolean = false)
    /** Ordered HTTP header, retaining distinct paths and the opaque legacy compatibility channel. */
    suspend fun requestCookieHeader(url: String): String?
    suspend fun get(url: String): Cookie?
    suspend fun getAll(): List<Cookie>
    suspend fun getOkHttpCookies(): List<Cookie>
    suspend fun insert(cookie: Cookie)
    suspend fun update(cookie: Cookie)
    suspend fun delete(url: String)
    suspend fun deleteOkHttp()
}
