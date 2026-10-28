import shared
import UIKit
import WebKit

@MainActor
enum RssArticleHTMLRenderer {
    static func render(_ content: String, source: RssSource?, traits: UITraitCollection) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let styleBlock = makeStyleBlock(source: source, traits: traits)
        let viewport = "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=3.0\">"

        if trimmed.range(of: "<html", options: .caseInsensitive) != nil {
            var html = trimmed
            if html.range(of: "name=\"viewport\"", options: .caseInsensitive) == nil {
                html = injectIntoHead(markup: html, injection: viewport)
            }
            return injectIntoHead(markup: html, injection: styleBlock)
        }

        if trimmed.range(of: "<style", options: .caseInsensitive) != nil,
            source?.style?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            return """
                <!doctype html>
                <html>
                <head>\(viewport)</head>
                <body>\(trimmed)</body>
                </html>
                """
        }

        return """
            <!doctype html>
            <html>
            <head>\(viewport)\(styleBlock)</head>
            <body>\(trimmed)</body>
            </html>
            """
    }

    static func fallback(article: RssArticle, title: String) -> String {
        let title = htmlEscape(title)
        let description = htmlEscape(article.description_ ?? "")
        let date = htmlEscape(article.pubDate ?? "")
        let link = htmlEscape(article.link)
        let linkMarkup = link.isEmpty ? "" : "<p><a href=\"\(link)\">\(link)</a></p>"
        return """
            <article>
            <h2>\(title)</h2>
            <p style="color:rgba(120,120,120,0.92);font-size:14px;">\(date)</p>
            <div>\(description.replacingOccurrences(of: "\n", with: "<br>"))</div>
            \(linkMarkup)
            </article>
            """
    }

    static func userScripts(source: RssSource?, remote: Bool) -> [WKUserScript] {
        var scripts: [WKUserScript] = []
        if remote, let style = source?.style?.trimmingCharacters(in: .whitespacesAndNewlines), !style.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: [style]), let payload = String(data: data, encoding: .utf8)
        {
            let script = """
                (function() {
                    var style = document.createElement('style');
                    style.textContent = \(payload)[0];
                    (document.head || document.documentElement).appendChild(style);
                })();
                """
            scripts.append(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        if let injectJs = source?.injectJs?.trimmingCharacters(in: .whitespacesAndNewlines), injectJs.isEmpty == false {
            scripts.append(WKUserScript(source: injectJs, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        return scripts
    }

    private static func injectIntoHead(markup: String, injection: String) -> String {
        if let headRange = markup.range(of: "</head>", options: .caseInsensitive) {
            var html = markup
            html.insert(contentsOf: injection, at: headRange.lowerBound)
            return html
        }
        if let htmlRange = markup.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var html = markup
            html.insert(contentsOf: "<head>\(injection)</head>", at: htmlRange.upperBound)
            return html
        }
        return "<head>\(injection)</head>\(markup)"
    }

    private static func makeStyleBlock(source: RssSource?, traits: UITraitCollection) -> String {
        let customStyle = source?.style?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageBackground = cssColor(AndroidReplicaTheme.background.resolvedColor(with: traits))
        let primaryText = cssColor(AndroidReplicaTheme.primaryText.resolvedColor(with: traits))
        let secondaryText = cssColor(AndroidReplicaTheme.secondaryText.resolvedColor(with: traits))
        let divider = cssColor(AndroidReplicaTheme.divider.resolvedColor(with: traits))
        let accent = cssColor(AndroidReplicaTheme.accent.resolvedColor(with: traits))

        return """
            <style>
            html,body{margin:0;padding:0;background:\(pageBackground);color:\(primaryText);font:-apple-system-body;line-height:1.72;word-wrap:break-word;}
            body{box-sizing:border-box;min-height:100%;padding:18px 17px 34px;}
            img{display:block;max-width:100% !important;width:auto;height:auto;margin:10px auto;border-radius:2px;}
            video,iframe{max-width:100% !important;width:100%;height:auto;}
            a{color:\(accent);text-decoration:none;}
            p{margin:0 0 0.86em;}
            blockquote{margin:12px 0;padding:8px 12px;border-left:3px solid \(divider);color:\(secondaryText);}
            table{max-width:100%;border-collapse:collapse;}
            pre,code{white-space:pre-wrap;word-break:break-word;}
            \(customStyle ?? "")
            </style>
            """
    }

    private static func cssColor(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "rgba(%d,%d,%d,%.3f)",
            Int(red * 255),
            Int(green * 255),
            Int(blue * 255),
            Double(alpha)
        )
    }

    private static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
