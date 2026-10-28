@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)

package io.legado.kmp.shared.image

import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.cinterop.useContents
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSData
import platform.Foundation.NSError
import platform.Foundation.NSNumber
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSThread
import platform.UIKit.UIColor
import platform.UIKit.UIImage
import platform.UIKit.UIScreen
import platform.UIKit.UIScrollViewContentInsetAdjustmentBehavior
import platform.WebKit.WKContentRuleList
import platform.WebKit.WKDownload
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationAction
import platform.WebKit.WKNavigationActionPolicy
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKNavigationResponse
import platform.WebKit.WKNavigationResponsePolicy
import platform.WebKit.WKPDFConfiguration
import platform.WebKit.WKSnapshotConfiguration
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.NSObject
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

private val localBookSvgRenderMutex = Mutex()

internal actual suspend fun renderLocalBookSvg(bytes: ByteArray): ByteArray = withTimeout(20_000L) {
    // Queueing, XML/base64 work, loading and both capture paths share the same deadline.
    localBookSvgRenderMutex.withLock {
        val document = withContext(Dispatchers.Default) { prepareLocalBookSvg(bytes) }
        withContext(Dispatchers.Main.immediate) {
            val rules = localBookSvgContentRules()
            val session = LocalBookSvgSession(document, rules)
            try {
                session.load()
                session.capture()
            } finally {
                // Retains the weak navigation delegate until all terminal paths reach teardown.
                withContext(NonCancellable + Dispatchers.Main.immediate) { session.dispose() }
            }
        }
    }
}

