import Foundation
import shared
import WebKit

@MainActor
final class RssArticleWebSession {
    private let article: RssArticle
    private var nativeSession: IosRssWebNavigationSession?
    private var requests: [UUID: FlowSubscription] = [:]
    private var generation = UUID()
    private var isCancelled = false
    private var headerOrigin: URL?
    private var originalBody: Data?
    private var lastPrepared: RssArticleWebRequest?
    private var isAnonymous = false
    private(set) var isPrepared = false

    nonisolated static let safetyErrorDomain = "io.legado.rss.article.security"

    init(article: RssArticle) {
        self.article = article
    }

    func prepare(navigation: Bool, webView: WKWebView) async throws -> RssArticleWebRequest {
        let current = beginPreparation()
        do {
            let facade = try RssArticleWebFacade.companion.create()
            let prepared: RssArticleWebRequest = try await value(generation: current) { completion in
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
            try await startSession(prepared, webView: webView, generation: current, resuming: false)
            return prepared
        } catch {
            if generation == current { cancel() }
            throw error
        }
    }

    func prepareAnonymous(webView: WKWebView) async throws {
        let current = beginPreparation()
        do {
            try checkActive(current)
            let prepared = try IosRssWebNavigationSession.companion.anonymousRequest(url: article.link)
            isAnonymous = true
            try await startSession(prepared, webView: webView, generation: current, resuming: false)
        } catch {
            if generation == current { cancel() }
            throw error
        }
    }

    /// Restores only the native cookie/policy session. The existing document is never loaded again.
    func resume(webView: WKWebView) async throws {
        try Task.checkCancellation()
        if isPrepared {
            try checkActive(generation)
            return
        }
        guard let prepared = lastPrepared else { throw Self.failure("订阅网页会话尚未准备") }
        cancel()
        isCancelled = false
        let current = generation
        do {
            try await startSession(prepared, webView: webView, generation: current, resuming: true)
        } catch {
            if generation == current { cancel() }
            throw error
        }
    }

    func request(_ prepared: RssArticleWebRequest) throws -> URLRequest {
        guard let url = URL(string: prepared.url) else { throw Self.failure("订阅文章地址无效") }
        var request = URLRequest(url: url)
        request.httpMethod = prepared.method
        for (key, value) in prepared.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try body(prepared)
        return request
    }

    /// nil keeps the original frame, method and body. Only a main-frame action can return a replay.
    func prepareNavigation(_ action: WKNavigationAction, webView: WKWebView) async throws -> URLRequest? {
        let current = generation
        let session = try activeSession(current)
        guard action.targetFrame != nil else {
            throw Self.safetyFailure("新窗口导航须先经订阅跳转规则批准")
        }
        try validateNavigationBody(action.request)
        let result = try await nativeValue(generation: current) { completion in
            session.decide(action: action, webView: webView, onResult: completion)
        }
        if result.request != nil {
            guard action.targetFrame?.isMainFrame == true, result.request?.httpBodyStream == nil else {
                throw Self.safetyFailure("不能重载子框架或流式请求正文")
            }
        }
        return result.request
    }

    /// Only for a popup approved by the outer hook and intentionally loaded into the main frame.
    func prepareNavigation(_ request: URLRequest, webView: WKWebView) async throws -> URLRequest {
        let current = generation
        let session = try activeSession(current)
        try validateNavigationBody(request)
        guard request.httpBodyStream == nil else { throw Self.safetyFailure("不能重发流式请求正文") }
        let result = try await nativeValue(generation: current) { completion in
            session.prepareTopLevelRequest(request: request, webView: webView, onResult: completion)
        }
        guard let prepared = result.request else { throw Self.safetyFailure("订阅网页主导航未获批准") }
        return prepared
    }

    func persist(webView: WKWebView) async throws {
        let current = generation
        let session = try activeSession(current)
        let _ = try await nativeValue(generation: current) { completion in
            session.persist(webView: webView, onResult: completion)
        }
    }

    func prepareResource(_ url: URL) async throws -> URLRequest {
        let current = generation
        try checkActive(current)
        if isAnonymous {
            let request = URLRequest(url: url)
            try validateNavigationBody(request)
            return request
        }
        let facade = try RssArticleWebFacade.companion.create()
        let prepared: RssArticleResourceRequest = try await value(generation: current) { completion in
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

    func cancel() {
        isCancelled = true
        isPrepared = false
        generation = UUID()
        nativeSession?.cancel()
        nativeSession = nil
        let pending = Array(requests.values)
        requests.removeAll()
        for request in pending { request.cancel() }
    }

    func dispose() {
        cancel()
        lastPrepared = nil
        isAnonymous = false
        headerOrigin = nil
        originalBody = nil
    }

    nonisolated static func isSafetyError(_ error: Error) -> Bool {
        (error as NSError).domain == safetyErrorDomain
    }

    private func beginPreparation() -> UUID {
        dispose()
        isCancelled = false
        return generation
    }

    private func startSession(
        _ prepared: RssArticleWebRequest, webView: WKWebView, generation current: UUID, resuming: Bool
    ) async throws {
        try checkActive(current)
        guard let url = URL(string: prepared.url) else { throw Self.failure("订阅文章地址无效") }
        let requestBody = try body(prepared)
        lastPrepared = prepared
        headerOrigin = url
        originalBody = requestBody
        let session = try IosRssWebNavigationSession.companion.create(prepared: prepared)
        nativeSession = session
        let _ = try await nativeValue(generation: current) { completion in
            if resuming { return session.resume(webView: webView, onResult: completion) }
            return session.prepare(webView: webView, onResult: completion)
        }
        try checkActive(current)
        isPrepared = true
        webView.customUserAgent = prepared.headers.first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?.value
    }

    private func activeSession(_ current: UUID) throws -> IosRssWebNavigationSession {
        try checkActive(current)
        guard isPrepared, let nativeSession else { throw Self.failure("订阅网页会话尚未准备") }
        return nativeSession
    }

    private func checkActive(_ current: UUID) throws {
        try Task.checkCancellation()
        guard !isCancelled, current == generation else { throw CancellationError() }
    }

    private func value<T>(
        generation current: UUID,
        start: @escaping (@escaping @Sendable (T?, Error?) -> Void) -> FlowSubscription
    ) async throws -> T {
        try checkActive(current)
        let id = UUID()
        defer { requests.removeValue(forKey: id) }
        let result: T = try await SharedCancellableAsync.value { completion in
            // The generic async bridge does not preserve this actor for its synchronous starter.
            // WebKit setup and the token registry must both stay on the main thread.
            let install = {
                let subscription = start(completion)
                self.requests[id] = subscription
                return subscription
            }
            return Thread.isMainThread ? install() : DispatchQueue.main.sync(execute: install)
        }
        try checkActive(current)
        return result
    }

    private func nativeValue(
        generation current: UUID,
        start: @escaping (@escaping (IosRssWebNavigationResult) -> Void) -> FlowSubscription
    ) async throws -> IosRssWebNavigationResult {
        let result: IosRssWebNavigationResult = try await value(generation: current) { completion in
            start { completion($0, nil) }
        }
        if result.isCancelled { throw CancellationError() }
        if result.isRejected { throw Self.safetyFailure(result.errorMessage ?? "已阻止不安全的订阅网页导航") }
        if let message = result.errorMessage { throw Self.failure(message) }
        return result
    }

    private func validateNavigationBody(_ request: URLRequest) throws {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { throw Self.safetyFailure("不支持的文章链接") }
        if !Self.sameOrigin(headerOrigin, url), request.httpMethod?.uppercased() == "POST",
            let originalBody, request.httpBody == originalBody
        {
            throw Self.safetyFailure("不能向其他站点重发原订阅请求正文")
        }
    }

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

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.rss.article", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private nonisolated static func safetyFailure(_ message: String) -> NSError {
        NSError(domain: safetyErrorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
