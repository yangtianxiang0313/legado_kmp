import UIKit
import WebKit
import shared

/// Keeps each visited cookie owner separate; never aliases an identity provider to the book source.
@MainActor
final class SourceLoginWebSession {
    private let sourceURL: String
    private var owners: [String: String] = [:]
    private var seededHosts = Set<String>()
    private var preparations: [String: (UUID, Task<Void, Error>)] = [:]
    private var sourceHeaders: [String: String] = [:]

    init(sourceURL: String) { self.sourceURL = sourceURL }

    func configureHeaders(_ json: String) throws {
        guard let headers = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String] else {
            throw SourceLoginScreenAdapter.invalidConfiguration()
        }
        sourceHeaders = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
    }

    func recordSeeded(_ url: String) throws {
        let owner = try Self.owner(url)
        guard owners[owner.host] != nil || owners.count < 32 else { throw SourceLoginScreenAdapter.invalidConfiguration() }
        if owners[owner.host] == nil || owner.url.hasPrefix("https:") { owners[owner.host] = owner.url }
        seededHosts.insert(owner.host)
    }

    func prepare(_ url: URL, screen: SourceLoginScreenAdapter, webView: WKWebView) async throws {
        let owner = try Self.owner(url.absoluteString)
        if seededHosts.contains(owner.host) { return }
        guard owners.count < 32 else { throw SourceLoginScreenAdapter.invalidConfiguration() }
        if let existing = preparations[owner.host] {
            try await existing.1.value
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        let sourceURL = sourceURL
        let work = Task { @MainActor in
            let seed = try await screen.loadWebCookieSeed(sourceURL: sourceURL, targetURL: owner.url)
            try Task.checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let headers = seed.cookieHeader.map { ["Cookie": $0] } ?? [:]
                IosSourceCookieBridge.shared.prepareWebView(
                    webView: webView, ownerUrl: owner.url, headers: headers, cookies: seed.cookies
                ) { continuation.resume() }
            }
            try Task.checkCancellation()
        }
        preparations[owner.host] = (id, work)
        defer { if preparations[owner.host]?.0 == id { preparations.removeValue(forKey: owner.host) } }
        try await work.value
        try Task.checkCancellation()
        try recordSeeded(owner.url)
    }

    func snapshots(_ cookies: [HTTPCookie]) -> [CookieHostSnapshot] {
        owners.values.sorted().map { owner in
            CookieHostSnapshot(
                ownerUrl: owner, cookies: IosSourceCookieBridge.shared.storedCookies(cookies: cookies, ownerUrl: owner))
        }
    }

    func cancelPreparation() {
        for preparation in preparations.values { preparation.1.cancel() }
        preparations.removeAll()
    }

    func sanitized(_ request: URLRequest) -> URLRequest {
        guard let target = request.url, !Self.sameOrigin(URL(string: sourceURL), target) else { return request }
        var sanitized = request
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            if !Self.publicHeaders.contains(key), sourceHeaders[key] == value {
                sanitized.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return sanitized
    }

    private static func owner(_ raw: String) throws -> (host: String, url: String) {
        guard let url = URLComponents(string: raw), let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme), let host = url.host?.lowercased(), !host.isEmpty,
            !host.hasSuffix("."), url.user == nil, url.password == nil
        else {
            throw SourceLoginScreenAdapter.invalidConfiguration()
        }
        var owner = URLComponents()
        owner.scheme = scheme
        owner.host = host
        owner.port = url.port
        owner.path = "/"
        guard let value = owner.url?.absoluteString else { throw SourceLoginScreenAdapter.invalidConfiguration() }
        return (host, value)
    }

    private static func sameOrigin(_ source: URL?, _ target: URL) -> Bool {
        source?.scheme?.lowercased() == target.scheme?.lowercased()
            && source?.host?.lowercased() == target.host?.lowercased()
            && (source?.port ?? (source?.scheme == "https" ? 443 : 80)) == (target.port ?? (target.scheme == "https" ? 443 : 80))
    }

    private static let publicHeaders: Set<String> = [
        "user-agent", "accept", "accept-language", "accept-encoding", "referer", "origin",
    ]
}
