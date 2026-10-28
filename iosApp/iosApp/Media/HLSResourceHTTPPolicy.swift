import Foundation
import shared

enum HLSResourceHTTPPolicy {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumDuration: TimeInterval = 120
    private static let maximumBodyBytes = 1024 * 1024
    private static let publicHeaders: Set<String> = ["accept", "accept-language", "user-agent"]
    private static let managedHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection", "keep-alive", "te", "trailer", "upgrade",
        "accept-encoding", "cookie2", "range",
    ]
    private static let unsupportedHeaders: Set<String> = [
        "proxy", "cookiejar", "if-range", "content-range", "x-http-method-override",
        "if-match", "if-none-match", "if-modified-since", "if-unmodified-since",
    ]

    struct Input: @unchecked Sendable {
        let request: URLRequest
        let range: ByteRange?
        let headerOrigin: URL
        private let original: PreparedMediaRequest
        private let context: MediaResourceContext

        init(_ prepared: PreparedMediaRequest, range: String?) throws {
            try validateRequestHeaders(prepared.headers)
            if let encoded = prepared.bodyBase64 {
                guard encoded.utf8.count <= ((maximumBodyBytes + 2) / 3) * 4 else {
                    throw HLSResourceHTTPError.invalidRequest
                }
            }
            let native: URLRequest
            do { native = try MediaPlaybackRequest.native(prepared) } catch { throw HLSResourceHTTPError.invalidRequest }
            guard let initialURL = native.url else { throw HLSResourceHTTPError.invalidRequest }
            let url = try networkURL(initialURL)
            let origin = try networkURL(prepared.resourceContext?.headerOriginUrl ?? prepared.url)
            let method = native.httpMethod?.uppercased() ?? "GET"
            let timeout = Double(prepared.timeoutMillis) / 1000
            guard ["GET", "POST"].contains(method), native.httpBodyStream == nil,
                (native.httpBody?.count ?? 0) <= maximumBodyBytes, timeout.isFinite, timeout > 0,
                method != "GET" || native.httpBody == nil
            else { throw HLSResourceHTTPError.invalidRequest }
            guard !(origin.scheme?.lowercased() == "https" && url.scheme?.lowercased() != "https"),
                sameOrigin(origin, url) || (method == "GET" && native.httpBody == nil)
            else { throw HLSResourceHTTPError.unsupportedRedirect }
            let embedded = native.value(forHTTPHeaderField: "Range")
            let selectedRange = try range.map { try ByteRange($0) }
            let embeddedRange = try embedded.map { try ByteRange($0) }
            if let selectedRange, let embeddedRange, selectedRange != embeddedRange {
                throw HLSResourceHTTPError.invalidRange
            }
            let byteRange = selectedRange ?? embeddedRange
            guard method == "GET" || byteRange == nil else { throw HLSResourceHTTPError.invalidRange }
            // Capture explicit provenance before the first jar merge, including direct native callers.
            original =
                prepared.resourceContext == nil
                ? PreparedMediaRequest(
                    url: prepared.url, method: prepared.method, headers: prepared.headers, bodyBase64: prepared.bodyBase64,
                    timeoutMillis: prepared.timeoutMillis, allowsSystemAsset: prepared.allowsSystemAsset,
                    resourceContext: MediaResourceContext(
                        sourceUrl: "", headerOriginUrl: prepared.url,
                        explicitCookie: prepared.headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?.value,
                        enabledCookieJar: false))
                : prepared
            context =
                prepared.resourceContext
                ?? MediaResourceContext(
                    sourceUrl: "", headerOriginUrl: url.absoluteString,
                    explicitCookie: native.value(forHTTPHeaderField: "Cookie"), enabledCookieJar: false)
            headerOrigin = origin
            self.range = byteRange
            request = try HLSResourceHTTPPolicy.request(
                url: url, method: method, body: native.httpBody, headers: native.allHTTPHeaderFields ?? [:],
                timeout: min(30, timeout), allowsPrivate: sameOrigin(origin, url), range: byteRange)
        }

        func snapshot(_ request: URLRequest, explicitCookie: String?) -> PreparedMediaRequest {
            let context = MediaResourceContext(
                sourceUrl: self.context.sourceUrl, headerOriginUrl: self.context.headerOriginUrl,
                explicitCookie: explicitCookie, enabledCookieJar: self.context.enabledCookieJar)
            return PreparedMediaRequest(
                url: request.url!.absoluteString, method: request.httpMethod ?? "GET",
                headers: request.allHTTPHeaderFields ?? [:],
                bodyBase64: request.httpBody == nil ? nil : original.bodyBase64,
                timeoutMillis: original.timeoutMillis, allowsSystemAsset: original.allowsSystemAsset,
                resourceContext: context)
        }

        var initialPrepared: PreparedMediaRequest {
            snapshot(
                request,
                explicitCookie: sameOrigin(headerOrigin, request.url!) ? context.explicitCookie : nil)
        }
    }

    enum ByteRange: Equatable, Sendable {
        case closed(Int64, Int64)
        case open(Int64)
        case suffix(Int64)

        init(_ value: String) throws {
            guard value.utf8.count <= 128, value.lowercased().hasPrefix("bytes=") else {
                throw HLSResourceHTTPError.invalidRange
            }
            let fields = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw HLSResourceHTTPError.invalidRange }
            if fields[0].isEmpty, let count = number(fields[1]), count > 0 {
                self = .suffix(count)
            } else if let start = number(fields[0]), fields[1].isEmpty {
                self = .open(start)
            } else if let start = number(fields[0]), let end = number(fields[1]), end >= start {
                self = .closed(start, end)
            } else {
                throw HLSResourceHTTPError.invalidRange
            }
        }

        var header: String {
            switch self {
            case let .closed(start, end): return "bytes=\(start)-\(end)"
            case let .open(start): return "bytes=\(start)-"
            case let .suffix(count): return "bytes=-\(count)"
            }
        }

        func responseLength(_ raw: String) throws -> Int {
            guard raw.utf8.count <= 128, raw.lowercased().hasPrefix("bytes ") else {
                throw HLSResourceHTTPError.invalidResponse
            }
            let fields = raw.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw HLSResourceHTTPError.invalidResponse }
            let offsets = fields[0].split(separator: "-", omittingEmptySubsequences: false)
            let total = number(fields[1])
            guard offsets.count == 2, let first = number(offsets[0]), let last = number(offsets[1]),
                last >= first, fields[1] == "*" || total != nil,
                total.map({ $0 > last }) ?? true
            else { throw HLSResourceHTTPError.invalidResponse }
            switch self {
            case let .closed(start, end):
                guard first == start, last <= end,
                    total.map({ last == min(end, $0 - 1) }) ?? true
                else { throw HLSResourceHTTPError.invalidResponse }
            case let .open(start):
                guard first == start, total.map({ last == $0 - 1 }) ?? true else {
                    throw HLSResourceHTTPError.invalidResponse
                }
            case let .suffix(count):
                guard let total, first == max(0, total - count), last == total - 1 else {
                    throw HLSResourceHTTPError.invalidResponse
                }
            }
            guard last - first < Int64(maximumBytes) else { throw HLSResourceHTTPError.tooLarge }
            return Int(last - first + 1)
        }
    }

    struct Response {
        let url: URL
        let statusCode: Int
        let headers: [String: String]
        let expectedBytes: Int?

        init(_ response: HTTPURLResponse, request: URLRequest, range: ByteRange?) throws {
            guard let url = response.url, url == request.url else { throw HLSResourceHTTPError.invalidResponse }
            guard [200, 206].contains(response.statusCode) else { throw HLSResourceHTTPError.http(response.statusCode) }
            let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?
                .trimmingCharacters(in: .whitespaces).lowercased()
            guard encoding == nil || encoding == "identity",
                response.mimeType?.lowercased() != "multipart/byteranges"
            else { throw HLSResourceHTTPError.invalidResponse }
            var declared: Int64?
            if let value = response.value(forHTTPHeaderField: "Content-Length") {
                guard let length = number(Substring(value.trimmingCharacters(in: .whitespaces))),
                    response.value(forHTTPHeaderField: "Transfer-Encoding") == nil
                else { throw HLSResourceHTTPError.invalidResponse }
                declared = length
            }
            if response.expectedContentLength >= 0 {
                guard declared == nil || declared == response.expectedContentLength else {
                    throw HLSResourceHTTPError.invalidResponse
                }
                declared = response.expectedContentLength
            }
            if let declared, declared > Int64(maximumBytes) { throw HLSResourceHTTPError.tooLarge }
            if response.statusCode == 206 {
                guard request.httpMethod == "GET", let range,
                    let contentRange = response.value(forHTTPHeaderField: "Content-Range")
                else { throw HLSResourceHTTPError.invalidResponse }
                let length = try range.responseLength(contentRange)
                guard declared == nil || declared == Int64(length) else { throw HLSResourceHTTPError.invalidResponse }
                expectedBytes = length
            } else {
                guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
                    throw HLSResourceHTTPError.invalidResponse
                }
                expectedBytes = declared.map(Int.init)
            }
            guard expectedBytes != 0 else { throw HLSResourceHTTPError.empty }
            var headers: [String: String] = [:]
            for name in [
                "Content-Type", "Content-Length", "Content-Range", "Accept-Ranges",
                "ETag", "Last-Modified", "Cache-Control", "Expires",
            ] {
                if let value = response.value(forHTTPHeaderField: name) {
                    try validateHeaders([name: value])
                    headers[name] = value
                }
            }
            self.url = url
            statusCode = response.statusCode
            self.headers = headers
        }
    }

    static func request(
        url: URL, method: String, body: Data?, headers: [String: String], timeout: TimeInterval,
        allowsPrivate: Bool, range: ByteRange?, strippedEntity: Bool = false
    ) throws -> URLRequest {
        try validateRequestHeaders(headers)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        for (name, value) in headers {
            let key = name.lowercased()
            if managedHeaders.contains(key) { continue }
            if strippedEntity && (key.hasPrefix("content-") || key == "digest" || key == "expect") { continue }
            // Only common may supply a Cookie value scoped to this target, including foreign origins.
            if !allowsPrivate && key != "cookie" && !publicHeaders.contains(key) { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if method == "GET", let range { request.setValue(range.header, forHTTPHeaderField: "Range") }
        return request
    }

    static func setCookieHeaders(_ response: HTTPURLResponse) throws -> [String] {
        var fields: [String] = []
        for (name, value) in response.allHeaderFields {
            guard let name = name.base as? String, name.caseInsensitiveCompare("Set-Cookie") == .orderedSame else { continue }
            if let raw = value as? String {
                fields.append(raw)
            } else if let raw = value as? [String] {
                fields.append(contentsOf: raw)
            } else {
                throw HLSResourceHTTPError.invalidResponse
            }
        }
        if fields.isEmpty, let value = response.value(forHTTPHeaderField: "Set-Cookie") { fields.append(value) }
        guard fields.count <= 128 else { throw HLSResourceHTTPError.invalidResponse }
        var bytes = 0
        for field in fields {
            guard field.utf8.count <= 64 * 1024 - bytes, !hasControl(field) else {
                throw HLSResourceHTTPError.invalidResponse
            }
            bytes += field.utf8.count
        }
        // Do not split on commas: Expires attributes can contain commas, and common parses folded fields.
        return fields
    }

    static func networkURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw HLSResourceHTTPError.invalidRequest }
        return try networkURL(url)
    }

    static func networkURL(_ url: URL) throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
            url.user == nil, url.password == nil, url.port.map({ (1...65535).contains($0) }) ?? true,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw HLSResourceHTTPError.invalidRequest }
        components.fragment = nil
        guard let networkURL = components.url else { throw HLSResourceHTTPError.invalidRequest }
        return networkURL
    }

    static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased() && port(left) == port(right)
    }

    private static func number(_ value: Substring) -> Int64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(value)
    }

    private static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    private static func validateRequestHeaders(_ headers: [String: String]) throws {
        try validateHeaders(headers)
        for (name, value) in headers {
            let key = name.lowercased()
            guard key != "proxy", !key.hasPrefix("proxy-") else { throw HLSResourceHTTPError.unsupportedTransport }
            guard !unsupportedHeaders.contains(key) else { throw HLSResourceHTTPError.invalidRequest }
            if key == "accept-encoding", value.trimmingCharacters(in: .whitespaces).lowercased() != "identity" {
                throw HLSResourceHTTPError.invalidRequest
            }
        }
    }

    private static func validateHeaders(_ headers: [String: String]) throws {
        guard headers.count <= 128 else { throw HLSResourceHTTPError.invalidRequest }
        var seen = Set<String>()
        var bytes = 0
        for (name, value) in headers {
            let size = name.utf8.count + value.utf8.count
            guard !name.isEmpty,
                name.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                        || "!#$%&'*+-.^_`|~".utf8.contains($0)
                }), !hasControl(value), seen.insert(name.lowercased()).inserted,
                value.utf8.count <= 16 * 1024, size <= 64 * 1024 - bytes
            else { throw HLSResourceHTTPError.invalidRequest }
            bytes += size
        }
    }
}
