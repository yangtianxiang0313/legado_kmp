import Foundation

/// Inclusive HTTP byte offsets; only the media loader may generate Range/If-Range headers.
struct MediaHTTPByteRange {
    let start: Int64
    let end: Int64
    let validator: String?

    var count: Int64 { end - start + 1 }

    func responseRange(_ response: HTTPURLResponse) throws -> (end: Int64, total: Int64) {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity",
            let value = response.value(forHTTPHeaderField: "Content-Range"),
            value.lowercased().hasPrefix("bytes ")
        else { throw MediaAudioError.network }
        let fields = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2 else { throw MediaAudioError.network }
        let offsets = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        func number(_ part: Substring) -> Int64? {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int64(part)
        }
        guard offsets.count == 2, let first = number(offsets[0]), let last = number(offsets[1]),
            let total = number(fields[1]), first == start, last >= first, last <= end, total > last,
            total <= 64 * 1024 * 1024 * 1024,
            response.expectedContentLength < 0 || response.expectedContentLength == last - first + 1
        else { throw MediaAudioError.network }
        return (last, total)
    }

    /// RFC 9110: ranges may be recombined only with a common strong validator.
    static func strongValidator(_ response: HTTPURLResponse) -> String? {
        if let etag = response.value(forHTTPHeaderField: "ETag"), etag.utf8.count <= 1024,
            etag.first == "\"", etag.last == "\"", etag.count >= 2,
            etag.dropFirst().dropLast().utf8.allSatisfy({ $0 >= 33 && $0 != 34 && $0 != 127 })
        {
            return etag
        }
        // A Last-Modified date is strong for a client only when Date is at least 60 seconds later.
        guard response.value(forHTTPHeaderField: "ETag") == nil,
            let modified = response.value(forHTTPHeaderField: "Last-Modified"),
            let date = response.value(forHTTPHeaderField: "Date")
        else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let modifiedDate = formatter.date(from: modified), let serverDate = formatter.date(from: date),
            serverDate.timeIntervalSince(modifiedDate) >= 60
        else { return nil }
        return modified
    }
}
