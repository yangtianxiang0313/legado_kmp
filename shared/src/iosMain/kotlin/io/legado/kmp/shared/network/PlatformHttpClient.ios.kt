package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig
import io.ktor.client.engine.darwin.Darwin

/**
 * iOS implementation using Darwin (NSURLSession) engine.
 *
 * TLS certificate/hostname validation and other authentication challenges are
 * delegated to Darwin/NSURLSession defaults.
 */
actual fun createPlatformHttpClient(
    block: HttpClientConfig<*>.() -> Unit
): HttpClient {
    return HttpClient(Darwin) {
        engine {
            configureSession {
                // Source cookies are scoped and persisted by CookieRepository, not a second system jar.
                HTTPShouldSetCookies = false
                HTTPCookieStorage = null
            }
        }
        block()
    }
}

actual fun normalizePlatformRequestUrl(url: String): String = url
