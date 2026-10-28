import Foundation
import NIOCore
import NIOHTTP1

/// Counts raw ingress without parsing HTTP. This also bounds request-line bytes and pipeline bursts.
final class HLSRelayHTTPIngressLimit: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var received = 0
    private var rejected = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        let size = unwrapInboundIn(data).readableBytes
        guard size <= 16 * 1024 - received else {
            rejected = true
            context.fireErrorCaught(HLSRelayHTTPFailure.request(400))
            return
        }
        received += size
        context.fireChannelRead(data)
    }
}

struct HLSRelayHTTPRequest: Sendable {
    let path: String
    let method: String
    let headers: [String: String]

    init(_ head: HTTPRequestHead, host: String) throws {
        guard head.version == .http1_1 || head.version == .http1_0 else {
            throw HLSRelayHTTPFailure.request(400)
        }
        var fields: [String: String] = [:]
        for (name, value) in head.headers {
            let key = name.lowercased()
            guard fields[key] == nil,
                value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 <= 126) })
            else { throw HLSRelayHTTPFailure.request(400) }
            fields[key] = value
        }
        guard fields["if-range"] == nil else { throw HLSRelayHTTPFailure.request(400) }
        guard fields["host"] == host else { throw HLSRelayHTTPFailure.request(403) }
        guard head.method == .GET || head.method == .HEAD else { throw HLSRelayHTTPFailure.request(405) }
        guard fields["transfer-encoding"] == nil, fields["expect"] == nil,
            fields["upgrade"] == nil, fields["trailer"] == nil,
            fields["content-length"] == nil || fields["content-length"] == "0"
        else { throw HLSRelayHTTPFailure.request(400) }
        if let connection = fields["connection"] {
            let tokens = connection.lowercased().split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard !tokens.isEmpty, tokens.allSatisfy({ $0 == "close" || $0 == "keep-alive" }) else {
                throw HLSRelayHTTPFailure.request(400)
            }
        }

        let path = head.uri
        guard path.utf8.count <= 2048, path.hasPrefix("/"), !path.hasPrefix("//"),
            path.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [UInt8(45), 46, 47, 95, 126].contains($0)
            })
        else { throw HLSRelayHTTPFailure.request(400) }
        // Opaque session routes need no percent escapes, query, fragment, or path normalization.
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("."), !components.contains(".."), !path.contains("//") else {
            throw HLSRelayHTTPFailure.request(403)
        }

        var forwarded: [String: String] = [:]
        if let range = fields["range"] {
            guard Self.validRange(range) else { throw HLSRelayHTTPFailure.request(400) }
            forwarded["range"] = "bytes=" + range.dropFirst(6)
        }
        self.path = path
        method = head.method == .HEAD ? "HEAD" : "GET"
        headers = forwarded
    }

    private static func validRange(_ value: String) -> Bool {
        guard value.utf8.count <= 128, value.prefix(6).lowercased() == "bytes=" else { return false }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        if parts[0].isEmpty { return number(parts[1]).map { $0 > 0 } ?? false }
        guard let first = number(parts[0]) else { return false }
        if parts[1].isEmpty { return true }
        return number(parts[1]).map { $0 >= first } ?? false
    }

    static func number<S: StringProtocol>(_ value: S) -> Int64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(value)
    }
}
