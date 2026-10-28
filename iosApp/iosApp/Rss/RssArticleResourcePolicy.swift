import Foundation
import WebKit

/// Prepare first, check the caller's article/load generation, then install before loading.
/// The original document (including redirects) must also pass allowsMainDocument(_:).
@MainActor
final class RssArticleResourcePolicy {
    enum Mode: Sendable, Equatable {
        case unrestricted
        case blacklist
        case whitelist
    }

    enum JavaRegexValidity {
        case valid
        case invalid
        case unknown
    }

    /// Optional authority for expressions outside PortableRegex's proven shared subset.
    /// Never report .invalid based only on an ICU/JS rejection; use .unknown instead.
    /// Invalid patterns still participate in the literal startsWith branch.
    typealias JavaRegexValidator = (String) throws -> JavaRegexValidity

    struct Diagnostic: Sendable {
        enum Kind: Sendable, Equatable {
            case invalidJavaRegex
            case unsupportedLiteralPrefix
            case unsupportedJavaRegex
            case unknownJavaRegex
            case webKitCompilation
        }

        let kind: Kind
        let mode: Mode
        /// Zero-based index after Android's splitNotBlank trimming/filtering.
        let index: Int?
        /// Internal fixed diagnostic text, without source patterns or underlying error text.
        let message: String
    }

    struct PreparationError: LocalizedError {
        let diagnostics: [Diagnostic]
        /// Internal inspection only. Do not display or log this error or the source patterns.
        let underlyingError: Error?

        var errorDescription: String? {
            diagnostics.contains { $0.kind == .webKitCompilation }
                ? "订阅资源过滤规则加载失败" : "订阅资源过滤规则不受支持"
        }

        var recoverySuggestion: String? {
            "请修改订阅源的过滤规则后重试。"
        }
    }

    let mode: Mode
    /// Nonfatal invalid-Java diagnostics, equivalent to Android logging PatternSyntaxException.
    let diagnostics: [Diagnostic]
    private let matchers: [Matcher]
    private let ruleList: WKContentRuleList?

    // A reserved identifier, shared by every compile, bounds persistent disk entries to one.
    private static let identifier = "io.legado.rss.article-resource-policy.v1"
    private static let compiler = Compiler()
    // Weak controllers, strong policies: an installed policy cannot lose its removal bookkeeping.
    private static let owners = NSMapTable<WKUserContentController, RssArticleResourcePolicy>.weakToStrongObjects()

    private init(mode: Mode, diagnostics: [Diagnostic], matchers: [Matcher], ruleList: WKContentRuleList?) {
        self.mode = mode
        self.diagnostics = diagnostics
        self.matchers = matchers
        self.ruleList = ruleList
    }

    /// Throws rather than silently dropping a valid Java expression that WebKit cannot represent.
    /// Portable expressions need no external engine. Other expressions require an authoritative
    /// invalid verdict to keep just their prefix; an unknown verdict is an explicit limitation.
    /// WebKit's native compilation cannot be stopped, but cancelling this await returns promptly.
    /// Preparation never changes an installed policy, even if it completes after cancellation.
    static func prepare(
        contentBlacklist: String?, contentWhitelist: String?,
        validateJavaRegex: JavaRegexValidator? = nil
    ) async throws -> RssArticleResourcePolicy {
        try Task.checkCancellation()
        guard (contentBlacklist?.utf8.count ?? 0) <= 256 * 1024 else {
            throw PreparationError(diagnostics: [], underlyingError: nil)
        }
        let blacklist = entries(contentBlacklist)
        let mode: Mode
        let patterns: [String]
        if !blacklist.isEmpty {
            mode = .blacklist
            patterns = blacklist
        } else {
            guard (contentWhitelist?.utf8.count ?? 0) <= 256 * 1024 else {
                throw PreparationError(diagnostics: [], underlyingError: nil)
            }
            patterns = entries(contentWhitelist)
            mode = patterns.isEmpty ? .unrestricted : .whitelist
        }

        guard patterns.count <= 512, patterns.allSatisfy({ $0.utf8.count <= 8192 }) else {
            throw PreparationError(diagnostics: [], underlyingError: nil)
        }

        var diagnostics: [Diagnostic] = []
        var matchers: [Matcher] = []
        var filters: [String] = []
        var seenFilters: Set<String> = []
        for (index, pattern) in patterns.enumerated() {
            try Task.checkCancellation()
            // Never URL-encode or lowercase a pattern: either changes Android startsWith semantics.
            guard pattern.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
                diagnostics.append(
                    Diagnostic(
                        kind: .unsupportedLiteralPrefix, mode: mode, index: index,
                        message: "Literal prefixes must be printable ASCII for canonical WebKit resource URLs."
                    ))
                continue
            }

            let prefix = "^" + escapeLiteral(pattern)
            if seenFilters.insert(prefix).inserted { filters.append(prefix) }
            if let portable = PortableRegex.translate(pattern) {
                matchers.append(Matcher(prefix: pattern, expression: portable.expression))
                let fullMatch = "^\(portable.body)$"
                if seenFilters.insert(fullMatch).inserted { filters.append(fullMatch) }
                continue
            }

            let validity: JavaRegexValidity
            do {
                validity = try validateJavaRegex?(pattern) ?? .unknown
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let failure = Diagnostic(
                    kind: .unknownJavaRegex, mode: mode, index: index,
                    message: "The optional authoritative Java validator is unavailable."
                )
                throw PreparationError(diagnostics: diagnostics + [failure], underlyingError: error)
            }
            switch validity {
            case .invalid:
                diagnostics.append(
                    Diagnostic(
                        kind: .invalidJavaRegex, mode: mode, index: index,
                        message: "Authoritatively invalid Java regex; the literal prefix branch is retained."
                    ))
                matchers.append(Matcher(prefix: pattern, expression: nil))
            case .valid:
                diagnostics.append(
                    Diagnostic(
                        kind: .unsupportedJavaRegex, mode: mode, index: index,
                        message: "Valid Java regex outside the proven WebKit-compatible subset."
                    ))
            case .unknown:
                diagnostics.append(
                    Diagnostic(
                        kind: .unknownJavaRegex, mode: mode, index: index,
                        message:
                            "Java validity is unknown outside the portable subset; native rejection is not proof of invalid Java syntax."
                    ))
            }
        }
        try Task.checkCancellation()
        guard diagnostics.allSatisfy({ $0.kind == .invalidJavaRegex }) else {
            throw PreparationError(diagnostics: diagnostics, underlyingError: nil)
        }

