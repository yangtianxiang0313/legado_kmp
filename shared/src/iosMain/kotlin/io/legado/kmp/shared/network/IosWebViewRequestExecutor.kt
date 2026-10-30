package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSThread
import platform.Foundation.NSURL
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
        return withTimeout(60_000L) {
            suspendCancellableCoroutine { continuation ->
                val lifetime = SupervisorJob(continuation.context[Job])
                val scope = CoroutineScope(lifetime + Dispatchers.Main.immediate)
                // Session state and WebKit teardown are confined to the main thread.
                var finished = false
                var webView: WKWebView? = null
                var delegate: IosWebViewNavigationDelegate? = null
                var navigationSession: IosSourceWebNavigationSession? = null

                fun cleanUp() {
                    if (finished) return
                    finished = true
                    lifetime.cancel()
                    delegate?.cancel()
                    navigationSession?.cancel()
                    webView?.navigationDelegate = null
                    webView?.stopLoading()
                    webView?.removeFromSuperview()
                    webView = null
                    delegate = null
                    navigationSession = null
                }

                fun finish(result: Result<HttpResponse>) {
                    if (finished) return
                    cleanUp()
                    if (continuation.isActive) {
                        result.onSuccess(continuation::resume)
                        result.onFailure(continuation::resumeWithException)
                    }
                }

                continuation.invokeOnCancellation {
                    lifetime.cancel()
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
                        val createdSession = IosSourceWebNavigationSession(
                            initialUrl = loadUrl,
                            sourceUrl = context.source?.bookSourceUrl ?: context.requestConfig.url,
                            headers = requestHeaders,
                            cookieRepository = cookieRepository,
                            persistCookies = context.source?.enabledCookieJar == true,
                        )
                        navigationSession = createdSession
                        val createdDelegate = IosWebViewNavigationDelegate(
                            context = context,
                            initialResponse = initialResponse,
                            navigationSession = createdSession,
                            scope = scope,
                            onComplete = ::finish,
                        )
                        delegate = createdDelegate
                        webView = createdView
                        createdView.navigationDelegate = createdDelegate
                        scope.launch {
                            try {
                                createdSession.prepareInitial(createdView)
                                ensureActive()
                                if (!finished && continuation.isActive) {
                                    createdDelegate.loadInitialPage(createdView, requestUrl)
                                }
                            } catch (throwable: Throwable) {
                                if (!finished && continuation.isActive && lifetime.isActive) {
                                    finish(Result.failure(throwable))
                                }
                            }
                        }
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
