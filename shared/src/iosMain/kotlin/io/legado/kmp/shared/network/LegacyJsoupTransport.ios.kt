@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import okio.Buffer
import platform.Foundation.*
import platform.darwin.NSObject
import kotlin.coroutines.CoroutineContext

private const val LEGACY_JSOUP_COPY_SIZE = 64 * 1024

internal actual suspend fun legacyJsoupTransport(
    request: LegacyJsoupTransportRequest,
    acceptBody: (LegacyJsoupTransportHead) -> Boolean,
): LegacyJsoupTransportResponse {
    val caller = currentCoroutineContext()
    caller.ensureActive()
    require(request.timeoutMillis >= 0 && request.maxBodySize >= 0) { "Invalid Jsoup transport limits" }
    val url = requireNotNull(NSURL.URLWithString(request.url)) { "Invalid Jsoup transport URL" }
    require(url.scheme?.lowercase() in setOf("http", "https") && !url.host.isNullOrBlank() &&
        url.user == null && url.password == null && request.url.none { it < ' ' || it == '\u007f' || it == '\\' }
    ) { "Jsoup transport requires an HTTP URL without credentials" }
    require(legacyJsoupNativeToken(request.method)) { "Invalid Jsoup transport method" }
    val total = if (request.timeoutMillis == 0) Double.MAX_VALUE else request.timeoutMillis / 1000.0
    val idle = if (request.timeoutMillis == 0) Double.MAX_VALUE else request.timeoutMillis / 2000.0
    val nativeRequest = NSMutableURLRequest.requestWithURL(url).apply {
        setHTTPMethod(request.method)
        setHTTPShouldHandleCookies(false)
        setCachePolicy(NSURLRequestReloadIgnoringLocalCacheData)
        setTimeoutInterval(idle)
        request.headers.forEach { (name, value) ->
            caller.ensureActive()
            require(legacyJsoupNativeToken(name) && value.none { it < ' ' || it == '\u007f' }) {
                "Invalid Jsoup transport header"
            }
            setValue(value, forHTTPHeaderField = name)
        }
        // Do not turn a null GET body into empty NSData / Content-Length: 0.
        request.body?.let { bytes ->
            val data = if (bytes.isEmpty()) NSData() else bytes.usePinned {
                NSData.create(bytes = it.addressOf(0), length = bytes.size.toULong())
            }
            setHTTPBody(data)
        }
    }
    caller.ensureActive()
    val config = NSURLSessionConfiguration.ephemeralSessionConfiguration.apply {
        HTTPShouldSetCookies = false
        HTTPCookieStorage = null
        URLCredentialStorage = null
        URLCache = null
        HTTPAdditionalHeaders = null
        requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData
        waitsForConnectivity = false
        timeoutIntervalForRequest = idle
        timeoutIntervalForResource = total
    }
    val queue = NSOperationQueue().apply {
        name = "io.legado.jsoup.transport"
        maxConcurrentOperationCount = 1
    }
    val delegate = LegacyJsoupNativeDelegate(request, acceptBody, caller)
    // The session retains both delegate and queue until invalidation; keep our ownership through terminal cleanup.
    val session = NSURLSession.sessionWithConfiguration(config, delegate, queue)
    var task: NSURLSessionDataTask? = null
    val result = try {
        val native = session.dataTaskWithRequest(nativeRequest)
        task = native
        delegate.attach(native)
        if (!caller.isActive) delegate.cancelFromCaller()
        native.resume()
        delegate.terminal.await()
        caller.ensureActive()
        delegate.response()
    } finally {
        withContext(NonCancellable) {
            try {
                if (task != null) {
                    if (!delegate.terminal.isCompleted) delegate.cancelFromCaller()
                    // Only didCompleteWithError signals this deferred, including after task.cancel().
                    delegate.terminal.await()
                }
            } finally {
                try { delegate.release() } finally { session.invalidateAndCancel() }
            }
        }
    }
    caller.ensureActive()
    return result
}

