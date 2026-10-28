import Foundation
import Network
import UIKit
import shared

@MainActor
final class ForegroundWebServer {
    static let shared = ForegroundWebServer()
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var token = ""
    private var allowsWrites = false
    private(set) var port: UInt16?
    private(set) var accessURL: URL?
    private(set) var isRunning = false
    var onChange: (() -> Void)?
    private var privacyObserver: NSObjectProtocol?
    private let sockets = ForegroundWebSocketServer()

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
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(localNetwork ? .any : .loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let revision = generation
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.generation == revision else { return }
                if case .ready = state {
                    self.port = listener.port?.rawValue
                    if let port = self.port {
                        let host = localNetwork ? (ForegroundWebAddress.localIPv4() ?? "127.0.0.1") : "127.0.0.1"
                        do {
                            try self.sockets.start(localNetwork: localNetwork, httpPort: port, token: self.token) { [weak self] in
                                guard let self, self.generation == revision else { return }
                                self.isRunning = true
                                self.accessURL = URL(string: "http://\(host):\(port)/#\(self.token)")
                                self.onChange?()
                            } onFailure: { [weak self] in
                                self?.stop()
                            }
                        } catch { self.stop() }
                    }
                    self.onChange?()
                } else if case .failed = state {
                    self.stop()
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == revision, self.clients.count < 4 else { connection.cancel(); return }
                self.accept(connection, revision: revision)
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        listener?.cancel(); listener = nil
        clients.values.forEach { $0.cancel() }; clients.removeAll()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        sockets.stop()
        token = ""; port = nil; accessURL = nil; isRunning = false
        onChange?()
    }

    private func accept(_ connection: NWConnection, revision: UUID) {
        let id = UUID()
        clients[id] = connection
        connection.start(queue: .main)
        let parser = ForegroundHTTPParser()
        receive(connection, id: id, revision: revision, parser: parser)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak connection] in
            guard let self, self.clients[id] === connection else { return }
            self.finish(id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, revision: UUID, parser: ForegroundHTTPParser) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == revision, self.clients[id] === connection else { return }
                do {
                    if let data, !data.isEmpty, let request = try parser.append(data) {
                        self.tasks[id] = Task { [weak self] in await self?.respond(request, id: id, revision: revision) }
                    } else if complete || error != nil {
                        self.finish(id)
                    } else {
                        self.receive(connection, id: id, revision: revision, parser: parser)
                    }
                } catch { self.send(id: id, status: 400, body: Data("Bad Request".utf8)) }
            }
        }
    }

    private func respond(_ request: ForegroundHTTPRequest, id: UUID, revision: UUID) async {
        guard generation == revision, validHost(request.host),
            request.origin == nil || request.origin == "http://\(request.host)"
        else { send(id: id, status: 403, body: Data("Forbidden".utf8)); return }
        let assets: [String: (String, String, String)] = [
            "/": ("ForegroundWeb", "html", "text/html; charset=utf-8"),
            "/ForegroundWebReading.js": ("ForegroundWebReading", "js", "text/javascript; charset=utf-8"),
            "/ForegroundWebStream.js": ("ForegroundWebStream", "js", "text/javascript; charset=utf-8"),
            "/ForegroundWebWorkbench.js": ("ForegroundWebWorkbench", "js", "text/javascript; charset=utf-8"),
        ]
        if request.method == "GET", let asset = assets[request.path] {
            guard let url = Bundle.main.url(forResource: asset.0, withExtension: asset.1),
                let page = try? Data(contentsOf: url)
            else { send(id: id, status: 500, body: Data()); return }
            send(id: id, status: 200, body: page, type: asset.2)
            return
        }
        guard request.token == "Bearer \(token)", !token.isEmpty else {
            send(id: id, status: 401, body: Data("Unauthorized".utf8)); return
        }
        let isRead = request.method == "GET" && request.path != "/refreshToc"
        guard isRead || ((request.method == "POST" || request.path == "/refreshToc") && allowsWrites) else {
            send(id: id, status: 403, body: Data("Read Only".utf8)); return
        }
        do {
            if request.method == "GET", request.path == "/getWebServiceInfo" {
                guard let socketPort = sockets.port else { throw failure("持续连接服务尚未就绪，请重试") }
                let value: [String: Any] = [
                    "isSuccess": true, "errorMsg": "", "data": ["socketPort": Int(socketPort), "allowsWrites": allowsWrites],
                ]
                send(id: id, status: 200, body: try JSONSerialization.data(withJSONObject: value))
                return
            }
            if request.method == "GET", request.path == "/bookPDF" {
                guard let url = request.parameters["url"], !url.isEmpty else { throw failure("缺少书籍地址") }
                let data = try await ForegroundWebPDF.load(bookUrl: url)
                guard !Task.isCancelled, generation == revision else { return }
                send(id: id, status: 200, body: data, type: "application/pdf")
                return
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
                guard !Task.isCancelled, generation == revision else { return }
                send(id: id, status: 200, body: data)
                return
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
            guard !Task.isCancelled, generation == revision else { return }
            send(id: id, status: 200, body: Data(value.utf8))
        } catch {
            guard generation == revision else { return }
            let payload: [String: Any] = ["isSuccess": false, "errorMsg": error.userFacingMessage, "data": NSNull()]
            send(id: id, status: 400, body: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }
    }

    private func validHost(_ host: String) -> Bool {
        guard let port, let components = URLComponents(string: "http://\(host)"), components.port == Int(port),
            components.user == nil, components.password == nil, components.path.isEmpty,
            components.query == nil, components.fragment == nil, let address = components.host
        else { return false }
        if address == "127.0.0.1" || address == "localhost" { return true }
        let bytes = address.split(separator: ".").compactMap { UInt8($0) }
        return bytes.count == 4
            && (bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254))
    }

    private func send(id: UUID, status: Int, body: Data, type: String = "application/json; charset=utf-8") {
        guard let connection = clients[id] else { return }
        var socketOrigins = ""
        if let socketPort = sockets.port {
            let hosts = Set(["127.0.0.1", "localhost", ForegroundWebAddress.localIPv4() ?? "127.0.0.1"])
            socketOrigins = hosts.sorted().map { " ws://\($0):\(socketPort)" }.joined()
        }
        let header =
            "HTTP/1.1 \(status) Response\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; connect-src 'self'\(socketOrigins); img-src 'self' data: blob:; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; frame-src blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'\r\n\r\n"
        connection.send(
            content: Data(header.utf8) + body,
            completion: .contentProcessed { [weak self] _ in
                Task { @MainActor in self?.finish(id) }
            })
    }

    private func finish(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
