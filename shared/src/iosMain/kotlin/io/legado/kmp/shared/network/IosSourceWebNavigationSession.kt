@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.network

import io.legado.kmp.shared.domain.repository.CookieRepository
import io.legado.kmp.shared.model.StoredHttpCookie
import kotlinx.cinterop.useContents
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.job
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import platform.Foundation.HTTPBody
import platform.Foundation.HTTPBodyStream
import platform.Foundation.HTTPMethod
import platform.Foundation.HTTPShouldHandleCookies
import platform.Foundation.HTTPShouldUsePipelining
import platform.Foundation.NSHTTPCookie
import platform.Foundation.NSMutableURLRequest
import platform.Foundation.NSProcessInfo
import platform.Foundation.NSThread
import platform.Foundation.NSURL
import platform.Foundation.NSURLComponents
import platform.Foundation.NSURLRequest
import platform.Foundation.allHTTPHeaderFields
import platform.Foundation.setHTTPBody
import platform.Foundation.setHTTPMethod
import platform.Foundation.setHTTPShouldHandleCookies
import platform.Foundation.setHTTPShouldUsePipelining
import platform.Foundation.setValue
import platform.WebKit.WKNavigationAction
import platform.WebKit.WKWebView
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import kotlin.coroutines.resume

internal sealed class IosSourceWebNavigationDecision {
    object Allow : IosSourceWebNavigationDecision()
    object Cancel : IosSourceWebNavigationDecision()
    data class Reload(val request: NSURLRequest) : IosSourceWebNavigationDecision()
}