private class LegacyJsoupNativeDelegate(
    private val request: LegacyJsoupTransportRequest,
    acceptBody: (LegacyJsoupTransportHead) -> Boolean,
    private val caller: CoroutineContext,
) : NSObject(), NSURLSessionDataDelegateProtocol {
    val terminal = CompletableDeferred<Unit>()
    private val lock = NSRecursiveLock()
    private val body = Buffer()
    private val scratch = ByteArray(minOf(LEGACY_JSOUP_COPY_SIZE, request.maxBodySize.takeIf { it > 0 } ?: LEGACY_JSOUP_COPY_SIZE))
    private var policy: ((LegacyJsoupTransportHead) -> Boolean)? = acceptBody
    private var native: NSURLSessionDataTask? = null
    private var head: LegacyJsoupTransportHead? = null
    private var failure: Throwable? = null
    private var nativeError: NSError? = null
    private var reading = false
    private var stoppedEarly = false
    private var callerCancelled = false
    private var finished = false
    private var authenticationChallenges = 0

    fun attach(task: NSURLSessionDataTask) = locked { native = task }

    fun cancelFromCaller() = locked {
        callerCancelled = true
        reading = false
        native?.cancel()
    }

    override fun URLSession(
        session: NSURLSession,
        didReceiveChallenge: NSURLAuthenticationChallenge,
        completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Unit,
    ) {
        locked { authenticationChallenges++ }
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, null)
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        didReceiveChallenge: NSURLAuthenticationChallenge,
        completionHandler: (NSURLSessionAuthChallengeDisposition, NSURLCredential?) -> Unit,
    ) {
        locked { authenticationChallenges++ }
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, null)
    }

    override fun URLSession(
        session: NSURLSession,
        task: NSURLSessionTask,
        willPerformHTTPRedirection: NSHTTPURLResponse,
        newRequest: NSURLRequest,
        completionHandler: (NSURLRequest?) -> Unit,
    ) {
        var stop = false
        protect(task) {
            if (finished || callerCancelled || failure != null) return@protect
            acceptHead(willPerformHTTPRedirection)
            stop = stoppedEarly
        }
        protect(task) {
            completionHandler(null)
            if (stop) task.cancel()
        }
    }

    override fun URLSession(
        session: NSURLSession,
        dataTask: NSURLSessionDataTask,
        didReceiveResponse: NSURLResponse,
        completionHandler: (NSURLSessionResponseDisposition) -> Unit,
    ) {
        var disposition = NSURLSessionResponseCancel
        protect(dataTask) {
            if (finished || callerCancelled || failure != null) return@protect
            val http = didReceiveResponse as? NSHTTPURLResponse ?: error("Jsoup received a non-HTTP response")
            acceptHead(http)
            if (reading) disposition = NSURLSessionResponseAllow
        }
        // Even a throwing policy must release Foundation's pending response decision exactly once.
        protect(dataTask) { completionHandler(disposition) }
    }

    override fun URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData: NSData) =
        protect(dataTask) {
            if (finished || !reading || callerCancelled || failure != null) return@protect
            var offset = 0uL
            while (offset < didReceiveData.length) {
                caller.ensureActive()
                val remaining = if (request.maxBodySize == 0) Long.MAX_VALUE
                    else request.maxBodySize.toLong() - body.size
                if (remaining <= 0) {
                    stopAtLimit(dataTask)
                    return@protect
                }
                val count = minOf(scratch.size.toULong(), didReceiveData.length - offset, remaining.toULong()).toInt()
                scratch.usePinned {
                    didReceiveData.getBytes(it.addressOf(0), range = NSMakeRange(offset, count.toULong()))
                }
                body.write(scratch, 0, count)
                offset += count.toULong()
                if (request.maxBodySize > 0 && body.size >= request.maxBodySize.toLong()) {
                    stopAtLimit(dataTask)
                    return@protect
                }
            }
        }

    override fun URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError: NSError?) {
        try {
            protect(task) {
                nativeError = didCompleteWithError
                reading = false
                finished = true
            }
        } finally {
            protect(task) { terminal.complete(Unit) }
        }
    }

    fun response(): LegacyJsoupTransportResponse = locked {
        check(finished && terminal.isCompleted) { "Jsoup transport has not reached native terminal state" }
        if (callerCancelled) throw CancellationException("Jsoup native request was cancelled by its caller")
        failure?.let { throw it }
        nativeError?.let { cause ->
            val cancelled = cause.domain == NSURLErrorDomain && cause.code == NSURLErrorCancelled
            if (!cancelled || !stoppedEarly) {
                if (cancelled) throw CancellationException("Jsoup native request was cancelled")
                error("Jsoup native HTTP failed (${cause.domain}/${cause.code}; " +
                    "headers=${head != null}, bytes=${body.size}, challenges=$authenticationChallenges): ${cause.localizedDescription}")
            }
        }
        LegacyJsoupTransportResponse(
            requireNotNull(head) { "Jsoup native task completed without HTTP headers" },
            body.readByteArray(),
        )
    }

    fun release() = locked {
        native = null
        policy = null
        head = null
        nativeError = null
        failure = null
        body.clear()
    }

    private fun stopAtLimit(task: NSURLSessionTask) {
        stoppedEarly = true
        reading = false
        task.cancel()
    }

    private fun acceptHead(http: NSHTTPURLResponse) {
        if (head != null) return
        caller.ensureActive()
        val received = http.transportHead()
        head = received
        val accepted = requireNotNull(policy).invoke(received)
        caller.ensureActive()
        val empty = request.method == "HEAD" || http.expectedContentLength == 0L ||
            received.statusCode == 204 || received.statusCode == 304
        reading = accepted && !empty
        if (!reading) stoppedEarly = true
    }

    private inline fun protect(task: NSURLSessionTask, action: () -> Unit) {
        try {
            locked(action)
        } catch (error: Throwable) {
            // Kotlin failures, including policy/cancellation failures, must not escape an ObjC delegate entry.
            locked {
                if (failure == null) failure = error
                reading = false
                task.cancel()
            }
        }
    }

    private inline fun <T> locked(action: () -> T): T {
        lock.lock()
        try { return action() } finally { lock.unlock() }
    }

    private fun NSHTTPURLResponse.transportHead(): LegacyJsoupTransportHead {
        val headers = linkedMapOf<String, List<String>>()
        allHeaderFields.forEach { (rawName, rawValue) ->
            caller.ensureActive()
            val name = rawName?.toString() ?: return@forEach
            val values = when (rawValue) {
                is List<*> -> rawValue.mapNotNull { it?.toString() }
                null -> emptyList()
                else -> listOf(rawValue.toString())
            }
            val key = headers.keys.firstOrNull { it.equals(name, true) } ?: name
            headers[key] = headers[key].orEmpty() + values
        }
        return LegacyJsoupTransportHead(
            requireNotNull(URL?.absoluteString) { "Jsoup native response has no URL" },
            statusCode.toInt(),
            headers,
        )
    }

}

private fun legacyJsoupNativeToken(value: String): Boolean = value.isNotEmpty() &&
    value.all { it in '0'..'9' || it in 'a'..'z' || it in 'A'..'Z' || it in "!#$%&'*+-.^_`|~" }
