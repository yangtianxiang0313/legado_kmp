import Foundation
import shared

enum MediaPlaybackRequest {
    static func native(_ prepared: PreparedMediaRequest) throws -> URLRequest {
        guard let url = URL(string: prepared.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil, url.user == nil, url.password == nil
        else { throw URLError(.badURL) }
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: max(1, min(300, Double(prepared.timeoutMillis) / 1000)))
        request.httpMethod = prepared.method
        for (name, value) in prepared.headers {
            if prepared.allowsSystemAsset, name.caseInsensitiveCompare("User-Agent") != .orderedSame { continue }
            guard !name.contains("\r"), !name.contains("\n"), !value.contains("\r"), !value.contains("\n") else {
                throw URLError(.badURL)
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = prepared.bodyBase64 {
            guard let data = Data(base64Encoded: body) else { throw URLError(.cannotDecodeContentData) }
            request.httpBody = data
        }
        return request
    }
}
