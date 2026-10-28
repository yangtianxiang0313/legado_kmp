@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.model.StoredHttpCookie
import platform.Foundation.NSDate
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSURLComponents
import platform.WebKit.WKWebView
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

internal object IosWebViewCookieBridge {
    fun prepare(
        webView: WKWebView,
        requestUrl: String,
        headers: Map<String, String>,
        storedCookies: List<StoredHttpCookie> = emptyList(),
        completion: () -> Unit
    ) {
        val nativeCookies = storedCookies.mapNotNull { IosStoredCookieCodec.toNative(it, requestUrl) }
        onMain {
            if (nativeCookies.isEmpty()) {
                prepareHeaders(webView, requestUrl, headers, completion)
            } else {
                var remaining = nativeCookies.size
                nativeCookies.forEach { cookie ->
                    webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                        onMain {
                            remaining -= 1
                            if (remaining == 0) prepareHeaders(webView, requestUrl, headers, completion)
                        }
                    }
                }
            }
        }
    }

    fun exportCookiesForHost(cookies: List<NSHTTPCookie>, url: String): List<StoredHttpCookie> =
        IosStoredCookieCodec.exportForHost(cookies, url)

    private fun prepareHeaders(
        webView: WKWebView,
        requestUrl: String,
        headers: Map<String, String>,
        completion: () -> Unit,
    ) {
        val requestedCookies = parseCookieHeaders(headers)
        if (requestedCookies.isEmpty()) {
            completion()
            return
        }
        val target = cookieUrl(requestUrl)
        if (target == null) {
            completion()
            return
        }

        onMain {
            val store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies ->
                onMain {
                    val existingCookies = cookies.orEmpty().filterIsInstance<NSHTTPCookie>()
                    val now = NSDate().timeIntervalSinceReferenceDate
                    val pending = requestedCookies.mapNotNull { (name, value) ->
                        // A bare request header must not widen a known cookie's path or weaken its flags.
                        val alreadyStored = existingCookies.any { cookie ->
                            cookie.name == name && cookie.value == value &&
                                domainMatches(cookie.domain.orEmpty(), target.host) &&
                                isUnexpired(cookie, now)
                        }
                        if (alreadyStored) null else conservativeCookie(name, value, target)
                    }
                    if (pending.isEmpty()) {
                        completion()
                    } else {
                        var remaining = pending.size
                        pending.forEach { cookie ->
                            store.setCookie(cookie) {
                                onMain {
                                    remaining -= 1
                                    if (remaining == 0) completion()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fun matchingCookieHeader(cookies: List<NSHTTPCookie>, url: String): String? {
        val target = cookieUrl(url) ?: return null
        val now = NSDate().timeIntervalSinceReferenceDate
        return cookies.mapNotNull { cookie ->
            val name = cookie.name ?: return@mapNotNull null
            val value = cookie.value ?: return@mapNotNull null
            if (!isCookieName(name) || !isCookieValue(value) ||
                !domainMatches(cookie.domain.orEmpty(), target.host) ||
                !pathMatches(cookie.path.orEmpty(), target.path) ||
                (cookie.secure && !target.secure) || !isUnexpired(cookie, now)
            ) {
                return@mapNotNull null
            }
            "$name=$value"
        }.joinToString("; ").takeIf { it.isNotEmpty() }
    }

    private fun parseCookieHeaders(headers: Map<String, String>): Map<String, String> {
        val cookies = linkedMapOf<String, String>()
        for ((headerName, headerValue) in headers) {
            if (!headerName.equals("Cookie", ignoreCase = true) ||
                headerValue.any { it == '\r' || it == '\n' }
            ) {
                continue
            }
            for (part in headerValue.split(';')) {
                val pair = part.trim(' ', '\t')
                val separator = pair.indexOf('=')
                if (separator <= 0) continue
                val name = pair.substring(0, separator)
                val value = pair.substring(separator + 1)
                if (isCookieName(name) && isCookieValue(value) && name !in cookies) {
                    // A request header cannot distinguish same-name cookies with different paths.
                    cookies[name] = value
                }
            }
        }
        return cookies
    }

    private fun conservativeCookie(name: String, value: String, target: CookieUrl): NSHTTPCookie? {
        if (!target.secure && (name.startsWith("__Secure-") || name.startsWith("__Host-"))) {
            return null
        }
        // There is no public NSHTTPCookieHTTPOnly properties key. Parse a real Set-Cookie field.
        // Unknown request cookies become host-only, session-only and HttpOnly; JS-readable auth
        // cookies and original SameSite/path/lifetime semantics cannot be recovered from this header.
        val setCookie = "$name=$value; Path=/; HttpOnly" + if (target.secure) "; Secure" else ""
        return NSHTTPCookie.cookiesWithResponseHeaderFields(
            headerFields = mapOf("Set-Cookie" to setCookie),
            forURL = target.url
        ).filterIsInstance<NSHTTPCookie>().singleOrNull()?.takeIf { cookie ->
            val domain = cookie.domain.orEmpty()
            cookie.name == name && cookie.value == value && cookie.path == "/" &&
                !domain.startsWith('.') && canonicalHost(domain) == target.host &&
                cookie.HTTPOnly && cookie.secure == target.secure && cookie.expiresDate == null
        }
    }

    private fun cookieUrl(value: String): CookieUrl? {
        if (value.any { it.code <= 0x20 || it.code == 0x7f }) return null
        val url = NSURL(string = value) ?: return null
        val scheme = url.scheme?.lowercase() ?: return null
        if (scheme != "http" && scheme != "https") return null
        val host = url.host?.let(::canonicalHost)?.takeIf { it.isNotEmpty() } ?: return null
        val components = NSURLComponents.componentsWithURL(url, resolvingAgainstBaseURL = false)
            ?: return null
        return CookieUrl(
            url = url,
            host = host,
            path = components.percentEncodedPath.orEmpty().ifEmpty { "/" },
            secure = scheme == "https"
        )
    }

    private fun domainMatches(rawDomain: String, host: String): Boolean {
        val includesSubdomains = rawDomain.startsWith('.')
        val domain = canonicalHost(if (includesSubdomains) rawDomain.substring(1) else rawDomain)
        if (domain.isEmpty() || domain.startsWith('.')) return false
        if (host == domain) return true
        // Foundation represents domain cookies with a leading dot; host-only cookies never suffix-match.
        return includesSubdomains && !isIpLiteral(host) && !isIpLiteral(domain) &&
            host.endsWith(".$domain")
    }

    private fun pathMatches(cookiePath: String, requestPath: String): Boolean {
        if (!cookiePath.startsWith('/')) return false
        if (cookiePath == requestPath) return true
        return requestPath.startsWith(cookiePath) &&
            (cookiePath.endsWith('/') || requestPath.getOrNull(cookiePath.length) == '/')
    }

    private fun isUnexpired(cookie: NSHTTPCookie, now: Double): Boolean {
        val expiry = cookie.expiresDate?.timeIntervalSinceReferenceDate ?: return true
        return expiry > now
    }

    private fun canonicalHost(host: String): String = host.removeSurrounding("[", "]").lowercase()

    private fun isIpLiteral(host: String): Boolean =
        ':' in host || host.all { it in '0'..'9' || it == '.' }

    private fun isCookieName(name: String): Boolean =
        name.isNotEmpty() && name.first() != '$' && name.lowercase() !in COOKIE_ATTRIBUTES &&
            name.all { character ->
                character in 'a'..'z' || character in 'A'..'Z' || character in '0'..'9' ||
                    character in "!#$%&'*+-.^_`|~"
            }

    private fun isCookieValue(value: String): Boolean {
        val content = if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
            value.substring(1, value.lastIndex)
        } else {
            value
        }
        return content.all { it.code in 0x21..0x7e && it !in "\"\\;," }
    }

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
    }

    private data class CookieUrl(
        val url: NSURL,
        val host: String,
        val path: String,
        val secure: Boolean
    )

    private val COOKIE_ATTRIBUTES = setOf(
        "domain", "path", "expires", "max-age", "secure", "httponly", "samesite",
        "partitioned", "priority", "version", "comment", "commenturl", "discard", "port"
    )
}
