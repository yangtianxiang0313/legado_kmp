@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.engine.darwin.Darwin
import io.ktor.client.plugins.HttpRedirect
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.plugins.defaultRequest
import io.ktor.client.request.header
import platform.Foundation.NSNumber

class IosProxyRequestExecutor : ProxyRequestExecutor {

    override suspend fun executeText(context: SourceExecutionContext, proxy: String): HttpResponse {
        val parsed = parseProxy(proxy)
        val client = createIosProxyHttpClient(parsed, followRedirects = context.requestConfig.followRedirects)
        try {
            val legadoClient = LegadoHttpClient(client)
            return legadoClient.execute(context.requestConfig)
        } finally {
            client.close()
        }
    }

}

/**
 * TLS certificate/hostname validation and other authentication challenges are
 * delegated to Darwin/NSURLSession defaults.
 */
internal fun createIosProxyHttpClient(proxy: ParsedProxy, followRedirects: Boolean = true): HttpClient {
    return HttpClient(Darwin) {
        this.followRedirects = followRedirects
        engine {
            configureSession {
                HTTPShouldSetCookies = false
                HTTPCookieStorage = null
                val dict = mutableMapOf<Any?, Any?>()
                when (proxy.type) {
                    "http" -> {
                        dict["HTTPEnable"] = NSNumber(int = 1)
                        dict["HTTPProxy"] = proxy.host
                        dict["HTTPPort"] = NSNumber(int = proxy.port)
                        dict["HTTPSEnable"] = NSNumber(int = 1)
                        dict["HTTPSProxy"] = proxy.host
                        dict["HTTPSPort"] = NSNumber(int = proxy.port)
                        if (proxy.username != null) {
                            dict["HTTPProxyUsername"] = proxy.username
                            dict["HTTPProxyPassword"] = proxy.password ?: ""
                        }
                    }
                    "socks4", "socks5" -> {
                        dict["SOCKSEnable"] = NSNumber(int = 1)
                        dict["SOCKSProxy"] = proxy.host
                        dict["SOCKSPort"] = NSNumber(int = proxy.port)
                        if (proxy.username != null) {
                            dict["SOCKSUsername"] = proxy.username
                            dict["SOCKSPassword"] = proxy.password ?: ""
                        }
                    }
                }
                connectionProxyDictionary = dict
            }
        }

        install(HttpTimeout) {
            requestTimeoutMillis = 60_000
            connectTimeoutMillis = 15_000
            socketTimeoutMillis = 60_000
        }

        if (followRedirects) {
            install(HttpRedirect) {
                allowHttpsDowngrade = false
                checkHttpMethod = false
            }
        }

        defaultRequest {
            header("User-Agent", DEFAULT_USER_AGENT)
            header("Keep-Alive", "300")
            header("Connection", "Keep-Alive")
            header("Cache-Control", "no-cache")
        }

        expectSuccess = false
    }
}

private const val DEFAULT_USER_AGENT =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
