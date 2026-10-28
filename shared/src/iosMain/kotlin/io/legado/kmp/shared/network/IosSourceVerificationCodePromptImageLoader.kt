@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.ktor.http.URLBuilder
import io.ktor.http.Url
import io.ktor.http.takeFrom
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookSource
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.useContents
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import platform.Foundation.NSData
import platform.Foundation.create
import platform.UIKit.UIImage
import kotlin.time.Duration.Companion.seconds

internal class IosSourceVerificationCodePromptImageLoader(
    private val httpUseCase: HttpUseCase,
    private val cookieRepository: CookieRepository,
    private val headerResolver: SourceHeaderResolver,
) {
    /** Runs in the prompt's main-thread job; checkCurrent also guards repository writes. */
    suspend fun load(source: BookSource, imageRule: String, checkCurrent: () -> Unit): UIImage = withTimeout(30_000L) {
        val built = AnalyzeUrl().build(imageRule, source.bookSourceUrl)
        checkCurrent()
        require(!built.useWebView && built.proxy.isNullOrBlank() && built.serverId == null) {
            "Verification images require a direct HTTP request"
        }
        // Android's Glide Request.Builder always loads captcha images with GET, even with URL options.
        val initial = built.toHttpRequestConfig().copy(method = HttpMethod.GET, body = null, bodyBytes = null)
        val imageOrigin = checkedUrl(initial.url)
        val sourceOrigin = httpCookieUrl(source.bookSourceUrl)
        val variables = mapOf(
            "url" to built.url,
            "baseUrl" to built.baseUrl,
            "source" to mapOf(
                "bookSourceUrl" to source.bookSourceUrl,
                "bookSourceName" to source.bookSourceName,
                "loginUrl" to source.loginUrl,
                "loginCheckJs" to source.loginCheckJs,
                "enabledCookieJar" to source.enabledCookieJar,
            ),
        )
        val sourceHeaders = cleanHeaders(headerResolver.resolve(source.header, variables))
        checkCurrent()
        val headers = sourceHeaders.filterKeys { name ->
            sourceOrigin?.sameOrigin(imageOrigin) == true || name in publicHeaders
        }.toMutableMap()
        // Explicit image-rule headers are scoped to that image's origin, not to redirect targets.
        headers.putAll(cleanHeaders(initial.headers))
        if (!headers.containsKey("accept")) headers["accept"] = "image/*"
        headers["cache-control"] = "no-cache, no-store, max-age=0"
        headers["pragma"] = "no-cache"
        var current = initial.copy(
            url = imageOrigin.toString(),
            headers = headers,
            followRedirects = false,
            cacheStrategy = CacheStrategy.NoCache,
            timeout = 30.seconds,
        )
        var redirects = 0
        var allowPrivateHeaders = true
        while (true) {
            checkCurrent()
            val currentUrl = checkedUrl(current.url)
            val requestHeaders = current.headers.filterKeys { !it.equals("cookie", ignoreCase = true) }.toMutableMap()
            val explicitCookie = current.headers["cookie"].takeIf { allowPrivateHeaders }
            val cookie = mergeRequestCookieHeader(cookieRepository.requestCookieHeader(current.url), explicitCookie)
            checkCurrent()
            if (!cookie.isNullOrBlank()) requestHeaders["Cookie"] = cookie
            val response = withContext(Dispatchers.Default) {
                httpUseCase.execute(current.copy(headers = requestHeaders)).getOrThrow()
            }
            checkCurrent()
            val responseUrl = checkedUrl(response.url.ifBlank { current.url })
            check(responseUrl.sameOrigin(currentUrl)) { "Unexpected automatic verification image redirect" }
            val setCookies = response.headerValues("Set-Cookie").mapNotNull {
                parseStoredSetCookie(responseUrl.toString(), it)
            }
            if (setCookies.isNotEmpty()) {
                checkCurrent()
                cookieRepository.saveCookies(
                    responseUrl.toString(),
                    setCookies,
                    persistCookies = source.enabledCookieJar,
                )
                checkCurrent()
            }
            if (response.statusCode !in redirectStatuses) {
                if (!response.isSuccessful) throw HttpException(response.statusCode, response.statusText)
                return@withTimeout decodeImage(response, checkCurrent)
            }
            val location = response.headerValues("Location").firstOrNull()
                ?: throw NetworkException("Verification image redirect has no Location")
            require(location.length < 64 * 1024 && location.none { it < ' ' || it == '\u007f' }) {
                "Invalid verification image redirect"
            }
            if (++redirects > 10) throw NetworkException("Too many verification image redirects")
            val target = checkedUrl(URLBuilder(responseUrl).apply {
                if (location.isNotEmpty() && !location.startsWith('#')) parameters.clear()
            }.takeFrom(location).build().toString())
            require(responseUrl.protocol.name != "https" || target.protocol.name != "http") {
                "Insecure verification image redirect"
            }
            allowPrivateHeaders = allowPrivateHeaders && responseUrl.sameOrigin(target)
            current = current.copy(
                url = target.toString(),
                headers = current.headers.filterKeys { name ->
                    allowPrivateHeaders || name in publicHeaders
                },
                parameters = emptyMap(),
            )
        }
        @Suppress("UNREACHABLE_CODE")
        error("Unreachable verification image redirect state")
    }

    private suspend fun decodeImage(response: HttpResponse, checkCurrent: () -> Unit): UIImage {
        require(response.body.isNotEmpty() && response.body.size <= 8 * 1024 * 1024) {
            "Verification image is empty or too large"
        }
        val contentType = response.headerValues("Content-Type").firstOrNull()?.substringBefore(';')?.trim()?.lowercase()
        require(contentType == null || contentType.isEmpty() || contentType.startsWith("image/") ||
            contentType == "application/octet-stream" || contentType == "binary/octet-stream"
        ) { "Verification image response is not an image" }
        val image = withContext(Dispatchers.Default) {
            val data = response.body.usePinned { pinned ->
                NSData.create(bytes = pinned.addressOf(0), length = response.body.size.toULong())
            }
            val decoded = UIImage.imageWithData(data) ?: throw NetworkException("Unable to decode verification image")
            val pixels = decoded.size.useContents { width * height * decoded.scale * decoded.scale }
            require(pixels.isFinite() && pixels > 0 && pixels <= 16_000_000) { "Verification image dimensions are too large" }
            decoded
        }
        checkCurrent()
        return image
    }

    private fun cleanHeaders(headers: Map<String, String>): Map<String, String> = buildMap {
        headers.forEach { (rawName, value) ->
            val name = rawName.lowercase()
            if (name.isNotEmpty() && name.all { it in 'a'..'z' || it in '0'..'9' || it in "!#$%&'*+-.^_`|~" } &&
                name !in transportHeaders && value.none { it < ' ' || it == '\u007f' }
            ) put(name, value)
        }
    }

    private fun checkedUrl(value: String): Url {
        require(value.length < 64 * 1024 && value.none { it < ' ' || it == '\u007f' || it == '\\' }) {
            "Invalid verification image URL"
        }
        val parsed = httpCookieUrl(value) ?: throw IllegalArgumentException("Verification image must use HTTP(S)")
        require(parsed.user.isNullOrEmpty() && parsed.password.isNullOrEmpty()) { "Verification image URL contains credentials" }
        return URLBuilder(parsed).apply { fragment = "" }.build()
    }

    private fun Url.sameOrigin(other: Url): Boolean =
        protocol == other.protocol && host.equals(other.host, ignoreCase = true) && port == other.port

    private fun HttpResponse.headerValues(name: String): List<String> =
        allHeaders.entries.filter { it.key.equals(name, ignoreCase = true) }.flatMap { it.value }.ifEmpty {
            headers.entries.filter { it.key.equals(name, ignoreCase = true) }.map { it.value }
        }

    private companion object {
        val redirectStatuses = setOf(301, 302, 303, 307, 308)
        val publicHeaders = setOf("user-agent", "accept", "accept-language", "cache-control", "pragma")
        val transportHeaders = setOf(
            "host", "connection", "keep-alive", "transfer-encoding", "content-length", "upgrade", "te", "trailer",
            "proxy", "proxy-authorization", "proxy-connection", "cookiejar", "expect", "x-http-method-override",
        )
    }
}