private class LocalBookSvgSession(
    private val document: LocalBookSvgDocument,
    private val rules: WKContentRuleList,
) : NSObject(), WKNavigationDelegateProtocol {
    // All state below is main-thread confined, including cancellation and native callbacks.
    private var view: WKWebView? = null
    private var navigation: WKNavigation? = null
    private var closed = false
    private var loaded = false
    private var initialNavigationAllowed = false
    private var revision = 0L
    private var failure: Throwable? = null
    private var failPending: ((Throwable) -> Unit)? = null
    private var finishLoading: (() -> Unit)? = null

    suspend fun load() {
        awaitResult<Unit> { complete ->
            val configuration = WKWebViewConfiguration().apply {
                websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
                defaultWebpagePreferences.allowsContentJavaScript = false
                preferences.javaScriptCanOpenWindowsAutomatically = false
                suppressesIncrementalRendering = true
                allowsAirPlayForMediaPlayback = false
                allowsPictureInPictureMediaPlayback = false
                userContentController.addContentRuleList(rules)
            }
            val browser = WKWebView(
                CGRectMake(0.0, 0.0, document.width.toDouble(), document.height.toDouble()), configuration,
            )
            view = browser
            browser.navigationDelegate = this
            browser.opaque = false
            browser.backgroundColor = UIColor.clearColor
            browser.scrollView.backgroundColor = UIColor.clearColor
            browser.scrollView.scrollEnabled = false
            browser.scrollView.bounces = false
            browser.scrollView.contentInsetAdjustmentBehavior =
                UIScrollViewContentInsetAdjustmentBehavior.UIScrollViewContentInsetAdjustmentNever
            browser.userInteractionEnabled = false
            browser.allowsBackForwardNavigationGestures = false
            finishLoading = { complete(Result.success(Unit)) }
            // No file URLs, read-access grants, host cookies, user scripts, windows or presentation.
            navigation = checkNotNull(browser.loadHTMLString(document.html, baseURL = null)) {
                "Local book SVG HTML navigation was not accepted"
            }
        }
        val browser = checkNotNull(view)
        browser.setNeedsLayout()
        browser.layoutIfNeeded()
        delay(32L)
    }

    suspend fun capture(): ByteArray {
        var snapshotFailure: Throwable? = null
        // The detached view has no guaranteed screen commit. Bound the after-updates attempt,
        // then try the public immediate snapshot path before falling back to offscreen PDF.
        for (afterUpdates in listOf(true, false)) {
            try {
                val image = withTimeout(1_500L) {
                    awaitResult<UIImage> { complete ->
                        val browser = checkNotNull(view)
                        val configuration = WKSnapshotConfiguration().apply {
                            rect = browser.bounds
                            // snapshotWidth is in points, but the returned CGImage uses device pixels.
                            snapshotWidth = NSNumber(double = document.width / UIScreen.mainScreen.scale)
                            afterScreenUpdates = afterUpdates
                        }
                        browser.takeSnapshotWithConfiguration(configuration) { snapshot, error ->
                            complete(nativeResult(snapshot, error, "snapshot"))
                        }
                    }
                }
                return encodeLocalBookSvgSnapshot(image, document)
            } catch (error: CancellationException) {
                currentCoroutineContext().ensureActive()
                snapshotFailure = error
            } catch (error: Exception) {
                currentCoroutineContext().ensureActive()
                snapshotFailure = error
            }
        }
        // iOS 16 PDF capture forces a white page. Never silently discard source transparency.
        check(NSProcessInfo.processInfo.operatingSystemVersion.useContents { majorVersion >= 17 }) {
            "Local book SVG snapshot failed; transparent PDF fallback requires iOS 17+: ${snapshotFailure?.message}"
        }
        try {
            val pdf = withTimeout(8_000L) {
                awaitResult<NSData> { complete ->
                    val configuration = WKPDFConfiguration().apply {
                        rect = CGRectMake(0.0, 0.0, document.width.toDouble(), document.height.toDouble())
                        allowTransparentBackground = true
                    }
                    checkNotNull(view).createPDFWithConfiguration(configuration) { data, error ->
                        complete(nativeResult(data, error, "PDF capture"))
                    }
                }
            }
            return encodeLocalBookSvgPdf(pdf, document)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            throw IllegalStateException(
                "Local book SVG capture failed (snapshot: ${snapshotFailure?.message}; PDF: ${error.message})", error,
            )
        }
    }

    private suspend fun <T> awaitResult(start: (complete: (Result<T>) -> Unit) -> Unit): T =
        suspendCancellableCoroutine { continuation ->
            val operation = ++revision
            var completed = false
            fun complete(result: Result<T>) = onLocalBookSvgMain {
                if (closed || operation != revision || completed) return@onLocalBookSvgMain
                completed = true
                failPending = null
                if (continuation.isActive) continuation.resumeWith(result)
            }
            failPending = { complete(Result.failure(it)) }
            continuation.invokeOnCancellation {
                onLocalBookSvgMain {
                    if (operation == revision) {
                        completed = true
                        revision++
                        failPending = null
                        finishLoading = null
                    }
                }
            }
            if (continuation.isActive) {
                try {
                    check(!closed) { "Local book SVG renderer is closed" }
                    failure?.let { throw it }
                    start(::complete)
                } catch (error: Exception) {
                    complete(Result.failure(error))
                }
            }
        }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ) {
        val allowed = isCurrent(webView) && !initialNavigationAllowed && !loaded &&
            decidePolicyForNavigationAction.targetFrame?.mainFrame == true &&
            decidePolicyForNavigationAction.request.URL?.absoluteString == "about:blank" &&
            !decidePolicyForNavigationAction.shouldPerformDownload
        if (allowed) initialNavigationAllowed = true
        decisionHandler(if (allowed) WKNavigationActionPolicy.WKNavigationActionPolicyAllow
            else WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
        if (!allowed && isCurrent(webView)) fail(IllegalStateException("Local book SVG navigation is prohibited"))
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationResponse: WKNavigationResponse,
        decisionHandler: (WKNavigationResponsePolicy) -> Unit,
    ) {
        val allowed = isCurrent(webView) && !loaded && decidePolicyForNavigationResponse.forMainFrame &&
            decidePolicyForNavigationResponse.canShowMIMEType &&
            decidePolicyForNavigationResponse.response.URL?.absoluteString == "about:blank" &&
            decidePolicyForNavigationResponse.response.MIMEType == "text/html"
        decisionHandler(if (allowed) WKNavigationResponsePolicy.WKNavigationResponsePolicyAllow
            else WKNavigationResponsePolicy.WKNavigationResponsePolicyCancel)
        if (!allowed && isCurrent(webView)) fail(IllegalStateException("Local book SVG response/download is prohibited"))
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
        if (!isCurrent(webView) || loaded || (navigation != null && navigation != didFinishNavigation)) return
        loaded = true
        val complete = finishLoading
        finishLoading = null
        complete?.invoke()
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFailNavigation: WKNavigation?, withError: NSError) {
        navigationFailed(webView, didFailNavigation, withError)
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFailProvisionalNavigation: WKNavigation?, withError: NSError) {
        navigationFailed(webView, didFailProvisionalNavigation, withError)
    }

    override fun webViewWebContentProcessDidTerminate(webView: WKWebView) {
        if (isCurrent(webView)) fail(IllegalStateException("Local book SVG WebKit process terminated"))
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, navigationAction: WKNavigationAction, didBecomeDownload: WKDownload) {
        didBecomeDownload.cancel(null)
        if (isCurrent(webView)) fail(IllegalStateException("Local book SVG downloads are prohibited"))
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, navigationResponse: WKNavigationResponse, didBecomeDownload: WKDownload) {
        didBecomeDownload.cancel(null)
        if (isCurrent(webView)) fail(IllegalStateException("Local book SVG downloads are prohibited"))
    }

    private fun navigationFailed(browser: WKWebView, failed: WKNavigation?, error: NSError) {
        if (isCurrent(browser) && (navigation == null || navigation == failed)) {
            fail(IllegalStateException("Local book SVG navigation failed: ${error.localizedDescription}"))
        }
    }

    private fun fail(error: Throwable) {
        if (closed) return
        failure = error
        failPending?.invoke(error)
    }

    private fun isCurrent(browser: WKWebView): Boolean = !closed && browser == view

    fun dispose() {
        if (closed) return
        closed = true
        revision++
        failPending = null
        finishLoading = null
        view?.let { browser ->
            browser.navigationDelegate = null
            browser.UIDelegate = null
            browser.stopLoading()
            browser.configuration.userContentController.removeAllUserScripts()
            browser.configuration.userContentController.removeAllContentRuleLists()
            browser.removeFromSuperview()
        }
        view = null
        navigation = null
    }
}

internal fun onLocalBookSvgMain(block: () -> Unit) {
    if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
}

private fun <T> nativeResult(value: T?, error: NSError?, operation: String): Result<T> =
    if (error != null || value == null) Result.failure(IllegalStateException(
        "Local book SVG $operation failed: ${error?.localizedDescription ?: "no content returned"}",
    )) else Result.success(value)
