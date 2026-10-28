package io.legado.kmp.shared.network

/** Page-world request observation, not an HTTP interceptor: workers/native media may be invisible. */
internal class IosSourceWebViewScript(val token: String) {
    val handlerName = "legadoResource"
    private val cleanupKey = "__legadoResourceCleanup_" + token.replace("-", "")

    val cleanup: String
        get() = "(function(){var f=window['$cleanupKey'];if(f)f();})()"

    val install: String
        get() = """
            (function () {
                'use strict';
                var token = '$token';
                var cleanupKey = '$cleanupKey';
                if (window[cleanupKey]) return;
                var active = true;
                var seen = new Set();
                var restores = [];
                var observer = null;
                var mutationObserver = null;
                var fallbackTimer = null;
                var mediaTargets = new Set();
                var xhrStarts = new Map();
                var xhrRequests = new WeakMap();
                var NativeURL = window.URL;
                var NativeRequest = window.Request;
                var nativePost = window.webkit && window.webkit.messageHandlers['$handlerName'];
                var addEvent = EventTarget.prototype.addEventListener;
                var removeEvent = EventTarget.prototype.removeEventListener;

                function requestUrl(value) {
                    try {
                        if (NativeRequest && value instanceof NativeRequest) return value.url;
                        if (value instanceof NativeURL) return value.href;
                        // Do not invoke an arbitrary object's toString a second time.
                        if (typeof value !== 'string') return null;
                        return new NativeURL(value, document.baseURI).href;
                    } catch (_) { return null; }
                }

                function report(url, kind) {
                    if (!active || typeof url !== 'string' || !url || seen.has(url)) return;
                    seen.add(url);
                    try { nativePost.postMessage({token: token, url: url, kind: kind}); } catch (_) {}
                }

                function patch(owner, name, replacement) {
                    if (!owner) return;
                    try {
                        var original = owner[name];
                        owner[name] = replacement;
                        if (owner[name] === replacement) restores.push(function () {
                            if (owner[name] === replacement) owner[name] = original;
                        });
                    } catch (_) {}
                }

                function readResources() {
                    try {
                        performance.getEntriesByType('resource').forEach(function (entry) {
                            report(entry.name, 'resource');
                        });
                    } catch (_) {}
                }

                try {
                    observer = new PerformanceObserver(function (list) {
                        list.getEntries().forEach(function (entry) { report(entry.name, 'resource'); });
                    });
                    try { observer.observe({type: 'resource', buffered: true}); }
                    catch (_) { observer.observe({entryTypes: ['resource']}); }
                } catch (_) {
                    observer = null;
                    fallbackTimer = setInterval(readResources, 250);
                }
                readResources();

                var nativeFetch = window.fetch;
                if (typeof nativeFetch === 'function') patch(window, 'fetch', function (input, init) {
                    var result = nativeFetch.apply(this, arguments);
                    try {
                        var signal = init && init.signal || input && input.signal;
                        if (!signal || !signal.aborted) report(requestUrl(input), 'fetch');
                    } catch (_) {}
                    return result;
                });

                var xhrPrototype = window.XMLHttpRequest && XMLHttpRequest.prototype;
                if (xhrPrototype) {
                    var nativeOpen = xhrPrototype.open;
                    var nativeSend = xhrPrototype.send;
                    patch(xhrPrototype, 'open', function (method, url, async) {
                        var result = nativeOpen.apply(this, arguments);
                        var previous = xhrStarts.get(this);
                        if (previous) removeEvent.call(this, 'loadstart', previous, false);
                        xhrStarts.delete(this);
                        xhrRequests.set(this, {url: requestUrl(url), async: arguments.length < 3 || !!async});
                        return result;
                    });
                    patch(xhrPrototype, 'send', function () {
                        var xhr = this;
                        var request = xhrRequests.get(xhr);
                        if (!active || !request) return nativeSend.apply(xhr, arguments);
                        var started = function (event) {
                            if (event && !event.isTrusted) return;
                            removeEvent.call(xhr, 'loadstart', started, false);
                            xhrStarts.delete(xhr);
                            report(request.url, 'xhr');
                        };
                        addEvent.call(xhr, 'loadstart', started, false);
                        xhrStarts.set(xhr, started);
                        try {
                            var result = nativeSend.apply(xhr, arguments);
                            // Synchronous XHR does not dispatch progress/loadstart events.
                            if (!request.async) started();
                            return result;
                        } catch (error) {
                            removeEvent.call(xhr, 'loadstart', started, false);
                            xhrStarts.delete(xhr);
                            throw error;
                        }
                    });
                }

                function mediaStarted(event) {
                    if (!event.isTrusted) return;
                    var media = event.target;
                    if (!(media instanceof HTMLMediaElement)) return;
                    // currentSrc is the selected resource; src/source attributes may never load.
                    if (media.currentSrc) report(media.currentSrc, 'media');
                }

                function watchMedia(element) {
                    if (!(element instanceof HTMLMediaElement) || mediaTargets.has(element)) return element;
                    mediaTargets.add(element);
                    addEvent.call(element, 'loadstart', mediaStarted, false);
                    return element;
                }

                function scanMedia(root) {
                    watchMedia(root);
                    if (root.querySelectorAll) root.querySelectorAll('audio,video').forEach(watchMedia);
                }

                addEvent.call(document, 'loadstart', mediaStarted, true);
                scanMedia(document);
                try {
                    mutationObserver = new MutationObserver(function (records) {
                        records.forEach(function (record) { record.addedNodes.forEach(scanMedia); });
                    });
                    mutationObserver.observe(document, {childList: true, subtree: true});
                } catch (_) {}

                // Detached new Audio()/createElement('video') still receive request-start listeners.
                var documentPrototype = window.Document && Document.prototype;
                if (documentPrototype) {
                    ['createElement', 'createElementNS'].forEach(function (method) {
                        var original = documentPrototype[method];
                        if (typeof original === 'function') patch(documentPrototype, method, function () {
                            return watchMedia(original.apply(this, arguments));
                        });
                    });
                }
                var NativeAudio = window.Audio;
                if (typeof NativeAudio === 'function') {
                    var observedAudio = function () {
                        return watchMedia(Reflect.construct(NativeAudio, Array.prototype.slice.call(arguments), new.target || NativeAudio));
                    };
                    observedAudio.prototype = NativeAudio.prototype;
                    Object.setPrototypeOf(observedAudio, NativeAudio);
                    patch(window, 'Audio', observedAudio);
                }

                function cleanupMessage(event) {
                    if (event.data && event.data.legadoCleanup === token) cleanup();
                }

                function cleanup() {
                    if (!active) return;
                    active = false;
                    // Each frame relays cleanup; cross-origin frame DOM access is unnecessary.
                    for (var i = 0; i < window.frames.length; i++) {
                        try { window.frames[i].postMessage({legadoCleanup: token}, '*'); } catch (_) {}
                    }
                    if (observer) observer.disconnect();
                    if (mutationObserver) mutationObserver.disconnect();
                    if (fallbackTimer !== null) clearInterval(fallbackTimer);
                    removeEvent.call(document, 'loadstart', mediaStarted, true);
                    removeEvent.call(window, 'message', cleanupMessage, false);
                    mediaTargets.forEach(function (media) { removeEvent.call(media, 'loadstart', mediaStarted, false); });
                    xhrStarts.forEach(function (listener, xhr) { removeEvent.call(xhr, 'loadstart', listener, false); });
                    restores.reverse().forEach(function (restore) { try { restore(); } catch (_) {} });
                    mediaTargets.clear();
                    xhrStarts.clear();
                    seen.clear();
                    delete window[cleanupKey];
                }

                addEvent.call(window, 'message', cleanupMessage, false);
                Object.defineProperty(window, cleanupKey, {value: cleanup, configurable: true});
            })();
        """.trimIndent()
}
