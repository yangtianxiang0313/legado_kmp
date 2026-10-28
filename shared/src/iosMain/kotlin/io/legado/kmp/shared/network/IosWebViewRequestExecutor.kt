package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.setValue
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
class IosWebViewRequestExecutor(
    private val httpUseCase: HttpUseCase,
    private val cookieRepository: CookieRepository,
    private val proxyRequestExecutor: ProxyRequestExecutor = IosProxyRequestExecutor(),
) : WebViewRequestExecutor {

    override suspend fun executeText(context: SourceExecutionContext): HttpResponse {
        val directGet = context.request.method == HttpMethod.GET
        val initialResponse = if (directGet) {
            // The navigation delegate replaces this with the main-frame HTTP response.
            HttpResponse.success().copy(url = context.requestConfig.url)
        } else {
            context.proxy?.takeIf { it.isNotBlank() }?.let { proxy ->
                proxyRequestExecutor.executeText(context, proxy)
            } ?: httpUseCase.execute(context.requestConfig).getOrThrow()
        }
        if (!directGet && (!initialResponse.isSuccessful || initialResponse.bodyText.isBlank())) {
            return initialResponse
        }
        val loadUrl = if (directGet) context.requestConfig.url else {
            initialResponse.url.ifBlank { context.request.url }
        }
        val requestUrl = NSURL(string = loadUrl)
            ?: throw IllegalArgumentException("Invalid WebView URL: $loadUrl")
        val seedUrls = listOfNotNull(loadUrl, context.source?.bookSourceUrl)
            .filter { NSURL(string = it)?.host != null }.distinctBy { NSURL(string = it)?.host }
        val cookieSeeds = seedUrls.map { it to cookieRepository.getCookiesForHost(it) }

        return withTimeout(60_000L) {
            suspendCancellableCoroutine { continuation ->
                // Session state and WebKit teardown are confined to the main thread.
                var finished = false
                var webView: WKWebView? = null
                var delegate: IosWebViewNavigationDelegate? = null
                var cookieJob: Job? = null

                fun cleanUp() {
                    finished = true
                    delegate?.cancel()
                    webView?.navigationDelegate = null
                    webView?.stopLoading()
                    webView?.removeFromSuperview()
                    cookieJob?.cancel()
                    cookieJob = null
                    webView = null
                    delegate = null
                }

                fun finish(result: Result<HttpResponse>) {
                    if (finished) return
                    cleanUp()
                    if (continuation.isActive) {
                        result.onSuccess(continuation::resume)
                        result.onFailure(continuation::resumeWithException)
                    }
                }

                fun persistCookies(view: WKWebView, completion: () -> Unit) {
                    if (finished || !continuation.isActive) return
                    view.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies ->
                        onMain {
                            if (finished || !continuation.isActive) return@onMain
                            val finalUrl = view.URL?.absoluteString.orEmpty().ifBlank { loadUrl }
                            val snapshot = cookies.orEmpty().filterIsInstance<NSHTTPCookie>()
                            cookieJob = CoroutineScope(continuation.context).launch(Dispatchers.Default) {
                                try {
                                    for (url in (seedUrls + finalUrl).distinctBy { NSURL(string = it)?.host }) {
                                        ensureActive()
                                        cookieRepository.replaceCookiesForHost(
                                            url,
                                            IosWebViewCookieBridge.exportCookiesForHost(snapshot, url),
                                            persistSession = context.source?.enabledCookieJar == true,
                                            persistCookies = context.source?.enabledCookieJar == true,
                                        )
                                    }
                                    ensureActive()
                                    onMain {
                                        if (!finished && continuation.isActive) completion()
                                    }
                                } catch (throwable: Throwable) {
                                    onMain {
                                        if (!finished && continuation.isActive) finish(Result.failure(throwable))
                                    }
                                }
                            }
                        }
                    }
                }

                continuation.invokeOnCancellation {
                    onMain { cleanUp() }
                }

                onMain {
                    if (finished || !continuation.isActive) return@onMain
                    try {
                        val configuration = WKWebViewConfiguration().apply {
                            websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
                        }
                        val createdView = WKWebView(
                            frame = CGRectMake(0.0, 0.0, 1.0, 1.0),
                            configuration = configuration,
                        )
                        val requestHeaders = context.requestConfig.headers.withoutNullUserAgent()
                        requestHeaders.entries
                            .firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }
                            ?.value?.takeIf { it.isNotBlank() }
                            ?.let { createdView.customUserAgent = it }
                        val createdDelegate = IosWebViewNavigationDelegate(
                            context = context,
                            initialResponse = initialResponse,
                            onComplete = ::finish,
                            onCookies = ::persistCookies,
                        )
                        delegate = createdDelegate
                        webView = createdView
                        createdView.navigationDelegate = createdDelegate
                        fun loadPreparedPage() {
                            if (!finished && continuation.isActive) {
                                try {
                                    if (directGet) {
                                        val request = NSMutableURLRequest.requestWithURL(requestUrl)
                                        requestHeaders.filterKeys { !it.equals("Cookie", true) }.forEach { (name, value) ->
                                            request.setValue(value, forHTTPHeaderField = name)
                                        }
                                        createdView.loadRequest(request)
                                    } else {
                                        createdView.loadHTMLString(initialResponse.bodyText, baseURL = requestUrl)
                                    }
                                } catch (throwable: Throwable) {
                                    finish(Result.failure(throwable))
                                }
                            }
                        }
                        fun prepareSeed(index: Int) {
                            if (finished || !continuation.isActive) return
                            val seed = cookieSeeds.getOrNull(index)
                            if (seed == null) {
                                loadPreparedPage()
                            } else {
                                val headers = if (NSURL(string = seed.first)?.host == requestUrl.host) requestHeaders else emptyMap()
                                IosWebViewCookieBridge.prepare(createdView, seed.first, headers, seed.second) {
                                    if (!finished && continuation.isActive) prepareSeed(index + 1)
                                }
                            }
                        }
                        prepareSeed(0)
                    } catch (throwable: Throwable) {
                        finish(Result.failure(throwable))
                    }
                }
            }
        }
    }

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
    }
}
