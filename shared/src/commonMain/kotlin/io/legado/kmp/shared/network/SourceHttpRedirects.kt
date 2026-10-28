package io.legado.kmp.shared.network

import io.ktor.client.statement.HttpResponse as KtorHttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.takeFrom
import kotlinx.coroutines.withTimeout

internal suspend fun executeSourceHttpRedirects(
    config: HttpRequestConfig,
    execute: suspend (HttpRequestConfig) -> KtorHttpResponse,
): KtorHttpResponse = withTimeout(config.timeout.inWholeMilliseconds.coerceAtLeast(1L)) {
    var current = config
    var redirects = 0
    while (true) {
        val response = execute(current)
        val status = response.status.value
        if (status !in SOURCE_REDIRECT_STATUSES) return@withTimeout response
        val location = response.headers["Location"] ?: return@withTimeout response
        val origin = response.call.request.url
        val target = runCatching {
            URLBuilder(origin).apply {
                if (location.isNotEmpty() && !location.startsWith('#')) parameters.clear()
            }.takeFrom(location).build()
        }.getOrNull()
            ?: return@withTimeout response
        if (target.protocol.name !in SOURCE_HTTP_PROTOCOLS ||
            (origin.protocol.name == "https" && target.protocol.name == "http")
        ) {
            return@withTimeout response
        }
        if (++redirects > MAX_SOURCE_REDIRECTS) {
            response.bodyAsChannel().cancel(null)
            throw NetworkException("Too many HTTP redirects")
        }

        // Match Legado's OkHttp POST handling; 307/308 retain the method and body.
        val redirectToGet = status != 307 && status != 308 &&
            current.method != HttpMethod.GET && current.method != HttpMethod.HEAD
        val sameOrigin = origin.hasSameOrigin(target)
        val headers = current.headers.filterKeys { name ->
            !(redirectToGet && SOURCE_BODY_HEADERS.any { it.equals(name, ignoreCase = true) }) &&
                !(SOURCE_AUTH_HEADERS.any { it.equals(name, ignoreCase = true) } && !sameOrigin)
        }
        current = current.copy(
            url = target.toString(),
            method = if (redirectToGet) HttpMethod.GET else current.method,
            headers = headers,
            parameters = emptyMap(),
            body = current.body.takeUnless { redirectToGet },
            bodyBytes = current.bodyBytes.takeUnless { redirectToGet },
        )
        response.bodyAsChannel().cancel(null)
    }
    @Suppress("UNREACHABLE_CODE")
    error("Unreachable redirect state")
}

private fun Url.hasSameOrigin(other: Url): Boolean =
    protocol == other.protocol && host.equals(other.host, ignoreCase = true) && port == other.port

private val SOURCE_REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
private val SOURCE_HTTP_PROTOCOLS = setOf("http", "https")
private val SOURCE_BODY_HEADERS = setOf("Content-Type", "Content-Length", "Transfer-Encoding", "X-HTTP-Method-Override")
private val SOURCE_AUTH_HEADERS = setOf("Authorization", "Proxy-Authorization", "Cookie")
private const val MAX_SOURCE_REDIRECTS = 20
