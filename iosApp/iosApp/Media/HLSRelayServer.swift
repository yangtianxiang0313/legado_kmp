import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

struct HLSRelayHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

/// A session-owned, IPv4 loopback-only HTTP endpoint. No shared server or LAN access policy is used.
final class HLSRelayServer: @unchecked Sendable {
    typealias Handler =
        @Sendable (_ path: String, _ method: String, _ headers: [String: String]) async throws
        -> HLSRelayHTTPResponse

    let baseURL: URL
    private let runtime: HLSRelayHTTPRuntime

    private init(baseURL: URL, runtime: HLSRelayHTTPRuntime) {
        self.baseURL = baseURL
        self.runtime = runtime
    }

    /// The handler receives an undecoded origin-form path and a validated lowercase range header only.
    /// The owning session must authenticate the opaque path and rewrite all playlist URLs itself.
    static func start(handler: @escaping Handler) async throws -> HLSRelayServer {
        let runtime = HLSRelayHTTPRuntime(handler: handler)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let address = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
                let listener = try await ServerBootstrap(group: runtime.group)
                    .serverChannelOption(ChannelOptions.backlog, value: 4)
                    .serverChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                    .childChannelOption(ChannelOptions.autoRead, value: false)
                    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
                    .childChannelOption(
                        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 8 * 1024)
                    )
                    .childChannelOption(
                        ChannelOptions.writeBufferWaterMark, value: .init(low: 16 * 1024, high: 64 * 1024)
                    )
                    .childChannelInitializer { channel in runtime.configure(channel) }
                    .bind(to: address).get()
                guard runtime.finishBinding(listener),
                    listener.localAddress?.ipAddress == "127.0.0.1",
                    let port = listener.localAddress?.port, port > 0,
                    let url = URL(string: "http://127.0.0.1:\(port)/")
                else { throw HLSRelayHTTPFailure.unavailable }
                try Task.checkCancellation()
                return HLSRelayServer(baseURL: url, runtime: runtime)
            } catch {
                runtime.finishBinding(nil)
                runtime.cancel()
                if Task.isCancelled { throw CancellationError() }
                // Do not expose NIO errors, addresses, or request details to callers.
                throw HLSRelayHTTPFailure.unavailable
            }
        } onCancel: {
            runtime.cancel()
        }
    }

    /// Thread-safe, idempotent, and nonblocking, including from deinit or a NIO event loop.
    func cancel() { runtime.cancel() }

    deinit { runtime.cancel() }
}

enum HLSRelayHTTPFailure: Error {
    case unavailable
    case request(Int)
}

/// The lock protects ownership only. NIO operations and Task cancellation always happen outside it.
final class HLSRelayHTTPRuntime: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var handler: HLSRelayServer.Handler?
    private var listener: Channel?
    private var children: [UUID: Channel] = [:]
    private var rejection: (id: UUID, channel: Channel)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var binding = true
    private var cancelled = false
    private var shutdownStarted = false

    init(handler: @escaping HLSRelayServer.Handler) { self.handler = handler }

    @discardableResult
    func finishBinding(_ channel: Channel?) -> Bool {
        lock.lock()
        binding = false
        if let channel { listener = channel }
        let accepted = !cancelled && channel != nil
        lock.unlock()
        if !accepted { cancel() }
        return accepted
    }

    func configure(_ channel: Channel) -> EventLoopFuture<Void> {
        guard channel.localAddress?.ipAddress == "127.0.0.1",
            channel.remoteAddress?.ipAddress == "127.0.0.1", let port = channel.localAddress?.port
        else { return channel.eventLoop.makeFailedFuture(HLSRelayHTTPFailure.unavailable) }

        let id = UUID()
        lock.lock()
        let admitted = !cancelled && children.count < 4
        // One bounded, transient 429 writer; further excess sockets are immediately closed by bootstrap.
        let canReject = !cancelled && !admitted && rejection == nil
        if admitted { children[id] = channel }
        if canReject { rejection = (id, channel) }
        lock.unlock()
        guard admitted || canReject else {
            return channel.eventLoop.makeFailedFuture(HLSRelayHTTPFailure.unavailable)
        }
        channel.closeFuture.whenComplete { [weak self] _ in self?.remove(id) }

        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = 16 * 1024
        limits.maxHeaderListSize = 16 * 1024
        limits.maxHeaderFieldCount = 64
        return channel.pipeline.addHandler(HLSRelayHTTPIngressLimit())
            .flatMap {
                channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false, withErrorHandling: false,
                    withDecoderLimitConfiguration: limits)
            }
            .flatMap {
                channel.pipeline.addHandler(
                    HLSRelayHTTPConnection(
                        runtime: self, id: id, host: "127.0.0.1:\(port)", overloaded: !admitted))
            }
    }

    func requestHandler(for id: UUID) -> HLSRelayServer.Handler? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, children[id] != nil else { return nil }
        return handler
    }

    func store(_ task: Task<Void, Never>, for id: UUID) {
        lock.lock()
        let accepted = !cancelled && children[id] != nil
        if accepted { tasks[id] = task }
        lock.unlock()
        if !accepted { task.cancel() }
    }

    func cancelTask(for id: UUID) {
        lock.lock()
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        children.removeValue(forKey: id)
        if rejection?.id == id { rejection = nil }
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    func cancel() {
        lock.lock()
        guard !cancelled || (!binding && !shutdownStarted) else { lock.unlock(); return }
        cancelled = true
        handler = nil
        let channels = Array(children.values) + (rejection.map { [$0.channel] } ?? [])
        let listener = self.listener
        let tasks = Array(self.tasks.values)
        self.listener = nil
        self.tasks.removeAll()
        let shutdown = !binding && !shutdownStarted
        if shutdown { shutdownStarted = true }
        lock.unlock()

        tasks.forEach { $0.cancel() }
        let closes = (channels + (listener.map { [$0] } ?? [])).map { $0.close() }
        if shutdown {
            let group = self.group
            EventLoopFuture.andAllComplete(closes, on: group.next()).whenComplete { _ in
                group.shutdownGracefully(queue: .global(qos: .utility)) { _ in }
            }
        }
    }
}
