@file:OptIn(kotlinx.cinterop.BetaInteropApi::class, kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.ktor.http.Url
import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.BookSource
import io.legado.kmp.shared.model.StoredHttpCookie
import io.legado.kmp.shared.source.SourceStateStore
import kotlinx.cinterop.ObjCAction
import kotlinx.cinterop.ObjCSignatureOverride
import kotlinx.cinterop.useContents
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import platform.CoreGraphics.CGRectMake
import platform.Foundation.NSError
import platform.Foundation.HTTPMethod
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSSelectorFromString
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSURLRequest
import platform.Foundation.allHTTPHeaderFields
import platform.Foundation.setValue
import platform.Foundation.valueForHTTPHeaderField
import platform.UIKit.UIApplication
import platform.UIKit.UIAlertController
import platform.UIKit.UIButton
import platform.UIKit.UIButtonTypeSystem
import platform.UIKit.UIColor
import platform.UIKit.UIControlEventTouchUpInside
import platform.UIKit.UILabel
import platform.UIKit.UIModalPresentationFullScreen
import platform.UIKit.UINavigationController
import platform.UIKit.UISceneActivationStateForegroundActive
import platform.UIKit.UITabBarController
import platform.UIKit.UIViewController
import platform.UIKit.UIWindow
import platform.UIKit.UIWindowScene
import platform.UIKit.secondaryLabelColor
import platform.UIKit.systemBackgroundColor
import platform.WebKit.WKNavigation
import platform.WebKit.WKNavigationAction
import platform.WebKit.WKNavigationActionPolicy
import platform.WebKit.WKNavigationDelegateProtocol
import platform.WebKit.WKNavigationResponse
import platform.WebKit.WKNavigationResponsePolicy
import platform.WebKit.WKWebView
import platform.WebKit.WKWebViewConfiguration
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal class IosBrowserVerification(
    private val cookieRepository: CookieRepository,
    private val headerResolver: SourceHeaderResolver,
    private val sourceStateStore: SourceStateStore?,
) {
    suspend fun present(
        source: BookSource?,
        url: String,
        title: String,
        waitForResult: Boolean,
        refetch: (suspend (String?) -> SourceResponse)? = null,
    ): SourceResponse? {
        require(url.length < 64 * 1024 && browserHttpUrl(url) != null) { "Invalid browser verification URL" }
        val headers = withContext(Dispatchers.Default) { resolveHeaders(source, url) }
        val sameSourceOrigin = source == null || browserOrigin(source.bookSourceUrl)?.let { it == browserOrigin(url) } == true
        val refetchHeaderOverride = if (sameSourceOrigin) null else JsonObject(
            headers.filterKeys { it.equals("User-Agent", true) }.mapValues { JsonPrimitive(it.value) }
        ).toString()
        val fetchResult: (suspend () -> SourceResponse)? = if (refetch != null) {
            { refetch(refetchHeaderOverride) }
        } else null
        return suspendCancellableCoroutine { continuation ->
            val lifetime = SupervisorJob()
            // The reference and UIKit state are main-confined. Cancellation stops repository work immediately.
            var controller: BrowserVerificationController? = null
            continuation.invokeOnCancellation {
                lifetime.cancel()
                browserOnMain { controller?.cancel() }
            }
            browserOnMain {
                if (!continuation.isActive || !lifetime.isActive) return@browserOnMain
                val presenter = browserPresenter()
                if (presenter == null || presenter is UIAlertController || presenter is BrowserVerificationController ||
                    presenter.viewIfLoaded?.window == null || presenter.isBeingDismissed() || presenter.isBeingPresented()
                ) {
                    lifetime.cancel()
                    continuation.resumeWithException(IllegalStateException("Unable to present browser verification on iOS"))
                    return@browserOnMain
                }
                val browser = BrowserVerificationController(
                    source = source,
                    initialUrl = url,
                    titleText = title,
                    headers = headers,
                    cookieRepository = cookieRepository,
                    lifetime = lifetime,
                    needsPageResult = waitForResult,
                    refetch = fetchResult,
                ) { result ->
                    if (continuation.isActive) {
                        result.fold(continuation::resume, continuation::resumeWithException)
                    }
                }
                controller = browser
                browser.modalPresentationStyle = UIModalPresentationFullScreen
                presenter.presentViewController(browser, animated = true) {
                    // startBrowser transfers ownership to the visible controller; Await retains cancellation.
                    if (!waitForResult && continuation.isActive && lifetime.isActive) continuation.resume(null)
                }
            }
        }
    }

    private suspend fun resolveHeaders(source: BookSource?, url: String): Map<String, String> {
        val sourceKey = source?.bookSourceUrl.orEmpty()
        val variables = linkedMapOf<String, Any?>(
            "baseUrl" to sourceKey.ifBlank { url },
            "url" to url,
            "sourceVariable" to source?.let { sourceStateStore?.getSourceVariable(sourceKey) },
            "sourceVariableMap" to source?.let { sourceStateStore?.getSourceVariableMap(sourceKey) }.orEmpty(),
        )
        val resolved = LinkedHashMap(headerResolver.resolve(source?.header, variables))
        source?.let { resolved.putAllUserAgentAware(sourceStateStore?.getLoginHeaderMap(sourceKey).orEmpty()) }
        return resolved.withoutNullUserAgent().filter { (name, value) ->
            name.isNotEmpty() && name.all { it.isLetterOrDigit() && it.code < 128 || it in "!#$%&'*+-.^_`|~" } &&
                value.none { it == '\r' || it == '\n' || it == '\u0000' } &&
                name.lowercase() !in BROWSER_MANAGED_HEADERS
        }
    }
}

private class BrowserVerificationController(
    private val source: BookSource?,
    private val initialUrl: String,
    private val titleText: String,
    private val headers: Map<String, String>,
    private val cookieRepository: CookieRepository,
    private val lifetime: Job,
    private val needsPageResult: Boolean,
    private val refetch: (suspend () -> SourceResponse)?,
    onComplete: (Result<SourceResponse?>) -> Unit,
) : UIViewController(nibName = null, bundle = null), WKNavigationDelegateProtocol {
    private val scope = CoroutineScope(lifetime + Dispatchers.Main.immediate)
    private val ownerOrigin = if (source == null) browserOrigin(initialUrl) else browserOrigin(source.bookSourceUrl)
    private var completion: ((Result<SourceResponse?>) -> Unit)? = onComplete
    private var dismissal: (() -> Unit)? = null
    private var dismissalStarted = false
    private var state = State.PREPARING
    private var webView: WKWebView? = null
    private var navigation: WKNavigation? = null
    private var revision = 0L
    private var loaded = false
    private var pageResponse: NSHTTPURLResponse? = null
    private var timeout: Job? = null
    private val cookieSeeds = linkedMapOf<String, CookieSeed>()
    private val visitedUrls = linkedMapOf<String, String>()
    private var policyReload: NSURLRequest? = null
    private val replacedNavigations = mutableSetOf<WKNavigation>()
    private val cancelButton = UIButton.buttonWithType(UIButtonTypeSystem) as UIButton
    private val completeButton = UIButton.buttonWithType(UIButtonTypeSystem) as UIButton
    private val titleLabel = UILabel()
    private val statusLabel = UILabel()

    override fun viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackgroundColor
        cancelButton.setTitle("取消", forState = 0u)
        cancelButton.addTarget(this, NSSelectorFromString("cancel"), UIControlEventTouchUpInside)
        completeButton.setTitle("完成验证", forState = 0u)
        completeButton.enabled = false
        completeButton.addTarget(this, NSSelectorFromString("confirm"), UIControlEventTouchUpInside)
        titleLabel.text = titleText.ifBlank { source?.bookSourceName.orEmpty().ifBlank { "网页验证" } }
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75
        statusLabel.text = "正在加载网页"
        statusLabel.numberOfLines = 2
        statusLabel.textColor = UIColor.secondaryLabelColor
        listOf(cancelButton, completeButton, titleLabel, statusLabel).forEach { view.addSubview(it) }

        val configuration = WKWebViewConfiguration().apply {
            websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore()
        }
        val browser = WKWebView(CGRectMake(0.0, 0.0, 1.0, 1.0), configuration)
        webView = browser
        browser.navigationDelegate = this
        headers.entries.firstOrNull { it.key.equals("User-Agent", true) }?.value
            ?.let { browser.customUserAgent = it }
        view.addSubview(browser)
        armTimeout("Browser cookie preparation timed out")
        scope.launch {
            try {
                val seeds = withContext(Dispatchers.Default) {
                    listOfNotNull(source?.bookSourceUrl, initialUrl)
                        .filter { browserHttpUrl(it) != null }
                        .distinctBy { browserHttpUrl(it)?.host?.lowercase() }
                        .map { url ->
                            ensureActive()
                            CookieSeed(url, cookieRepository.getCookiesForHost(url), cookieRepository.requestCookieHeader(url))
                        }
                }
                if (!active(State.PREPARING)) return@launch
                seeds.forEach { seed -> cookieSeeds[browserHost(seed.url)] = seed }
                seedCookies(browser, seeds, 0)
            } catch (error: Throwable) {
                fail(error)
            }
        }
    }

    override fun viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        val top = view.safeAreaInsets.useContents { top }
        val bottom = view.safeAreaInsets.useContents { bottom }
        val left = view.safeAreaInsets.useContents { left }
        val right = view.safeAreaInsets.useContents { right }
        val width = view.bounds.useContents { size.width }
        val height = view.bounds.useContents { size.height }
        cancelButton.setFrame(CGRectMake(left + 8.0, top + 4.0, 60.0, 44.0))
        completeButton.setFrame(CGRectMake(width - right - 108.0, top + 4.0, 100.0, 44.0))
        titleLabel.setFrame(CGRectMake(left + 76.0, top + 4.0, (width - left - right - 192.0).coerceAtLeast(0.0), 44.0))
        statusLabel.setFrame(CGRectMake(left + 16.0, top + 52.0, (width - left - right - 32.0).coerceAtLeast(0.0), 44.0))
        webView?.setFrame(CGRectMake(left, top + 100.0, width - left - right, (height - top - bottom - 100.0).coerceAtLeast(0.0)))
    }

    override fun viewDidDisappear(animated: Boolean) {
        super.viewDidDisappear(animated)
        if (state != State.FINISHED && (isBeingDismissed() || presentingViewController == null)) cancel()
        if (state == State.FINISHED && presentingViewController == null) deliverDismissal()
    }

    override fun viewDidAppear(animated: Boolean) {
        super.viewDidAppear(animated)
        if (state == State.FINISHED) dismissFinished()
    }

    private fun seedCookies(browser: WKWebView, seeds: List<CookieSeed>, index: Int) {
        if (!active(State.PREPARING)) return
        val seed = seeds.getOrNull(index)
        if (seed == null) {
            state = State.BROWSING
            timeout?.cancel()
            cookieSeeds.values.forEach { rememberUrl(it.url) }
            rememberUrl(initialUrl)
            val request = NSMutableURLRequest.requestWithURL(checkNotNull(NSURL.URLWithString(initialUrl)))
            headersFor(initialUrl).filterKeys { !it.equals("Cookie", true) }.forEach { (name, value) ->
                request.setValue(value, forHTTPHeaderField = name)
            }
            navigation = browser.loadRequest(request)
            return
        }
        val seedHeaders = headersFor(seed.url).toMutableMap()
        val explicit = seedHeaders.entries.firstOrNull { it.key.equals("Cookie", true) }?.value
        seedHeaders.keys.filter { it.equals("Cookie", true) }.forEach(seedHeaders::remove)
        mergeRequestCookieHeader(seed.legacyHeader, explicit)?.let { seedHeaders["Cookie"] = it }
        IosWebViewCookieBridge.prepare(browser, seed.url, seedHeaders, seed.cookies) {
            browserOnMain {
                if (active(State.PREPARING)) {
                    try {
                        seedCookies(browser, seeds, index + 1)
                    } catch (error: Throwable) {
                        fail(error)
                    }
                }
            }
        }
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) {
        if (!active(State.BROWSING)) return
        navigation = didStartProvisionalNavigation
        revision++
        loaded = false
        pageResponse = null
        completeButton.enabled = false
        statusLabel.text = "正在加载网页"
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationResponse: WKNavigationResponse,
        decisionHandler: (WKNavigationResponsePolicy) -> Unit,
    ) {
        if (!active(State.BROWSING)) {
            decisionHandler(WKNavigationResponsePolicy.WKNavigationResponsePolicyCancel)
            return
        }
        if (decidePolicyForNavigationResponse.forMainFrame) {
            pageResponse = decidePolicyForNavigationResponse.response as? NSHTTPURLResponse
            rememberUrl(pageResponse?.URL?.absoluteString.orEmpty())
        }
        decisionHandler(WKNavigationResponsePolicy.WKNavigationResponsePolicyAllow)
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
        if (!active(State.BROWSING) || navigation != null && navigation != didFinishNavigation) return
        loaded = pageResponse != null
        rememberUrl(webView.URL?.absoluteString.orEmpty())
        completeButton.enabled = loaded
        statusLabel.text = if (loaded) webView.URL?.host.orEmpty() else "网页没有有效 HTTP 响应"
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationAction: WKNavigationAction,
        decisionHandler: (WKNavigationActionPolicy) -> Unit,
    ) {
        if (!active(State.BROWSING)) {
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            return
        }
        val action = decidePolicyForNavigationAction
        val request = action.request
        val url = request.URL?.absoluteString.orEmpty()
        val target = browserHttpUrl(url)
        if (target == null) {
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            return
        }
        val mainFrame = action.targetFrame?.mainFrame != false
        if (mainFrame) rememberUrl(url)
        val approved = policyReload
        policyReload = null
        if (approved != null && request.URL == approved.URL && request.HTTPMethod == approved.HTTPMethod) {
            // Browser-generated standard fields may reappear, but source credentials must stay removed.
            val credentialNames = headers.keys.filter { it.lowercase() !in BROWSER_PUBLIC_HEADERS }
            val carriesCredentials = credentialNames.any { request.valueForHTTPHeaderField(it) != null } ||
                request.valueForHTTPHeaderField("Authorization") != null ||
                request.valueForHTTPHeaderField("Proxy-Authorization") != null
            if (browserOrigin(url) == ownerOrigin || !carriesCredentials) {
                decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyAllow)
                return
            }
        }

        // Never copy source credentials to an IdP, a sibling host, another port or HTTPS downgrade.
        val sameOrigin = browserOrigin(url) == ownerOrigin && ownerOrigin != null
        val stripped = request.allHTTPHeaderFields.orEmpty().keys.filterIsInstance<String>().filter { name ->
            !sameOrigin && (name.equals("Authorization", true) || name.equals("Proxy-Authorization", true) ||
                headers.keys.any { it.equals(name, true) && !it.equals("User-Agent", true) && !it.equals("Cookie", true) })
        }
        val missing = if (sameOrigin && mainFrame) headers.filter { (name, value) ->
            !name.equals("Cookie", true) && request.valueForHTTPHeaderField(name) != value
        } else emptyMap()
        if (stripped.isNotEmpty() || missing.isNotEmpty() || action.targetFrame == null) {
            val clean = request.mutableCopyWithZone(null) as NSMutableURLRequest
            stripped.forEach { clean.setValue(null, forHTTPHeaderField = it) }
            missing.forEach { (name, value) -> clean.setValue(value, forHTTPHeaderField = name) }
            // WKHTTPCookieStore, not a copied request header, chooses cookies for this URL.
            clean.setValue(null, forHTTPHeaderField = "Cookie")
            if (mainFrame) navigation?.let(replacedNavigations::add)
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
            if (!mainFrame) return // Do not turn a frame request into a top-level credential replay.
            policyReload = clean
            navigation = webView.loadRequest(clean)
        } else {
            decisionHandler(WKNavigationActionPolicy.WKNavigationActionPolicyAllow)
        }
    }

    @ObjCAction
    fun confirm() {
        val browser = webView ?: return
        if (!active(State.BROWSING) || !loaded || pageResponse == null) return
        completeButton.enabled = false
        browser.userInteractionEnabled = false
        // Change state before stopLoading: its cancellation callbacks must not fail a confirmed page.
        state = if (needsPageResult && refetch == null) State.CAPTURING else State.SAVING
        browser.stopLoading()
        armTimeout("Browser verification completion timed out")
        // Android false captures the DOM; true replays the original URL only after exporting cookies.
        if (!needsPageResult || refetch != null) {
            exportCookies(browser, null)
            return
        }
        val response = checkNotNull(pageResponse)
        if (response.statusCode !in 200L..299L) {
            fail(HttpException(response.statusCode.toInt(), "Browser verification page failed"))
            return
        }
        val documentRevision = revision
        browser.evaluateJavaScript("({body: document.documentElement ? document.documentElement.outerHTML : '', url: window.location.href})") { value, scriptError ->
            browserOnMain {
                if (!active(State.CAPTURING) || revision != documentRevision) return@browserOnMain
                try {
                    check(scriptError == null) { scriptError?.localizedDescription ?: "Unable to capture verification page" }
                    val snapshot = value as? Map<*, *> ?: error("Verification page snapshot unavailable")
                    val body = snapshot["body"] as? String ?: error("Verification page body unavailable")
                    val finalUrl = snapshot["url"] as? String ?: error("Verification page URL unavailable")
                    check(body.isNotBlank()) { "Verification result is empty" }
                    check(browserOrigin(finalUrl) != null && browserOrigin(finalUrl) == browserOrigin(response.URL?.absoluteString.orEmpty())) {
                        "Verification document changed during capture"
                    }
                    rememberUrl(finalUrl)
                    exportCookies(browser, response.toSourceResponse(finalUrl, body))
                } catch (failure: Throwable) {
                    fail(failure)
                }
            }
        }
    }

    private fun exportCookies(browser: WKWebView, page: SourceResponse?) {
        if (!alive()) return
        state = State.SAVING
        statusLabel.text = "正在保存验证状态"
        browser.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies ->
            browserOnMain {
                if (!active(State.SAVING)) return@browserOnMain
                val nativeCookies = cookies.orEmpty().filterIsInstance<NSHTTPCookie>()
                // Include intermediate and third-party cookie owners, not just the initial/final page.
                nativeCookies.forEach { cookie ->
                    val host = cookie.domain.orEmpty().trimStart('.')
                    val url = "https://${if (':' in host) "[$host]" else host}/"
                    rememberUrl(url)
                }
                val targets = visitedUrls.values.toList()
                scope.launch {
                    try {
                        withContext(Dispatchers.Default) {
                            val previous = cookieSeeds.values.flatMap { it.cookies }.associateBy { it.browserIdentity() }
                            for (url in targets) {
                                ensureActive()
                                val snapshot = IosWebViewCookieBridge.exportCookiesForHost(nativeCookies, url).map { cookie ->
                                    previous[cookie.browserIdentity()]?.let { cookie.copy(creationTimeMillis = it.creationTimeMillis) } ?: cookie
                                }
                                // Explicit completion saves session cookies as well as their full attributes.
                                if (browserHost(url) in cookieSeeds) {
                                    cookieRepository.replaceCookiesForHost(url, snapshot, persistSession = true, persistCookies = true)
                                } else {
                                    // An unseeded third party is not an authoritative snapshot of its repository jar.
                                    cookieRepository.saveCookies(url, snapshot, persistSession = true, persistCookies = true)
                                }
                                ensureActive()
                            }
                        }
                        if (!active(State.SAVING)) return@launch
                        state = State.REFETCHING
                        statusLabel.text = "正在获取验证结果"
                        val result = if (refetch != null) withContext(Dispatchers.Default) { refetch.invoke() } else page
                        ensureActive()
                        if (!active(State.REFETCHING)) return@launch
                        if (needsPageResult) {
                            checkNotNull(result) { "Verification result unavailable" }
                            if (result.statusCode !in 200..299) throw HttpException(result.statusCode, result.statusText)
                            check(result.bodyText.isNotBlank()) { "Verification result is empty" }
                        }
                        finish(Result.success(result))
                    } catch (error: Throwable) {
                        fail(error)
                    }
                }
            }
        }
    }

    @ObjCAction
    fun cancel() = finish(Result.failure(CancellationException("Browser verification cancelled")))

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFailNavigation: WKNavigation?, withError: NSError) =
        navigationFailed(didFailNavigation, withError)

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFailProvisionalNavigation: WKNavigation?, withError: NSError) =
        navigationFailed(didFailProvisionalNavigation, withError)

    override fun webViewWebContentProcessDidTerminate(webView: WKWebView) {
        if (alive()) fail(IllegalStateException("Browser verification content process terminated"))
    }

    private fun navigationFailed(failed: WKNavigation?, error: NSError) {
        if (failed != null && replacedNavigations.remove(failed)) return
        if (active(State.BROWSING) && (navigation == null || navigation == failed)) {
            fail(IllegalStateException(error.localizedDescription ?: "Browser verification navigation failed"))
        }
    }

    private fun headersFor(url: String): Map<String, String> =
        if (ownerOrigin != null && browserOrigin(url) == ownerOrigin) headers
        else headers.filterKeys { it.equals("User-Agent", true) }

    private fun rememberUrl(url: String) {
        browserHttpUrl(url)?.host?.lowercase()?.let { visitedUrls[it] = url }
    }

    private fun alive(): Boolean = lifetime.isActive && state != State.FINISHED

    private fun active(expected: State): Boolean = alive() && state == expected

    private fun armTimeout(message: String) {
        timeout?.cancel()
        timeout = scope.launch {
            delay(60_000L)
            if (alive()) fail(IllegalStateException(message))
        }
    }

    private fun fail(error: Throwable) {
        if (alive()) finish(Result.failure(error))
    }

    private fun finish(result: Result<SourceResponse?>) {
        if (state == State.FINISHED || result.isSuccess && !lifetime.isActive) return
        state = State.FINISHED
        revision++
        lifetime.cancel()
        policyReload = null
        replacedNavigations.clear()
        webView?.apply {
            navigationDelegate = null
            UIDelegate = null
            stopLoading()
        }
        val callback = completion
        completion = null
        dismissal = { callback?.invoke(result); Unit }
        dismissFinished()
    }

    private fun dismissFinished() {
        if (presentingViewController == null) {
            deliverDismissal()
        } else if (!isBeingPresented() && !dismissalStarted) {
            dismissalStarted = true
            dismissViewControllerAnimated(true) { deliverDismissal() }
        }
    }

    private fun deliverDismissal() {
        val callback = dismissal
        dismissal = null
        callback?.invoke()
    }

    private enum class State { PREPARING, BROWSING, CAPTURING, SAVING, REFETCHING, FINISHED }
    private data class CookieSeed(val url: String, val cookies: List<StoredHttpCookie>, val legacyHeader: String?)
}

