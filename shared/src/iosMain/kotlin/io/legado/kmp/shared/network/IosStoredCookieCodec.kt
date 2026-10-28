@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.util.currentTimeMillis
import platform.Foundation.NSDate
import platform.Foundation.NSDateFormatter
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSLocale
import platform.Foundation.NSTimeZone
import platform.Foundation.NSURL
import platform.Foundation.NSTimeIntervalSince1970
import platform.Foundation.timeZoneForSecondsFromGMT
import platform.WebKit.WKWebView

/** Foundation conversion belongs to the iOS boundary, not the shared cookie model. */
object IosSourceCookieBridge {
    fun prepareWebView(
        webView: WKWebView,
        ownerUrl: String,
        headers: Map<String, String>,
        cookies: List<StoredHttpCookie>,
        completion: () -> Unit,
    ) = IosWebViewCookieBridge.prepare(webView, ownerUrl, headers, cookies, completion)

    fun platformCookies(cookies: List<StoredHttpCookie>, ownerUrl: String): List<NSHTTPCookie> =
        cookies.mapNotNull { IosStoredCookieCodec.toNative(it, ownerUrl) }

    fun storedCookies(cookies: List<NSHTTPCookie>, ownerUrl: String): List<StoredHttpCookie> =
        IosStoredCookieCodec.exportForHost(cookies, ownerUrl)
}

internal object IosStoredCookieCodec {
    fun toNative(cookie: StoredHttpCookie, ownerUrl: String): NSHTTPCookie? {
        val owner = NSURL(string = ownerUrl) ?: return null
        val host = owner.host?.lowercase() ?: return null
        val domain = cookie.domain.trimStart('.').lowercase()
        if (!matchesHost(domain, host, cookie.hostOnly) || !validName(cookie.name) ||
            !validValue(cookie.value) || !cookie.path.startsWith('/') ||
            cookie.path.any { it == ';' || it.code <= 0x20 || it.code == 0x7f } ||
            cookie.expiresAtMillis?.let { it <= currentTimeMillis() } == true
        ) return null
        val scheme = if (cookie.secure) "https" else owner.scheme ?: return null
        val origin = NSURL(string = "$scheme://$host${cookie.path}") ?: return null
        val header = buildString {
            append(cookie.name).append('=').append(cookie.value)
            append("; Path=").append(cookie.path)
            if (!cookie.hostOnly) append("; Domain=").append(domain)
            if (cookie.secure) append("; Secure")
            if (cookie.httpOnly) append("; HttpOnly")
            cookie.sameSite?.takeIf { it.lowercase() in setOf("strict", "lax", "none") }
                ?.let { append("; SameSite=").append(it) }
            cookie.expiresAtMillis?.let { expiry ->
                val formatter = NSDateFormatter().apply {
                    locale = NSLocale(localeIdentifier = "en_US_POSIX")
                    timeZone = NSTimeZone.timeZoneForSecondsFromGMT(0)
                    dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                }
                append("; Expires=").append(formatter.stringFromDate(NSDate(timeIntervalSinceReferenceDate = expiry / 1000.0 - NSTimeIntervalSince1970)))
            }
        }
        return NSHTTPCookie.cookiesWithResponseHeaderFields(mapOf("Set-Cookie" to header), origin)
            .filterIsInstance<NSHTTPCookie>().singleOrNull()?.takeIf {
                it.name == cookie.name && it.value == cookie.value && it.path == cookie.path &&
                    it.secure == cookie.secure && it.HTTPOnly == cookie.httpOnly &&
                    it.domain.orEmpty().startsWith('.') != cookie.hostOnly
            }
    }

    fun exportForHost(cookies: List<NSHTTPCookie>, ownerUrl: String): List<StoredHttpCookie> {
        val host = NSURL(string = ownerUrl)?.host?.lowercase() ?: return emptyList()
        return cookies.mapNotNull { cookie ->
            val name = cookie.name ?: return@mapNotNull null
            val value = cookie.value ?: return@mapNotNull null
            val domain = cookie.domain.orEmpty().trimStart('.').lowercase()
            val hostOnly = !cookie.domain.orEmpty().startsWith('.')
            if (!matchesHost(domain, host, hostOnly) || !validName(name) || !validValue(value)) return@mapNotNull null
            StoredHttpCookie(
                name = name,
                value = value,
                domain = domain,
                path = cookie.path.orEmpty().ifEmpty { "/" },
                hostOnly = hostOnly,
                secure = cookie.secure,
                httpOnly = cookie.HTTPOnly,
                expiresAtMillis = cookie.expiresDate?.let { ((it.timeIntervalSinceReferenceDate + NSTimeIntervalSince1970) * 1000.0).toLong() },
                sameSite = cookie.sameSitePolicy,
            )
        }
    }

    private fun matchesHost(domain: String, host: String, hostOnly: Boolean): Boolean =
        domain.isNotBlank() && (host == domain || !hostOnly && host.endsWith(".$domain"))

    private fun validName(name: String): Boolean = name.isNotEmpty() && name.all {
        it.isLetterOrDigit() && it.code < 128 || it in "!#$%&'*+-.^_`|~"
    }

    private fun validValue(value: String): Boolean = value.all { it.code in 0x21..0x7e && it !in "\"\\;," }
}
