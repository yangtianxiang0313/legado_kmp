@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.client.engine.darwin.Darwin
import io.legado.kmp.shared.util.currentTimeMillis
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.useContents
import okio.ByteString.Companion.toByteString
import platform.CoreFoundation.CFDataGetBytePtr
import platform.CoreFoundation.CFDataGetLength
import platform.CoreFoundation.CFRelease
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSNumber
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSRecursiveLock
import platform.Foundation.NSURLAuthenticationChallenge
import platform.Foundation.NSURLAuthenticationMethodServerTrust
import platform.Foundation.NSURLCredential
import platform.Foundation.NSURLSessionAuthChallengePerformDefaultHandling
import platform.Foundation.NSURLSessionAuthChallengeUseCredential
import platform.Foundation.NSURLSessionConfiguration
import platform.Foundation.serverTrust
import platform.Foundation.credentialForTrust
import platform.Network.nw_endpoint_create_host
import platform.Network.nw_proxy_config_create_http_connect
import platform.Network.nw_proxy_config_create_socksv5
import platform.Network.nw_proxy_config_set_username_and_password
import platform.Security.SecCertificateCopyData
import platform.Security.SecTrustEvaluateWithError
import platform.Security.SecTrustGetCertificateAtIndex
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebView

private val issueLock = NSRecursiveLock()
private val certificateIssues = linkedMapOf<String, SourceCertificateIssue>()

/** Shared by Ktor, WebKit and native file loaders; no global trust-all delegate exists. */
object SourceNetworkNative {
    const val certificateRejectedNotification = "io.legado.source-network.certificate-rejected"

