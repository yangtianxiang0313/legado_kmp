import UIKit
import shared

struct ConfigurationEditorField {
    enum Kind {
        case text(UIKeyboardType), multiline, password, toggle, options([(String, String)])
    }

    let key: String
    let title: String
    let kind: Kind

    init(_ key: String, _ title: String, _ kind: Kind = .text(.default)) {
        self.key = key
        self.title = title
        self.kind = kind
    }
}

struct ConfigurationEditorSection {
    let title: String
    var fields: [ConfigurationEditorField]
    var footer: String? = nil
}

struct ConfigurationEditorDraft {
    let category: ConfigurationManagementCategory
    let original: ConfigurationManagementRecord?
    var text: [String: String] = [:]
    var switches: [String: Bool] = [:]

    init(category: ConfigurationManagementCategory, original: ConfigurationManagementRecord?, nextOrder: Int32) {
        self.category = category
        self.original = original
        text["order"] = String(nextOrder)
        text["type"] = "0"
        text["serverType"] = "webdav"
        text["concurrentRate"] = "0"
        switch original {
        case let .subscription(item):
            text.merge(["name": item.name, "url": item.url, "type": String(item.type), "order": String(item.customOrder)]) {
                _, new in new
            }
            switches["autoUpdate"] = item.autoUpdate
        case let .server(item):
            let config = ConfigurationManagementWebDavConfig(json: item.config)
            text.merge([
                "name": item.name, "url": config.url, "username": config.username,
                "password": config.password, "order": String(item.sortNumber),
            ]) { _, new in new }
        case let .speechEngine(item):
            text["name"] = item.name
            text["url"] = item.url
            text["contentType"] = item.contentType ?? ""
            text["concurrentRate"] = item.concurrentRate ?? ""
            text["loginUrl"] = item.loginUrl ?? ""
            text["loginUi"] = item.loginUi ?? ""
            text["header"] = item.header ?? ""
            text["jsLib"] = item.jsLib ?? ""
            text["loginCheckJs"] = item.loginCheckJs ?? ""
            switches["enabledCookieJar"] = item.enabledCookieJar
        case let .keyboardAssist(item):
            text.merge([
                "type": String(item.type), "key": item.key, "value": item.value,
                "order": String(item.serialNo),
            ]) { _, new in new }
        case nil: break
        }
    }

    var sections: [ConfigurationEditorSection] {
        switch category {
        case .subscriptions:
            var options = [("0", "书源"), ("1", "RSS 源"), ("2", "净化规则")]
            if !options.contains(where: { $0.0 == value("type") }) {
                options.append((value("type"), "类型 \(value("type"))"))
            }
            return [
                ConfigurationEditorSection(
                    title: "订阅",
                    fields: [
                        .init("name", "名称"), .init("url", "订阅 URL", .text(.URL)),
                        .init("type", "订阅类型", .options(options)),
                        .init("autoUpdate", "启动时自动更新", .toggle),
                    ])
            ]
        case .servers:
            var warning: String?
            if case let .server(item) = original,
                ConfigurationManagementWebDavConfig(json: item.config).isMalformed
            {
                warning = "原 WebDAV 配置无效，保存将用以下字段重新生成配置。"
            }
            return [
                ConfigurationEditorSection(
                    title: "服务器",
                    fields: [
                        .init("name", "名称"), .init("serverType", "类型", .options([("webdav", "WebDAV")])),
                    ]),
                ConfigurationEditorSection(
                    title: "WebDAV",
                    fields: [
                        .init("url", "URL", .text(.URL)), .init("username", "用户名", .text(.asciiCapable)),
                        .init("password", "密码", .password),
                    ], footer: warning),
            ]
        case .speechEngines:
            return [
                ConfigurationEditorSection(
                    title: "朗读引擎",
                    fields: [
                        .init("name", "名称"), .init("url", "请求 URL / 规则", .multiline),
                        .init("contentType", "音频 Content-Type", .text(.asciiCapable)),
                        .init("concurrentRate", "并发率", .text(.asciiCapable)),
                    ]),
                ConfigurationEditorSection(
                    title: "请求与脚本",
                    fields: [
                        .init("header", "请求头", .multiline), .init("jsLib", "JavaScript 库", .multiline),
                        .init("enabledCookieJar", "启用 Cookie 管理", .toggle),
                    ]),
                ConfigurationEditorSection(
                    title: "登录",
                    fields: [
                        .init("loginUrl", "登录 URL / 规则", .multiline), .init("loginUi", "登录界面", .multiline),
                        .init("loginCheckJs", "登录检查 JavaScript", .multiline),
                    ]),
            ]
        case .keyboardAssists:
            return [
                ConfigurationEditorSection(
                    title: "辅助按键",
                    fields: [
                        .init("key", "按键名称（key）"), .init("value", "插入内容（value）", .multiline),
                        .init("type", "类型", .text(.numbersAndPunctuation)),
                    ])
            ]
        }
    }

