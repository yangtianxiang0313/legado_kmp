import shared
import UIKit
import WebKit

@MainActor
enum RssArticleContentResolver {
    enum Content {
        case html(String)
        case web(URLRequest)
    }

    struct Resolution {
        let source: RssSource?
        let content: Content
    }

    static func storedBody(_ article: RssArticle) -> String? {
        [article.content, article.description_].compactMap { $0 }.first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func usesWebPage(article: RssArticle, source: RssSource?) -> Bool {
        storedBody(article) == nil && source?.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    static func resolve(
        article: RssArticle, source initial: RssSource?, refresh: Bool,
        screen: RssScreenAdapter, browser: RssArticleWebSession, webView: WKWebView
    ) async throws -> Resolution {
        var source = initial
        let stored = storedBody(article)
        if initial != nil {
            do {
                source = try await screen.loadSource(sourceURL: article.origin)
            } catch {
                try Task.checkCancellation()
                guard stored != nil, !refresh else { throw error }
                source = nil
            }
        }
        try Task.checkCancellation()
        let hasRule = source?.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if let stored, !refresh || !hasRule {
            if source != nil {
                do {
                    let prepared = try await browser.prepare(navigation: false, webView: webView)
                    source = prepared.source
                } catch {
                    try Task.checkCancellation()
                    // A retained article remains readable if optional source/header preparation is unavailable.
                }
            }
            return Resolution(source: source, content: .html(stored))
        }
        if source != nil {
            let prepared = try await browser.prepare(navigation: !hasRule, webView: webView)
            try Task.checkCancellation()
            if hasRule {
                let content = try await screen.loadContent(article: article, source: prepared.source)
                try Task.checkCancellation()
                return Resolution(source: prepared.source, content: .html(content))
            }
            return Resolution(source: prepared.source, content: .web(try browser.request(prepared)))
        }
        // Deleted sources can still leave a public article link; never replay its former private headers.
        guard let url = URL(string: article.link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host?.isEmpty == false, url.user == nil, url.password == nil
        else { throw NSError(domain: "io.legado.rss", code: 1, userInfo: [NSLocalizedDescriptionKey: "订阅文章地址无效"]) }
        return Resolution(source: nil, content: .web(URLRequest(url: url)))
    }

    static func favoriteArticle(_ article: RssArticle, content: String?) -> RssArticle {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return article }
        return article.doCopy(
            origin: article.origin, sort: article.sort, title: article.title, order: article.order, link: article.link,
            pubDate: article.pubDate, description: article.description_, content: content, image: article.image,
            group: article.group, read: article.read, variable: article.variable)
    }
}
