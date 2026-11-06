import CryptoKit
import Foundation
import shared

/// One player item owns one listener and its resource tree. Upstream URLs never reach AVFoundation.
actor HLSAudioRelay {
    private struct Resource {
        let request: PreparedMediaRequest
    }

    private struct RootResponse {
        let path: String
        let response: HLSRelayHTTPResponse
    }

    private let fetcher = HLSResourceFetcher()
    private var server: HLSRelayServer?
    private var resources: [String: Resource] = [:]
    private var registered: [String: String] = [:]
    private var prefetched: RootResponse?
    private var rootCookieTask: Task<Void, Error>?
    private var cancelled = false

    static func prepare(_ request: PreparedMediaRequest) async throws -> (HLSAudioRelay, URL) {
        let relay = HLSAudioRelay()
        return try await withTaskCancellationHandler {
            do {
                let url = try await relay.start(request)
                try Task.checkCancellation()
                return (relay, url)
            } catch {
                await relay.cancel()
                throw error
            }
        } onCancel: {
            Task { await relay.cancel() }
        }
    }

    /// Promotes an already completed audio response without replaying its root request during handoff.
    static func prepare(
        _ request: PreparedMediaRequest, prefetchedRoot: MediaAudioPlaylistResponse
    ) async throws -> (HLSAudioRelay, URL) {
        let relay = HLSAudioRelay()
        return try await withTaskCancellationHandler {
            do {
                let url = try await relay.start(request, prefetchedRoot: prefetchedRoot)
                try Task.checkCancellation()
                return (relay, url)
            } catch {
                await relay.cancel()
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task { await relay.cancel() }
        }
    }

    func cancel() async {
        cancelled = true
        server?.cancel()
        server = nil
        resources.removeAll()
        registered.removeAll()
        prefetched = nil
        let cookies = rootCookieTask
        cookies?.cancel()
        if let cookies { _ = await cookies.result }
        await fetcher.cancel()
    }

    private func start(_ input: PreparedMediaRequest) async throws -> URL {
        try checkActive()
        let request = try Self.withContext(input)
        let response = try await fetcher.fetch(request)
        try checkActive()
        guard Self.isPlaylist(response) else { throw HLSResourceHTTPError.invalidResponse }
        try await startListener()
        try checkActive()
        let root = try register(response.finalRequest, key: "root", extension: "m3u8")
        prefetched = RootResponse(
            path: root.path, response: try render(response, parent: root.path, range: nil))
        return root
    }

    private func start(
        _ input: PreparedMediaRequest, prefetchedRoot: MediaAudioPlaylistResponse
    ) async throws -> URL {
        try checkActive()
        let response = try Self.receivedRoot(prefetchedRoot, original: input)
        let cookies = try HLSResourceHTTPPolicy.setCookieHeaders(prefetchedRoot.response)
        try await recordRootCookies(cookies, request: response.finalRequest, url: response.url)
        try checkActive()
        try await startListener()
        try checkActive()
        let root = try register(response.finalRequest, key: "root", extension: "m3u8")
        // Mamba validates the complete playlist and registers children using the final-hop snapshot.
        let rendered = try render(response, parent: root.path, range: nil)
        try checkActive()
        prefetched = RootResponse(path: root.path, response: rendered)
        return root
    }

    private func startListener() async throws {
        try checkActive()
        let listener = try await HLSRelayServer.start { [weak self] path, method, headers in
            guard let self else { throw CancellationError() }
            return try await self.respond(path: path, method: method, headers: headers)
        }
        do {
            try checkActive()
            server = listener
        } catch {
            listener.cancel()
            throw error
        }
    }

    private func recordRootCookies(_ cookies: [String], request: PreparedMediaRequest, url: URL) async throws {
        try checkActive()
        guard !cookies.isEmpty else { return }
        let task = Task<Void, Error> {
            try checkActive()
            let facade = try MediaResourceFacade.companion.create()
            try checkActive()
            try await facade.recordResponseCookies(
                request: request, responseUrl: url.absoluteString, setCookieHeaders: cookies)
            try checkActive()
        }
        rootCookieTask = task
        defer { rootCookieTask = nil }
        // Cancellation must not return while shared cookie work can still complete a write.
        try await withTaskCancellationHandler {
            try await task.value
            try checkActive()
        } onCancel: {
            task.cancel()
        }
    }

    private func respond(path: String, method: String, headers: [String: String]) async throws -> HLSRelayHTTPResponse {
        try checkActive()
        guard let resource = resources[path] else {
            return HLSRelayHTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let range = headers.first { $0.key.caseInsensitiveCompare("Range") == .orderedSame }?.value
        if let first = prefetched, first.path == path, range == nil {
            if method == "GET" { prefetched = nil }
            return first.response
        }
        let response = try await fetcher.fetch(resource.request, range: range)
        try checkActive()
        let rendered = try render(response, parent: path, range: range)
        // Reloads keep the final-hop method and credential scope, not the original redirect route.
        resources[path] = Resource(request: Self.withoutRange(response.finalRequest))
        return rendered
    }

    private func render(_ response: HLSResourceResponse, parent: String, range: String?) throws -> HLSRelayHTTPResponse {
        if Self.isPlaylist(response) {
            guard range == nil, response.statusCode == 200 else { throw HLSResourceHTTPError.invalidRange }
            let scope = try Self.credentialScope(response.finalRequest)
            let data = try HLSPlaylistRewriter.rewrite(Self.playlistBody(response.body), baseURL: response.url) { target in
                let child = try Self.childRequest(target, parent: response.finalRequest)
                return try register(
                    child, key: parent + "\n" + scope + "\n" + target.absoluteString, extension: target.pathExtension)
            }
            return HLSRelayHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-store"], body: data)
        }
        var headers = response.headers
        headers["Cache-Control"] = "no-store"
        return HLSRelayHTTPResponse(statusCode: response.statusCode, headers: headers, body: response.body)
    }

    private func register(_ request: PreparedMediaRequest, key: String, extension suffix: String) throws -> URL {
        guard let base = server?.baseURL else { throw CancellationError() }
        if let path = registered[key] { return base.appendingPathComponent(String(path.dropFirst())) }
        guard resources.count < 20_000 else { throw HLSResourceHTTPError.tooLarge }
        let safeSuffix =
            suffix.utf8.count <= 12 && suffix.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
            ? suffix : "bin"
        let path = "/" + UUID().uuidString.lowercased() + "." + (safeSuffix.isEmpty ? "bin" : safeSuffix)
        resources[path] = Resource(request: request)
        registered[key] = path
        return base.appendingPathComponent(String(path.dropFirst()))
    }

    private static func withContext(_ request: PreparedMediaRequest) throws -> PreparedMediaRequest {
        _ = try HLSResourceHTTPPolicy.networkURL(request.url)
        guard request.resourceContext == nil else { return request }
        let context = MediaResourceContext(
            sourceUrl: "", headerOriginUrl: request.url,
            explicitCookie: request.headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value,
            enabledCookieJar: false)
        return PreparedMediaRequest(
            url: request.url, method: request.method, headers: request.headers, bodyBase64: request.bodyBase64,
            timeoutMillis: request.timeoutMillis, allowsSystemAsset: false, resourceContext: context)
    }

    private static func receivedRoot(
        _ received: MediaAudioPlaylistResponse, original: PreparedMediaRequest
    ) throws -> HLSResourceResponse {
        let original = try withContext(original)
        let originalURL = try HLSResourceHTTPPolicy.networkURL(original.url)
        guard let context = original.resourceContext, let effectiveURL = received.effectiveRequest.url,
            received.response.url == effectiveURL
        else { throw HLSResourceHTTPError.invalidResponse }
        let finalURL = try HLSResourceHTTPPolicy.networkURL(effectiveURL)
        let headerOrigin = try HLSResourceHTTPPolicy.networkURL(context.headerOriginUrl)
        guard originalURL.scheme?.lowercased() != "https" || finalURL.scheme?.lowercased() == "https" else {
            throw HLSResourceHTTPError.unsupportedRedirect
        }
        guard received.response.statusCode == 200 else { throw HLSResourceHTTPError.invalidResponse }
        guard received.effectiveRequest.value(forHTTPHeaderField: "Range") == nil,
            received.effectiveRequest.value(forHTTPHeaderField: "If-Range") == nil
        else { throw HLSResourceHTTPError.invalidRange }
        let validated = try HLSResourceHTTPPolicy.Response(
            received.response, request: received.effectiveRequest, range: nil)
        guard received.body.count <= HLSResourceHTTPPolicy.maximumBytes else { throw HLSResourceHTTPError.tooLarge }
        guard !received.body.isEmpty else { throw HLSResourceHTTPError.empty }
        guard validated.expectedBytes.map({ $0 == received.body.count }) ?? true else {
            throw HLSResourceHTTPError.invalidResponse
        }
        // Check wire lengths before removing the optional UTF-8 BOM for this handoff only.
        let body = playlistBody(received.body)
        guard body.prefix(7) == Data("#EXTM3U".utf8) else { throw HLSResourceHTTPError.invalidResponse }

        let effective = received.effectiveRequest
        let method = effective.httpMethod?.uppercased() ?? "GET"
        guard effective.httpBodyStream == nil, effective.timeoutInterval.isFinite, effective.timeoutInterval > 0 else {
            throw HLSResourceHTTPError.invalidRequest
        }
        let sameOrigin = HLSResourceHTTPPolicy.sameOrigin(originalURL, finalURL)
        guard sameOrigin || (method == "GET" && effective.httpBody == nil) else {
            throw HLSResourceHTTPError.unsupportedRedirect
        }
        let finalCookie = effective.value(forHTTPHeaderField: "Cookie")
        let initialCookie = original.headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value
        // Origin equality alone cannot detect a return hop after a credential-stripping redirect.
        let retainsExplicitCookie =
            sameOrigin && HLSResourceHTTPPolicy.sameOrigin(headerOrigin, finalURL)
            && finalCookie != nil && finalCookie == initialCookie
        let finalRequest = PreparedMediaRequest(
            url: finalURL.absoluteString, method: method, headers: effective.allHTTPHeaderFields ?? [:],
            bodyBase64: effective.httpBody?.base64EncodedString(), timeoutMillis: original.timeoutMillis,
            allowsSystemAsset: false,
            resourceContext: MediaResourceContext(
                sourceUrl: context.sourceUrl, headerOriginUrl: context.headerOriginUrl,
                explicitCookie: retainsExplicitCookie ? context.explicitCookie : nil,
                enabledCookieJar: context.enabledCookieJar))
        _ = try HLSResourceHTTPPolicy.Input(finalRequest, range: nil)
        var headers = validated.headers
        headers["Content-Length"] = String(body.count)
        return HLSResourceResponse(
            url: finalURL, statusCode: 200, headers: headers, body: body, finalRequest: finalRequest)
    }

    /// The same URI after a credential-stripping redirect must not alias an earlier privileged route.
    private static func credentialScope(_ request: PreparedMediaRequest) throws -> String {
        let fields: [String: Any] = [
            "headers": request.headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame },
            "source": request.resourceContext?.sourceUrl ?? "",
            "origin": request.resourceContext?.headerOriginUrl ?? request.url,
            "explicitCookie": request.resourceContext?.explicitCookie ?? "",
        ]
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func childRequest(_ target: URL, parent: PreparedMediaRequest) throws -> PreparedMediaRequest {
        let target = try HLSResourceHTTPPolicy.networkURL(target)
        let parentURL = try HLSResourceHTTPPolicy.networkURL(parent.url)
        guard parentURL.scheme?.lowercased() != "https" || target.scheme?.lowercased() == "https" else {
            throw HLSResourceHTTPError.unsupportedRedirect
        }
        let context = parent.resourceContext.map {
            MediaResourceContext(
                sourceUrl: $0.sourceUrl, headerOriginUrl: $0.headerOriginUrl,
                explicitCookie: HLSResourceHTTPPolicy.sameOrigin(parentURL, target) ? $0.explicitCookie : nil,
                enabledCookieJar: $0.enabledCookieJar)
        }
        let entityHeaders: Set<String> = ["content-type", "content-length", "content-encoding", "range", "if-range"]
        return PreparedMediaRequest(
            url: target.absoluteString, method: "GET",
            headers: parent.headers.filter { !entityHeaders.contains($0.key.lowercased()) }, bodyBase64: nil,
            timeoutMillis: parent.timeoutMillis, allowsSystemAsset: false, resourceContext: context)
    }

    private static func withoutRange(_ request: PreparedMediaRequest) -> PreparedMediaRequest {
        PreparedMediaRequest(
            url: request.url, method: request.method,
            headers: request.headers.filter { $0.key.caseInsensitiveCompare("Range") != .orderedSame },
            bodyBase64: request.bodyBase64, timeoutMillis: request.timeoutMillis,
            allowsSystemAsset: false, resourceContext: request.resourceContext)
    }

    private static func playlistBody(_ body: Data) -> Data {
        body.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(body.dropFirst(3)) : body
    }

    private static func isPlaylist(_ response: HLSResourceResponse) -> Bool {
        let mime =
            response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased() ?? ""
        return mime.contains("mpegurl") || ["m3u", "m3u8"].contains(response.url.pathExtension.lowercased())
            || playlistBody(response.body).prefix(7) == Data("#EXTM3U".utf8)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }
}
