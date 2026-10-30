import Foundation
import NIOHTTP1

/// Owns framing and an intentionally small media-header allowlist, never upstream transport headers.
struct HLSRelayHTTPOutput {
    let head: HTTPResponseHead
    let body: Data
    var stream: (any HLSRelayHTTPStreamingBody)? = nil

    static func prepare(
        _ response: HLSRelayHTTPResponse, isHead: Bool, version: HTTPVersion
    ) -> HLSRelayHTTPOutput {
        do {
            let output = try checked(response, isHead: isHead, version: version)
            // HEAD and static error responses do not retain a reader. Cancelling a reader
            // releases only that reader; the streaming-body contract preserves its source.
            if output.stream == nil { response.stream?.cancel() }
            return output
        } catch {
            response.stream?.cancel()
            return Self.error(500, isHead: isHead, version: version)
        }
    }

    static func error(_ code: Int, isHead: Bool, version: HTTPVersion) -> HLSRelayHTTPOutput {
        let status = HTTPResponseStatus(statusCode: code)
        let message = status.reasonPhrase.isEmpty ? "Request Failed" : status.reasonPhrase
        let data = Data(message.utf8)
        var headers = baseHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: String(data.count))
        if code == 405 { headers.add(name: "Allow", value: "GET, HEAD") }
        return HLSRelayHTTPOutput(
            head: HTTPResponseHead(version: version, status: status, headers: headers), body: isHead ? Data() : data)
    }

    private static func checked(
        _ response: HLSRelayHTTPResponse, isHead: Bool, version: HTTPVersion
    ) throws -> HLSRelayHTTPOutput {
        guard response.headers.count <= 64 else { throw HLSRelayHTTPFailure.unavailable }
        var fields: [String: String] = [:]
        var remaining = 16 * 1024
        for (name, value) in response.headers {
            guard name.utf8.count <= remaining else { throw HLSRelayHTTPFailure.unavailable }
            remaining -= name.utf8.count
            guard value.utf8.count <= remaining else { throw HLSRelayHTTPFailure.unavailable }
            remaining -= value.utf8.count
            let key = name.lowercased()
            guard fields[key] == nil else { throw HLSRelayHTTPFailure.unavailable }
            fields[key] = value
        }

        let code = response.statusCode
        if (400...599).contains(code) {
            // An upstream error page can contain its origin URL or credentials; never forward it.
            var output = error(code, isHead: isHead, version: version)
            if code == 416, let value = fields["content-range"], let range = contentRange(value), range.length == nil {
                var head = output.head
                head.headers.add(name: "Content-Range", value: range.value)
                output = HLSRelayHTTPOutput(head: head, body: output.body)
            }
            return output
        }
        guard [200, 204, 206, 304].contains(code),
            fields["content-encoding"] == nil || fields["content-encoding"]?.lowercased() == "identity"
        else { throw HLSRelayHTTPFailure.unavailable }

        var headers = baseHeaders()
        if let value = fields["content-type"] {
            // Parameters can carry origin URLs; a MIME type is all the player needs here.
            let mime = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces).lowercased()
            let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isTokenByte) }) else {
                throw HLSRelayHTTPFailure.unavailable
            }
            headers.add(name: "Content-Type", value: mime)
        } else {
            headers.add(name: "Content-Type", value: "application/octet-stream")
        }
        if let value = fields["accept-ranges"], value == "bytes" || value == "none" {
            headers.add(name: "Accept-Ranges", value: value)
        }

        let suppliedLength: Int64?
        if let value = fields["content-length"] {
            guard let length = HLSRelayHTTPRequest.number(value) else { throw HLSRelayHTTPFailure.unavailable }
            suppliedLength = length
        } else {
            suppliedLength = nil
        }

        if let stream = response.stream {
            guard (code == 200 || code == 206), response.body.isEmpty else {
                throw HLSRelayHTTPFailure.unavailable
            }
            if let length = stream.length {
                guard length >= 0, suppliedLength == nil || suppliedLength == length else {
                    throw HLSRelayHTTPFailure.unavailable
                }
                if code == 206 {
                    guard let value = fields["content-range"], let range = contentRange(value),
                        range.length == length
                    else { throw HLSRelayHTTPFailure.unavailable }
                    headers.add(name: "Content-Range", value: range.value)
                } else {
                    guard fields["content-range"] == nil else { throw HLSRelayHTTPFailure.unavailable }
                }
                headers.add(name: "Content-Length", value: String(length))
            } else {
                guard code == 200, suppliedLength == nil, fields["content-range"] == nil else {
                    throw HLSRelayHTTPFailure.unavailable
                }
                // Leave unknown lengths unframed here: NIO's HTTP/1.1 encoder owns
                // chunking, while HTTP/1.0 uses the connection-close boundary.
            }
            return HLSRelayHTTPOutput(
                head: HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: code), headers: headers),
                body: Data(), stream: isHead ? nil : stream)
        }

        if code == 206 {
            guard let value = fields["content-range"], let range = contentRange(value), let length = range.length,
                isHead || length == Int64(response.body.count), suppliedLength == nil || suppliedLength == length
            else { throw HLSRelayHTTPFailure.unavailable }
            headers.add(name: "Content-Range", value: range.value)
            headers.add(name: "Content-Length", value: String(length))
        } else if code == 200 {
            // GET can be a rewritten playlist, so its upstream length must not control framing.
            let length = isHead ? suppliedLength ?? Int64(response.body.count) : Int64(response.body.count)
            headers.add(name: "Content-Length", value: String(length))
        } else {
            guard response.body.isEmpty else { throw HLSRelayHTTPFailure.unavailable }
            if code == 304, let suppliedLength { headers.add(name: "Content-Length", value: String(suppliedLength)) }
        }
        return HLSRelayHTTPOutput(
            head: HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: code), headers: headers),
            body: isHead ? Data() : response.body)
    }

    private static func baseHeaders() -> HTTPHeaders {
        HTTPHeaders([("Connection", "close"), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")])
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
    }

    private static func contentRange(_ value: String) -> (value: String, length: Int64?)? {
        guard value.hasPrefix("bytes "), value.utf8.count <= 128 else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0] == "*", let total = HLSRelayHTTPRequest.number(parts[1]) {
            return ("bytes */\(total)", nil)
        }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let first = HLSRelayHTTPRequest.number(bounds[0]),
            let last = HLSRelayHTTPRequest.number(bounds[1]), last >= first, last < Int64.max
        else { return nil }
        let total: String
        if parts[1] == "*" {
            total = "*"
        } else if let count = HLSRelayHTTPRequest.number(parts[1]), count > last {
            total = String(count)
        } else {
            return nil
        }
        return ("bytes \(first)-\(last)/\(total)", last - first + 1)
    }
}