    func value(_ key: String) -> String { text[key] ?? "" }

    func makeRecord() throws -> ConfigurationManagementRecord {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        switch category {
        case .subscriptions:
            var old: RuleSub?
            if case let .subscription(item) = original { old = item }
            try require("name", title: "名称")
            try requireHTTPURL("url", title: "订阅 URL")
            return .subscription(
                RuleSub(
                    id: old?.id ?? 0, name: value("name"), url: value("url"), type: try integer("type", title: "订阅类型"),
                    customOrder: try integer("order", title: "排序"), autoUpdate: switches["autoUpdate"] ?? false,
                    update: old?.update ?? now
                ))
        case .servers:
            var old: Server?
            if case let .server(item) = original { old = item }
            try require("name", title: "名称")
            try requireHTTPURL("url", title: "WebDAV URL")
            let config = try ConfigurationManagementWebDavConfig(json: old?.config).encoded(
                url: value("url"), username: value("username"), password: value("password")
            )
            return .server(
                Server(
                    id: old?.id ?? 0, name: value("name"), type: old?.type ?? .webdav,
                    config: config, sortNumber: try integer("order", title: "排序")))
        case .speechEngines:
            var old: HttpTTS?
            if case let .speechEngine(item) = original { old = item }
            try require("name", title: "名称")
            // Legado request rules may contain templates, scripts and request options.
            try require("url", title: "请求 URL / 规则")
            return .speechEngine(
                HttpTTS(
                    id: old?.id ?? 0, name: value("name"), url: value("url"),
                    contentType: nullable("contentType", old: old?.contentType),
                    concurrentRate: nullable("concurrentRate", old: old?.concurrentRate),
                    loginUrl: nullable("loginUrl", old: old?.loginUrl), loginUi: nullable("loginUi", old: old?.loginUi),
                    header: nullable("header", old: old?.header), jsLib: nullable("jsLib", old: old?.jsLib),
                    enabledCookieJar: switches["enabledCookieJar"] ?? false,
                    loginCheckJs: nullable("loginCheckJs", old: old?.loginCheckJs), lastUpdateTime: old?.lastUpdateTime ?? now
                ))
        case .keyboardAssists:
            try require("key", title: "按键名称")
            return .keyboardAssist(
                KeyboardAssist(
                    type: try integer("type", title: "类型"), key: value("key"),
                    value: value("value"), serialNo: try integer("order", title: "排序")))
        }
    }

    private func nullable(_ key: String, old: String?) -> String? {
        let current = value(key)
        return current == (old ?? "") ? old : current
    }

    private func require(_ key: String, title: String) throws {
        if value(key).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigurationEditorError(message: "\(title)不能为空", field: key)
        }
    }

    private func requireHTTPURL(_ key: String, title: String) throws {
        guard let parts = URLComponents(string: value(key)),
            ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            let host = parts.host, !host.isEmpty
        else { throw ConfigurationEditorError(message: "\(title)必须是有效的 HTTP 或 HTTPS 地址", field: key) }
    }

    private func integer(_ key: String, title: String) throws -> Int32 {
        guard let number = Int32(value(key).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ConfigurationEditorError(message: "\(title)必须是 32 位整数", field: key)
        }
        return number
    }
}

struct ConfigurationEditorError: LocalizedError {
    let message: String
    let field: String
    var errorDescription: String? { message }
}
