package io.legado.kmp.shared.facade

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.network.PreparedMediaRequest
import org.koin.mp.KoinPlatformTools
import kotlin.coroutines.cancellation.CancellationException

/** Shared HTTP resource scoping only; never sends requests or runs source/login scripts. */
class MediaResourceFacade(private val cookies: CookieRepository) {
    companion object {
        @Throws(RecoverableSharedException::class, CancellationException::class)
        fun create(): MediaResourceFacade = try {
            SharedBootstrap.startOrThrow()
            val koin = KoinPlatformTools.defaultContext().get()
            MediaResourceFacade(koin.get<CookieRepository>())
        } catch (error: Throwable) {
            findFacadeRequestCancellation(error)?.let { throw it }
            throw RecoverableSharedException("MediaResourceFacade.create", "媒体资源服务不可用，请重试")
        }
    }

    /**
     * Call for every absolute playlist/key/segment URL and every redirect target. Retain the returned
     * headers and target URL in the current request copy, including for descendant resources. Keep
     * the initial resourceContext.headerOriginUrl; on ANY origin change clear its explicitCookie.
     * Never restart from the original headers/context after crossing origins, even on a return hop.
     * The caller owns redirect method/body changes, hop/deadline limits, and response/body limits.
     *
     * A null context is a direct-native input only: origin=request.url, sourceUrl="", and its Cookie
     * is opaque explicit input, NOT jar provenance. Responses are memory-only. Before reusing such
     * an intent for hops/children, supply a context retaining that initial origin and explicit input;
     * never infer explicit cookies from this method's merged output. Source intents include context.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun headersForURL(request: PreparedMediaRequest, targetUrl: String): Map<String, String> =
        recoverMediaResource("headersForURL") { mediaResourceHeadersForUrl(cookies, request, targetUrl) }

    /**
     * Record every actual response BEFORE following its redirect, including the final response.
     * request.url must be the current hop, not the original playlist or an implicitly redirected URL.
     * Pass all raw Set-Cookie fields; combined fields with Expires commas are supported. The context's
     * enabledCookieJar controls persistence only, never reading or updating URL-scoped session cookies.
     * A missing context or empty sourceUrl never persists cookies. CookieJar headers cannot override it.
     * No loginCheckJs, book/reading mutations, network probes, or response retries run here.
     */
    @Throws(RecoverableSharedException::class, CancellationException::class)
    suspend fun recordResponseCookies(request: PreparedMediaRequest, responseUrl: String, setCookieHeaders: List<String>) {
        recoverMediaResource("recordResponseCookies") {
            recordMediaResourceCookies(cookies, request, responseUrl, setCookieHeaders)
        }
    }
}
