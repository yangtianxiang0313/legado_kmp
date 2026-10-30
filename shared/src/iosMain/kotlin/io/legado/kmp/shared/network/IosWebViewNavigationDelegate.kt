package io.legado.kmp.shared.network

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import platform.Foundation.HTTPBody
import platform.Foundation.HTTPBodyStream
import platform.Foundation.HTTPMethod
import platform.Foundation.NSError
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSString
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSURLComponents
import platform.Foundation.NSURLErrorCancelled
import platform.Foundation.NSURLErrorDomain
import platform.Foundation.NSURLRequest
import platform.Foundation.setValue
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationAction
import platform.WebKit.WKNavigationActionPolicy
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKNavigationResponse
import platform.WebKit.WKNavigationResponsePolicy
import platform.WebKit.WKWebView
import platform.darwin.DISPATCH_TIME_NOW
import platform.darwin.NSObject
import platform.darwin.dispatch_after
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import platform.darwin.dispatch_time

@OptIn(ExperimentalForeignApi::class, BetaInteropApi::class)
internal class IosWebViewNavigationDelegate(
    private val context: SourceExecutionContext,
    private val initialResponse: HttpResponse,
    private val navigationSession: IosSourceWebNavigationSession,
    private val scope: CoroutineScope,
    private val onComplete: (Result<HttpResponse>) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol {
    private val directGet = context.request.method == HttpMethod.GET

    // Mutable state, including cookie completion, is confined to the main thread.
    private var completed = false
    private var revision = 0L
    private var navigation: WKNavigation? = null
    private var response: HttpResponse? = initialResponse.takeUnless { directGet }
    private var mainDocumentUrl = initialResponse.url.ifBlank { context.requestConfig.url }
    private var initialHtmlPolicyPending = !directGet
    private var initialHtmlDocument = !directGet
    private var initialHtmlBaseUrl: NSURL? = null
    private var initialHtmlNavigation: WKNavigation? = null
    private var documentLoaded = false
    private var policyRevision = 0L
    private var pendingMainPolicy = false
    private var deferringMainPolicy = false
    private var policyJob: Job? = null
    private val framePolicyJobs = mutableSetOf<Job>()
    private val pendingPolicyCallbacks = mutableSetOf<() -> Unit>()
    private var persistenceJob: Job? = null
    private var policyReload: NSURLRequest? = null
    private val replacedNavigations = mutableSetOf<WKNavigation>()
    private val policyCancelledNavigations = mutableSetOf<WKNavigation>()
    private var cancelledUnboundNavigation = false

    fun loadInitialPage(webView: WKWebView, url: NSURL) {
        if (!alive()) return
        navigation = if (directGet) {
            val request = NSMutableURLRequest.requestWithURL(url)
            context.requestConfig.headers.withoutNullUserAgent()
                .filterKeys { !it.equals("Cookie", true) }.forEach { (name, value) ->
                    request.setValue(value, forHTTPHeaderField = name)
                }
            webView.loadRequest(request)
        } else {
            // The HTTP layer has already sent the original body exactly once.
            initialHtmlBaseUrl = url
            navigationSession.recordDocument(url.absoluteString)
            webView.loadHTMLString(initialResponse.bodyText, baseURL = url).also {
                initialHtmlNavigation = it
            }
        }
    }

    fun cancel() = onMain {
        completed = true
        revision++
        policyRevision++
        policyJob?.cancel()
        framePolicyJobs.toList().forEach { it.cancel() }
        framePolicyJobs.clear()
        pendingPolicyCallbacks.toList().forEach { it() }
        pendingPolicyCallbacks.clear()
        persistenceJob?.cancel()
        policyReload = null
        replacedNavigations.clear()
        policyCancelledNavigations.clear()
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) = onMain {
        if (!alive() || didStartProvisionalNavigation != null && didStartProvisionalNavigation in replacedNavigations) return@onMain
        if (pendingMainPolicy) {
            if (!deferringMainPolicy) didStartProvisionalNavigation?.let(replacedNavigations::add)
            return@onMain
        }
        navigation = didStartProvisionalNavigation
        cancelledUnboundNavigation = false
        invalidateDocument()
        if (initialHtmlDocument && initialHtmlNavigation != null && initialHtmlNavigation != navigation) {
            initialHtmlDocument = false
        }
        response = if (initialHtmlDocument) initialResponse else null
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ) {
        var delivered = false
        var deferred = false
        var cancelPolicy: (() -> Unit)? = null
        val policyNavigation = navigation
        fun reply(policy: WKNavigationActionPolicy) {
            if (delivered) return
            delivered = true
            cancelPolicy?.let(pendingPolicyCallbacks::remove)
            if (policy == WKNavigationActionPolicy.WKNavigationActionPolicyCancel &&
                decidePolicyForNavigationAction.targetFrame?.mainFrame != false
            ) {
                val cancelled = policyNavigation
                if (cancelled == null) cancelledUnboundNavigation = true
                else policyCancelledNavigations.add(cancelled)
            }
            decisionHandler(policy)
        }
        val cancellation = { reply(WKNavigationActionPolicy.WKNavigationActionPolicyCancel) }
        cancelPolicy = cancellation
        pendingPolicyCallbacks.add(cancellation)
        try {
            deferred = decideNavigationAction(webView, decidePolicyForNavigationAction, ::reply)
        } catch (throwable: Throwable) {
            reply(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            finish(Result.failure(throwable))
        } finally {
            if (!deferred) reply(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
        }
    }

    private fun decideNavigationAction(
        webView: WKWebView,
        action: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ): Boolean {
        val allow = WKNavigationActionPolicy.WKNavigationActionPolicyAllow
        val cancel = WKNavigationActionPolicy.WKNavigationActionPolicyCancel
        if (!alive()) {
            decisionHandler(cancel)
            return false
        }
        val mainFrame = action.targetFrame?.mainFrame != false
        if (mainFrame && initialHtmlPolicyPending) {
            initialHtmlPolicyPending = false
            if (action.targetFrame?.mainFrame == true &&
                (action.request.URL == initialHtmlBaseUrl || action.request.URL?.absoluteString == "about:blank")
            ) {
                decisionHandler(allow)
                return false
            }
        }
        val preflight = try {
            navigationSession.preflight(webView, action)
        } catch (throwable: Throwable) {
            decisionHandler(cancel)
            finish(Result.failure(throwable))
            return false
        }
        val approved = if (mainFrame) policyReload.also { policyReload = null } else null
        if (preflight == IosSourceWebNavigationDecision.Allow) {
            if (mainFrame && !isSameDocumentNavigation(webView, action.request)) {
                beginNetworkDocument(action.request)
            }
            decisionHandler(allow)
            return false
        }
        if (preflight == null && navigationSession.needsDeferredPreparation(webView, action)) {
            prepareDeferredNavigation(webView, action, decisionHandler)
            return true
        }
        if (preflight == IosSourceWebNavigationDecision.Cancel ||
            preflight is IosSourceWebNavigationDecision.Reload &&
            (!mainFrame || !preflight.request.isReplayableNavigation())
        ) {
            decisionHandler(cancel)
            return false
        }
        if (approved != null && approved.URL == action.request.URL && approved.HTTPMethod == action.request.HTTPMethod) {
            // A single sanitized replay must either be approved or stop, never replay itself again.
            decisionHandler(cancel)
            finish(Result.failure(IllegalStateException("WKWebView rejected a prepared navigation")))
            return false
        }
        val currentPolicyRevision = if (mainFrame) {
            beginNetworkDocument(action.request)
            pendingMainPolicy = true
            navigation?.let(replacedNavigations::add)
            policyRevision
        } else {
            policyRevision
        }
        // Fulfil WebKit's callback before starting any suspended cookie preparation or loadRequest.
        decisionHandler(cancel)
        val job = scope.launch {
            try {
                val decision = preflight ?: navigationSession.decide(webView, action)
                ensureActive()
                if (!alive() || currentPolicyRevision != policyRevision) return@launch
                when (decision) {
                    is IosSourceWebNavigationDecision.Reload -> {
                        if (!mainFrame) return@launch
                        if (!decision.request.isReplayableNavigation()) {
                            pendingMainPolicy = false
                            finish(Result.failure(IllegalStateException("WKWebView cannot replay a navigation body")))
                            return@launch
                        }
                        pendingMainPolicy = false
                        policyReload = decision.request
                        navigation = webView.loadRequest(decision.request)
                    }
                    IosSourceWebNavigationDecision.Allow,
                    IosSourceWebNavigationDecision.Cancel -> {
                        if (mainFrame) pendingMainPolicy = false
                    }
                }
            } catch (throwable: Throwable) {
                if (isActive && alive() && currentPolicyRevision == policyRevision) finish(Result.failure(throwable))
            }
        }
        if (mainFrame) policyJob = job
        return false
    }

    private fun prepareDeferredNavigation(
        webView: WKWebView,
        action: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ) {
        val cancel = WKNavigationActionPolicy.WKNavigationActionPolicyCancel
        val mainFrame = action.targetFrame?.mainFrame == true
        if (mainFrame) {
            beginNetworkDocument(action.request)
            pendingMainPolicy = true
            deferringMainPolicy = true
        }
        val currentPolicyRevision = policyRevision
        val job = scope.launch {
            try {
                val decision = navigationSession.decide(webView, action)
                ensureActive()
                if (!alive() || currentPolicyRevision != policyRevision) return@launch
                if (mainFrame) {
                    pendingMainPolicy = false
                    deferringMainPolicy = false
                }
                decisionHandler(
                    if (decision == IosSourceWebNavigationDecision.Allow) {
                        WKNavigationActionPolicy.WKNavigationActionPolicyAllow
                    } else {
                        cancel
                    }
                )
            } catch (throwable: Throwable) {
                if (mainFrame && isActive && alive() && currentPolicyRevision == policyRevision) {
                    finish(Result.failure(throwable))
                }
            } finally {
                decisionHandler(cancel)
            }
        }
        if (mainFrame) policyJob = job else framePolicyJobs.add(job)
        // A cancelled scope can reject launch before its body (and finally block) ever runs.
        job.invokeOnCompletion {
            onMain {
                if (mainFrame && policyJob == job) policyJob = null
                framePolicyJobs.remove(job)
                decisionHandler(cancel)
            }
        }
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationResponse: WKNavigationResponse,
        decisionHandler: (WKNavigationResponsePolicy) -> Unit,
    ) = onMain {
        if (!alive() || decidePolicyForNavigationResponse.forMainFrame && pendingMainPolicy) {
            decisionHandler(WKNavigationResponsePolicy.WKNavigationResponsePolicyCancel)
            return@onMain
        }
        var failure: Throwable? = null
        try {
            if (decidePolicyForNavigationResponse.forMainFrame && !initialHtmlDocument) {
                val httpResponse = decidePolicyForNavigationResponse.response as? NSHTTPURLResponse
                invalidateDocument()
                response = httpResponse?.toHttpResponse()
            }
        } catch (throwable: Throwable) {
            failure = throwable
        }
        decisionHandler(
            if (failure == null) WKNavigationResponsePolicy.WKNavigationResponsePolicyAllow
            else WKNavigationResponsePolicy.WKNavigationResponsePolicyCancel
        )
        failure?.let { finish(Result.failure(it)) }
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) = onMain {
        if (!alive() || pendingMainPolicy || didFinishNavigation != null && didFinishNavigation in replacedNavigations ||
            navigation != null && navigation != didFinishNavigation
        ) return@onMain
        documentLoaded = true
        val currentRevision = ++revision
        val delayMillis = (1_000L + context.request.webViewDelayTime).coerceAtLeast(0L)
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, delayMillis * 1_000_000L),
            dispatch_get_main_queue(),
        ) {
            if (isActive(currentRevision)) evaluateJavaScriptWithRetry(webView, currentRevision, 0)
        }
    }

    private fun evaluateJavaScriptWithRetry(webView: WKWebView, currentRevision: Long, retry: Int) {
        if (!isActive(currentRevision)) return
        val currentResponse = response
        if (currentResponse == null) {
            finish(Result.failure(IllegalStateException("WKWebView did not receive an HTTP response")))
            return
        }
        // Error pages must reach the HTTP status check without running source WebJs.
        val script = if (currentResponse.isSuccessful) {
            context.request.webJs?.takeIf { it.isNotBlank() } ?: DEFAULT_HTML_JS
        } else {
            DEFAULT_HTML_JS
        }
        try {
            webView.evaluateJavaScript(script) { value, error ->
                onMain {
                    if (!isActive(currentRevision)) return@onMain
                    val bodyText = if (error == null) value.toNavigationJavascriptString() else ""
                    val hasBody = bodyText.isNotEmpty() && bodyText != "null"
                    if (!currentResponse.isSuccessful) {
                        completeResponse(
                            webView, currentResponse,
                            bodyText.takeIf { hasBody } ?: currentResponse.bodyText, currentRevision,
                        )
                    } else if (error != null) {
                        finish(Result.failure(error.asNavigationException()))
                    } else if (hasBody) {
                        completeResponse(webView, currentResponse, bodyText, currentRevision)
                    } else if (retry > WEB_VIEW_JS_EMPTY_RETRY_LIMIT) {
                        finish(Result.failure(IllegalStateException(WEB_VIEW_JS_TIMEOUT_MESSAGE)))
                    } else {
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW, WEB_VIEW_JS_RETRY_DELAY_MILLIS * 1_000_000L),
                            dispatch_get_main_queue(),
                        ) {
                            evaluateJavaScriptWithRetry(webView, currentRevision, retry + 1)
                        }
                    }
                }
            }
        } catch (throwable: Throwable) {
            if (!isActive(currentRevision)) return
            if (currentResponse.isSuccessful) {
                finish(Result.failure(throwable))
            } else {
                completeResponse(webView, currentResponse, currentResponse.bodyText, currentRevision)
            }
        }
    }

    private fun completeResponse(
        webView: WKWebView,
        currentResponse: HttpResponse,
        bodyText: String,
        currentRevision: Long,
    ) {
        if (!isActive(currentRevision)) return
        val result = Result.success(
            currentResponse.copy(
                body = bodyText.encodeToByteArray(),
                bodyText = bodyText,
                errorBodyText = bodyText.takeUnless { currentResponse.isSuccessful },
            )
        )
        persistenceJob?.cancel()
        persistenceJob = scope.launch {
            try {
                navigationSession.persist(webView)
                ensureActive()
                if (isActive(currentRevision)) finish(result)
            } catch (throwable: Throwable) {
                if (isActive(currentRevision)) {
                    finish(if (currentResponse.isSuccessful) Result.failure(throwable) else result)
                }
            }
        }
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        didFailNavigation: WKNavigation?,
        withError: NSError,
    ) = failNavigation(didFailNavigation, withError)

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        didFailProvisionalNavigation: WKNavigation?,
        withError: NSError,
    ) = failNavigation(didFailProvisionalNavigation, withError)

    override fun webViewWebContentProcessDidTerminate(webView: WKWebView) = onMain {
        finish(Result.failure(IllegalStateException("WKWebView content process terminated")))
    }

    private fun failNavigation(failedNavigation: WKNavigation?, error: NSError) = onMain {
        if (!alive() || failedNavigation != null && failedNavigation in replacedNavigations) return@onMain
        if (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled &&
            (failedNavigation != null && failedNavigation in policyCancelledNavigations ||
                navigation == null && cancelledUnboundNavigation)
        ) return@onMain
        if (navigation == null || navigation == failedNavigation) {
            finish(Result.failure(error.asNavigationException()))
        }
    }

    private fun NSHTTPURLResponse.toHttpResponse(): HttpResponse {
        val values = linkedMapOf<String, List<String>>()
        allHeaderFields.forEach { (key, rawValue) ->
            val name = key?.toString() ?: return@forEach
            // Do not split scalar fields on commas: cookie dates can contain commas.
            val fieldValues = when (rawValue) {
                is List<*> -> rawValue.mapNotNull { it?.toString() }
                is Array<*> -> rawValue.mapNotNull { it?.toString() }
                null -> emptyList()
                else -> listOf(rawValue.toString())
            }
            val existingName = values.keys.firstOrNull { it.equals(name, ignoreCase = true) } ?: name
            values[existingName] = values[existingName].orEmpty() + fieldValues
        }
        return initialResponse.copy(
            statusCode = statusCode.toInt(),
            statusText = NSHTTPURLResponse.localizedStringForStatusCode(statusCode),
            headers = values.mapValues { it.value.firstOrNull().orEmpty() },
            allHeaders = values,
            body = ByteArray(0),
            bodyText = "",
            url = URL?.absoluteString.orEmpty().ifBlank { mainDocumentUrl },
            errorBodyText = null,
        )
    }

    private fun alive(): Boolean = !completed && scope.isActive

    private fun isActive(currentRevision: Long): Boolean = alive() && revision == currentRevision

    private fun invalidateDocument() {
        revision++
        documentLoaded = false
        persistenceJob?.cancel()
        persistenceJob = null
    }

    private fun beginNetworkDocument(request: NSURLRequest) {
        policyRevision++
        policyJob?.cancel()
        policyJob = null
        framePolicyJobs.toList().forEach { it.cancel() }
        framePolicyJobs.clear()
        invalidateDocument()
        initialHtmlPolicyPending = false
        initialHtmlDocument = false
        response = null
        mainDocumentUrl = request.URL?.absoluteString.orEmpty()
        pendingMainPolicy = false
        deferringMainPolicy = false
    }

    private fun isSameDocumentNavigation(webView: WKWebView, request: NSURLRequest): Boolean {
        if (!documentLoaded || !request.isReplayableNavigation()) return false
        val current = webView.URL?.let {
            NSURLComponents.componentsWithURL(it, resolvingAgainstBaseURL = false)
        } ?: return false
        val target = request.URL?.let {
            NSURLComponents.componentsWithURL(it, resolvingAgainstBaseURL = false)
        } ?: return false
        if (current.fragment == target.fragment) return false
        current.fragment = null
        target.fragment = null
        return current.URL == target.URL
    }

    private fun NSURLRequest.isReplayableNavigation(): Boolean =
        (HTTPMethod ?: "GET").uppercase() in setOf("GET", "HEAD") && HTTPBody == null && HTTPBodyStream == null

    private fun finish(result: Result<HttpResponse>) {
        if (!alive()) return
        completed = true
        revision++
        onComplete(result)
    }

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
    }

}

private const val DEFAULT_HTML_JS = "document.documentElement.outerHTML"
private const val WEB_VIEW_JS_EMPTY_RETRY_LIMIT = 30
private const val WEB_VIEW_JS_RETRY_DELAY_MILLIS = 1_000L
private const val WEB_VIEW_JS_TIMEOUT_MESSAGE = "js执行超时"

private fun Any?.toNavigationJavascriptString(): String = when (this) {
    null -> ""
    is String -> this
    is NSString -> toString()
    else -> toString()
}

private fun NSError.asNavigationException(): IllegalStateException =
    IllegalStateException(localizedDescription ?: "WKWebView request failed")
