import Foundation
import shared

enum ExternalRuleImportKind: String, Equatable {
    case bookSource, rssSource, replaceRule, httpTTS, theme, textTocRule, dictRule

    init?(route: String) {
        switch route.lowercased() {
        case "booksource": self = .bookSource
        case "rsssource": self = .rssSource
        case "replace", "replacerule": self = .replaceRule
        case "httptts": self = .httpTTS
        case "theme": self = .theme
        case "texttocrule", "txttocrule", "txtrule": self = .textTocRule
        case "dictrule": self = .dictRule
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .bookSource: return "书源"
        case .rssSource: return "RSS 源"
        case .replaceRule: return "净化规则"
        case .httpTTS: return "HTTP 朗读引擎"
        case .theme: return "主题"
        case .textTocRule: return "TXT 目录规则"
        case .dictRule: return "字典规则"
        }
    }
}

enum ExternalRuleImportInput {
    case file(URL), remote(URL)
}

struct ExternalRuleImportDocument {
    let kind: ExternalRuleImportKind
    let payload: String
    let rows: [ExternalRuleImportRow]

    static func parse(_ data: Data, expected: ExternalRuleImportKind?) throws -> Self {
        guard data.count <= ExternalRuleImportLoader.maximumBytes else { throw failure("规则文件超过 32 MB") }
        guard let text = String(data: data, encoding: .utf8) else { throw failure("规则文件不是 UTF-8 文本") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
            in: CharacterSet(charactersIn: "\u{feff}"))
        let json = Data(trimmed.utf8)
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: json) } catch { throw failure("内容不是有效的规则 JSON") }
        let objects: [[String: Any]]
        if let array = root as? [[String: Any]] {
            objects = array
        } else if let object = root as? [String: Any] {
            objects = [object]
        } else {
            throw failure("规则必须是 JSON 对象或对象数组")
        }
        guard !objects.isEmpty, objects.count <= 10_000 else { throw failure("规则为空或超过 10000 条") }
        let kinds = try objects.map { object -> ExternalRuleImportKind in
            // Backup envelopes must stay on the separate, explicit restore path.
            guard
                Set(object.keys).isDisjoint(with: [
                    "books", "bookSources", "rssSources", "replaceRules", "preferences", "settings", "backupVersion",
                    "schemaVersion",
                ])
            else {
                throw failure("这是备份或集合文件，请使用“恢复备份”入口")
            }
            var matches: [ExternalRuleImportKind] = []
            if object["bookSourceUrl"] != nil { matches.append(.bookSource) }
            if object["sourceUrl"] != nil { matches.append(.rssSource) }
            if object["pattern"] != nil { matches.append(.replaceRule) }
            if object["themeName"] != nil { matches.append(.theme) }
            if object["showRule"] != nil { matches.append(.dictRule) }
            if object["name"] != nil, object["rule"] != nil { matches.append(.textTocRule) }
            if matches.isEmpty, object["name"] != nil, object["url"] != nil { matches.append(.httpTTS) }
            guard matches.count == 1, let kind = matches.first else { throw failure("无法识别规则类型，未执行导入") }
            return kind
        }
        guard let kind = kinds.first, kinds.allSatisfy({ $0 == kind }) else { throw failure("文件包含不同类型的规则，请分开导入") }
        if let expected, kind != expected { throw failure("链接类型为\(expected.title)，但内容为\(kind.title)") }
        if kind == .bookSource {
            return Self(kind: kind, payload: trimmed, rows: [])
        }
        let seed = Int64(Date().timeIntervalSince1970 * 1000)
        let rows = try objects.enumerated().map { index, object in
            try ExternalRuleImportRow(kind: kind, object: object, fallbackID: seed + Int64(index), index: index)
        }
        guard Set(rows.map(\.identity)).count == rows.count else { throw failure("文件包含重复规则标识，请先合并重复项") }
        return Self(kind: kind, payload: trimmed, rows: rows)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.externalRuleImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct ExternalRuleImportRow {
    enum Value {
        case rss(String), replace(ReplaceRule), speech(HttpTTS), theme(String), txtToc(TxtTocRule), dictionary(DictRule)
    }

    let identity: String
    let title: String
    let summary: String
    let value: Value

    init(kind: ExternalRuleImportKind, object: [String: Any], fallbackID: Int64, index: Int) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let payload = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        switch kind {
        case .rssSource:
            let source = try decoder.decode(ExternalRuleImportRSS.self, from: data)
            guard !source.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !source.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ExternalRuleImportDocument.failure("RSS 源名称和地址不能为空") }
            identity = source.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            title = source.sourceName
            summary = source.sourceGroup ?? "RSS 源"
            value = .rss(payload)
        case .replaceRule:
            let rule = try decoder.decode(ExternalRuleImportReplacement.self, from: data)
            guard !rule.pattern.isEmpty else { throw ExternalRuleImportDocument.failure("净化规则的匹配内容不能为空") }
            let id = rule.id ?? fallbackID
            let name = rule.name ?? rule.replaceSummary ?? "净化规则 \(index + 1)"
            identity = String(id)
            title = name
            summary = rule.group ?? "净化规则"
            value = .replace(
                ReplaceRule(
                    id: id, name: name, group: rule.group, pattern: rule.pattern, replacement: rule.replacement ?? "",
                    scope: rule.scope ?? rule.useTo, scopeTitle: rule.scopeTitle ?? false,
                    scopeContent: rule.scopeContent ?? true,
                    excludeScope: rule.excludeScope, isEnabled: rule.isEnabled ?? rule.enable ?? true,
                    isRegex: rule.isRegex ?? true,
                    timeoutMillisecond: rule.timeoutMillisecond ?? rule.timeout ?? 3000,
                    order: rule.order ?? rule.serialNumber ?? Int32(index)))
        case .httpTTS:
            let engine = try decoder.decode(ExternalRuleImportSpeech.self, from: data)
            guard !engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ExternalRuleImportDocument.failure("HTTP 朗读引擎名称和请求规则不能为空") }
            let id = engine.id ?? fallbackID
            identity = String(id)
            title = engine.name
            summary = engine.contentType ?? "HTTP TTS"
            value = .speech(
                HttpTTS(
                    id: id, name: engine.name, url: engine.url, contentType: engine.contentType,
                    concurrentRate: engine.concurrentRate ?? "0", loginUrl: engine.loginUrl, loginUi: engine.loginUi,
                    header: engine.header, jsLib: engine.jsLib, enabledCookieJar: engine.enabledCookieJar ?? false,
                    loginCheckJs: engine.loginCheckJs, lastUpdateTime: engine.lastUpdateTime ?? 0))
        case .theme:
            let theme = try decoder.decode(ExternalRuleImportTheme.self, from: data)
            guard theme.themeName.count <= 4096, data.count <= 1024 * 1024 else {
                throw ExternalRuleImportDocument.failure("主题配置过大")
            }
            try theme.validateColors()
            identity = theme.themeName
            title = theme.themeName.isEmpty ? "未命名主题" : theme.themeName
            summary = theme.isNightTheme == true ? "夜间主题" : "日间主题"
            value = .theme(payload)
        case .textTocRule:
            let rule = try decoder.decode(ExternalRuleImportTxtToc.self, from: data)
            guard !rule.rule.isEmpty else { throw ExternalRuleImportDocument.failure("TXT 目录匹配规则不能为空") }
            let id = rule.id ?? fallbackID
            identity = String(id)
            title = rule.name.isEmpty ? "TXT 目录规则 \(index + 1)" : rule.name
            summary = rule.rule
            value = .txtToc(
                TxtTocRule(
                    id: id, name: rule.name, rule: rule.rule, example: rule.example,
                    serialNumber: rule.serialNumber ?? -1, enable: rule.enable ?? true))
        case .dictRule:
            let rule = try decoder.decode(ExternalRuleImportDictionary.self, from: data)
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !rule.urlRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw ExternalRuleImportDocument.failure("字典名称和请求规则不能为空") }
            identity = rule.name
            title = rule.name
            summary = rule.showRule.isEmpty ? "原始响应" : rule.showRule
            value = .dictionary(
                DictRule(
                    name: rule.name, urlRule: rule.urlRule, showRule: rule.showRule,
                    enabled: rule.enabled ?? true, sortNumber: rule.sortNumber ?? 0))
        case .bookSource:
            throw ExternalRuleImportDocument.failure("书源应使用现有书源预览")
        }
    }
}