private fun NSHTTPURLResponse.toSourceResponse(finalUrl: String, html: String): SourceResponse {
    val fields = linkedMapOf<String, List<String>>()
    allHeaderFields.forEach { (key, value) ->
        val name = key?.toString() ?: return@forEach
        val values = when (value) {
            is List<*> -> value.mapNotNull { it?.toString() }
            is Array<*> -> value.mapNotNull { it?.toString() }
            null -> emptyList()
            else -> listOf(value.toString())
        }
        val existing = fields.keys.firstOrNull { it.equals(name, true) } ?: name
        fields[existing] = fields[existing].orEmpty() + values
    }
    val normalizedFields = fields.withSplitSetCookieHeaders()
    return SourceResponse(
        url = finalUrl,
        bodyText = html,
        body = html.encodeToByteArray(),
        statusCode = statusCode.toInt(),
        statusText = NSHTTPURLResponse.localizedStringForStatusCode(statusCode),
        headers = normalizedFields.mapValues { it.value.firstOrNull().orEmpty() },
        allHeaders = normalizedFields,
    )
}

private fun browserHttpUrl(value: String): Url? = runCatching {
    require(value.none { it.code <= 0x20 || it.code == 0x7f || it == '\\' })
    val nativeUrl = NSURL.URLWithString(value) ?: return@runCatching null
    Url(value).takeIf {
        it.protocol.name in setOf("http", "https") && it.host.isNotBlank() &&
            it.user.isNullOrEmpty() && it.password.isNullOrEmpty() &&
            it.host.removeSurrounding("[", "]").equals(nativeUrl.host?.removeSurrounding("[", "]"), true) &&
            it.protocol.name.equals(nativeUrl.scheme, true)
    }
}.getOrNull()

