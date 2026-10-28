import Foundation

enum SourceEditorTab: Int, CaseIterable {
    case base, search, explore, info, toc, content

    var title: String {
        switch self {
        case .base: return "基本"
        case .search: return L10n.SourceEdit.searchTab
        case .explore: return L10n.SourceEdit.exploreTab
        case .info: return L10n.SourceEdit.infoTab
        case .toc: return L10n.SourceEdit.tocTab
        case .content: return L10n.SourceEdit.contentTab
        }
    }
}

struct BookSourceEditorField {
    let path: [String]
    let title: String

    var id: String { path.joined(separator: ".") }
    var identifier: String { "sourceEdit.field." + id }

    static func fields(for tab: SourceEditorTab) -> [Self] {
        switch tab {
        case .base:
            return [
                Self(path: ["bookSourceUrl"], title: "源 URL（sourceUrl）"),
                Self(path: ["bookSourceName"], title: "源名称（sourceName）"),
                Self(path: ["bookSourceGroup"], title: "源分组（sourceGroup）"),
                Self(path: ["bookSourceComment"], title: "源注释（sourceComment）"),
                Self(path: ["loginUrl"], title: "登录 URL(loginUrl)"),
                Self(path: ["loginUi"], title: "登录 UI（loginUi）"),
                Self(path: ["loginCheckJs"], title: "登录检查 JS（loginCheckJs）"),
                Self(path: ["coverDecodeJs"], title: "封面解密（coverDecodeJs）"),
                Self(path: ["bookUrlPattern"], title: "书籍 URL 正则（bookUrlPattern）"),
                Self(path: ["header"], title: "请求头（header）"),
                Self(path: ["variableComment"], title: "变量说明(variableComment)"),
                Self(path: ["concurrentRate"], title: "并发率（concurrentRate）"),
                Self(path: ["jsLib"], title: "jsLib"),
            ]
        case .search:
            return [
                Self(path: ["searchUrl"], title: "搜索地址（url）"),
                Self(path: ["ruleSearch", "checkKeyWord"], title: "校验关键字（checkKeyWord）"),
                Self(path: ["ruleSearch", "bookList"], title: "书籍列表规则（bookList）"),
                Self(path: ["ruleSearch", "name"], title: "书名规则（name）"),
                Self(path: ["ruleSearch", "author"], title: "作者规则（author）"),
                Self(path: ["ruleSearch", "kind"], title: "分类规则（kind）"),
                Self(path: ["ruleSearch", "wordCount"], title: "字数规则（wordCount）"),
                Self(path: ["ruleSearch", "lastChapter"], title: "最新章节规则（lastChapter）"),
                Self(path: ["ruleSearch", "intro"], title: "简介规则（intro）"),
                Self(path: ["ruleSearch", "coverUrl"], title: "封面规则（coverUrl）"),
                Self(path: ["ruleSearch", "bookUrl"], title: "详情页 URL 规则（bookUrl）"),
            ]
        case .explore:
            return [
                Self(path: ["exploreUrl"], title: "发现地址规则（url）"),
                Self(path: ["ruleExplore", "bookList"], title: "书籍列表规则（bookList）"),
                Self(path: ["ruleExplore", "name"], title: "书名规则（name）"),
                Self(path: ["ruleExplore", "author"], title: "作者规则（author）"),
                Self(path: ["ruleExplore", "kind"], title: "分类规则（kind）"),
                Self(path: ["ruleExplore", "wordCount"], title: "字数规则（wordCount）"),
                Self(path: ["ruleExplore", "lastChapter"], title: "最新章节规则（lastChapter）"),
                Self(path: ["ruleExplore", "intro"], title: "简介规则（intro）"),
                Self(path: ["ruleExplore", "coverUrl"], title: "封面规则（coverUrl）"),
                Self(path: ["ruleExplore", "bookUrl"], title: "详情页 URL 规则（bookUrl）"),
            ]
        case .info:
            return [
                Self(path: ["ruleBookInfo", "init"], title: "预处理规则（bookInfoInit）"),
                Self(path: ["ruleBookInfo", "name"], title: "书名规则（name）"),
                Self(path: ["ruleBookInfo", "author"], title: "作者规则（author）"),
                Self(path: ["ruleBookInfo", "kind"], title: "分类规则（kind）"),
                Self(path: ["ruleBookInfo", "wordCount"], title: "字数规则（wordCount）"),
                Self(path: ["ruleBookInfo", "lastChapter"], title: "最新章节规则（lastChapter）"),
                Self(path: ["ruleBookInfo", "intro"], title: "简介规则（intro）"),
                Self(path: ["ruleBookInfo", "coverUrl"], title: "封面规则（coverUrl）"),
                Self(path: ["ruleBookInfo", "tocUrl"], title: "目录 URL 规则（tocUrl）"),
                Self(path: ["ruleBookInfo", "canReName"], title: "允许修改书名作者（canReName）"),
                Self(path: ["ruleBookInfo", "downloadUrls"], title: "下载URL规则(downloadUrls)"),
            ]
        case .toc:
            return [
                Self(path: ["ruleToc", "preUpdateJs"], title: "更新之前 JS（preUpdateJs）"),
                Self(path: ["ruleToc", "chapterList"], title: "目录列表规则（chapterList）"),
                Self(path: ["ruleToc", "chapterName"], title: "章节名称规则（ChapterName）"),
                Self(path: ["ruleToc", "chapterUrl"], title: "章节 URL 规则（chapterUrl）"),
                Self(path: ["ruleToc", "formatJs"], title: "格式化规则(formatJs)"),
                Self(path: ["ruleToc", "isVolume"], title: "Volume 标识（isVolume）"),
                Self(path: ["ruleToc", "updateTime"], title: "更新时间（ChapterInfo）"),
                Self(path: ["ruleToc", "isVip"], title: "VIP 标识（isVip）"),
                Self(path: ["ruleToc", "isPay"], title: "购买标识（isPay）"),
                Self(path: ["ruleToc", "nextTocUrl"], title: "目录下一页规则（nextTocUrl）"),
            ]
        case .content:
            return [
                Self(path: ["ruleContent", "content"], title: "正文规则（content）"),
                Self(path: ["ruleContent", "title"], title: "章节名称规则（ChapterName）"),
                Self(path: ["ruleContent", "nextContentUrl"], title: "正文下一页 URL 规则（nextContentUrl）"),
                Self(path: ["ruleContent", "webJs"], title: "WebView JS（webJs）"),
                Self(path: ["ruleContent", "sourceRegex"], title: "资源正则（sourceRegex）"),
                Self(path: ["ruleContent", "replaceRegex"], title: "替换规则（replaceRegex）"),
                Self(path: ["ruleContent", "imageStyle"], title: "图片样式（imageStyle）"),
                Self(path: ["ruleContent", "imageDecode"], title: "图片解密（imageDecode）"),
                Self(path: ["ruleContent", "payAction"], title: "购买操作（payAction）"),
            ]
        }
    }
}

