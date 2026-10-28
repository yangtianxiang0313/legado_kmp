import Foundation
import Network
import shared

/// Network.framework owns the upgrade, masking, fragmentation, ping and close protocol.
@MainActor
final class ForegroundWebSocketServer {
    private final class Client {
        let connection: NWConnection
        var operation = UUID()
        var subscription: FlowSubscription?
        var queue: [Message] = []
        var queuedBytes = 0
        var totalBytes = 0
        var sending = false
        var closing = false
        var channel: String?

        init(_ connection: NWConnection) { self.connection = connection }
    }

    private struct Message {
        let id = UUID()
        let data: Data
        let close: Bool
    }

    private let channels = Set(["searchBook", "bookSourceDebug", "rssSourceDebug"])
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var generation = UUID()
    private(set) var port: UInt16?

    func start(
        localNetwork: Bool, httpPort: UInt16, token: String, onReady: @escaping () -> Void, onFailure: @escaping () -> Void
    )
        throws
    {
        stop()
        let revision = generation
        let hosts = Set(["127.0.0.1", "localhost", localNetwork ? ForegroundWebAddress.localIPv4() ?? "127.0.0.1" : "127.0.0.1"])
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 256 * 1024
        options.setClientRequestHandler(.main) { [weak self] protocols, headers in
            MainActor.assumeIsolated {
                let protocols = protocols.map { $0.trimmingCharacters(in: .whitespaces) }
                guard let self, self.generation == revision, self.port != nil,
                    protocols.count == 2, Set(protocols).count == 2, protocols.contains("legado." + token),
                    let selected = protocols.first(where: {
                        self.channels.contains(String($0.dropFirst(7))) && $0.hasPrefix("legado.")
                    }),
                    self.validHeaders(headers, hosts: hosts, httpPort: httpPort)
                else { return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil) }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: selected)
            }
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localNetwork ? .any : .loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.generation == revision else { return }
                if case .ready = state {
                    self.port = listener.port?.rawValue
                    onReady()
                } else if case .failed = state {
                    self.stop()
                    onFailure()
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
        listener?.cancel()
        listener = nil
        for client in clients.values {
            client.subscription?.cancel()
            client.connection.cancel()
        }
        clients.removeAll()
        port = nil
    }

