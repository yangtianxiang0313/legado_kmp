import Foundation

/// Adapts an existing spool to native HTTP playback without owning or restarting its upstream.
final class ProgressiveAudioHTTPRelay: @unchecked Sendable {
    let url: URL
    private let server: HLSRelayServer

    private init(url: URL, server: HLSRelayServer) {
        self.url = url
        self.server = server
    }

    static func start(
        contentType: String,
        idleTimeoutSeconds: Int64,
        currentLength: @escaping @Sendable () async throws -> Int64?,
        read: @escaping @Sendable (Int64, Int) async throws -> Data?
    ) async throws -> ProgressiveAudioHTTPRelay {
        try Task.checkCancellation()
        guard idleTimeoutSeconds > 0, idleTimeoutSeconds <= Int64.max / 1_000_000_000 else {
            throw ProgressiveAudioHTTPRelayFailure.invalidConfiguration
        }
        let mime = try mimeType(contentType)
        let path = "/" + UUID().uuidString.lowercased() + ".audio"
        let server = try await HLSRelayServer.start { requestedPath, method, headers in
            try Task.checkCancellation()
            guard requestedPath == path else {
                return HLSRelayHTTPResponse(statusCode: 404, headers: ["Cache-Control": "no-store"], body: Data())
            }
            guard method == "GET" || method == "HEAD" else {
                return HLSRelayHTTPResponse(statusCode: 405, headers: ["Cache-Control": "no-store"], body: Data())
            }
            let total = try await currentLength()
            try Task.checkCancellation()
            if let total, total < 0 { throw ProgressiveAudioHTTPRelayFailure.invalidLength }

            var responseHeaders = ["Content-Type": mime, "Cache-Control": "no-store"]
            var status = 200
            var first: Int64 = 0
            var count = total
            if let total {
                responseHeaders["Accept-Ranges"] = "bytes"
                if let range = headers["range"] {
                    guard let interval = ProgressiveAudioHTTPInterval(range: range, total: total) else {
                        responseHeaders["Content-Range"] = "bytes */\(total)"
                        return HLSRelayHTTPResponse(statusCode: 416, headers: responseHeaders, body: Data())
                    }
                    first = interval.first
                    count = interval.end - interval.first
                    status = 206
                    responseHeaders["Content-Range"] = "bytes \(interval.first)-\(interval.end - 1)/\(total)"
                }
                responseHeaders["Content-Length"] = String(count ?? total)
            } else {
                // Range probes cannot establish boundaries for a still-open representation.
                responseHeaders["Accept-Ranges"] = "none"
            }

            let reader = ProgressiveAudioHTTPReader(
                offset: first, length: count, idleTimeoutSeconds: idleTimeoutSeconds, read: read)
            // HEAD retains the stream's optional length for framing; the connection never reads it.
            return HLSRelayHTTPResponse(statusCode: status, headers: responseHeaders, body: Data(), stream: reader)
        }
        do {
            try Task.checkCancellation()
            return ProgressiveAudioHTTPRelay(
                url: server.baseURL.appendingPathComponent(String(path.dropFirst())), server: server)
        } catch {
            server.cancel()
            throw error
        }
    }

    func cancel() { server.cancel() }

    deinit { server.cancel() }

    private static func mimeType(_ value: String) throws -> String {
        let mime = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
        let parts = mime.split(separator: "/", omittingEmptySubsequences: false)
        guard mime.utf8.count <= 255, parts.count == 2,
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isTokenByte) })
        else { throw ProgressiveAudioHTTPRelayFailure.invalidContentType }
        return mime
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
    }
}

/// Cancel synchronously before enqueueing spool cleanup; queued reader registration checks this token.
final class ProgressiveAudioHTTPReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
}

private struct ProgressiveAudioHTTPInterval {
    let first: Int64
    let end: Int64

    init?(range: String, total: Int64) {
        guard total > 0, range.utf8.count <= 128, range.prefix(6).lowercased() == "bytes=" else { return nil }
        let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = HLSRelayHTTPRequest.number(parts[1]), suffix > 0 else { return nil }
            first = suffix >= total ? 0 : total - suffix
            end = total
        } else {
            guard let start = HLSRelayHTTPRequest.number(parts[0]), start < total else { return nil }
            first = start
            if parts[1].isEmpty {
                end = total
            } else {
                guard let last = HLSRelayHTTPRequest.number(parts[1]), last >= start else { return nil }
                // Clamp a satisfiable range before adding one, including an Int64.max upper bound.
                end = min(last, total - 1) + 1
            }
        }
    }
}

/// Each response owns one cursor; actor isolation plus the in-flight guard prevents overlapping reads.
private actor ProgressiveAudioHTTPReader: HLSRelayHTTPStreamingBody {
    nonisolated let length: Int64?
    nonisolated let idleTimeoutSeconds: Int64
    private let read: @Sendable (Int64, Int) async throws -> Data?
    private let cancellation = ProgressiveAudioHTTPReadCancellation()
    private var offset: Int64
    private var remaining: Int64?
    private var reading = false
    private var finished = false

    init(
        offset: Int64, length: Int64?, idleTimeoutSeconds: Int64,
        read: @escaping @Sendable (Int64, Int) async throws -> Data?
    ) {
        self.offset = offset
        self.length = length
        self.remaining = length
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.read = read
    }

    nonisolated func cancel() { cancellation.cancel() }

    func nextChunk() async throws -> Data? {
        try cancellation.check()
        guard !reading else { throw ProgressiveAudioHTTPRelayFailure.concurrentRead }
        guard !finished else { return nil }
        if remaining == 0 {
            finished = true
            return nil
        }
        reading = true
        defer { reading = false }
        do {
            guard offset >= 0 else { throw ProgressiveAudioHTTPRelayFailure.invalidLength }
            let count = Int(min(32 * 1024, min(remaining ?? Int64.max, Int64.max - offset)))
            guard count > 0 else { throw ProgressiveAudioHTTPRelayFailure.invalidLength }
            let data = try await read(offset, count)
            try cancellation.check()
            guard let data else {
                guard remaining == nil else { throw ProgressiveAudioHTTPRelayFailure.unexpectedEnd }
                finished = true
                return nil
            }
            guard !data.isEmpty, data.count <= count else { throw ProgressiveAudioHTTPRelayFailure.invalidChunk }
            let next = offset.addingReportingOverflow(Int64(data.count))
            guard !next.overflow else { throw ProgressiveAudioHTTPRelayFailure.invalidLength }
            offset = next.partialValue
            if let remaining { self.remaining = remaining - Int64(data.count) }
            return data
        } catch {
            finished = true
            cancellation.cancel()
            throw error
        }
    }
}

private enum ProgressiveAudioHTTPRelayFailure: Error {
    case invalidConfiguration
    case invalidContentType
    case invalidLength
    case invalidChunk
    case unexpectedEnd
    case concurrentRead
}
