@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.bootstrap.SharedBootstrap
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.facade.FlowSubscription
import io.legado.kmp.shared.facade.RecoverableSharedException
import io.legado.kmp.shared.facade.RssArticleWebRequest
import io.legado.kmp.shared.facade.findFacadeRequestCancellation
import io.legado.kmp.shared.model.RssSource
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.koin.mp.KoinPlatformTools
import platform.Foundation.HTTPBody
import platform.Foundation.HTTPBodyStream
import platform.Foundation.HTTPMethod
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSURLComponents
import platform.Foundation.NSURLRequest
import platform.WebKit.WKNavigationAction
import platform.WebKit.WKWebView
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

/** A null request permits the original action; rejection and cancellation are separate outcomes. */
class IosRssWebNavigationResult internal constructor(
    val request: NSURLRequest? = null,
    val isRejected: Boolean = false,
    val errorMessage: String? = null,
    val isCancelled: Boolean = false,
) {
    override fun toString(): String = "IosRssWebNavigationResult(redacted)"
}

/** iOS-only callback boundary: every operation has its own cancellable child of the browser lifetime. */
class IosRssWebNavigationSession private constructor(
    prepared: RssArticleWebRequest,
    cookieRepository: CookieRepository,
) {
    companion object {
        @Throws(RecoverableSharedException::class)
        fun anonymousRequest(url: String): RssArticleWebRequest = try {
            require(url.isNotBlank() && url.length <= 32768 && url.none { it.code <= 0x20 || it.code == 0x7f })
            val nativeUrl = requireNotNull(NSURL(string = url))
            val components = requireNotNull(NSURLComponents.componentsWithURL(nativeUrl, resolvingAgainstBaseURL = false))
            val scheme = components.scheme?.lowercase()
            val host = components.host
            require(scheme == "http" || scheme == "https")
            require(!host.isNullOrBlank() && !host.endsWith('.'))
            require(components.user == null && components.password == null)
            require((components.port?.intValue ?: if (scheme == "https") 443 else 80) in 1..65535)
            val target = requireNotNull(nativeUrl.absoluteString)
            RssArticleWebRequest(RssSource(sourceUrl = target, enabledCookieJar = false), target, "GET", emptyMap(), null, emptyList())
        } catch (_: Exception) {
            throw RecoverableSharedException("IosRssWebNavigationSession.anonymous", "公开文章地址无效")
        }

        @Throws(RecoverableSharedException::class)
        fun create(prepared: RssArticleWebRequest): IosRssWebNavigationSession = try {
            check(NSThread.isMainThread)
            SharedBootstrap.startOrThrow()
            val repository: CookieRepository = KoinPlatformTools.defaultContext().get().get()
            IosRssWebNavigationSession(prepared, repository)
        } catch (_: Exception) {
            throw RecoverableSharedException("IosRssWebNavigationSession.create", "订阅网页会话不可用，请重试")
        }
    }

    private val lifetime = SupervisorJob()
    private val scope = CoroutineScope(lifetime + Dispatchers.Main.immediate)
    private val navigation = IosSourceWebNavigationSession(
        initialUrl = prepared.url,
        sourceUrl = prepared.source.sourceUrl,
        headers = prepared.headers,
        cookieRepository = cookieRepository,
        persistCookies = prepared.source.enabledCookieJar,
    )
    private var ready = false

    fun prepare(webView: WKWebView, onResult: (IosRssWebNavigationResult) -> Unit): FlowSubscription =
        start("订阅网页 Cookie 准备失败", onResult) {
            navigation.prepareInitial(webView)
            lifetime.ensureActive()
            ready = true
            IosRssWebNavigationResult()
        }

    fun resume(webView: WKWebView, onResult: (IosRssWebNavigationResult) -> Unit): FlowSubscription =
        start("订阅网页会话恢复失败", onResult) {
            navigation.prepareInitial(webView, includeCurrentDocument = true)
            lifetime.ensureActive()
            ready = true
            IosRssWebNavigationResult()
        }

    fun decide(
        action: WKNavigationAction,
        webView: WKWebView,
        onResult: (IosRssWebNavigationResult) -> Unit,
    ): FlowSubscription = start("订阅网页导航准备失败", onResult) {
        check(ready)
        when (val decision = navigation.decide(webView, action)) {
            IosSourceWebNavigationDecision.Allow -> IosRssWebNavigationResult()
            IosSourceWebNavigationDecision.Cancel -> rejected()
            is IosSourceWebNavigationDecision.Reload -> {
                val request = action.request
                val bodyKnown = (request.HTTPMethod ?: "GET").uppercase() in setOf("GET", "HEAD") || request.HTTPBody != null
                if (action.targetFrame?.mainFrame == true && request.HTTPBodyStream == null && bodyKnown) {
                    IosRssWebNavigationResult(request = decision.request)
                } else {
                    navigation.discardPendingReload(decision.request)
                    rejected()
                }
            }
        }
    }

    /** The caller has already approved the popup hook and chosen an explicit main-frame load. */
    fun prepareTopLevelRequest(
        request: NSURLRequest,
        webView: WKWebView,
        onResult: (IosRssWebNavigationResult) -> Unit,
    ): FlowSubscription = start("订阅网页导航准备失败", onResult) {
        check(ready)
        when (val decision = navigation.prepareTopLevelRequest(webView, request)) {
            is IosSourceWebNavigationDecision.Reload -> IosRssWebNavigationResult(request = decision.request)
            IosSourceWebNavigationDecision.Allow -> IosRssWebNavigationResult(request = request)
            IosSourceWebNavigationDecision.Cancel -> rejected()
        }
    }

    fun persist(webView: WKWebView, onResult: (IosRssWebNavigationResult) -> Unit): FlowSubscription =
        start("订阅网页 Cookie 保存失败", onResult) {
            check(ready)
            navigation.persist(webView, finalSnapshot = false, persistSession = false, commitOnMain = true)
            IosRssWebNavigationResult()
        }

    fun cancel() {
        check(NSThread.isMainThread) { "RSS WebView session must run on main" }
        navigation.cancel()
        lifetime.cancel()
        ready = false
    }

    private fun start(
        failureMessage: String,
        onResult: (IosRssWebNavigationResult) -> Unit,
        work: suspend () -> IosRssWebNavigationResult,
    ): FlowSubscription {
        check(NSThread.isMainThread) { "RSS WebView session must run on main" }
        var result: IosRssWebNavigationResult? = null
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                ensureActive()
                result = work()
                ensureActive()
            } catch (error: Throwable) {
                findFacadeRequestCancellation(error)?.let { throw it }
                ensureActive()
                // Never expose URLs, private headers, form data or cookie values through errors.
                result = IosRssWebNavigationResult(errorMessage = failureMessage)
            }
        }
        // Also deliver a terminal callback when cancellation wins before the coroutine starts.
        job.invokeOnCompletion { cause ->
            val terminal = when {
                job.isCancelled || findFacadeRequestCancellation(cause) != null -> IosRssWebNavigationResult(isCancelled = true)
                cause != null -> IosRssWebNavigationResult(errorMessage = failureMessage)
                else -> result ?: IosRssWebNavigationResult(errorMessage = failureMessage)
            }
            if (NSThread.isMainThread) onResult(terminal)
            else dispatch_async(dispatch_get_main_queue()) { onResult(terminal) }
        }
        job.start()
        return FlowSubscription(job)
    }

    private fun rejected() = IosRssWebNavigationResult(
        isRejected = true,
        errorMessage = "已阻止不安全的订阅网页导航",
    )
}