        var rules: [[String: Any]] = []
        if mode == .whitelist { rules.append(rule(filter: ".*", action: "block")) }
        let action = mode == .whitelist ? "ignore-previous-rules" : "block"
        rules.append(contentsOf: filters.map { rule(filter: $0, action: action) })
        var compiled: WKContentRuleList?
        if !rules.isEmpty {
            do {
                let data = try JSONSerialization.data(withJSONObject: rules)
                // JSONSerialization emits UTF-8; never interpolate source strings into JSON.
                let json = String(decoding: data, as: UTF8.self)
                compiled = try await compiler.compile(json)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                let failure = Diagnostic(
                    kind: .webKitCompilation, mode: mode, index: nil,
                    message: "WebKit rejected the resource rules; no policy was installed."
                )
                throw PreparationError(diagnostics: diagnostics + [failure], underlyingError: error)
            }
        }
        try Task.checkCancellation()
        return RssArticleResourcePolicy(mode: mode, diagnostics: diagnostics, matchers: matchers, ruleList: compiled)
    }

    /// Apply to the actual request URL, without exempting the original article or redirect target.
    /// Keep the original request string; this helper does not rewrite case, escaping, or origin.
    func allowsMainDocument(_ url: String) -> Bool {
        switch mode {
        case .unrestricted: return true
        case .blacklist: return !matchers.contains { $0.matches(url) }
        case .whitelist: return matchers.contains { $0.matches(url) }
        }
    }

    /// Synchronous by design: the caller checks cancellation/generation immediately before this.
    /// Only this component's reserved rule list is replaced; scripts and other rule lists survive.
    func install(on controller: WKUserContentController) {
        if let previous = Self.owners.object(forKey: controller) { previous.remove(from: controller) }
        guard let ruleList else { return }
        controller.add(ruleList)
        Self.owners.setObject(self, forKey: controller)
    }

    /// An old policy cannot remove a newer policy installed on the same controller.
    func remove(from controller: WKUserContentController) {
        guard Self.owners.object(forKey: controller) === self else { return }
        if let ruleList { controller.remove(ruleList) }
        Self.owners.removeObject(forKey: controller)
    }

    private static func entries(_ value: String?) -> [String] {
        (value ?? "").components(separatedBy: ",").compactMap { entry in
            let scalars = entry.unicodeScalars
            guard let first = scalars.firstIndex(where: { !isAndroidWhitespace($0) }),
                let last = scalars.lastIndex(where: { !isAndroidWhitespace($0) })
            else { return nil }
            return String(scalars[first...last])
        }
    }

    private static func isAndroidWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        // Kotlin uses Character.isWhitespace || isSpaceChar; Foundation also trims U+0085.
        if (0x09...0x0D).contains(scalar.value) || (0x1C...0x1F).contains(scalar.value) { return true }
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    private static func escapeLiteral(_ value: String) -> String {
        let metacharacters = Set("\\.^$|?*+()[]{}")
        return value.map { metacharacters.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    private static func rule(filter: String, action: String) -> [String: Any] {
        [
            "trigger": ["url-filter": filter, "url-filter-is-case-sensitive": true],
            // No resource-type restriction: frames, scripts, images, CSS, XHR, etc. are covered.
            "action": ["type": action],
        ]
    }

    private struct Matcher {
        let prefix: String
        let expression: NSRegularExpression?

        func matches(_ url: String) -> Bool {
            // Java startsWith compares UTF-16, unlike Swift's Unicode-equivalent hasPrefix.
            if url.utf16.starts(with: prefix.utf16) { return true }
            guard let expression else { return false }
            let range = NSRange(url.startIndex..<url.endIndex, in: url)
            return expression.firstMatch(in: url, range: range)?.range == range
        }
    }

    private enum PortableRegex {
        // This is a closed lexical allowlist, not a Java regex parser or a best-effort rewrite.
        // Native ICU validates syntax only within this common language; WebKit must also compile it.
        // Failure at either boundary never establishes that an arbitrary Java expression is invalid.
        // Accepted: printable ASCII literals, punctuation escapes, ., * + ?, (?:)/() groups,
        // simple ASCII classes/ranges, and optional outer ^/$. No alternation, flags,
        // lookarounds, class intersections/nesting, alphabetic escapes, counted/possessive repeats.
        struct Translation {
            let body: String
            let expression: NSRegularExpression
        }

        private static let allowlist: NSRegularExpression? = {
            let literal = #"[^\\\[\](){}.*+?^$|]"#
            let escaped = #"\\[\\.^$|?*+()\[\]{}/-]"#
            // Exclude ':' as well as nesting, so ICU POSIX/UnicodeSet syntax cannot enter.
            let characterClass = #"\[\^?(?:[-A-Za-z0-9_/\.%#@=~!; '<>]|"# + escaped + #")+\]"#
            let groupStart = #"\((?:\?:|(?!\?))"#
            let quantifier = #"[?*+]\??(?![?*+])"#
            let token = "(?:\(escaped)|\(characterClass)|\(groupStart)|\\)|\\.|\(quantifier)|\(literal))"
            return try? NSRegularExpression(pattern: "\\A\\^?(\(token)*)\\$?\\z")
        }()

        static func translate(_ pattern: String) -> Translation? {
            let range = NSRange(pattern.startIndex..<pattern.endIndex, in: pattern)
            guard let match = allowlist?.firstMatch(in: pattern, range: range), match.range == range,
                let bodyRange = Range(match.range(at: 1), in: pattern)
            else { return nil }
            let body = String(pattern[bodyRange])
            guard let expression = try? NSRegularExpression(pattern: "\\A(?:\(body))\\z") else { return nil }
            return Translation(body: body, expression: expression)
        }
    }

    @MainActor
    private final class Compiler {
        private var tail: Task<Void, Never>?

        func compile(_ json: String) async throws -> WKContentRuleList {
            let result = CompilationResult()
            let previous = tail
            // Independent of the waiting task: an in-flight native callback must drain before
            // another write to the same persistent identifier, even if its caller cancels.
            tail = Task { @MainActor in
                await previous?.value
                guard !result.isFinished else { return }
                guard let store = WKContentRuleListStore.default() else {
                    result.finish(
                        .failure(
                            NSError(
                                domain: Self.errorDomain, code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "订阅资源过滤暂不可用"]
                            )))
                    return
                }
                let errorDomain = Self.errorDomain
                await withCheckedContinuation { (drained: CheckedContinuation<Void, Never>) in
                    store.compileContentRuleList(
                        forIdentifier: RssArticleResourcePolicy.identifier, encodedContentRuleList: json
                    ) { list, error in
                        if let error {
                            result.finish(.failure(error))
                        } else if let list {
                            result.finish(.success(list))
                        } else {
                            result.finish(
                                .failure(
                                    NSError(
                                        domain: errorDomain, code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "订阅资源过滤规则加载失败"]
                                    )))
                        }
                        drained.resume()
                    }
                }
            }
            let list = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { result.wait($0) }
            } onCancel: {
                result.finish(.failure(CancellationError()))
            }
            try Task.checkCancellation()
            return list
        }

        private static let errorDomain = "io.legado.rss.article-resource-policy"
    }

    /// The cancellation handler can run off-main; native WebKit objects are only used on-main.
    private final class CompilationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<WKContentRuleList, Error>?
        private var continuation: CheckedContinuation<WKContentRuleList, Error>?

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return result != nil
        }

        func wait(_ continuation: CheckedContinuation<WKContentRuleList, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        func finish(_ result: Result<WKContentRuleList, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
