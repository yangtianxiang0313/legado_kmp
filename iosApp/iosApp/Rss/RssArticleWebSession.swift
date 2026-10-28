import Foundation
import shared
import WebKit

@MainActor
final class RssArticleWebSession {
    private let article: RssArticle
    private let login = SourceLoginScreenAdapter(rssSource: true)
    private var cookies: SourceLoginWebSession
    private var cookieSeeding: Task<Void, Never>?
    private var headerOrigin: URL?
    private var privateHeaders: [String: String] = [:]
    private var originalBody: Data?
    private var usesCookies = false

    init(article: RssArticle) {
        self.article = article
        cookies = SourceLoginWebSession(sourceURL: article.origin)
    }

    func prepare(navigation: Bool, webView: WKWebView) async throws -> RssArticleWebRequest {
        let facade = try RssArticleWebFacade.companion.create()
        let prepared: RssArticleWebRequest = try await SharedCancellableAsync.value { completion in
            facade.prepareRequest(article: self.article, navigation: navigation) { result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if let request = result.request {
                    completion(request, nil)
                } else {
                    completion(nil, Self.failure(result.errorMessage ?? "订阅文章请求准备失败"))
                }
            }
        }
        try Task.checkCancellation()
        guard let url = URL(string: prepared.url) else { throw Self.failure("订阅文章地址无效") }
        cookies.cancelPreparation()
        cookies = SourceLoginWebSession(sourceURL: article.origin)
        headerOrigin = url
        privateHeaders = Dictionary(prepared.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, new in new })
        originalBody = try body(prepared)
        usesCookies = prepared.source.enabledCookieJar
        let previous = cookieSeeding
        let seeding = Task { @MainActor in
            await previous?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                IosSourceCookieBridge.shared.prepareWebView(
                    webView: webView, ownerUrl: prepared.url, headers: prepared.headers, cookies: prepared.cookies
                ) { continuation.resume() }
            }
        }
        cookieSeeding = seeding
        await seeding.value
        try Task.checkCancellation()
        try cookies.recordSeeded(prepared.url)
        webView.customUserAgent = prepared.headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
        return prepared
    }

    func request(_ prepared: RssArticleWebRequest) throws -> URLRequest {
        guard let url = URL(string: prepared.url) else { throw Self.failure("订阅文章地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = prepared.method
        for (key, value) in prepared.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try body(prepared)
        return request
    }

    func prepareNavigation(_ request: URLRequest, webView: WKWebView) async throws -> URLRequest {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { throw Self.failure("不支持的文章链接") }
        if usesCookies { try await cookies.prepare(url, screen: login, webView: webView) }
        try Task.checkCancellation()
        guard !Self.sameOrigin(headerOrigin, url) else { return request }
        if request.httpMethod?.uppercased() == "POST", let originalBody, request.httpBody == originalBody {
            throw Self.failure("不能向其他站点重发原订阅请求正文")
        }
        var result = URLRequest(url: url, cachePolicy: request.cachePolicy, timeoutInterval: request.timeoutInterval)
        result.httpMethod = request.httpMethod
        result.httpBody = request.httpBody
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            guard key != "cookie", key != "authorization", key != "proxy-authorization",
                Self.publicHeaders.contains(key) || privateHeaders[key] != value
            else { continue }
            result.setValue(value, forHTTPHeaderField: name)
        }
        return result
    }

    func prepareResource(_ url: URL) async throws -> URLRequest {
        let facade = try RssArticleWebFacade.companion.create()
        let prepared: RssArticleResourceRequest = try await SharedCancellableAsync.value { completion in
            facade.prepareResourceRequest(
                article: self.article, targetUrl: url.absoluteString, requestOriginUrl: self.headerOrigin?.absoluteString
            ) {
                result in
                if result.isCancelled {
                    completion(nil, CancellationError())
                } else if let request = result.request {
                    completion(request, nil)
                } else {
                    completion(nil, Self.failure(result.errorMessage ?? "订阅图片请求准备失败"))
                }
            }
        }
        try Task.checkCancellation()
        guard let target = URL(string: prepared.url) else { throw Self.failure("订阅图片地址无效") }
        var request = URLRequest(url: target)
        request.httpMethod = "GET"
        for (name, value) in prepared.headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    func cancel() { cookies.cancelPreparation() }

    private func body(_ prepared: RssArticleWebRequest) throws -> Data? {
        guard let encoded = prepared.bodyBase64 else { return nil }
        guard let data = Data(base64Encoded: encoded), data.count <= 1024 * 1024 else {
            throw Self.failure("订阅文章请求正文无效")
        }
        return data
    }

    private static func sameOrigin(_ source: URL?, _ target: URL) -> Bool {
        source?.scheme?.lowercased() == target.scheme?.lowercased()
            && source?.host?.lowercased() == target.host?.lowercased()
            && (source?.port ?? (source?.scheme == "https" ? 443 : 80)) == (target.port ?? (target.scheme == "https" ? 443 : 80))
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.rss.article", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static let publicHeaders: Set<String> = [
        "user-agent", "accept", "accept-language", "accept-encoding", "referer", "origin",
    ]
}
