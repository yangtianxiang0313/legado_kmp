package io.legado.kmp.shared.network

import kotlinx.cinterop.BetaInteropApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.ObjCSignatureOverride
import platform.Foundation.NSError
import platform.Foundation.NSHTTPURLResponse
import platform.Foundation.NSString
import platform.Foundation.NSThread
import platform.WebKit.WKNavigation
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
    private val onComplete: (Result<HttpResponse>) -> Unit,
    private val onCookies: (webView: WKWebView, completion: () -> Unit) -> Unit,
) : NSObject(), WKNavigationDelegateProtocol {
    private val directGet = context.request.method == HttpMethod.GET

    // Mutable state, including cookie completion, is confined to the main thread.
    private var completed = false
    private var revision = 0L
    private var navigation: WKNavigation? = null
    private var response: HttpResponse? = initialResponse.takeUnless { directGet }

    fun cancel() = onMain {
        completed = true
        revision++
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didStartProvisionalNavigation: WKNavigation?) = onMain {
        if (completed) return@onMain
        navigation = didStartProvisionalNavigation
        revision++
        if (directGet) response = null
    }

    @ObjCSignatureOverride
    override fun webView(
        webView: WKWebView,
        decidePolicyForNavigationResponse: WKNavigationResponse,
        decisionHandler: (WKNavigationResponsePolicy) -> Unit,
    ) = onMain {
        try {
            if (!completed && directGet && decidePolicyForNavigationResponse.forMainFrame) {
                val httpResponse = decidePolicyForNavigationResponse.response as? NSHTTPURLResponse
                revision++
                response = httpResponse?.toHttpResponse()
            }
        } catch (throwable: Throwable) {
            finish(Result.failure(throwable))
        } finally {
            decisionHandler(WKNavigationResponsePolicy.WKNavigationResponsePolicyAllow)
        }
    }

    @ObjCSignatureOverride
    override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) = onMain {
        if (completed || (navigation != null && navigation != didFinishNavigation)) return@onMain
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
        try {
            onCookies(webView) {
                onMain {
                    if (isActive(currentRevision)) finish(result)
                }
            }
        } catch (throwable: Throwable) {
            if (isActive(currentRevision)) {
                finish(if (currentResponse.isSuccessful) Result.failure(throwable) else result)
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
            url = URL?.absoluteString.orEmpty().ifBlank { context.requestConfig.url },
            errorBodyText = null,
        )
    }

    private fun isActive(currentRevision: Long): Boolean = !completed && revision == currentRevision

    private fun finish(result: Result<HttpResponse>) {
        if (completed) return
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
