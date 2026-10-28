import Foundation
import shared

struct ReplaceRuleEditorDraft: Equatable {
    var name = ""
    var group = ""
    var pattern = ""
    var replacement = ""
    var isRegex = false
    var scopeTitle = false
    var scopeContent = true
    var scope = ""
    var excludeScope = ""
    var timeout = "3000"

    init(rule: ReplaceRule?) {
        guard let rule else { return }
        name = rule.name
        group = rule.group ?? ""
        pattern = rule.pattern
        replacement = rule.replacement
        isRegex = rule.isRegex
        scopeTitle = rule.scopeTitle
        scopeContent = rule.scopeContent
        scope = rule.scope ?? ""
        excludeScope = rule.excludeScope ?? ""
        timeout = String(rule.timeoutMillisecond)
    }

    static func selection(text: String, bookName: String, sourceURL: String?) -> ReplaceRuleEditorDraft {
        var draft = ReplaceRuleEditorDraft(rule: nil)
        // Kotlin lineSequence splits CRLF, LF and CR, retaining empty and trailing lines.
        draft.pattern = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map(trimSelectionLine)
            .joined(separator: "\n")
        // 5f5d314 ReplaceEditViewModel.initData also seeds the name from the pattern.
        draft.name = draft.pattern
        draft.scope = ([bookName] + (sourceURL.map { [$0] } ?? [])).joined(separator: ";")
        return draft
    }

    private static func trimSelectionLine(_ line: String) -> String {
        // Match Kotlin/JVM Char.isWhitespace, including separators and U+001C...U+001F.
        func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
            default: return (9...13).contains(scalar.value) || (28...31).contains(scalar.value)
            }
        }
        let scalars = line.unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, isWhitespace(scalars[start]) { scalars.formIndex(after: &start) }
        while start < end {
            let last = scalars.index(before: end)
            guard isWhitespace(scalars[last]) else { break }
            end = last
        }
        return String(scalars[start..<end])
    }

    func makeRule(original: ReplaceRule?, newID: Int64) throws -> ReplaceRule {
        let timeoutText = timeout.isEmpty ? "3000" : timeout
        guard timeoutText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
            let milliseconds = Int64(timeoutText)
        else {
            throw DraftError.invalidTimeout
        }
        // Unedited nullable fields and all non-form metadata survive a save verbatim.
        func optionalValue(_ value: String, original: String?) -> String? {
            value == (original ?? "") ? original : value
        }
        return ReplaceRule(
            id: original?.id ?? newID,
            name: name,
            group: optionalValue(group, original: original?.group),
            pattern: pattern,
            replacement: replacement,
            scope: optionalValue(scope, original: original?.scope),
            scopeTitle: scopeTitle,
            scopeContent: scopeContent,
            excludeScope: optionalValue(excludeScope, original: original?.excludeScope),
            isEnabled: original?.isEnabled ?? true,
            isRegex: isRegex,
            timeoutMillisecond: milliseconds,
            order: original?.order ?? Int32.max
        )
    }

    enum DraftError: LocalizedError {
        case emptyPattern
        case invalidPattern
        case invalidTimeout
        case invalidClipboard

        var errorDescription: String? {
            switch self {
            case .emptyPattern: return "替换规则不能为空"
            case .invalidPattern: return "替换规则无效"
            case .invalidTimeout: return "超时毫秒数只能包含数字 0 到 9，且不能超出整数范围"
            case .invalidClipboard: return L10n.ReplaceRule.pasteRuleInvalid
            }
        }
    }
}

enum ReplaceRuleEditorClipboard {
    static func encode(_ rule: ReplaceRule) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Document(rule: rule))
        guard let text = String(data: data, encoding: .utf8) else {
            throw ReplaceRuleEditorDraft.DraftError.invalidClipboard
        }
        return text
    }

    static func decode(_ text: String) throws -> ReplaceRuleEditorDraft {
        let document = try JSONDecoder().decode(Document.self, from: Data(text.utf8))
        guard let pattern = document.pattern else {
            throw ReplaceRuleEditorDraft.DraftError.invalidClipboard
        }
        // ReplaceEditActivity.upReplaceView only pastes form fields, never the record identity.
        var draft = ReplaceRuleEditorDraft(rule: nil)
        draft.name = document.name ?? ""
        draft.group = document.group ?? ""
        draft.pattern = pattern
        draft.replacement = document.replacement ?? ""
        draft.isRegex = document.isRegex ?? true
        draft.scopeTitle = document.scopeTitle ?? false
        draft.scopeContent = document.scopeContent ?? true
        draft.scope = document.scope ?? ""
        draft.excludeScope = document.excludeScope ?? ""
        draft.timeout = String(document.timeoutMillisecond ?? document.timeout ?? 3000)
        return draft
    }

    private struct Document: Codable {
        var id: Int64?
        var name: String?
        var group: String?
        var pattern: String?
        var replacement: String?
        var scope: String?
        var scopeTitle: Bool?
        var scopeContent: Bool?
        var excludeScope: String?
        var isEnabled: Bool?
        var isRegex: Bool?
        var timeoutMillisecond: Int64?
        var order: Int32?
        // Read the old iOS clipboard key, but only write Android's timeoutMillisecond.
        var timeout: Int64?

        init(rule: ReplaceRule) {
            id = rule.id
            name = rule.name
            group = rule.group
            pattern = rule.pattern
            replacement = rule.replacement
            scope = rule.scope
            scopeTitle = rule.scopeTitle
            scopeContent = rule.scopeContent
            excludeScope = rule.excludeScope
            isEnabled = rule.isEnabled
            isRegex = rule.isRegex
            timeoutMillisecond = rule.timeoutMillisecond
            order = rule.order
        }
    }
}
