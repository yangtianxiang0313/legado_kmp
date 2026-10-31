@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class, kotlin.experimental.ExperimentalNativeApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.facade.AppLogStore
import kotlinx.cinterop.ObjCAction
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSError
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSString
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSURLErrorCancelled
import platform.Foundation.NSURLErrorDomain
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
    cookieRepository: CookieRepository,
    private val lifetime: Job,
    onComplete: (Result<String?>) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol {

    private val terminal = MutableStateFlow(false)
    private val scope = CoroutineScope(lifetime + Dispatchers.Main.immediate)
    private var completion: ((Result<String?>) -> Unit)? = onComplete
    private val navigationSession = IosSourceWebNavigationSession(
        initialUrl = request.url,
        sourceUrl = request.source?.bookSourceUrl,
        headers = request.headers,
        cookieRepository = cookieRepository,
        persistCookies = request.source?.enabledCookieJar == true,
    )

    // Only cancellation/terminal arbitration is cross-thread; WebKit and session state stay on main.
    private var state = State.NEW
    private var webView: WKWebView? = null
    private var instrumentation: IosSourceWebViewScript? = null
    private var sourcePattern: Regex? = null
    private var overridePattern: Regex? = null
    private var navigation: WKNavigation? = null
    private var navigationRevision = 0L
    private var evaluationJob: Job? = null
    private val pendingPolicies = mutableSetOf<SourceNavigationPolicy>()
    private var policyRevision = 0L
    private var preparingNavigation = false
    private var initialHtmlPending = false
    private val replacedNavigations = mutableSetOf<WKNavigation>()

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
                val patterns = withContext(Dispatchers.Default) {
                    // Compile before creating/loading WebKit; malformed rules are ordinary failures.
                    Patterns(
                        source = request.sourceRegex?.takeIf { it.isNotBlank() }?.let(::Regex),
                        overrideUrl = request.overrideUrlRegex?.takeIf { it.isNotBlank() }?.let(::Regex),
                    )
                }
                if (!isPreparing()) return@launch
                sourcePattern = patterns.source
                overridePattern = patterns.overrideUrl
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

    private suspend fun createWebView() {
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
        navigationSession.prepareInitial(view)
        if (!isPreparing() || webView != view) return
        trace("cookie scope ready")
        state = State.RUNNING
        trace(if (request.html != null) "loading HTML" else "loading URL")
        if (request.html != null) {
            initialHtmlPending = true
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
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) = onMain {
        if (!isRunning(webView)) return@onMain
        trace("navigation started")
        preparingNavigation = false
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
        if (matched != null || failure != null) {
            // Fulfil WebKit's policy callback before stopping the view or exporting cookies.
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            trace("navigation intercepted")
            failure?.let(::fail) ?: matched?.let(::succeed)
            return@onMain
        }
        val action = decidePolicyForNavigationAction
        val mainFrame = action.targetFrame?.mainFrame == true
        if (mainFrame) {
            policyRevision++
            cancelPendingPolicies()
        }
        val htmlBootstrap = mainFrame && initialHtmlPending
        if (mainFrame) initialHtmlPending = false
        val actionUrl = action.request.URL?.absoluteString
        val initialUrl = request.url?.let(NSURL::URLWithString)?.absoluteString
        if (htmlBootstrap && (actionUrl == "about:blank" || initialUrl != null && actionUrl == initialUrl)) {
            // This is the caller's in-memory document, not a request to follow about:blank/file URLs.
            navigationSession.recordDocument(request.url)
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyAllow)
            trace("initial HTML navigation allowed")
            return@onMain
        }
        val decision: IosSourceWebNavigationDecision?
        val deferred: Boolean
        try {
            decision = navigationSession.preflight(webView, action)
            deferred = decision == null && navigationSession.needsDeferredPreparation(webView, action)
        } catch (error: Throwable) {
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            fail(error)
            return@onMain
        }
        if (decision == IosSourceWebNavigationDecision.Allow) {
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyAllow)
            trace("navigation allowed")
            return@onMain
        }
        if (decision == IosSourceWebNavigationDecision.Cancel) {
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            trace("navigation cancelled")
            return@onMain
        }
        if (mainFrame) {
            navigationRevision++
            evaluationJob?.cancel()
            evaluationJob = null
        }
        val pending = SourceNavigationPolicy(mainFrame, decisionHandler)
        pendingPolicies.add(pending)
        if (!deferred) {
            if (mainFrame) {
                navigation?.let(replacedNavigations::add)
                preparingNavigation = true
            }
            pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
        }
        trace(if (deferred) "awaiting navigation cookies" else "sanitizing navigation headers")
        val revision = policyRevision
        // Cookie-only preparation retains the original policy/body/frame; only header rewriting reloads.
        dispatch_async(dispatch_get_main_queue()) {
            if (!isRunning(webView) || policyRevision != revision) {
                pending.cancel()
                pendingPolicies.remove(pending)
                return@dispatch_async
            }
            val job = scope.launch(start = CoroutineStart.LAZY) {
                try {
                    val prepared = decision ?: navigationSession.decide(webView, action)
                    if (!isRunning(webView) || policyRevision != revision) return@launch
                    when (prepared) {
                        IosSourceWebNavigationDecision.Allow -> {
                            pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyAllow)
                            trace("prepared navigation allowed")
                        }
                        IosSourceWebNavigationDecision.Cancel -> {
                            pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
                            trace("prepared navigation cancelled")
                        }
                        is IosSourceWebNavigationDecision.Reload -> {
                            if (!mainFrame || deferred) {
                                pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
                                return@launch
                            }
                            pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
                            trace("reloading sanitized navigation")
                            navigation = webView.loadRequest(prepared.request)
                        }
                    }
                } catch (cancelled: CancellationException) {
                    if (isRunning(webView) && policyRevision == revision) fail(cancelled)
                } catch (error: Throwable) {
                    if (isRunning(webView) && policyRevision == revision) fail(error)
                } finally {
                    pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
                    pendingPolicies.remove(pending)
                }
            }
            pending.job = job
            // A lazy job can be cancelled before entering its body, so finally alone is insufficient.
            job.invokeOnCompletion {
                onMain {
                    pending.answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
                    pendingPolicies.remove(pending)
                }
            }
            job.start()
        }
    }

    private fun cancelPendingPolicies() {
        if (pendingPolicies.any { it.mainFrame }) navigation?.let(replacedNavigations::add)
        val pending = pendingPolicies.toList()
        pendingPolicies.clear()
        pending.forEach { it.cancel() }
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
        if (failedNavigation != null && replacedNavigations.remove(failedNavigation)) return@onMain
        if (preparingNavigation && error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled) return@onMain
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
        policyRevision++
        cancelPendingPolicies()
        navigationRevision++
        quiesce(view)
        trace("exporting navigation cookies")
        scope.launch {
            try {
                navigationSession.persist(view)
                if (isExporting(view)) finish(Result.success(value))
            } catch (cancelled: CancellationException) {
                if (lifetime.isActive) fail(cancelled)
            } catch (error: Throwable) {
                if (lifetime.isActive) fail(error)
            }
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
        policyRevision++
        cancelPendingPolicies()
        navigationSession.cancel()
        lifetime.cancel()
        evaluationJob = null
        webView?.let { view ->
            quiesce(view)
            view.removeFromSuperview()
        }
        webView = null
        navigation = null
        replacedNavigations.clear()
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

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
    }

    private fun trace(stage: String) {
        if (Platform.isDebugBinary) AppLogStore.record(level = "D", tag = "SourceWebView", message = stage)
    }

    private enum class State { NEW, PREPARING, RUNNING, EXPORTING, FINISHED }
    private data class Patterns(val source: Regex?, val overrideUrl: Regex?)
}

private class SourceNavigationPolicy(
    val mainFrame: Boolean,
    private var handler: ((WKNavigationActionPolicy) -> Unit)?,
) {
    var job: Job? = null

    fun answer(policy: WKNavigationActionPolicy) {
        val callback = handler ?: return
        handler = null
        callback(policy)
    }

    fun cancel() {
        answer(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
        job?.cancel()
    }
}

private class SourceResourceMessageHandler(runner: InteractiveWebViewRunner) : NSObject(), WKScriptMessageHandlerProtocol {
    private val runner = WeakReference(runner)

    override fun userContentController(userContentController: WKUserContentController, didReceiveScriptMessage: WKScriptMessage) {
        runner.get()?.receiveResourceMessage(didReceiveScriptMessage)
    }
}

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
