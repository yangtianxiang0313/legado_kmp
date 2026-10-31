@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import platform.Foundation.NSURL
import platform.Foundation.NSThread
import platform.UIKit.UIAlertController
import platform.UIKit.UIAlertControllerStyleAlert
import platform.UIKit.UIApplication
import platform.UIKit.UINavigationController
import platform.UIKit.UITabBarController
import platform.UIKit.UIViewController
import platform.darwin.DISPATCH_TIME_NOW
import platform.darwin.dispatch_after
import platform.darwin.dispatch_get_main_queue
import platform.darwin.dispatch_time
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class IosInteractiveSourceCapability(
    private val httpUseCase: HttpUseCase,
    private val cookieRepository: CookieRepository,
    private val webViewRequestExecutor: WebViewRequestExecutor,
    private val proxyRequestExecutor: ProxyRequestExecutor,
    private val mediaRequestExecutor: MediaRequestExecutor,
    private val headerResolver: SourceHeaderResolver = SourceHeaderResolver(),
    private val sourceRequestExecutor: () -> SourceRequestExecutor,
    private val sourceStateStore: SourceStateStore? = null,
) : InteractiveSourceCapability {

    override suspend fun executeWebView(request: LegacyWebViewRequest): String? {
        val requestUrl = request.url?.takeIf { it.isNotBlank() }
        if (request.html == null && requestUrl == null) {
            throw SharedCapabilityException(
                capabilityGapKey = "webview_request_unsupported",
                message = "Legacy JS webView requests require html or a concrete URL on iOS"
            )
        }
        if (request.html == null && request.sourceRegex == null && request.overrideUrlRegex == null) {
            checkNotNull(requestUrl)
            val context = SourceExecutionContext(
                request = BuiltUrl(
                    ruleUrl = requestUrl,
                    url = requestUrl,
                    urlNoQuery = requestUrl.substringBefore("?"),
                    baseUrl = AnalyzeUrl.getBaseUrl(requestUrl),
                    useWebView = true,
                    webJs = request.javaScript,
                    webViewDelayTime = request.webViewDelayTime,
                ),
                requestConfig = HttpRequestConfig(
                    url = requestUrl,
                    method = HttpMethod.GET,
                    headers = request.headers
                ),
                source = request.source,
                defaultHeaders = request.headers,
                cookieDomain = cookieDomain(request.source, requestUrl),
                proxy = request.proxy
            )
            val response = webViewRequestExecutor.executeText(context)
            if (!response.isSuccessful) {
                throw HttpException(response.statusCode, response.statusText)
            }
            return response.bodyText
        }
        return executeInteractiveWebView(request)
    }

    override suspend fun executeProxy(context: SourceExecutionContext, proxy: String): HttpResponse {
        return proxyRequestExecutor.executeText(context, proxy)
    }

    override suspend fun executeMedia(context: SourceExecutionContext): HttpResponse {
        context.proxy?.takeIf { it.isNotBlank() }?.let { proxy ->
            return proxyRequestExecutor.executeText(context, proxy).let(::encodeMediaBodyAsHex)
        }
        return mediaRequestExecutor.execute(context)
    }

    override suspend fun startBrowser(source: BookSource?, url: String, title: String) {
        browserVerification().present(source, url, title, waitForResult = false)
    }

    override suspend fun startBrowserAwait(
        source: BookSource?,
        url: String,
        title: String,
        refetchAfterSuccess: Boolean,
    ): SourceResponse {
        return checkNotNull(browserVerification().present(
            source = source,
            url = url,
            title = title,
            waitForResult = true,
            refetch = if (refetchAfterSuccess) {
                { headerOverride ->
                    val executor = sourceRequestExecutor()
                    if (source != null) {
                        executor.executeForLegacyJs(
                            urlRule = url,
                            source = source,
                            headerJson = headerOverride,
                            baseUrl = source.bookSourceUrl,
                            ruleData = emptyMap(),
                            chapter = null,
                        )
                    } else {
                        SourceResponse.fromHttpResponse(
                            executor.executeText(
                                request = AnalyzeUrl().build(url, url),
                                defaultHeaders = headerResolver.resolve(null),
                            ).getOrThrow().response
                        )
                    }
                }
            } else null,
        ))
    }

    override suspend fun getVerificationCode(source: BookSource?, imageUrl: String): String {
        return IosSourceVerificationCodePrompt(httpUseCase, cookieRepository, headerResolver).prompt(source, imageUrl)
    }

    override suspend fun openUrl(source: BookSource?, url: String, mimeType: String?) {
        val requestUrl = NSURL.URLWithString(url) ?: return
        onMain {
            UIApplication.sharedApplication.openURL(requestUrl)
        }
    }

    override suspend fun showToast(source: BookSource?, message: String, long: Boolean) {
        val sourceName = source?.bookSourceName?.takeIf { it.isNotBlank() }
        val displayMessage = if (sourceName != null) "$sourceName: $message" else message
        val durationMillis = if (long) 3_500L else 2_000L
        onMain {
            val presenter = topViewController() ?: return@onMain
            val alert = UIAlertController.alertControllerWithTitle(
                title = null,
                message = displayMessage,
                preferredStyle = UIAlertControllerStyleAlert
            )
            presenter.presentViewController(alert, animated = true, completion = null)
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, durationMillis * 1_000_000L),
                dispatch_get_main_queue()
            ) {
                alert.dismissViewControllerAnimated(true, completion = null)
            }
        }
    }

    private fun browserVerification() = IosBrowserVerification(cookieRepository, headerResolver, sourceStateStore)

    private suspend fun executeInteractiveWebView(request: LegacyWebViewRequest): String? {
        return withTimeout(WEB_VIEW_TIMEOUT_MILLIS) {
            suspendCancellableCoroutine { continuation ->
                val lifetime = SupervisorJob(continuation.context[Job])
                // Runner ownership and completion are confined to main.
                var finished = false
                var runner: InteractiveWebViewRunner? = null

                fun cleanUp() {
                    if (finished) return
                    finished = true
                    lifetime.cancel()
                    val container = runner
                    runner = null
                    container?.cancel()
                }

                fun finish(result: Result<String?>) {
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
                    if (finished || !continuation.isActive || !lifetime.isActive) {
                        cleanUp()
                        return@onMain
                    }
                    try {
                        val container = InteractiveWebViewRunner(
                            request = request,
                            cookieRepository = cookieRepository,
                            lifetime = lifetime,
                            onComplete = ::finish,
                        )
                        runner = container
                        container.start()
                    } catch (error: Throwable) {
                        finish(Result.failure(error))
                    }
                }
            }
        }
    }

    private fun cookieDomain(source: BookSource?, url: String): String {
        val sourceUrl = source?.bookSourceUrl?.takeIf { it.isNotBlank() } ?: url
        return runCatching { Url(sourceUrl).host.removePrefix(".") }.getOrDefault(url)
    }

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block()
        else platform.darwin.dispatch_async(platform.darwin.dispatch_get_main_queue(), block)
    }
}

private const val WEB_VIEW_TIMEOUT_MILLIS = 60_000L

private fun topViewController(): UIViewController? {
    val root = UIApplication.sharedApplication.keyWindow?.rootViewController ?: return null
    return findVisibleViewController(root)
}

private fun findVisibleViewController(controller: UIViewController): UIViewController {
    controller.presentedViewController?.let { return findVisibleViewController(it) }
    if (controller is UINavigationController) {
        controller.visibleViewController?.let { return findVisibleViewController(it) }
    }
    if (controller is UITabBarController) {
        controller.selectedViewController?.let { return findVisibleViewController(it) }
    }
    return controller
}
