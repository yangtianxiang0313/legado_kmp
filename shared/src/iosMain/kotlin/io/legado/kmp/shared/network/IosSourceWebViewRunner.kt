@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class, kotlin.experimental.ExperimentalNativeApi::class)

package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.facade.AppLogStore
import io.legado.kmp.shared.model.StoredHttpCookie
import kotlinx.cinterop.ObjCAction
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSError
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSString
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSUUID
import platform.Foundation.setValue
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationAction
import platform.WebKit.WKNavigationActionPolicy
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKScriptMessage
import platform.WebKit.WKScriptMessageHandlerProtocol
import platform.WebKit.WKUserContentController
import platform.WebKit.WKUserScript
import platform.WebKit.WKUserScriptInjectionTime
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.NSObject
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import kotlin.native.ref.WeakReference
import kotlin.native.Platform

internal class InteractiveWebViewRunner(
    private val request: LegacyWebViewRequest,
    private val cookieRepository: CookieRepository,
    onComplete: (Result<String?>) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol {

    private val lifetime = SupervisorJob()
    private val terminal = MutableStateFlow(false)
    private val scope = CoroutineScope(lifetime + Dispatchers.Main.immediate)
    private var completion: ((Result<String?>) -> Unit)? = onComplete

    // Only cancellation/terminal arbitration is cross-thread; WebKit and session state stay on main.
    private var state = State.NEW
    private var webView: WKWebView? = null
    private var instrumentation: IosSourceWebViewScript? = null
    private var sourcePattern: Regex? = null
    private var overridePattern: Regex? = null
    private var cookieSeeds: List<CookieSeed> = emptyList()
    private var navigation: WKNavigation? = null
    private var navigationRevision = 0L
    private var evaluationJob: Job? = null

    fun start() = onMain {
        if (state != State.NEW || !lifetime.isActive) return@onMain
        state = State.PREPARING
        trace("preparing")
        scope.launch {
            delay(WEB_VIEW_TIMEOUT_MILLIS)
            if (state != State.FINISHED) fail(IllegalStateException(timeoutMessage()))
        }
        scope.launch {
            try {
                trace("reading cookie scope")
                val prepared = withContext(Dispatchers.Default) {
                    // Compile before creating/loading WebKit; malformed rules are ordinary failures.
                    val patterns = Patterns(
                        source = request.sourceRegex?.takeIf { it.isNotBlank() }?.let(::Regex),
                        overrideUrl = request.overrideUrlRegex?.takeIf { it.isNotBlank() }?.let(::Regex),
                    )
                    val seeds = cookieScopeUrls().map { url ->
                        ensureActive()
                        CookieSeed(url, cookieRepository.getCookiesForHost(url))
                    }
                    ensureActive()
                    patterns to seeds
                }
                if (!isPreparing()) return@launch
                sourcePattern = prepared.first.source
                overridePattern = prepared.first.overrideUrl
                cookieSeeds = prepared.second
                trace("cookie scope ready")
                createWebView()
            } catch (cancelled: CancellationException) {
                if (lifetime.isActive) fail(cancelled)
            } catch (error: Throwable) {
                if (lifetime.isActive) fail(error)
            }
        }
    }

    fun cancel() {
        // Cancel repo work immediately, even when main is still handling an earlier callback.
        if (!terminal.compareAndSet(false, true)) return
        lifetime.cancel()
        onMain {
            finishClaimed(Result.failure(IllegalStateException("Interactive webView was cancelled before producing a result")))
        }
    }

    @ObjCAction
    fun close() {
        if (!terminal.compareAndSet(false, true)) return
        lifetime.cancel()
        onMain {
            finishClaimed(Result.failure(IllegalStateException("Interactive webView was closed before producing a result")))
        }
    }

    private fun createWebView() {
        if (!isPreparing()) return
        val url = request.url?.takeIf { it.isNotBlank() }?.let(NSURL::URLWithString)
        require(request.html != null || url != null) { "Interactive webView requires html or url" }
        val configuration = WKWebViewConfiguration().apply {
            websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
        }
        if (sourcePattern != null) {
            val script = IosSourceWebViewScript(NSUUID().UUIDString)
            instrumentation = script
            configuration.userContentController.apply {
                addScriptMessageHandler(SourceResourceMessageHandler(this@InteractiveWebViewRunner), script.handlerName)
                addUserScript(
                    WKUserScript(
                        source = script.install,
                        injectionTime = WKUserScriptInjectionTime.WKUserScriptInjectionTimeAtDocumentStart,
                        forMainFrameOnly = false,
                    )
                )
            }
        }
        val view = WKWebView(CGRectMake(0.0, 0.0, 1.0, 1.0), configuration)
        trace("webview created")
        webView = view
        view.navigationDelegate = this
        val headers = request.headers.withoutNullUserAgent()
        headers.entries.firstOrNull { it.key.equals("User-Agent", ignoreCase = true) }
            ?.value?.takeIf { it.isNotBlank() }?.let { view.customUserAgent = it }
        prepareCookies(view, headers, 0) {
            if (!isPreparing() || webView != view) return@prepareCookies
            try {
                state = State.RUNNING
                trace(if (request.html != null) "loading HTML" else "loading URL")
                if (request.html != null) {
                    navigation = view.loadHTMLString(request.html, baseURL = url)
                } else {
                    val nativeRequest = NSMutableURLRequest.requestWithURL(checkNotNull(url))
                    // Cookie headers have been scoped into WKHTTPCookieStore, not broadcast to redirects.
                    headers.filterKeys { !it.equals("Cookie", ignoreCase = true) }.forEach { (name, value) ->
                        nativeRequest.setValue(value, forHTTPHeaderField = name)
                    }
                    navigation = view.loadRequest(nativeRequest)
                }
                trace(if (navigation != null) "load accepted" else "load returned no navigation")
            } catch (error: Throwable) {
                fail(error)
            }
        }
    }

    private fun prepareCookies(view: WKWebView, headers: Map<String, String>, index: Int, done: () -> Unit) {
        if (!isPreparing() || webView != view) return
        val seed = cookieSeeds.getOrNull(index)
        if (seed == null) {
            done()
            return
        }
        val requestHost = httpHost(request.url)
        val seedHeaders = if (requestHost != null && httpHost(seed.url) == requestHost) headers else emptyMap()
        IosWebViewCookieBridge.prepare(view, seed.url, seedHeaders, storedCookies = seed.cookies) {
            onMain {
                if (!isPreparing() || webView != view) return@onMain
                try {
                    prepareCookies(view, headers, index + 1, done)
                } catch (error: Throwable) {
                    fail(error)
                }
            }
        }
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) = onMain {
        if (!isRunning(webView)) return@onMain
        trace("navigation started")
        navigation = didStartProvisionalNavigation
        navigationRevision++
        evaluationJob?.cancel()
        evaluationJob = null
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) = onMain {
        if (!isRunning(webView) || navigation != null && navigation != didFinishNavigation) return@onMain
        trace("navigation finished")
        val revision = ++navigationRevision
        evaluationJob?.cancel()
        evaluationJob = scope.launch {
            delay(initialDelayMillis())
            if (!isCurrentDocument(webView, revision)) return@launch
            val sniffing = sourcePattern != null || overridePattern != null
            val script = request.javaScript?.takeIf { it.isNotBlank() }
                ?: if (sniffing) return@launch else "document.documentElement.outerHTML"
            evaluate(webView, script, revision, retry = 0, sniffing = sniffing)
        }
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ) = onMain {
        if (!isRunning(webView)) {
            trace("inactive navigation cancelled")
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            return@onMain
        }
        var matched: String? = null
        var failure: Throwable? = null
        try {
            val url = decidePolicyForNavigationAction.request.URL?.absoluteString.orEmpty()
            // BackstageWebView@5f5d314 shouldOverrideUrlLoading uses matches, never find/contains.
            if (url.isNotEmpty() && overridePattern?.matches(url) == true) matched = url
        } catch (error: Throwable) {
            failure = error
        }
        // Fulfil WebKit's policy callback before stopping the view or exporting cookies.
        decisionHandler(
            if (matched != null || failure != null) WKNavigationActionPolicy.WKNavigationActionPolicyCancel
            else WKNavigationActionPolicy.WKNavigationActionPolicyAllow
        )
        trace(if (matched != null || failure != null) "navigation intercepted" else "navigation allowed")
        failure?.let(::fail) ?: matched?.let(::succeed)
    }

    internal fun receiveResourceMessage(message: WKScriptMessage) = onMain {
        val view = webView ?: return@onMain
        val script = instrumentation ?: return@onMain
        if (!isRunning(view) || message.webView != view || message.name != script.handlerName) return@onMain
        val body = message.body as? Map<*, *> ?: return@onMain
        val kind = body["kind"] as? String ?: return@onMain
        if (body["token"] != script.token || kind !in RESOURCE_EVENT_KINDS) return@onMain
        val url = body["url"] as? String ?: return@onMain
        if (url.isEmpty()) return@onMain
        try {
            // Only observed request events enter this path; never page URLs or DOM src/href guesses.
            if (sourcePattern?.matches(url) == true) succeed(url)
        } catch (error: Throwable) {
            fail(error)
        }
    }

    private fun evaluate(view: WKWebView, script: String, revision: Long, retry: Int, sniffing: Boolean) {
        if (!isCurrentDocument(view, revision)) return
        try {
            view.evaluateJavaScript(script) { value, error ->
                onMain {
                    if (!isCurrentDocument(view, revision)) return@onMain
                    if (error != null) {
                        fail(error.asSourceWebViewException())
                        return@onMain
                    }
                    if (sniffing) return@onMain
                    val payload = value.toSourceWebViewString()
                    if (payload.isNotEmpty() && payload != "null") {
                        succeed(payload)
                    } else if (retry > WEB_VIEW_JS_EMPTY_RETRY_LIMIT) {
                        fail(IllegalStateException("js执行超时"))
                    } else {
                        evaluationJob = scope.launch {
                            delay(WEB_VIEW_JS_RETRY_DELAY_MILLIS)
                            evaluate(view, script, revision, retry + 1, sniffing = false)
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            if (isCurrentDocument(view, revision)) fail(error)
        }
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFailNavigation: WKNavigation?, withError: NSError) =
        failNavigation(webView, didFailNavigation, withError)

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFailProvisionalNavigation: WKNavigation?, withError: NSError) =
        failNavigation(webView, didFailProvisionalNavigation, withError)

    override fun webViewWebContentProcessDidTerminate(webView: WKWebView) = onMain {
        if (isRunning(webView)) fail(IllegalStateException("WKWebView content process terminated"))
    }

    private fun failNavigation(view: WKWebView, failedNavigation: WKNavigation?, error: NSError) = onMain {
        if (isRunning(view) && (navigation == null || navigation == failedNavigation)) {
            fail(error.asSourceWebViewException())
        }
    }

    private fun succeed(value: String) {
        val view = webView ?: return
        if (!isRunning(view)) return
        state = State.EXPORTING
        evaluationJob?.cancel()
        evaluationJob = null
        navigationRevision++
        quiesce(view)
        try {
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies ->
                onMain {
                    if (!isExporting(view)) return@onMain
                    try {
                        val nativeCookies = cookies.orEmpty().filterIsInstance<NSHTTPCookie>()
                        val snapshots = cookieSeeds.map { seed ->
                            val oldCookies = seed.cookies.associateBy { it.identity() }
                            CookieSeed(
                                seed.url,
                                IosWebViewCookieBridge.exportCookiesForHost(nativeCookies, seed.url).map { cookie ->
                                    val previous = oldCookies[cookie.identity()]
                                    if (previous == null) cookie else cookie.copy(creationTimeMillis = previous.creationTimeMillis)
                                },
                            )
                        }
                        scope.launch {
                            try {
                                withContext(Dispatchers.Default) {
                                    val persist = request.source?.enabledCookieJar == true
                                    for (snapshot in snapshots) {
                                        ensureActive()
                                        cookieRepository.replaceCookiesForHost(
                                            url = snapshot.url,
                                            cookies = snapshot.cookies,
                                            persistSession = persist,
                                            persistCookies = persist,
                                        )
                                        ensureActive()
                                    }
                                }
                                if (isExporting(view)) finish(Result.success(value))
                            } catch (cancelled: CancellationException) {
                                if (lifetime.isActive) fail(cancelled)
                            } catch (error: Throwable) {
                                if (lifetime.isActive) fail(error)
                            }
                        }
                    } catch (error: Throwable) {
                        fail(error)
                    }
                }
            }
        } catch (error: Throwable) {
            fail(error)
        }
    }

    private fun quiesce(view: WKWebView) {
        view.navigationDelegate = null
        view.UIDelegate = null
        val script = instrumentation
        instrumentation = null
        if (script != null) {
            val controller = view.configuration.userContentController
            controller.removeScriptMessageHandlerForName(script.handlerName)
            controller.removeAllUserScripts()
            // The cleanup broadcasts to cross-origin child frames; no native owner is captured.
            runCatching { view.evaluateJavaScript(script.cleanup, completionHandler = null) }
        }
        view.stopLoading()
    }

    private fun fail(error: Throwable) = finish(Result.failure(error))

    private fun finish(result: Result<String?>) {
        if (result.isSuccess && !lifetime.isActive || !terminal.compareAndSet(false, true)) return
        finishClaimed(result)
    }

    private fun finishClaimed(result: Result<String?>) {
        trace(if (result.isSuccess) "completed" else "cancelled or failed")
        state = State.FINISHED
        navigationRevision++
        lifetime.cancel()
        evaluationJob = null
        webView?.let { view ->
            quiesce(view)
            view.removeFromSuperview()
        }
        webView = null
        navigation = null
        cookieSeeds = emptyList()
        val callback = completion
        completion = null
        callback?.invoke(result)
    }

    private fun isPreparing(): Boolean = !terminal.value && lifetime.isActive && state == State.PREPARING

    private fun isRunning(view: WKWebView): Boolean =
        !terminal.value && lifetime.isActive && state == State.RUNNING && webView == view

    private fun isExporting(view: WKWebView): Boolean =
        !terminal.value && lifetime.isActive && state == State.EXPORTING && webView == view

    private fun isCurrentDocument(view: WKWebView, revision: Long): Boolean =
        isRunning(view) && navigationRevision == revision

    private fun initialDelayMillis(): Long =
        request.webViewDelayTime.coerceIn(-1_000L, WEB_VIEW_TIMEOUT_MILLIS) + 1_000L

    private fun timeoutMessage(): String = when {
        state == State.EXPORTING -> "WebView cookie export timed out"
        sourcePattern != null -> "No WebView resource URL matched sourceRegex"
        overridePattern != null -> "No WebView navigation URL matched overrideUrlRegex"
        else -> "Interactive webView timed out"
    }

    private fun cookieScopeUrls(): List<String> =
        listOfNotNull(request.url, request.source?.bookSourceUrl)
            .filter { httpHost(it) != null }
            .distinctBy { httpHost(it) }

    private fun httpHost(url: String?): String? = url?.let {
        runCatching { Url(it) }.getOrNull()
            ?.takeIf { parsed -> parsed.protocol.name == "http" || parsed.protocol.name == "https" }
            ?.host?.lowercase()?.takeIf { host -> host.isNotBlank() }
    }

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
    }

    private fun trace(stage: String) {
        if (Platform.isDebugBinary) AppLogStore.record(level = "D", tag = "SourceWebView", message = stage)
    }

    private enum class State { NEW, PREPARING, RUNNING, EXPORTING, FINISHED }
    private data class Patterns(val source: Regex?, val overrideUrl: Regex?)
    private data class CookieSeed(val url: String, val cookies: List<StoredHttpCookie>)
}

private class SourceResourceMessageHandler(runner: InteractiveWebViewRunner) : NSObject(), WKScriptMessageHandlerProtocol {
    private val runner = WeakReference(runner)

    override fun userContentController(userContentController: WKUserContentController, didReceiveScriptMessage: WKScriptMessage) {
        runner.get()?.receiveResourceMessage(didReceiveScriptMessage)
    }
}

private fun StoredHttpCookie.identity(): Triple<String, String, String> = Triple(name, domain, path)

private fun Any?.toSourceWebViewString(): String = when (this) {
    null -> ""
    is String -> this
    is NSString -> toString()
    else -> toString()
}

private fun NSError.asSourceWebViewException(): IllegalStateException =
    IllegalStateException(localizedDescription ?: "Interactive iOS WebView failed")

private const val WEB_VIEW_TIMEOUT_MILLIS = 60_000L
private const val WEB_VIEW_JS_EMPTY_RETRY_LIMIT = 30
private const val WEB_VIEW_JS_RETRY_DELAY_MILLIS = 1_000L
private val RESOURCE_EVENT_KINDS = setOf("resource", "fetch", "xhr", "media")
