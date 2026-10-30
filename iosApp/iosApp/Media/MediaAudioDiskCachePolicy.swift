import Foundation
import CryptoKit

enum MediaAudioDiskCachePolicy {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resourceKey(_ url: URL) -> String {
        digest(Data(url.absoluteString.utf8))
    }

    static func requestKey(_ request: URLRequest) -> String? {
        guard let url = request.url, validURL(url),
            (request.httpMethod ?? "GET").uppercased() == "GET",
            request.httpBody == nil, request.httpBodyStream == nil,
            let headers = normalizedHeaders(request.allHTTPHeaderFields ?? [:]),
            headers["accept-encoding"]?.lowercased() == "identity",
            headers["content-range"] == nil,
            cacheControl(headers["cache-control"]) != nil,
            !hasNoCachePragma(headers["pragma"])
        else { return nil }

        var bytes = Data()
        func append(_ value: String) {
            let field = Data(value.utf8)
            bytes.append(contentsOf: "\(field.count):".utf8)
            bytes.append(field)
        }
        append("media-audio-request-v1")
        append(url.absoluteString)
        append((request.httpMethod ?? "GET").uppercased())
        append("body-absent")
        append("body-stream-absent")
        let names = headers.keys.filter { $0 != "range" && $0 != "if-range" }.sorted()
        append(String(names.count))
        for name in names {
            append(name)
            append(headers[name] ?? "")
        }
        return digest(bytes)
    }

    static func freshness(
        request: URLRequest,
        response: HTTPURLResponse,
        lifetime: TimeInterval,
        now: Date
    ) -> Date? {
        guard lifetime.isFinite, lifetime > 0, now.timeIntervalSince1970.isFinite,
            requestKey(request) != nil,
            response.statusCode == 200 || response.statusCode == 206,
            let url = response.url, validURL(url),
            let requestHeaders = normalizedHeaders(request.allHTTPHeaderFields ?? [:])
        else { return nil }
        var rawHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let value = value as? String else { return nil }
            rawHeaders[name] = value
        }
        guard let headers = normalizedHeaders(rawHeaders),
            headers["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true,
            let requestControl = cacheControl(requestHeaders["cache-control"]),
            let responseControl = cacheControl(headers["cache-control"]),
            !hasNoCachePragma(requestHeaders["pragma"]),
            !hasNoCachePragma(headers["pragma"]),
            !(headers["vary"]?.split(separator: ",").contains { trim(String($0)) == "*" } ?? false)
        else { return nil }
        let path = url.path.lowercased()
        let originalPath = request.url?.path.lowercased() ?? ""
        guard ![path, originalPath].contains(where: { $0.hasSuffix(".m3u8") || $0.hasSuffix(".mpd") }) else {
            return nil
        }
        if let mime = response.mimeType?.lowercased() {
            let manifests: Set<String> = [
                "application/vnd.apple.mpegurl", "application/x-mpegurl",
                "audio/mpegurl", "audio/x-mpegurl", "application/mpegurl",
                "application/dash+xml",
            ]
            guard !manifests.contains(mime) else { return nil }
        }

        var age: TimeInterval = 0
        if let rawAge = headers["age"] {
            guard let parsed = seconds(rawAge) else { return nil }
            age = parsed
        }
        var serverDate: Date?
        if let rawDate = headers["date"] {
            guard let parsed = httpDate(rawDate) else { return nil }
            serverDate = parsed
            age = max(age, max(0, now.timeIntervalSince(parsed)))
        }
        // HTTP age consumes the server's freshness lifetime, not our local retention cap.
        var allowed = responseControl.maxAge ?? lifetime
        if let maxAge = requestControl.maxAge { allowed = min(allowed, maxAge) }
        if let rawExpires = headers["expires"] {
            guard let expires = httpDate(rawExpires) else { return nil }
            allowed = min(allowed, expires.timeIntervalSince(serverDate ?? now))
        }
        let remaining = min(lifetime, 86_400, allowed - age)
        guard remaining.isFinite, remaining > 0 else { return nil }
        let expires = now.addingTimeInterval(remaining)
        return expires > now ? expires : nil
    }

    private static func validURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil
        else { return false }
        return !url.absoluteString.unicodeScalars.contains { $0.value <= 32 || $0.value == 127 }
    }

    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [String: String]? {
        let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var result: [String: String] = [:]
        for (name, value) in headers {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ token.contains($0) }),
                !value.unicodeScalars.contains(where: { ($0.value < 32 && $0.value != 9) || $0.value == 127 })
            else { return nil }
            let key = name.lowercased()
            guard result[key] == nil else { return nil }
            result[key] = trim(value)
        }
        return result
    }

    private struct CacheControl {
        var maxAge: TimeInterval?
    }

    private static func cacheControl(_ raw: String?) -> CacheControl? {
        guard let raw else { return CacheControl() }
        // Commas inside quoted extension values do not delimit directives.
        var fields: [String] = []
        var field = ""
        var quoted = false
        var escaped = false
        for character in raw {
            if escaped {
                field.append(character)
                escaped = false
            } else if quoted && character == "\\" {
                field.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                field.append(character)
            } else if character == "," && !quoted {
                fields.append(field)
                field = ""
            } else {
                field.append(character)
            }
        }
        guard !quoted, !escaped else { return nil }
        fields.append(field)
        var result = CacheControl()
        for field in fields {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = trim(String(parts[0])).lowercased()
            if name == "no-store" || name == "no-cache" { return nil }
            if name == "max-age" {
                guard result.maxAge == nil, parts.count == 2 else { return nil }
                var value = trim(String(parts[1]))
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                guard let parsed = seconds(value), parsed > 0 else { return nil }
                result.maxAge = parsed
            }
        }
        return result
    }

    private static func seconds(_ value: String) -> TimeInterval? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let number = TimeInterval(value), number.isFinite
        else { return nil }
        return number
    }

    private static func hasNoCachePragma(_ value: String?) -> Bool {
        value?.split(separator: ",").contains {
            trim(String($0).split(separator: "=", maxSplits: 1).first.map(String.init) ?? "").lowercased() == "no-cache"
        } ?? false
    }

    private static func httpDate(_ value: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
