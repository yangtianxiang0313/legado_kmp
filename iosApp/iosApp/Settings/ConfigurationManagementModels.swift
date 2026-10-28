import Foundation
import shared

enum ConfigurationManagementCategory: String, CaseIterable {
    case subscriptions, servers, speechEngines, keyboardAssists

    var title: String {
        switch self {
        case .subscriptions: return "规则订阅"
        case .servers: return "远程服务器"
        case .speechEngines: return "HTTP 朗读引擎"
        case .keyboardAssists: return "编辑器键盘辅助"
        }
    }

    func load(using facade: BackupCapabilitiesFacade) async throws -> [ConfigurationManagementRecord] {
        switch self {
        case .subscriptions:
            let items: [RuleSub] = try await SharedAsync.value { facade.loadSubscriptions(completionHandler: $0) }
            return items.map(ConfigurationManagementRecord.subscription)
        case .servers:
            let items: [Server] = try await SharedAsync.value { facade.loadServers(completionHandler: $0) }
            return items.map(ConfigurationManagementRecord.server)
        case .speechEngines:
            let items: [HttpTTS] = try await SharedAsync.value { facade.loadSpeechEngines(completionHandler: $0) }
            return items.map(ConfigurationManagementRecord.speechEngine)
        case .keyboardAssists:
            let items: [KeyboardAssist] = try await SharedAsync.value { facade.loadAllKeyboardAssists(completionHandler: $0) }
            return items.map(ConfigurationManagementRecord.keyboardAssist)
        }
    }
}

enum ConfigurationManagementRecord {
    case subscription(RuleSub), server(Server), speechEngine(HttpTTS), keyboardAssist(KeyboardAssist)

    var identity: String {
        switch self {
        case let .subscription(item): return "subscription.\(item.id)"
        case let .server(item): return "server.\(item.id)"
        case let .speechEngine(item): return "speechEngine.\(item.id)"
        case let .keyboardAssist(item): return "keyboardAssist.\(item.type).\(item.key)"
        }
    }

    var name: String {
        switch self {
        case let .subscription(item): return item.name
        case let .server(item): return item.name
        case let .speechEngine(item): return item.name
        case let .keyboardAssist(item): return item.key
        }
    }

    var summary: String {
        switch self {
        case let .subscription(item):
            let type = [Int32(0): "书源", 1: "RSS 源", 2: "净化规则"][item.type] ?? "类型 \(item.type)"
            return type + (item.autoUpdate ? " · 自动更新" : "")
        case .server: return "WebDAV"
        case let .speechEngine(item): return item.contentType?.isEmpty == false ? item.contentType! : "HTTP TTS"
        case let .keyboardAssist(item): return "类型 \(item.type) · 排序 \(item.serialNo)\n\(item.value)"
        }
    }

    var order: Int32 {
        switch self {
        case let .subscription(item): return item.customOrder
        case let .server(item): return item.sortNumber
        case let .keyboardAssist(item): return item.serialNo
        case .speechEngine: return 0
        }
    }

    func save(using facade: BackupCapabilitiesFacade, original: ConfigurationManagementRecord?) async throws
        -> ConfigurationManagementRecord
    {
        switch self {
        case let .subscription(item):
            let saved: RuleSub = try await SharedAsync.value {
                facade.saveSubscription(subscription: item, isNew: original == nil, completionHandler: $0)
            }
            return .subscription(saved)
        case let .server(item):
            let saved: Server = try await SharedAsync.value {
                facade.saveServer(server: item, isNew: original == nil, completionHandler: $0)
            }
            return .server(saved)
        case let .speechEngine(item):
            let saved: HttpTTS = try await SharedAsync.value {
                facade.saveSpeechEngine(engine: item, isNew: original == nil, completionHandler: $0)
            }
            return .speechEngine(saved)
        case let .keyboardAssist(item):
            var originalType = item.type
            var originalKey: String?
            if case let .keyboardAssist(old) = original {
                originalType = old.type
                originalKey = old.key
            }
            let saved: KeyboardAssist = try await SharedAsync.value {
                facade.saveKeyboardAssist(
                    assist: item, originalType: originalType, originalKey: originalKey,
                    isNew: original == nil, completionHandler: $0)
            }
            return .keyboardAssist(saved)
        }
    }

    func delete(using facade: BackupCapabilitiesFacade) async throws {
        switch self {
        case let .subscription(item):
            try await SharedAsync.void { facade.deleteSubscription(id: item.id, completionHandler: $0) }
        case let .server(item):
            try await SharedAsync.void { facade.deleteServer(id: item.id, completionHandler: $0) }
        case let .speechEngine(item):
            try await SharedAsync.void { facade.deleteSpeechEngine(id: item.id, completionHandler: $0) }
        case let .keyboardAssist(item):
            try await SharedAsync.void { facade.deleteKeyboardAssist(type: item.type, key: item.key, completionHandler: $0) }
        }
    }
}

/// The persisted object has Server.WebDavConfig's url/username/password keys.
/// Retain unrecognized keys and the original serialization when no config field changed.
struct ConfigurationManagementWebDavConfig {
    private var document: [String: Any]
    let originalJSON: String?
    let isMalformed: Bool

    init(json: String?) {
        originalJSON = json
        if let json, !json.isEmpty {
            if let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
                let dictionary = object as? [String: Any]
            {
                document = dictionary
                isMalformed = ["url", "username", "password"].contains {
                    dictionary[$0] != nil && !(dictionary[$0] is String)
                }
            } else {
                document = [:]
                isMalformed = true
            }
        } else {
            document = [:]
            isMalformed = false
        }
    }

    var url: String { document["url"] as? String ?? "" }
    var username: String { document["username"] as? String ?? "" }
    var password: String { document["password"] as? String ?? "" }

    func encoded(url: String, username: String, password: String) throws -> String {
        if !isMalformed, url == self.url, username == self.username, password == self.password,
            let originalJSON
        {
            return originalJSON
        }
        let config = Server.WebDavConfig(url: url, username: username, password: password)
        var updated = document
        updated["url"] = config.url
        updated["username"] = config.username
        updated["password"] = config.password
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
