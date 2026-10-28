package io.legado.kmp.shared.network

import io.ktor.client.HttpClient
import io.ktor.client.HttpClientConfig

/**
 * Platform-specific HttpClient factory.
 *
 * Each platform provides an actual implementation that creates an HttpClient
 * with the appropriate engine and SSL/TLS configuration.
 *
 * Legacy legado uses an "unsafe trust-all" SSL strategy (SSLHelper.unsafeTrustManager)
 * that accepts all certificates including expired and self-signed ones. This is necessary
 * because many book source websites have expired or invalid SSL certificates.
 */
expect fun createPlatformHttpClient(
    block: HttpClientConfig<*>.() -> Unit = {}
): HttpClient

/**
 * Normalize request URLs before handing them to the platform HTTP engine.
 *
 * Legacy JVM networking accepts internationalized domain names via OkHttp/URL handling.
 * Shared must normalize those hosts the same way instead of failing early on URI parsing.
 */
expect fun normalizePlatformRequestUrl(url: String): String
