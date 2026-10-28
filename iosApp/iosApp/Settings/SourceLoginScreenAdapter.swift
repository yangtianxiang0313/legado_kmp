import Foundation
import shared

@MainActor
final class SourceLoginScreenAdapter {
    private var facade: SourceLoginFacade?
    private let rssSource: Bool

    init(facade: SourceLoginFacade? = nil, rssSource: Bool = false) {
        self.facade = facade
        self.rssSource = rssSource
    }

    func load(sourceURL: String) async throws -> SourceLoginConfiguration {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        let response = try await request { result in
            facade.loadRequest(sourceUrl: sourceURL, onResult: result)
        }
        guard let result = response.configuration else { throw Self.invalidConfiguration() }
        try Task.checkCancellation()
        return result
    }

    func submit(sourceURL: String, valuesJSON: String) async throws -> SourceLoginResult {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        let response = try await request { result in
            facade.submitRequest(sourceUrl: sourceURL, valuesJson: valuesJSON, onResult: result)
        }
        guard let result = response.loginResult else { throw Self.invalidConfiguration() }
        try Task.checkCancellation()
        return result
    }

    func runAction(sourceURL: String, rowIndex: Int, valuesJSON: String) async throws -> SourceLoginResult {
        let facade = try resolveFacade()
        guard let rowIndex = Int32(exactly: rowIndex) else { throw Self.invalidConfiguration() }
        try Task.checkCancellation()
        let response = try await request { result in
            facade.runActionRequest(sourceUrl: sourceURL, rowIndex: rowIndex, valuesJson: valuesJSON, onResult: result)
        }
        guard let result = response.loginResult else { throw Self.invalidConfiguration() }
        try Task.checkCancellation()
        return result
    }

    // WebView callers must retain the click-time sourceURL, not read a mutable selected-source property.
    func loadCookies(sourceURL: String, targetURL: String) async throws -> [StoredHttpCookie] {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        let response = try await request { result in
            facade.loadCookiesRequest(sourceUrl: sourceURL, targetUrl: targetURL, onResult: result)
        }
        guard let cookies = response.cookies else { throw Self.invalidConfiguration() }
        try Task.checkCancellation()
        return cookies
    }

    func saveCookies(sourceURL: String, cookies: [StoredHttpCookie]) async throws {
        let facade = try resolveFacade()
        let snapshot = cookies
        try Task.checkCancellation()
        _ = try await request { result in
            facade.saveCookiesRequest(sourceUrl: sourceURL, cookies: snapshot, onResult: result)
        }
        try Task.checkCancellation()
    }

    func loadWebCookieSeed(sourceURL: String, targetURL: String) async throws -> SourceLoginCookieSeed {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        let response = try await request { result in
            facade.loadWebCookieSeedRequest(sourceUrl: sourceURL, targetUrl: targetURL, onResult: result)
        }
        try Task.checkCancellation()
        guard let seed = response.cookieSeed else { throw Self.invalidConfiguration() }
        return seed
    }

    func saveWebCookies(sourceURL: String, snapshots: [CookieHostSnapshot]) async throws {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        _ = try await request { result in
            facade.saveWebCookiesRequest(sourceUrl: sourceURL, snapshots: snapshots, onResult: result)
        }
        try Task.checkCancellation()
    }

    func loadLoginHeader(sourceURL: String) async throws -> String? {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        let response = try await request { result in
            facade.loadLoginHeaderRequest(sourceUrl: sourceURL, onResult: result)
        }
        try Task.checkCancellation()
        return response.loginHeader
    }

    func clearLoginHeader(sourceURL: String) async throws {
        let facade = try resolveFacade()
        try Task.checkCancellation()
        _ = try await request { result in
            facade.clearLoginHeaderRequest(sourceUrl: sourceURL, onResult: result)
        }
        try Task.checkCancellation()
    }

    private func request(
        _ start: (@escaping (SourceLoginRequestResult) -> Void) -> FlowSubscription
    ) async throws -> SourceLoginRequestResult {
        try await SharedCancellableAsync.value { completion in
            start { response in
                if response.isCancelled {
                    completion(nil, CancellationError())
                } else if !response.completed || response.errorCode != nil || response.errorMessage != nil {
                    completion(
                        nil,
                        NSError(
                            domain: "io.legado.sourceLogin", code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "书源登录操作失败，请检查登录配置后重试"]))
                } else {
                    completion(response, nil)
                }
            }
        }
    }

    private func resolveFacade() throws -> SourceLoginFacade {
        let base = try facade ?? SharedRuntime.sourceLoginFacade().get()
        let resolved = rssSource ? base.forRssSources() : base
        self.facade = resolved
        return resolved
    }

    static func invalidConfiguration() -> NSError {
        NSError(
            domain: "io.legado.sourceLogin", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "书源登录配置无效，请检查后重试"])
    }
}
