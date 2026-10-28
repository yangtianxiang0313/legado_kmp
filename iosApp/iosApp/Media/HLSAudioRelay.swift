import CryptoKit
import Foundation
import shared

/// One player item owns one listener and its resource tree. Upstream URLs never reach AVFoundation.
actor HLSAudioRelay {
    private struct Resource {
        let request: PreparedMediaRequest
    }

    private let fetcher = HLSResourceFetcher()
    private var server: HLSRelayServer?
    private var resources: [String: Resource] = [:]
    private var registered: [String: String] = [:]
    private var prefetched: (String, HLSRelayHTTPResponse)?
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

    func cancel() async {
        cancelled = true
        server?.cancel()
        server = nil
        resources.removeAll()
        registered.removeAll()
        prefetched = nil
        await fetcher.cancel()
    }

    private func start(_ input: PreparedMediaRequest) async throws -> URL {
        try checkActive()
        let listener = try await HLSRelayServer.start { [weak self] path, method, headers in
            guard let self else { throw CancellationError() }
            return try await self.respond(path: path, method: method, headers: headers)
        }
        guard !cancelled else { listener.cancel(); throw CancellationError() }
        server = listener
        let request = try Self.withContext(input)
        let root = try register(request, key: "root", extension: "m3u8")
        let response = try await fetcher.fetch(request)
        try checkActive()
        guard Self.isPlaylist(response) else { throw HLSResourceHTTPError.invalidResponse }
        prefetched = (root.path, try render(response, parent: root.path, range: nil))
        return root
    }

    private func respond(path: String, method: String, headers: [String: String]) async throws -> HLSRelayHTTPResponse {
        try checkActive()
        guard let resource = resources[path] else {
            return HLSRelayHTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let range = headers.first { $0.key.caseInsensitiveCompare("Range") == .orderedSame }?.value
        if let first = prefetched, first.0 == path, range == nil {
            if method == "GET" { prefetched = nil }
            return first.1
        }
        let response = try await fetcher.fetch(resource.request, range: range)
        try checkActive()
        return try render(response, parent: path, range: range)
    }

    private func render(_ response: HLSResourceResponse, parent: String, range: String?) throws -> HLSRelayHTTPResponse {
        if Self.isPlaylist(response) {
            guard range == nil, response.statusCode == 200 else { throw HLSResourceHTTPError.invalidRange }
            let scope = try Self.credentialScope(response.finalRequest)
            let data = try HLSPlaylistRewriter.rewrite(response.body, baseURL: response.url) { target in
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

    private static func isPlaylist(_ response: HLSResourceResponse) -> Bool {
        let mime =
            response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased() ?? ""
        return mime.contains("mpegurl") || ["m3u", "m3u8"].contains(response.url.pathExtension.lowercased())
            || response.body.prefix(7) == Data("#EXTM3U".utf8)
    }

    private func checkActive() throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
    }
}