    private func validHeaders(_ headers: [(name: String, value: String)], hosts: Set<String>, httpPort: UInt16) -> Bool {
        guard headers.count <= 64, headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16 * 1024 else {
            return false
        }
        let origins = headers.filter { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
        guard origins.count <= 1 else { return false }
        if let origin = origins.first?.value {
            guard let value = URLComponents(string: origin), value.scheme == "http", value.port == Int(httpPort),
                value.user == nil, value.password == nil, value.query == nil, value.fragment == nil, value.path.isEmpty,
                let host = value.host, hosts.contains(host)
            else { return false }
        }
        // Some OS releases omit standard handshake headers from additionalHeaders.
        let authorities = headers.filter { $0.name.caseInsensitiveCompare("Host") == .orderedSame }
        guard authorities.count <= 1 else { return false }
        if let authority = authorities.first?.value {
            guard let value = URLComponents(string: "http://" + authority), value.port == port.map(Int.init),
                value.user == nil, value.password == nil, value.path.isEmpty, value.query == nil, value.fragment == nil,
                let host = value.host, hosts.contains(host)
            else { return false }
        }
        return true
    }

    private func accept(_ connection: NWConnection, revision: UUID) {
        let id = UUID()
        let client = Client(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            Task { @MainActor in
                guard let self, let client, self.generation == revision, self.clients[id] === client else { return }
                switch state {
                case .ready:
                    let metadata =
                        connection.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    guard let selected = metadata?.selectedSubprotocol, selected.hasPrefix("legado."),
                        self.channels.contains(String(selected.dropFirst(7)))
                    else { self.finish(id); return }
                    client.channel = String(selected.dropFirst(7))
                    self.receive(id, revision: revision)
                case .failed, .cancelled: self.finish(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak client] in
            guard let self, let client, self.clients[id] === client, client.subscription == nil else { return }
            self.finish(id)
        }
    }

    private func receive(_ id: UUID, revision: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receiveMessage { [weak self, weak client] data, context, complete, error in
            Task { @MainActor in
                guard let self, let client, self.generation == revision, self.clients[id] === client else { return }
                guard error == nil,
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                        as? NWProtocolWebSocket.Metadata
                else { self.finish(id); return }
                switch metadata.opcode {
                case .close: self.finish(id); return
                case .ping, .pong: break
                case .text:
                    guard complete, let data, data.count <= 256 * 1024, let body = String(data: data, encoding: .utf8) else {
                        self.close(id, reason: "请求必须为 UTF8 JSON 文本"); return
                    }
                    self.request(body, id: id, client: client, revision: revision)
                default: self.close(id, reason: "仅支持文本请求"); return
                }
                if !client.closing { self.receive(id, revision: revision) }
            }
        }
    }

    private func request(_ body: String, id: UUID, client: Client, revision: UUID) {
        guard !client.closing, let channel = client.channel else { return }
        client.subscription?.cancel()
        client.operation = UUID()
        client.queue.removeAll()
        client.queuedBytes = 0
        let operation = client.operation
        do {
            let facade = try ForegroundWebStreamFacade.companion.create()
            client.subscription = facade.request(path: "/" + channel, body: body) { [weak self, weak client] event in
                Task { @MainActor in
                    guard let self, let client, self.generation == revision, self.clients[id] === client,
                        client.operation == operation, !client.closing
                    else { return }
                    if let text = event.text { self.enqueue(text, id: id) }
                    if let reason = event.closeReason { self.close(id, reason: reason) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self, weak client] in
                guard let self, let client, self.clients[id] === client, client.operation == operation else { return }
                self.close(id, reason: "请求超时")
            }
        } catch { enqueue(error.userFacingMessage, id: id); close(id, reason: "请求失败") }
    }

    private func enqueue(_ text: String, id: UUID) {
        guard let client = clients[id], !client.closing else { return }
        let data = Data(text.utf8)
        guard data.count <= 8 * 1024 * 1024, client.queuedBytes + data.count <= 8 * 1024 * 1024,
            client.totalBytes + data.count <= 32 * 1024 * 1024
        else { close(id, reason: "输出超过限制，请缩小搜索或调试范围"); return }
        client.totalBytes += data.count
        client.queuedBytes += data.count
        client.queue.append(Message(data: data, close: false))
        drain(id)
    }

    private func close(_ id: UUID, reason: String) {
        guard let client = clients[id], !client.closing else { return }
        client.closing = true
        client.subscription?.cancel()
        client.subscription = nil
        let text = String(reason.prefix(30))
        client.queue.append(Message(data: Data(text.utf8), close: true))
        drain(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak client] in
            guard let self, let client, self.clients[id] === client else { return }
            self.finish(id)
        }
    }

    private func drain(_ id: UUID) {
        guard let client = clients[id], !client.sending, let message = client.queue.first else { return }
        client.sending = true
        let metadata = NWProtocolWebSocket.Metadata(opcode: message.close ? .close : .text)
        if message.close { metadata.closeCode = .protocolCode(.normalClosure) }
        let context = NWConnection.ContentContext(identifier: message.id.uuidString, metadata: [metadata])
        client.connection.send(
            content: message.data, contentContext: context, isComplete: true,
            completion: .contentProcessed {
                [weak self, weak client] error in
                Task { @MainActor in
                    guard let self, let client, self.clients[id] === client else { return }
                    client.sending = false
                    if error != nil || message.close { self.finish(id); return }
                    if client.queue.first?.id == message.id {
                        client.queue.removeFirst()
                        client.queuedBytes -= message.data.count
                    }
                    self.drain(id)
                }
            })
    }

    private func finish(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.subscription?.cancel()
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }
}
