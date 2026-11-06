import Foundation
import NIOCore
import NIOHTTP1

struct ForegroundHTTPRequest: Sendable {
    let method: String
    let path: String
    let host: String
    let origin: String?
    let token: String?
    let parameters: [String: String]
    var body: Data
    var contentType: String? = nil

    static let assets: [String: (name: String, suffix: String, type: String)] = [
        "/": ("ForegroundWeb", "html", "text/html; charset=utf-8"),
        "/ForegroundWebReading.js": ("ForegroundWebReading", "js", "text/javascript; charset=utf-8"),
        "/ForegroundWebStream.js": ("ForegroundWebStream", "js", "text/javascript; charset=utf-8"),
        "/ForegroundWebWorkbench.js": ("ForegroundWebWorkbench", "js", "text/javascript; charset=utf-8"),
        "/ForegroundWebUpload.js": ("ForegroundWebUpload", "js", "text/javascript; charset=utf-8"),
    ]

    var isUpload: Bool { method == "POST" && ["/addLocalBook", "/prepareLocalBook"].contains(path) }
}

struct ForegroundHTTPResponse: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String] = [:]
}

enum ForegroundHTTPFailure: Error { case request(Int) }

struct ForegroundHTTPPolicy: Sendable {
    let token: String
    let allowsWrites: Bool
    let hosts: Set<String>

    func request(_ head: HTTPRequestHead, port: Int) throws -> (ForegroundHTTPRequest, Int) {
        guard head.version == .http1_0 || head.version == .http1_1 else { throw ForegroundHTTPFailure.request(400) }
        var fields: [String: String] = [:]
        for (name, value) in head.headers {
            let key = name.lowercased()
            guard fields[key] == nil, value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw ForegroundHTTPFailure.request(400)
            }
            fields[key] = value
        }
        guard let host = fields["host"], hosts.contains(where: { host == "\($0):\(port)" }),
            fields["origin"] == nil || fields["origin"] == "http://\(host)"
        else { throw ForegroundHTTPFailure.request(403) }
        guard head.method == .GET || head.method == .POST else { throw ForegroundHTTPFailure.request(405) }
        guard fields["transfer-encoding"] == nil, fields["expect"] == nil,
            fields["upgrade"] == nil, fields["trailer"] == nil, fields["content-encoding"] == nil
        else { throw ForegroundHTTPFailure.request(400) }
        if let connection = fields["connection"] {
            let tokens = connection.lowercased().split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard tokens.allSatisfy({ $0 == "close" || $0 == "keep-alive" }) else {
                throw ForegroundHTTPFailure.request(400)
            }
        }
        guard head.uri.utf8.count <= 16 * 1024, head.uri.hasPrefix("/"), !head.uri.hasPrefix("//"),
            head.uri.utf8.allSatisfy({ (33...126).contains($0) && $0 != 92 }),
            let components = URLComponents(string: head.uri), components.scheme == nil, components.host == nil,
            components.fragment == nil, let path = components.percentEncodedPath.removingPercentEncoding,
            !path.contains("\\"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ForegroundHTTPFailure.request(400) }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query.count < 64, query[item.name] == nil else { throw ForegroundHTTPFailure.request(400) }
            query[item.name] = item.value ?? ""
        }
        let request = ForegroundHTTPRequest(
            method: head.method == .GET ? "GET" : "POST", path: path, host: host,
            origin: fields["origin"], token: fields["authorization"], parameters: query,
            body: Data(), contentType: fields["content-type"])
        if !(request.method == "GET" && ForegroundHTTPRequest.assets[path] != nil) {
            guard !token.isEmpty, request.token == "Bearer \(token)" else { throw ForegroundHTTPFailure.request(401) }
            guard request.method == "GET" && path != "/refreshToc" || allowsWrites else {
                throw ForegroundHTTPFailure.request(403)
            }
        }
        let raw = fields["content-length"] ?? "0"
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(raw) else {
            throw ForegroundHTTPFailure.request(400)
        }
        let limit =
            request.isUpload
            ? 32 * 1024 * 1024 + 64 * 1024
            : ["/commitLocalBook", "/discardLocalBook"].contains(path) ? 8 * 1024 : 8 * 1024 * 1024
        guard count <= limit else { throw ForegroundHTTPFailure.request(413) }
        guard request.method != "GET" || count == 0 else { throw ForegroundHTTPFailure.request(400) }
        return (request, count)
    }
}

/// Limits undecoded input as well as NIO's parsed fields, including an unfinished request line/header.
final class ForegroundHTTPIngressLimit: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var received = 0
    private var headerBytes = 0
    private var terminator = 0
    private var complete = false
    private var rejected = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !rejected else { return }
        let buffer = unwrapInboundIn(data)
        received += buffer.readableBytes
        guard received <= 32 * 1024 * 1024 + 80 * 1024 else { reject(context); return }
        if !complete {
            let end: [UInt8] = [13, 10, 13, 10]
            for byte in buffer.readableBytesView {
                headerBytes += 1
                guard headerBytes <= 16 * 1024 else { reject(context); return }
                terminator = byte == end[terminator] ? terminator + 1 : byte == 13 ? 1 : 0
                if terminator == 4 { complete = true; break }
            }
        }
        context.fireChannelRead(data)
    }

    private func reject(_ context: ChannelHandlerContext) {
        rejected = true
        context.fireErrorCaught(ForegroundHTTPFailure.request(413))
    }
}

