import UIKit
import shared

/// Native attributed text only: no WebView, page scripts, attachments or resource fetches.
@MainActor
enum ReaderDictionaryDialogHTMLRenderer {
    private static let textTags: Set<String> = [
        "a", "b", "big", "blockquote", "br", "cite", "code", "dd", "del", "dfn",
        "div", "dl", "dt", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6",
        "hr", "i", "li", "ol", "p", "pre", "s", "small", "span", "strike",
        "strong", "sub", "sup", "tt", "u", "ul",
    ]
    private static let discardedTags: Set<String> = [
        "head", "script", "style", "link", "base", "meta", "img", "picture", "source",
        "iframe", "frame", "frameset", "object", "embed", "applet", "svg", "math",
        "audio", "video", "track", "template", "noscript", "input", "button", "select", "textarea",
    ]

    static func render(_ html: String) throws -> NSAttributedString {
        try Task.checkCancellation()
        // Reuse the exported Ksoup parser; never sanitize arbitrary HTML with regexes.
        let body = HtmlParser().parseDocument(html: html, baseUri: "").body()
        let elements = body.getAllElements().compactMap { $0 as? KsoupElement }
        for element in elements.reversed() {
            try Task.checkCancellation()
            let tag = element.normalName()
            if tag == "body" { continue }
            if discardedTags.contains(tag) {
                element.remove()
                continue
            }
            guard textTags.contains(tag) else {
                _ = element.unwrap()
                continue
            }
            let href = tag == "a" ? element.attr(attributeKey: "href") : ""
            let color = tag == "font" ? element.attr(attributeKey: "color") : ""
            _ = element.clearAttributes()
            if let url = linkURL(href) {
                _ = element.attr(attributeKey: "href", attributeValue: url.absoluteString)
            }
            if !color.isEmpty {
                _ = element.attr(attributeKey: "color", attributeValue: color)
            }
        }
        let document = """
            <html><head><meta charset="utf-8"></head>
            <body style="font-family:Helvetica;font-size:14pt;color:rgb(1,2,3);margin:0;padding:0">
            \(body.html())
            </body></html>
            """
        let imported = try NSAttributedString(
            data: Data(document.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil)
        try Task.checkCancellation()
        let text = imported.string as NSString
        let first = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)
        guard first.location != NSNotFound else { return NSAttributedString(string: "") }
        let last = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards)
        return imported.attributedSubstring(
            from: NSRange(location: first.location, length: NSMaxRange(last) - first.location))
    }

    static func styled(_ imported: NSAttributedString, traits: UITraitCollection) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: imported)
        let fullRange = NSRange(location: 0, length: result.length)
        imported.enumerateAttributes(in: fullRange) { attributes, range, _ in
            let original = attributes[.font] as? UIFont ?? .systemFont(ofSize: 14)
            let symbolicTraits = original.fontDescriptor.symbolicTraits
            let font: UIFont
            if symbolicTraits.intersection([.traitItalic, .traitMonoSpace]).isEmpty {
                font = ReaderAndroidDefaultFont.scaledFont(
                    size: original.pointSize, textStyle: .body,
                    weight: symbolicTraits.contains(.traitBold) ? 700 : 400, compatibleWith: traits)
            } else {
                // Keep semantic italic/monospace faces when the bundled upright asset cannot supply them.
                let base: UIFont =
                    symbolicTraits.contains(.traitMonoSpace)
                    ? .monospacedSystemFont(ofSize: original.pointSize, weight: .regular)
                    : .systemFont(ofSize: original.pointSize)
                let descriptor = base.fontDescriptor.withSymbolicTraits(
                    symbolicTraits.intersection([.traitBold, .traitItalic, .traitMonoSpace]))
                let semantic = descriptor.map { UIFont(descriptor: $0, size: original.pointSize) } ?? base
                font = UIFontMetrics(forTextStyle: .body).scaledFont(for: semantic, compatibleWith: traits)
            }
            result.addAttribute(.font, value: font, range: range)
            if let color = attributes[.foregroundColor] as? UIColor,
                !isDefaultTextColor(color)
            {
                result.addAttribute(.foregroundColor, value: color, range: range)
            } else {
                result.addAttribute(.foregroundColor, value: AndroidReplicaTheme.secondaryText, range: range)
            }
            if let original = attributes[.paragraphStyle] as? NSParagraphStyle,
                let paragraph = original.mutableCopy() as? NSMutableParagraphStyle
            {
                paragraph.lineBreakMode = .byWordWrapping
                paragraph.minimumLineHeight = 0
                paragraph.maximumLineHeight = 0
                paragraph.headIndent = min(16, max(0, paragraph.headIndent))
                paragraph.firstLineHeadIndent = min(16, max(0, paragraph.firstLineHeadIndent))
                paragraph.tailIndent = 0
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
            result.removeAttribute(.backgroundColor, range: range)
            result.removeAttribute(.attachment, range: range)
            result.addAttribute(.kern, value: CGFloat(0), range: range)
        }
        return result
    }

    private static func isDefaultTextColor(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return abs(red - 1 / 255) < 0.0001 && abs(green - 2 / 255) < 0.0001
            && abs(blue - 3 / 255) < 0.0001 && abs(alpha - 1) < 0.0001
    }

    private static func linkURL(_ text: String) -> URL? {
        guard !text.isEmpty, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme)
        else { return nil }
        return url
    }
}