    internal fun handleWebViewChallenge(webView: WKWebView, sourceUrl: String?, compatibilityAllowed: Boolean,
        challenge: NSURLAuthenticationChallenge,
        complete: (platform.Foundation.NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Unit) {
        if (!compatibilityAllowed || challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust) {
            complete(NSURLSessionAuthChallengePerformDefaultHandling, null)
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies ->
            val host = challenge.protectionSpace.host.lowercase().trimEnd('.')
            val hasCredentials = cookies.orEmpty().filterIsInstance<platform.Foundation.NSHTTPCookie>().any {
                val domain = it.domain.lowercase().trimStart('.')
                host == domain || host.endsWith(".$domain")
            }
            if (!hasCredentials && acceptsCertificate(sourceUrl, true, challenge)) {
                complete(NSURLSessionAuthChallengeUseCredential, NSURLCredential.credentialForTrust(requireNotNull(challenge.protectionSpace.serverTrust)))
            } else complete(NSURLSessionAuthChallengePerformDefaultHandling, null)
        }
    }

    fun acceptsCertificate(sourceUrl: String?, compatibilityAllowed: Boolean, challenge: NSURLAuthenticationChallenge): Boolean {
        if (sourceUrl.isNullOrBlank() || !compatibilityAllowed ||
            challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust) return false
        val trust = challenge.protectionSpace.serverTrust ?: return false
        if (SecTrustEvaluateWithError(trust, null)) return false
        val certificate = SecTrustGetCertificateAtIndex(trust, 0) ?: return false
        val data = SecCertificateCopyData(certificate) ?: return false
        val fingerprint = try {
            val length = CFDataGetLength(data)
            if (length !in 1..131_072) return false
            CFDataGetBytePtr(data)?.readBytes(length.toInt())?.toByteString()?.sha256()?.hex() ?: return false
        } finally { CFRelease(data) }
        val host = challenge.protectionSpace.host.lowercase().trimEnd('.')
        val port = challenge.protectionSpace.port.toInt().takeIf { it in 1..65535 } ?: 443
        if (SourceNetworkPolicy.permitsCertificate(sourceUrl, host, port, fingerprint)) return true
        val id = "$sourceUrl\n$host\n$port\n$fingerprint".encodeToByteArray().toByteString().sha256().hex()
        val now = currentTimeMillis()
        issueLock.lock()
        val notify = try {
            val previous = certificateIssues[id]
            certificateIssues[id] = SourceCertificateIssue(id, sourceUrl, host, port, fingerprint, now)
            while (certificateIssues.size > 256) certificateIssues.remove(certificateIssues.keys.first())
            previous == null || now - previous.observedAt > 60_000
        } finally { issueLock.unlock() }
        if (notify) NSNotificationCenter.defaultCenter.postNotificationName(
            certificateRejectedNotification, null, mapOf("issueId" to id)
        )
        return false
    }

    @Throws(Exception::class)
    fun configureDownload(configuration: NSURLSessionConfiguration, sourceUrl: String, proxy: String?) {
        configuration.HTTPMaximumConnectionsPerHost = (SourceNetworkPolicy.effective(sourceUrl).maxConcurrent ?: 6).toLong()
        applySessionProxy(configuration, proxy)
    }

    @Throws(Exception::class)
    fun configureWebView(configuration: WKWebViewConfiguration, proxy: String?) {
        if (proxy.isNullOrBlank()) return
        require(NSProcessInfo.processInfo.operatingSystemVersion.useContents { majorVersion >= 17 }) {
            "WebView proxy requires iOS 17 or later; the request was not sent directly"
        }
        val parsed = parseSourceNetworkProxy(proxy)
        val endpoint = requireNotNull(nw_endpoint_create_host(parsed.host, parsed.port.toString()))
        val nativeProxy = requireNotNull(when (parsed.type) {
            "http" -> nw_proxy_config_create_http_connect(endpoint, null)
            "socks5" -> nw_proxy_config_create_socksv5(endpoint)
            else -> throw UnsupportedProxyRequestException("WebView requires an HTTP or SOCKS5 proxy")
        })
        parsed.username?.let { nw_proxy_config_set_username_and_password(nativeProxy, it, parsed.password) }
        configuration.websiteDataStore.proxyConfigurations = listOf(nativeProxy)
    }
}

internal actual fun pendingSourceCertificateIssues(): List<SourceCertificateIssue> {
    issueLock.lock()
    return try { certificateIssues.values.toList() } finally { issueLock.unlock() }
}

internal actual fun forgetSourceCertificateIssue(id: String) {
    issueLock.lock()
    try { certificateIssues.remove(id) } finally { issueLock.unlock() }
}

internal actual fun createSourcePlatformHttpClient(
    sourceUrl: String,
    proxy: String?,
    allowCertificateCompatibility: Boolean,
    maxConcurrent: Int,
    block: HttpClientConfig<*>.() -> Unit,
): HttpClient = HttpClient(Darwin) {
    engine {
        configureSession {
            HTTPShouldSetCookies = false
            HTTPCookieStorage = null
            URLCredentialStorage = null
            HTTPMaximumConnectionsPerHost = maxConcurrent.toLong()
            applySessionProxy(this, proxy)
        }
        handleChallenge { _, _, challenge, complete ->
            if (SourceNetworkNative.acceptsCertificate(sourceUrl, allowCertificateCompatibility, challenge)) {
                complete(NSURLSessionAuthChallengeUseCredential, NSURLCredential.credentialForTrust(requireNotNull(challenge.protectionSpace.serverTrust)))
            } else complete(NSURLSessionAuthChallengePerformDefaultHandling, null)
        }
    }
    block()
}

private fun applySessionProxy(configuration: NSURLSessionConfiguration, proxy: String?) {
    if (proxy == null) return // No override: retain the device's system proxy.
    val dictionary = mutableMapOf<Any?, Any?>()
    if (proxy.isNotBlank()) {
        val parsed = parseSourceNetworkProxy(proxy)
        when (parsed.type) {
            "http" -> {
                dictionary["HTTPEnable"] = NSNumber(int = 1)
                dictionary["HTTPProxy"] = parsed.host
                dictionary["HTTPPort"] = NSNumber(int = parsed.port)
                dictionary["HTTPSEnable"] = NSNumber(int = 1)
                dictionary["HTTPSProxy"] = parsed.host
                dictionary["HTTPSPort"] = NSNumber(int = parsed.port)
                parsed.username?.let {
                    dictionary["HTTPProxyUsername"] = it
                    dictionary["HTTPProxyPassword"] = parsed.password.orEmpty()
                }
            }
            "socks4", "socks5" -> {
                dictionary["SOCKSEnable"] = NSNumber(int = 1)
                dictionary["SOCKSProxy"] = parsed.host
                dictionary["SOCKSPort"] = NSNumber(int = parsed.port)
                parsed.username?.let {
                    dictionary["SOCKSUsername"] = it
                    dictionary["SOCKSPassword"] = parsed.password.orEmpty()
                }
            }
            else -> error("Unsupported proxy")
        }
    } else {
        dictionary["HTTPEnable"] = NSNumber(int = 0)
        dictionary["HTTPSEnable"] = NSNumber(int = 0)
        dictionary["SOCKSEnable"] = NSNumber(int = 0)
    }
    configuration.connectionProxyDictionary = dictionary
}
