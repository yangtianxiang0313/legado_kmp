import Foundation
import NIOCore
import NIOHTTP1

/// All mutable connection state is confined to its channel's event loop.
final class HLSRelayHTTPConnection: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private enum Phase: Equatable { case head, end, ready, handling, writing, closed }
    private enum StreamReadResult: Sendable { case chunk(Data?), failed }

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
    private var outboundStream: (any HLSRelayHTTPStreamingBody)?
    private var streamLength: Int64?
    private var streamBytes: Int64 = 0
    private var streamIdleSeconds: Int64 = 15
    private var streamChunk: Data?
    private var streamEOF = false
    private var streamReadID: UUID?
    private var streamReadTask: Task<Void, Never>?

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
        guard phase != .closed else { return }
        if phase == .writing {
            if outboundStream != nil { close() }
            return
        }
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
        case .writing:
            if outboundStream != nil { context.read() }
        case .closed: break
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
            let response: HLSRelayHTTPResponse
            do {
                try Task.checkCancellation()
                response = try await handler(request.path, request.method, request.headers)
            } catch {
                guard !Task.isCancelled else { return }
                response = HLSRelayHTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            guard !Task.isCancelled else { response.stream?.cancel(); return }
            channel.eventLoop.execute { [weak self] in
                guard let self else { response.stream?.cancel(); return }
                self.complete(response)
            }
        }
        runtime.store(task, for: id)
    }

    private func complete(_ response: HLSRelayHTTPResponse) {
        guard phase == .handling else { response.stream?.cancel(); return }
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
        guard let context, context.channel.isActive else { output.stream?.cancel(); close(); return }
        phase = .writing
        outboundBody = output.body
        outboundStream = output.stream
        if let stream = output.stream {
            // Use the already validated framing metadata, not a second length query on the reader.
            streamLength = output.head.headers.first(name: "Content-Length").flatMap { Int64($0) }
            streamIdleSeconds = min(300, max(1, stream.idleTimeoutSeconds))
        }
        offset = 0
        writePending = true
        armDeadline(seconds: outboundStream == nil ? 15 : streamIdleSeconds)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { [self] result in
            guard phase == .writing else { return }
            writePending = false
            if case .failure = result { close(); return }
            if outboundStream != nil { armDeadline(seconds: streamIdleSeconds) }
            scheduleWrite()
        }
        context.writeAndFlush(wrapOutboundOut(.head(output.head)), promise: promise)
        // Manual reads must continue during long responses to observe client EOF promptly.
        if phase == .writing, outboundStream != nil { context.read() }
    }

    private func scheduleWrite() {
        context?.eventLoop.execute { [weak self] in self?.writeNext() }
    }

    private func writeNext() {
        guard phase == .writing, !writePending, let context, context.channel.isActive,
            context.channel.isWritable
        else { return }
        if outboundStream != nil { writeStreamNext(context: context); return }
        guard let body = outboundBody else { return }
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

    private func writeStreamNext(context: ChannelHandlerContext) {
        guard streamReadID == nil, let stream = outboundStream else { return }
        if streamEOF {
            writePending = true
            armDeadline(seconds: streamIdleSeconds)
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [self] _ in close() }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
            return
        }
        if let chunk = streamChunk {
            streamChunk = nil
            writePending = true
            armDeadline(seconds: streamIdleSeconds)
            var buffer = context.channel.allocator.buffer(capacity: chunk.count)
            buffer.writeBytes(chunk)
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [self] result in
                guard phase == .writing else { return }
                writePending = false
                if case .failure = result { close(); return }
                armDeadline(seconds: streamIdleSeconds)
                scheduleWrite()
            }
            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
            return
        }

        let readID = UUID()
        streamReadID = readID
        let eventLoop = context.eventLoop
        // Only this task crosses executors; connection state and all NIO writes stay on the event loop.
        streamReadTask = Task.detached { [weak self] in
            let result: StreamReadResult
            do {
                let chunk = try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    let chunk = try await stream.nextChunk()
                    try Task.checkCancellation()
                    return chunk
                } onCancel: {
                    stream.cancel()
                }
                // Reject an oversized allocation before retaining it in the event-loop callback.
                if let chunk, chunk.count > 32 * 1024 {
                    result = .failed
                } else {
                    result = .chunk(chunk)
                }
            } catch {
                guard !Task.isCancelled else { return }
                result = .failed
            }
            guard !Task.isCancelled else { return }
            eventLoop.execute { [weak self] in self?.completeStreamRead(result, id: readID) }
        }
    }

    private func completeStreamRead(_ result: StreamReadResult, id: UUID) {
        guard phase == .writing, streamReadID == id else { return }
        streamReadID = nil
        streamReadTask = nil
        switch result {
        case .failed:
            close()
            return
        case .chunk(nil):
            guard streamLength == nil || streamBytes == streamLength else { close(); return }
            streamEOF = true
        case .chunk(.some(let chunk)):
            guard chunk.count <= 32 * 1024 else { close(); return }
            if chunk.isEmpty {
                // Empty reads are not EOF or progress and cannot extend the idle deadline.
                scheduleWrite()
                return
            }
            let (total, overflow) = streamBytes.addingReportingOverflow(Int64(chunk.count))
            guard !overflow else { close(); return }
            if let streamLength, total > streamLength { close(); return }
            streamBytes = total
            streamChunk = chunk
        }
        armDeadline(seconds: streamIdleSeconds)
        scheduleWrite()
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
        let readTask = streamReadTask
        let stream = outboundStream
        streamReadTask = nil
        streamReadID = nil
        outboundStream = nil
        streamChunk = nil
        readTask?.cancel()
        stream?.cancel()
    }
}