struct BookSourceEditorDraft {
    private struct TextEdit {
        let path: [String]
        let text: String
    }

    private var originalPayload: [String: Any]
    private var fieldEdits: [String: TextEdit] = [:]
    private var sourceTypeEdit: Int?
    private var flagEdits: [String: Bool] = [:]
    private var reviewEdit: String?

    init(payload: [String: Any] = [:]) {
        originalPayload = payload
    }

    mutating func load(_ payload: [String: Any]) {
        self = Self(payload: payload)
    }

    func text(for field: BookSourceEditorField) -> String {
        fieldEdits[field.id]?.text ?? Self.displayText(value(at: field.path))
    }

    mutating func setText(_ text: String, for field: BookSourceEditorField) {
        if text == Self.displayText(value(at: field.path)) {
            fieldEdits.removeValue(forKey: field.id)
        } else {
            fieldEdits[field.id] = TextEdit(path: field.path, text: text)
        }
    }

    var sourceType: Int {
        get { sourceTypeEdit ?? originalSourceType }
        set { sourceTypeEdit = newValue == originalSourceType ? nil : newValue }
    }

    var enabled: Bool {
        get { flagValue(for: "enabled") }
        set { setFlag(newValue, for: "enabled") }
    }

    var enabledExplore: Bool {
        get { flagValue(for: "enabledExplore") }
        set { setFlag(newValue, for: "enabledExplore") }
    }

