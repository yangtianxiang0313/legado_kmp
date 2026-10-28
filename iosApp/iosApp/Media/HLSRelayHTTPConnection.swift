import Foundation
import NIOCore
import NIOHTTP1

/// All mutable connection state is confined to its channel's event loop.
final class HLSRelayHTTPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum Phase: Equatable { case head, end, ready, handling, writing, closed }

    private let runtime: HLSRelayHTTPRuntime
    private let id: UUID
    private let host: String
    private let overloaded: Bool
    private var context: ChannelHandlerContext?
    private var phase = Phase.head
    private var request: HLSRelayHTTPRequest?
    private var version = HTTPVersion.http1_1
    private var isHead = false
    private var deadline: Scheduled<Void>?
    private var outboundBody: Data?
    private var offset = 0
    private var writePending = false

    init(runtime: HLSRelayHTTPRuntime, id: UUID, host: String, overloaded: Bool) {
        self.runtime = runtime
        self.id = id
        self.host = host
        self.overloaded = overloaded
    }

    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    func channelActive(context: ChannelHandlerContext) {
        context.fireChannelActive()
        if overloaded { fail(429); return }
        // Absolute header deadline prevents a slow sender from extending its slot indefinitely.
        armDeadline(seconds: 10)
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard phase != .closed, phase != .writing else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard phase == .head else { fail(429); return }
            version = head.version == .http1_0 ? .http1_0 : .http1_1
            isHead = head.method == .HEAD
            do {
                request = try HLSRelayHTTPRequest(head, host: host)
                phase = .end
            } catch HLSRelayHTTPFailure.request(let status) { fail(status) } catch { fail(400) }
        case .body:
            fail(400)
        case .end(let trailers):
            guard phase == .end, trailers == nil else { fail(400); return }
            phase = .ready
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        switch phase {
        case .head, .end: context.read()
        case .ready:
            // Wait for this read batch to finish so a pipelined request never starts an upstream task.
            beginRequest()
            if phase == .handling { context.read() }
        case .handling:
            // Observe EOF/cancel promptly; any extra request is rejected, never queued. Raw ingress stays bounded.
            context.read()
        case .writing, .closed: break
        }
        context.fireChannelReadComplete()
    }

    private func beginRequest() {
        guard phase == .ready, let request, let context,
            let handler = runtime.requestHandler(for: id)
        else { close(); return }
        phase = .handling
        armDeadline(seconds: 30)
        let channel = context.channel
        let task = Task.detached { [weak self] in
            var response: HLSRelayHTTPResponse
            do {
                try Task.checkCancellation()
                response = try await handler(request.path, request.method, request.headers)
                try Task.checkCancellation()
            } catch {
                guard !Task.isCancelled else { return }
                response = HLSRelayHTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            guard !Task.isCancelled else { return }
            channel.eventLoop.execute { [weak self] in self?.complete(response) }
        }
        runtime.store(task, for: id)
    }

    private func complete(_ response: HLSRelayHTTPResponse) {
        guard phase == .handling else { return }
        runtime.cancelTask(for: id)
        request = nil
        respond(HLSRelayHTTPOutput.prepare(response, isHead: isHead, version: version))
    }

    private func fail(_ status: Int) {
        guard phase != .closed else { return }
        guard phase != .writing else { close(); return }
        runtime.cancelTask(for: id)
        request = nil
        respond(HLSRelayHTTPOutput.error(status, isHead: isHead, version: version))
    }

    private func respond(_ output: HLSRelayHTTPOutput) {
        guard let context, context.channel.isActive else { close(); return }
        phase = .writing
        outboundBody = output.body
        offset = 0
        writePending = true
        armDeadline(seconds: 15)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [self] result in
            guard phase == .writing else { return }
            writePending = false
            if case .failure = result { close(); return }
            scheduleWrite()
        }
        context.writeAndFlush(wrapOutboundOut(.head(output.head)), promise: promise)
    }

    private func scheduleWrite() {
        context?.eventLoop.execute { [weak self] in self?.writeNext() }
    }

    private func writeNext() {
        guard phase == .writing, !writePending, let context, context.channel.isActive,
            context.channel.isWritable, let body = outboundBody
        else { return }
        armDeadline(seconds: 15)
        writePending = true
        let promise = context.eventLoop.makePromise(of: Void.self)
        if offset == body.count {
            // Keep the original Data alive through the final flush, not merely until write() returns.
            promise.futureResult.whenComplete { [self, body] _ in
                withExtendedLifetime(body) {}
                outboundBody = nil
                close()
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            return
        }

        let size = min(32 * 1024, body.count - offset)
        var buffer = context.channel.allocator.buffer(capacity: size)
        _ = body.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            buffer.writeBytes(UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + size)]))
        }
        offset += size
        promise.futureResult.whenComplete { [self, body] result in
            withExtendedLifetime(body) {}
            guard phase == .writing else { return }
            writePending = false
            if case .failure = result { close(); return }
            scheduleWrite()
        }
        context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if phase == .writing, context.channel.isWritable { scheduleWrite() }
        context.fireChannelWritabilityChanged()
    }

    private func armDeadline(seconds: Int64) {
        deadline?.cancel()
        deadline = context?.eventLoop.scheduleTask(in: .seconds(seconds)) { [weak self] in
            guard let self else { return }
            switch self.phase {
            case .head, .end, .ready: self.fail(400)
            case .handling: self.fail(500)
            case .writing: self.close()
            case .closed: break
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // NIO parser errors are deliberately reduced to a static, non-sensitive response.
        fail(400)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
        self.context = nil
    }

    private func close() {
        guard phase != .closed else { return }
        finish()
        context?.close(promise: nil)
    }

    private func finish() {
        phase = .closed
        deadline?.cancel()
        deadline = nil
        runtime.cancelTask(for: id)
        request = nil
        outboundBody = nil
    }
}