/** Main-confined; the caller owns the scope, timeout and WebKit delegate lifetime. */
internal class IosSourceWebNavigationSession(
    private val initialUrl: String?,
    private val sourceUrl: String?,
    headers: Map<String, String>,
    private val cookieRepository: CookieRepository,
    private val persistCookies: Boolean,
) {
    private val headers = headers.withoutNullUserAgent().toMap()
    private val headerOrigin = target(initialUrl)?.origin
    private val owners = linkedMapOf<String, Owner>()
    private val visitedOwners = linkedMapOf<String, Target>()
    private val cookieWork = Mutex()
    private val operations = mutableSetOf<Job>()
    private var boundView: WKWebView? = null
    private var pendingReload: NSURLRequest? = null
    private var cancelled = false
    private var persisted = false

    suspend fun prepareInitial(view: WKWebView, includeCurrentDocument: Boolean = false) = operation(view) {
        val initial = initialUrl?.takeIf { it.isNotBlank() }?.let {
            requireNotNull(target(it)) { "Invalid initial WebView URL" }
        }
        // A source key can be a logical identifier; it never grants headers to another origin.
        val document = if (includeCurrentDocument) target(view.URL?.absoluteString) else null
        val targets = listOfNotNull(initial, target(sourceUrl), document).distinctBy { it.host }
        cookieWork.withLock {
            for (target in targets) {
                checkActive()
                val owner = requireNotNull(owner(target)) { "Too many WebView cookie owners" }
                seed(view, owner, target)
            }
            if (document != null) remember(document)
        }
    }

    /**
     * null requires decide in the caller's main scope. For needsDeferredPreparation, retain the
     * policy callback and allow the original request after seeding; otherwise cancel before a reload.
     */
    fun preflight(view: WKWebView, action: WKNavigationAction): IosSourceWebNavigationDecision? {
        checkMain()
        if (cancelled) return IosSourceWebNavigationDecision.Cancel
        bind(view)
        val frame = action.targetFrame ?: return IosSourceWebNavigationDecision.Cancel
        val request = action.request
        val target = target(request.URL?.absoluteString) ?: return IosSourceWebNavigationDecision.Cancel
        val owner = owner(target) ?: return IosSourceWebNavigationDecision.Cancel
        val removed = sourceHeaderNames(request, target)
        if (frame.mainFrame) {
            val approved = pendingReload
            pendingReload = null
            if (approved != null && approved.URL?.absoluteString == request.URL?.absoluteString &&
                approved.HTTPMethod == request.HTTPMethod
            ) {
                // WebKit can regenerate Cookie from its own store. Other source credentials cannot reappear.
                if (sameRequest(approved, request) && owner.seeded && removed.all { it.equals("Cookie", true) }) {
                    remember(target)
                    return IosSourceWebNavigationDecision.Allow
                }
                return IosSourceWebNavigationDecision.Cancel
            }
        }
        if (removed.isEmpty()) {
            if (!owner.seeded) return null
            remember(target)
            return IosSourceWebNavigationDecision.Allow
        }
        // Never promote a subframe/new-window request into a top-level replay or replay a consumed stream.
        if (!frame.mainFrame || request.HTTPBodyStream != null) return IosSourceWebNavigationDecision.Cancel
        if (!owner.seeded) return null
        val clean = cleanRequest(request, removed)
        pendingReload = clean
        return IosSourceWebNavigationDecision.Reload(clean)
    }

    /** True only for cookie preparation that can preserve the original frame, method and body. */
    fun needsDeferredPreparation(view: WKWebView, action: WKNavigationAction): Boolean {
        checkMain()
        if (cancelled || action.targetFrame == null) return false
        bind(view)
        val target = target(action.request.URL?.absoluteString) ?: return false
        return owners[target.host]?.seeded != true && sourceHeaderNames(action.request, target).isEmpty()
    }

    suspend fun decide(view: WKWebView, action: WKNavigationAction): IosSourceWebNavigationDecision = operation(view) {
        preflight(view, action)?.let { return@operation it }
        val target = checkNotNull(target(action.request.URL?.absoluteString))
        val owner = checkNotNull(owner(target))
        val removed = sourceHeaderNames(action.request, target)
        val clean = if (removed.isEmpty()) null else cleanRequest(action.request, removed)
        cookieWork.withLock {
            checkActive()
            seed(view, owner, target)
        }
        checkActive()
        if (clean == null) {
            remember(target)
            IosSourceWebNavigationDecision.Allow
        } else {
            pendingReload = clean
            IosSourceWebNavigationDecision.Reload(clean)
        }
    }

    /** Only for a popup already approved by the caller's hook and deliberately loaded as main-frame. */
    suspend fun prepareTopLevelRequest(view: WKWebView, request: NSURLRequest): IosSourceWebNavigationDecision = operation(view) {
        val target = target(request.URL?.absoluteString) ?: return@operation IosSourceWebNavigationDecision.Cancel
        val owner = owner(target) ?: return@operation IosSourceWebNavigationDecision.Cancel
        if (request.HTTPBodyStream != null ||
            (request.HTTPMethod ?: "GET").uppercase() !in setOf("GET", "HEAD") && request.HTTPBody == null
        ) return@operation IosSourceWebNavigationDecision.Cancel
        val removed = sourceHeaderNames(request, target).toMutableSet()
        if (target.origin != headerOrigin) {
            request.allHTTPHeaderFields.orEmpty().keys.filterIsInstance<String>()
                .filterTo(removed) { it.lowercase() in setOf("cookie", "authorization", "proxy-authorization") }
        }
        cookieWork.withLock {
            checkActive()
            seed(view, owner, target)
        }
        checkActive()
        val prepared = if (removed.isEmpty()) request else cleanRequest(request, removed)
        pendingReload = prepared
        // The following WKNavigationAction, not the popup's mere preparation, records the visit.
        IosSourceWebNavigationDecision.Reload(prepared)
    }

    fun discardPendingReload(request: NSURLRequest) {
        checkMain()
        if (pendingReload === request) pendingReload = null
    }

    /** Records an approved in-memory document whose HTTP fetch was already performed by the caller. */
    fun recordDocument(url: String?) {
        checkMain()
        if (cancelled) return
        val target = target(url) ?: return
        if (owner(target) != null) remember(target)
    }

    /** Defaults retain the background consumers' one-shot terminal export and persistence policy. */
    suspend fun persist(
        view: WKWebView,
        finalSnapshot: Boolean = true,
        persistSession: Boolean = persistCookies,
        commitOnMain: Boolean = false,
    ) = operation(view) {
        cookieWork.withLock {
            checkActive()
            if (persisted) return@withLock
            target(view.URL?.absoluteString)?.let { target -> if (owner(target) != null) remember(target) }
            // Navigation policy can run while getAllCookies is suspended; freeze attribution first.
            val visited = visitedOwners.values.map { target ->
                val owner = checkNotNull(owners[target.host])
                ExportOwner(target, owner.seeded, owner.cookies.associateBy { it.identity() })
            }
            val nativeCookies = cookies(view)
            checkActive()
            val snapshots = visited.map { owner ->
                Snapshot(
                    owner.target.url,
                    owner.seeded,
                    IosWebViewCookieBridge.exportCookiesForHost(nativeCookies, owner.target.url).map { cookie ->
                        owner.cookies[cookie.identity()]?.let { cookie.copy(creationTimeMillis = it.creationTimeMillis) } ?: cookie
                    },
                )
            }
            // A live browser serializes cancel with repository commits on main. Its repository lock
            // remains cancellable; a synchronous commit cannot start after main-confined cancel.
            withContext(if (commitOnMain) Dispatchers.Main.immediate else Dispatchers.Default) {
                for (snapshot in snapshots) {
                    ensureActive()
                    if (snapshot.seeded) {
                        cookieRepository.replaceCookiesForHost(
                            snapshot.url, snapshot.cookies,
                            persistSession = persistSession, persistCookies = persistCookies,
                        )
                    } else {
                        // An unprepared owner (e.g. an already-finished redirect) is not an authoritative jar.
                        cookieRepository.saveCookies(
                            snapshot.url, snapshot.cookies,
                            persistSession = persistSession, persistCookies = persistCookies,
                        )
                    }
                    ensureActive()
                }
            }
            checkActive()
            for ((index, owner) in visited.withIndex()) owners[owner.target.host]?.cookies = snapshots[index].cookies
            if (finalSnapshot) persisted = true
        }
    }

    fun cancel() {
        checkMain()
        if (cancelled) return
        cancelled = true
        pendingReload = null
        operations.toList().forEach { it.cancel() }
        operations.clear()
        boundView = null
    }

    private suspend fun seed(view: WKWebView, owner: Owner, target: Target) {
        checkActive()
        if (owner.seeded) return
        val seed = withContext(Dispatchers.Default) {
            ensureActive()
            // Keep the exact owner URL, but include every path/scheme for authoritative host export.
            val stored = cookieRepository.getCookiesForHost(target.url)
            ensureActive()
            val cookieHeader = cookieRepository.requestCookieHeader(target.url)
            ensureActive()
            Seed(stored, cookieHeader)
        }
        checkActive()
        val existing = IosWebViewCookieBridge.exportCookiesForHost(cookies(view), target.url)
        checkActive()
        val existingKeys = existing.mapTo(mutableSetOf()) { it.identity() }
        // A page/redirect may already have set a newer cookie before this host's first navigation.
        val missing = seed.cookies.filter { it.identity() !in existingKeys }
        val knownNames = (existing + seed.cookies).mapTo(mutableSetOf()) { it.name }
        val explicit = if (target.origin == headerOrigin) {
            headers.entries.firstOrNull { it.key.equals("Cookie", true) }?.value
        } else null
        val header = mergeRequestCookieHeader(seed.header, explicit)
            ?.split(';')?.map { it.trim() }
            ?.filter { it.substringBefore('=') !in knownNames }
            ?.joinToString("; ")?.takeIf { it.isNotBlank() }
        val seedHeaders = header?.let { mapOf("Cookie" to it) }.orEmpty()
        suspendCancellableCoroutine<Unit> { continuation ->
            IosWebViewCookieBridge.prepare(view, target.url, seedHeaders, missing) {
                onMain {
                    if (!cancelled && continuation.isActive) continuation.resume(Unit)
                }
            }
        }
        checkActive()
        owner.cookies = seed.cookies
        owner.seeded = true
    }

    private suspend fun cookies(view: WKWebView): List<NSHTTPCookie> =
        suspendCancellableCoroutine { continuation ->
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies ->
                onMain {
                    if (!cancelled && continuation.isActive) {
                        continuation.resume(cookies.orEmpty().filterIsInstance<NSHTTPCookie>())
                    }
                }
            }
        }

    private fun sourceHeaderNames(request: NSURLRequest, target: Target): Set<String> {
        if (headerOrigin != null && target.origin == headerOrigin) return emptySet()
        return request.allHTTPHeaderFields.orEmpty().mapNotNull { (rawName, rawValue) ->
            val name = rawName as? String ?: return@mapNotNull null
            val value = rawValue as? String ?: return@mapNotNull null
            name.takeIf {
                name.lowercase() !in PUBLIC_HEADERS && headers.any { (originalName, originalValue) ->
                    originalName.equals(name, true) && originalValue == value
                }
            }
        }.toSet()
    }

    private fun cleanRequest(request: NSURLRequest, removed: Set<String>): NSURLRequest {
        check(request.HTTPBodyStream == null) { "Cannot replay a WebView body stream" }
        // A fresh request avoids Foundation's allHTTPHeaderFields setter merging removed fields back in.
        val clean = NSMutableURLRequest()
        clean.setURL(checkNotNull(request.URL))
        clean.setCachePolicy(request.cachePolicy)
        clean.setTimeoutInterval(request.timeoutInterval)
        clean.setHTTPMethod(request.HTTPMethod ?: "GET")
        clean.setHTTPBody(request.HTTPBody)
        clean.setMainDocumentURL(request.mainDocumentURL)
        clean.setNetworkServiceType(request.networkServiceType)
        clean.setAllowsCellularAccess(request.allowsCellularAccess)
        clean.setAllowsExpensiveNetworkAccess(request.allowsExpensiveNetworkAccess)
        clean.setAllowsConstrainedNetworkAccess(request.allowsConstrainedNetworkAccess)
        clean.setAssumesHTTP3Capable(request.assumesHTTP3Capable)
        clean.setAttribution(request.attribution)
        val supportsDnssec = NSProcessInfo.processInfo.operatingSystemVersion.useContents {
            majorVersion > 16 || majorVersion == 16L && minorVersion >= 1
        }
        if (supportsDnssec) clean.setRequiresDNSSECValidation(request.requiresDNSSECValidation)
        clean.setHTTPShouldHandleCookies(request.HTTPShouldHandleCookies)
        clean.setHTTPShouldUsePipelining(request.HTTPShouldUsePipelining)
        for ((rawName, rawValue) in request.allHTTPHeaderFields.orEmpty()) {
            val name = rawName as? String ?: continue
            val value = rawValue as? String ?: continue
            if (!name.equals("Cookie", true) && removed.none { it.equals(name, true) }) {
                clean.setValue(value, forHTTPHeaderField = name)
            }
        }
        return clean
    }

    private fun sameRequest(expected: NSURLRequest, actual: NSURLRequest): Boolean =
        expected.URL?.absoluteString == actual.URL?.absoluteString && expected.HTTPMethod == actual.HTTPMethod &&
            expected.HTTPBody == actual.HTTPBody && actual.HTTPBodyStream == null

    private fun owner(target: Target): Owner? = owners[target.host] ?: run {
        if (owners.size >= MAX_OWNERS) null else Owner().also { owners[target.host] = it }
    }

    private fun remember(target: Target) {
        // Keep the actual URL, including port/path, instead of inventing a root owner or source alias.
        visitedOwners[target.host] = target
    }

    private suspend fun <T> operation(view: WKWebView, block: suspend () -> T): T = coroutineScope {
        checkActive()
        bind(view)
        val job = currentCoroutineContext().job
        operations.add(job)
        try {
            block()
        } finally {
            operations.remove(job)
        }
    }

    private suspend fun checkActive() {
        checkMain()
        currentCoroutineContext().ensureActive()
        if (cancelled) throw CancellationException("WebView navigation session cancelled")
    }

    private fun bind(view: WKWebView) {
        check(boundView == null || boundView == view) { "WebView navigation session cannot be reused for another view" }
        boundView = view
    }

    private fun checkMain() = check(NSThread.isMainThread) { "WebView navigation session must run on main" }

    private fun onMain(block: () -> Unit) {
        if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
    }

    private data class Target(val url: String, val host: String, val origin: Origin)
    private data class Origin(val scheme: String, val host: String, val port: Int)
    private class Owner(var seeded: Boolean = false, var cookies: List<StoredHttpCookie> = emptyList())
    private data class Seed(val cookies: List<StoredHttpCookie>, val header: String?)
    private data class ExportOwner(val target: Target, val seeded: Boolean, val cookies: Map<Triple<String, String, String>, StoredHttpCookie>)
    private data class Snapshot(val url: String, val seeded: Boolean, val cookies: List<StoredHttpCookie>)

    private companion object {
        const val MAX_OWNERS = 32
        val PUBLIC_HEADERS = setOf("user-agent", "accept", "accept-language", "accept-encoding", "referer", "origin")

        fun target(raw: String?): Target? {
            if (raw.isNullOrBlank() || raw.length > 32768 || raw.any { it.code <= 0x20 || it.code == 0x7f }) return null
            val url = NSURL(string = raw) ?: return null
            val components = NSURLComponents.componentsWithURL(url, resolvingAgainstBaseURL = false) ?: return null
            val scheme = components.scheme?.lowercase()?.takeIf { it == "http" || it == "https" } ?: return null
            val host = components.host?.lowercase()?.takeIf { it.isNotBlank() && !it.endsWith('.') } ?: return null
            if (components.user != null || components.password != null) return null
            val port = components.port?.intValue ?: if (scheme == "https") 443 else 80
            if (port !in 1..65535) return null
            return Target(url.absoluteString ?: return null, host, Origin(scheme, host, port))
        }

        fun StoredHttpCookie.identity(): Triple<String, String, String> = Triple(name, domain, path)
    }
}