private struct ExternalRuleImportRSS: Decodable {
    let sourceUrl: String
    let sourceName: String
    let sourceGroup: String?
}

private struct ExternalRuleImportTxtToc: Decodable {
    let id: Int64?
    let name: String
    let rule: String
    let example: String?
    let serialNumber: Int32?
    let enable: Bool?
}

private struct ExternalRuleImportDictionary: Decodable {
    let name: String
    let urlRule: String
    let showRule: String
    let enabled: Bool?
    let sortNumber: Int32?
}

private struct ExternalRuleImportReplacement: Decodable {
    let id: Int64?
    let name: String?
    let replaceSummary: String?
    let group: String?
    let pattern: String
    let replacement: String?
    let scope: String?
    let useTo: String?
    let scopeTitle: Bool?
    let scopeContent: Bool?
    let excludeScope: String?
    let isEnabled: Bool?
    let enable: Bool?
    let isRegex: Bool?
    let timeoutMillisecond: Int64?
    let timeout: Int64?
    let order: Int32?
    let serialNumber: Int32?
}

private struct ExternalRuleImportSpeech: Decodable {
    let id: Int64?
    let name: String
    let url: String
    let contentType: String?
    let concurrentRate: String?
    let loginUrl: String?
    let loginUi: String?
    let header: String?
    let jsLib: String?
    let enabledCookieJar: Bool?
    let loginCheckJs: String?
    let lastUpdateTime: Int64?
}

private struct ExternalRuleImportTheme: Decodable {
    let themeName: String
    let isNightTheme: Bool?
    let primaryColor: String
    let accentColor: String
    let backgroundColor: String
    let bottomBackground: String

    func validateColors() throws {
        let names: Set<String> = [
            "black", "darkgray", "gray", "lightgray", "white", "red", "green", "blue", "yellow", "cyan", "magenta", "aqua",
            "fuchsia", "darkgrey", "grey", "lightgrey", "lime", "maroon", "navy", "olive", "purple", "silver", "teal",
        ]
        for color in [primaryColor, accentColor, backgroundColor, bottomBackground] {
            let hex =
                color.hasPrefix("#") && [7, 9].contains(color.count)
                && color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit })
            guard hex || names.contains(color.lowercased()) else { throw ExternalRuleImportDocument.failure("主题包含无效颜色") }
        }
    }
}