    var enabledCookieJar: Bool {
        get { flagValue(for: "enabledCookieJar") }
        set { setFlag(newValue, for: "enabledCookieJar") }
    }

    var reviewText: String {
        get { reviewEdit ?? Self.displayText(originalPayload["ruleReview"]) }
        set {
            reviewEdit = newValue == Self.displayText(originalPayload["ruleReview"]) ? nil : newValue
        }
    }

    func payloadData() throws -> Data {
        var payload = originalPayload
        // Compare against displayed originals so merely visiting a tab never rewrites its values.
        for edit in fieldEdits.values {
            let value: Any?
            if edit.path == ["header"] || edit.path == ["loginUi"] {
                value = try Self.parseJSONObjectOrString(edit.text)
            } else {
                let isRequired = edit.path == ["bookSourceName"] || edit.path == ["bookSourceUrl"]
                value = Self.isBlank(edit.text) && !isRequired ? nil : edit.text
            }
            Self.setValue(value, at: edit.path[...], in: &payload)
        }
        if let sourceTypeEdit {
            payload["bookSourceType"] = sourceTypeEdit
        }
        for (key, value) in flagEdits {
            payload[key] = value
        }
        if let reviewEdit {
            let trimmed = reviewEdit.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                payload.removeValue(forKey: "ruleReview")
            } else {
                payload["ruleReview"] = try Self.decodePayload(trimmed)
            }
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func decodePayload(_ str: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(str.utf8), options: [])
        guard let payload = object as? [String: Any] else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourcePayloadInvalid]
            )
        }
        return payload
    }

    private var originalSourceType: Int {
        originalPayload["bookSourceType"] as? Int ?? 0
    }

    private func flagValue(for key: String) -> Bool {
        flagEdits[key] ?? originalFlagValue(for: key)
    }

    private mutating func setFlag(_ value: Bool, for key: String) {
        if value == originalFlagValue(for: key) {
            flagEdits.removeValue(forKey: key)
        } else {
            flagEdits[key] = value
        }
    }

    private func originalFlagValue(for key: String) -> Bool {
        // BookSource defaults an absent CookieJar to true; the Android editor maps explicit null to false.
        if key == "enabledCookieJar", originalPayload[key] is NSNull { return false }
        return originalPayload[key] as? Bool ?? true
    }

    private func value(at path: [String]) -> Any? {
        var value: Any = originalPayload
        for key in path {
            guard let nested = value as? [String: Any], let next = nested[key] else { return nil }
            value = next
        }
        return value
    }

    private static func setValue(_ value: Any?, at path: ArraySlice<String>, in payload: inout [String: Any]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            payload[key] = value
            return
        }
        let existing = payload[key] as? [String: Any]
        // Clearing an absent leaf must not manufacture an empty rule object.
        guard existing != nil || value != nil else { return }
        var nested = existing ?? [:]
        setValue(value, at: path.dropFirst(), in: &nested)
        payload[key] = nested
    }

    private static func parseJSONObjectOrString(_ text: String) throws -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "{" || trimmed.first == "[" {
            return try JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [])
        }
        return text
    }

    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x0009...0x000D, 0x001C...0x0020, 0x00A0, 0x1680,
                0x2000...0x200A, 0x2028...0x2029, 0x202F, 0x205F, 0x3000:
                return true
            default: return false
            }
        }
    }

    private static func displayText(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        // Rule strings are opaque, even when they happen to look like JSON.
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
