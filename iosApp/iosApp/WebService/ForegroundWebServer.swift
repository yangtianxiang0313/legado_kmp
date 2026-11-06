import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import UIKit
import shared

@MainActor
final class ForegroundWebServer {
    static let shared = ForegroundWebServer()
    private var http: ForegroundWebHTTPRuntime?
    private var generation = UUID()
    private var token = ""
    private var allowsWrites = false
    private(set) var port: UInt16?
    private(set) var accessURL: URL?
    private(set) var isRunning = false
    var onChange: (() -> Void)?
    private var privacyObserver: NSObjectProtocol?
    private let sockets = ForegroundWebSocketServer()
    private let uploads = ForegroundWebUpload()

    private init() {
        privacyObserver = NotificationCenter.default.addObserver(forName: .appLockWillCover, object: nil, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    func start(localNetwork: Bool = false, allowsWrites: Bool = false, port: UInt16 = 0) throws {
        guard UIApplication.shared.applicationState == .active else { throw failure("仅可在前台启动服务") }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0.delegate as? SceneDelegate)?.window }).first,
            AppLockManager.shared.isUnlocked(in: window)
        else { throw failure("请先解锁应用") }
        stop()
        _ = try SharedRuntime.bootstrap().get()
        self.allowsWrites = allowsWrites
        token =
            UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let revision = generation
        let host = localNetwork ? (ForegroundWebAddress.localIPv4() ?? "127.0.0.1") : "127.0.0.1"
        let policy = ForegroundHTTPPolicy(token: token, allowsWrites: allowsWrites, hosts: ["127.0.0.1", "localhost", host])
        let runtime = ForegroundWebHTTPRuntime(policy: policy) { [weak self] request in
            guard let self else { return ForegroundHTTPResponse(status: 403, body: Data()) }
            return await self.respond(request, revision: revision)
        }
        http = runtime
        runtime.start(host: localNetwork ? "0.0.0.0" : "127.0.0.1", port: port) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == revision else { return }
                guard case .success(let port) = result else { self.stop(); return }
                self.port = port
                do {
                    try self.sockets.start(localNetwork: localNetwork, httpPort: port, token: self.token) { [weak self] in
                        guard let self, self.generation == revision else { return }
                        self.isRunning = true
                        self.accessURL = URL(string: "http://\(host):\(port)/#\(self.token)")
                        self.onChange?()
                    } onFailure: { [weak self] in
                        guard let self, self.generation == revision else { return }
                        self.stop()
                    }
                } catch { self.stop() }
                self.onChange?()
            }
        }
    }

    func stop() {
        generation = UUID()
        http?.cancel(); http = nil
        sockets.stop()
        uploads.stop()
        token = ""; port = nil; accessURL = nil; isRunning = false; allowsWrites = false
        onChange?()
    }

    private func respond(_ request: ForegroundHTTPRequest, revision: UUID) async -> ForegroundHTTPResponse {
        guard generation == revision, !Task.isCancelled else { return response(status: 403, body: Data()) }
        if request.method == "GET", let asset = ForegroundHTTPRequest.assets[request.path] {
            guard let url = Bundle.main.url(forResource: asset.name, withExtension: asset.suffix),
                let page = try? Data(contentsOf: url)
            else { return response(status: 500, body: Data()) }
            return response(body: page, type: asset.type)
        }
        guard request.token == "Bearer \(token)", !token.isEmpty else {
            return response(status: 401, body: Data())
        }
        let isRead = request.method == "GET" && request.path != "/refreshToc"
        guard isRead || (allowsWrites && (request.method == "POST" || request.method == "GET" && request.path == "/refreshToc")) else {
            return response(status: 403, body: Data())
        }
        do {
            if request.method == "POST", ["/prepareLocalBook", "/addLocalBook"].contains(request.path) {
                let file = try await ForegroundWebMultipart.decode(body: request.body, contentType: request.contentType)
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                let data: Data
                if request.path == "/prepareLocalBook" {
                    data = try await uploads.prepare(
                        fileName: file.fileName, data: file.data, uploadID: request.parameters["uploadId"])
                } else {
                    data = try await uploads.importDirect(fileName: file.fileName, data: file.data)
                }
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                return response(body: data)
            }
            if request.method == "POST", ["/commitLocalBook", "/discardLocalBook"].contains(request.path) {
                guard let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                    let uploadID = payload["uploadId"] as? String,
                    payload["entryPath"] == nil || payload["entryPath"] is String
                else { throw failure("缺少待导入文件编号") }
                let data: Data
                if request.path == "/commitLocalBook" {
                    data = try await uploads.commit(uploadID: uploadID, entryPath: payload["entryPath"] as? String)
                } else {
                    data = try await uploads.discard(uploadID: uploadID)
                }
                guard generation == revision else { throw CancellationError() }
                return response(body: data)
            }
            if request.method == "GET", request.path == "/getWebServiceInfo" {
                guard let socketPort = sockets.port else { throw failure("持续连接服务尚未就绪，请重试") }
                let value: [String: Any] = [
                    "isSuccess": true, "errorMsg": "", "data": ["socketPort": Int(socketPort), "allowsWrites": allowsWrites],
                ]
                return response(body: try JSONSerialization.data(withJSONObject: value))
            }
            if request.method == "GET", request.path == "/bookPDF" {
                guard let url = request.parameters["url"], !url.isEmpty else { throw failure("缺少书籍地址") }
                let data = try await ForegroundWebPDF.load(bookUrl: url)
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                return response(body: data, type: "application/pdf")
            }
            if request.method == "GET", request.path == "/getPDFInfo" || request.path == "/bookPDFPage" {
                guard let url = request.parameters["url"], !url.isEmpty else { throw failure("缺少书籍地址") }
                let data: Data
                if request.path == "/getPDFInfo" {
                    data = try await ForegroundWebPDF.info(bookUrl: url)
                } else {
                    guard let value = request.parameters["index"], let index = Int(value), index >= 0 else {
                        throw failure("PDF 页码无效")
                    }
                    data = try await ForegroundWebPDF.page(bookUrl: url, index: index)
                }
                try Task.checkCancellation()
                guard generation == revision else { throw CancellationError() }
                return response(body: data)
            }
            let facade = try ForegroundWebFacade.companion.create()
            let query = String(decoding: try JSONSerialization.data(withJSONObject: request.parameters), as: UTF8.self)
            guard let body = String(data: request.body, encoding: .utf8) else { throw failure("正文不是UTF8") }
            let value: String = try await SharedCancellableAsync.value { completion in
                facade.request(method: request.method, path: request.path, parameters: query, body: body) { response in
                    if response.cancelled {
                        completion(nil, CancellationError())
                    } else if let value = response.json {
                        completion(value, nil)
                    } else {
                        completion(nil, self.failure(response.error ?? "请求失败"))
                    }
                }
            }
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            return response(body: Data(value.utf8))
        } catch {
            let payload: [String: Any] = ["isSuccess": false, "errorMsg": error.userFacingMessage, "data": NSNull()]
            return response(status: 400, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }
    }

    private func response(
        status: Int = 200, body: Data, type: String = "application/json; charset=utf-8"
    ) -> ForegroundHTTPResponse {
        var socketOrigins = ""
        if let socketPort = sockets.port {
            let hosts = Set(["127.0.0.1", "localhost", ForegroundWebAddress.localIPv4() ?? "127.0.0.1"])
            socketOrigins = hosts.sorted().map { " ws://\($0):\(socketPort)" }.joined()
        }
        return ForegroundHTTPResponse(
            status: status, body: body,
            headers: [
                "Content-Type": type, "Referrer-Policy": "no-referrer", "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy":
                    "default-src 'self'; connect-src 'self'\(socketOrigins); img-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; frame-src blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'",
            ])
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Owns only this HTTP listener, its bounded connections and their cancellable request tasks.
final class ForegroundWebHTTPRuntime: @unchecked Sendable {
    typealias Handler = @Sendable (ForegroundHTTPRequest) async -> ForegroundHTTPResponse
    let policy: ForegroundHTTPPolicy
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var handler: Handler?
    private var listener: Channel?
    private var children: [UUID: Channel] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var binding = true
    private var cancelled = false
    private var shutdownStarted = false

    init(policy: ForegroundHTTPPolicy, handler: @escaping Handler) {
        self.policy = policy
        self.handler = handler
    }

    func start(host: String, port: UInt16, completion: @escaping @Sendable (Result<UInt16, Error>) -> Void) {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 4)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .serverChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
            .childChannelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 32 * 1024))
            .childChannelOption(ChannelOptions.writeBufferWaterMark, value: .init(low: 32 * 1024, high: 64 * 1024))
            .childChannelInitializer { [self] channel in configure(channel) }
            .bind(host: host, port: Int(port)).whenComplete { [self] result in
                let channel = try? result.get()
                lock.lock()
                binding = false
                listener = channel
                let accepted = !cancelled && channel != nil
                lock.unlock()
                guard accepted, let channel, let number = channel.localAddress?.port,
                    let boundPort = UInt16(exactly: number), boundPort > 0
                else {
                    cancel()
                    completion(.failure(ForegroundHTTPFailure.request(503)))
                    return
                }
                channel.closeFuture.whenComplete { _ in completion(.failure(ForegroundHTTPFailure.request(503))) }
                completion(.success(boundPort))
            }
    }

    private func configure(_ channel: Channel) -> EventLoopFuture<Void> {
        let id = UUID()
        lock.lock()
        let accepted = !cancelled && children.count < 4
        if accepted { children[id] = channel }
        lock.unlock()
        guard accepted else { return channel.eventLoop.makeFailedFuture(ForegroundHTTPFailure.request(429)) }
        channel.closeFuture.whenComplete { [weak self] _ in self?.remove(id) }
        var limits = NIOHTTPDecoderLimitConfiguration()
        limits.maxHeaderFieldSize = 16 * 1024
        limits.maxHeaderListSize = 16 * 1024
        limits.maxHeaderFieldCount = 64
        return channel.pipeline.addHandler(ForegroundHTTPIngressLimit()).flatMap {
            channel.pipeline.configureHTTPServerPipeline(
                withPipeliningAssistance: false, withErrorHandling: false, withDecoderLimitConfiguration: limits)
        }.flatMap {
            channel.pipeline.addHandler(ForegroundHTTPConnection(runtime: self, id: id))
        }
    }

    func requestHandler(for id: UUID) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && children[id] != nil ? handler : nil
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
        let task = tasks.removeValue(forKey: id)
        lock.unlock()
        task?.cancel()
    }

    func cancel() {
        lock.lock()
        guard !cancelled || (!binding && !shutdownStarted) else { lock.unlock(); return }
        cancelled = true
        handler = nil
        let channels = Array(children.values) + (listener.map { [$0] } ?? [])
        let tasks = Array(self.tasks.values)
        self.tasks.removeAll()
        listener = nil
        let shutdown = !binding && !shutdownStarted
        if shutdown { shutdownStarted = true }
        lock.unlock()
        tasks.forEach { $0.cancel() }
        let closes = channels.map { $0.close() }
        if shutdown {
            let group = self.group
            EventLoopFuture.andAllComplete(closes, on: group.next()).whenComplete { _ in
                group.shutdownGracefully(queue: .global(qos: .utility)) { _ in }
            }
        }
    }
}