private fun browserOrigin(url: String): Triple<String, String, Int>? = browserHttpUrl(url)?.let {
    Triple(it.protocol.name.lowercase(), it.host.lowercase(), it.port)
}

private fun browserHost(url: String): String = browserHttpUrl(url)?.host?.lowercase().orEmpty()

private fun StoredHttpCookie.browserIdentity(): Triple<String, String, String> = Triple(name, domain, path)

private fun browserPresenter(): UIViewController? {
    fun visible(controller: UIViewController): UIViewController {
        controller.presentedViewController?.let { return visible(it) }
        if (controller is UINavigationController) controller.visibleViewController?.let { return visible(it) }
        if (controller is UITabBarController) controller.selectedViewController?.let { return visible(it) }
        return controller
    }
    val windows = UIApplication.sharedApplication.connectedScenes.filterIsInstance<UIWindowScene>()
        .filter { it.activationState == UISceneActivationStateForegroundActive }
        .flatMap { it.windows.filterIsInstance<UIWindow>() }
    return windows.firstOrNull { it.isKeyWindow() && !it.hidden }?.rootViewController?.let(::visible)
}

private fun browserOnMain(block: () -> Unit) {
    if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
}

private val BROWSER_MANAGED_HEADERS = setOf(
    "host", "connection", "content-length", "transfer-encoding", "proxy", "cookiejar", "proxy-authorization",
)

private val BROWSER_PUBLIC_HEADERS = setOf("user-agent", "accept", "accept-language", "referer", "origin", "cookie")