/// Mutable parsing/writing state belongs exclusively to this channel's event loop.
final class ForegroundHTTPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private enum Phase: Equatable { case head, body, ready, handling, writing, closed }
    private let runtime: ForegroundWebHTTPRuntime
    private let id: UUID
    private var phase = Phase.head
    private var request: ForegroundHTTPRequest?
    private var expected = 0
    private var context: ChannelHandlerContext?
    private var deadline: Scheduled<Void>?
    private var outbound: Data?
    private var offset = 0
    private var writePending = false

    init(runtime: ForegroundWebHTTPRuntime, id: UUID) { self.runtime = runtime; self.id = id }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive(); armDeadline(seconds: 10); context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard phase != .closed else { return }
        if phase == .writing { close(); return }
        do {
            switch unwrapInboundIn(data) {
            case .head(let head):
                guard phase == .head, let port = context.channel.localAddress?.port else {
                    throw ForegroundHTTPFailure.request(400)
                }
                let parsed = try runtime.policy.request(head, port: port)
                request = parsed.0; expected = parsed.1
                phase = .body
                armDeadline(seconds: request?.isUpload == true ? 90 : 30)
            case .body(let buffer):
                guard phase == .body, let count = request?.body.count, buffer.readableBytes <= expected - count else {
                    throw ForegroundHTTPFailure.request(400)
                }
                request?.body.append(contentsOf: buffer.readableBytesView)
            case .end(let trailers):
                guard phase == .body, trailers == nil, request?.body.count == expected else {
                    throw ForegroundHTTPFailure.request(400)
                }
                phase = .ready
            }
        } catch ForegroundHTTPFailure.request(let status) { fail(status) } catch { fail(400) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if phase == .ready { beginRequest() }
        // Continue reading after the request to observe disconnects and reject pipelining.
        if phase != .closed { context.read() }
        context.fireChannelReadComplete()
    }

    private func beginRequest() {
        guard let request, let context, let handler = runtime.requestHandler(for: id) else { close(); return }
        phase = .handling
        armDeadline(seconds: request.isUpload || request.path == "/commitLocalBook" ? 180 : 30)
        let channel = context.channel
        let task = Task.detached { [weak self] in
            guard !Task.isCancelled else { return }
            let response = await handler(request)
            guard !Task.isCancelled else { return }
            channel.eventLoop.execute { [weak self] in
                guard let self, self.phase == .handling else { return }
                self.runtime.cancelTask(for: self.id)
                self.request = nil
                self.respond(response)
            }
        }
        runtime.store(task, for: id)
    }

    private func fail(_ status: Int) {
        guard phase != .closed else { return }
        if phase == .writing { close(); return }
        runtime.cancelTask(for: id); request = nil
        let body = try? JSONSerialization.data(withJSONObject: [
            "isSuccess": false, "errorMsg": "请求被拒绝（HTTP \(status)）", "data": NSNull(),
        ])
        respond(ForegroundHTTPResponse(status: status, body: body ?? Data()))
    }

    private func respond(_ response: ForegroundHTTPResponse) {
        guard let context, context.channel.isActive else { close(); return }
        phase = .writing; outbound = response.body; offset = 0; writePending = true
        armDeadline(seconds: 15)
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        headers.replaceOrAdd(name: "Connection", value: "close")
        headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        if !headers.contains(name: "Content-Type") {
            headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        }
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [self] result in
            writePending = false
            if case .failure = result { close(); return }
            scheduleWrite()
        }
        context.writeAndFlush(
            wrapOutboundOut(
                .head(
                    HTTPResponseHead(
                        version: .http1_1, status: HTTPResponseStatus(statusCode: response.status), headers: headers))), promise: promise)
    }

    private func scheduleWrite() { context?.eventLoop.execute { [weak self] in self?.writeNext() } }
    private func writeNext() {
        guard phase == .writing, !writePending, let context, context.channel.isActive,
            context.channel.isWritable, let body = outbound
        else { return }
        armDeadline(seconds: 15); writePending = true
        let promise = context.eventLoop.makePromise(of: Void.self)
        if offset == body.count {
            promise.futureResult.whenComplete { [self] _ in close() }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        } else {
            let size = min(32 * 1024, body.count - offset)
            var buffer = context.channel.allocator.buffer(capacity: size)
            let start = body.index(body.startIndex, offsetBy: offset)
            buffer.writeBytes(body[start..<body.index(start, offsetBy: size)])
            offset += size
            promise.futureResult.whenComplete { [self] result in
                writePending = false
                if case .failure = result { close(); return }
                scheduleWrite()
            }
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        writeNext(); context.fireChannelWritabilityChanged()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if case ForegroundHTTPFailure.request(let status) = error { fail(status) } else { fail(400) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        deadline?.cancel(); runtime.cancelTask(for: id); request = nil; outbound = nil; phase = .closed
        context.fireChannelInactive()
    }
    func handlerRemoved(context: ChannelHandlerContext) { deadline?.cancel(); self.context = nil }
    private func armDeadline(seconds: Int64) {
        deadline?.cancel()
        deadline = context?.eventLoop.scheduleTask(in: .seconds(seconds)) { [weak self] in self?.close() }
    }
    private func close() {
        guard phase != .closed else { return }
        phase = .closed; deadline?.cancel(); runtime.cancelTask(for: id); request = nil; outbound = nil
        context?.close(promise: nil)
    }
}
