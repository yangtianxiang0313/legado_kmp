import Foundation

func ruleAssistantString(_ key: String, _ value: String) -> String {
    NSLocalizedString("rule_assistant.\(key)", value: value, comment: "Rule assistant")
}

enum RuleAssistantOperation: String, Codable, CaseIterable {
    case replaceLiteral
    case removeContainingLines
    case removePrefixedLines
    case collapseBlankLines

    var title: String {
        switch self {
        case .replaceLiteral: return ruleAssistantString("literal", "精确替换")
        case .removeContainingLines: return ruleAssistantString("containing", "删除含指定文字的整行")
        case .removePrefixedLines: return ruleAssistantString("prefix", "删除指定前缀的整行")
        case .collapseBlankLines: return ruleAssistantString("blank_lines", "合并多余空行")
        }
    }
}

struct RuleAssistantPlan: Codable, Equatable {
    let operation: RuleAssistantOperation
    let text: String
    let replacement: String

    func validate() throws {
        guard text.utf16.count <= 512, replacement.utf16.count <= 512 else {
            throw RuleAssistantError(ruleAssistantString("text_limit", "匹配文字或替换文字不能超过 512 个字符"))
        }
        switch operation {
        case .replaceLiteral:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !text.utf16.elementsEqual(replacement.utf16)
            else {
                throw RuleAssistantError(ruleAssistantString("literal_required", "请填写需要替换的文字，且与替换结果不同"))
            }
        case .removeContainingLines, .removePrefixedLines:
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !text.contains("\r"), !text.contains("\n"), replacement.isEmpty
            else {
                throw RuleAssistantError(ruleAssistantString("line_required", "请填写非空的单行匹配文字；整行删除不能指定替换文字"))
            }
        case .collapseBlankLines:
            guard text.isEmpty, replacement.isEmpty else {
                throw RuleAssistantError(ruleAssistantString("blank_fields", "合并空行不需要匹配文字或替换文字"))
            }
        }
    }

    static func decode(_ result: String) throws -> RuleAssistantPlan {
        let invalidResult = RuleAssistantError(
            ruleAssistantString("invalid_result", "结果不是有效的规则草稿，尚未应用任何修改"))
        guard result.utf16.count <= 4_000 else { throw invalidResult }
        var text = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            guard text.hasSuffix("```"), let newline = text.firstIndex(where: { $0.isNewline }) else {
                throw invalidResult
            }
            let language = text[text.index(text.startIndex, offsetBy: 3)..<newline]
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard language.isEmpty || language == "json" else { throw invalidResult }
            text = String(text[text.index(after: newline)...].dropLast(3))
        }
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(["operation", "text", "replacement"]),
            let operationName = object["operation"] as? String,
            let operation = RuleAssistantOperation(rawValue: operationName),
            let matchText = object["text"] as? String,
            let replacement = object["replacement"] as? String
        else { throw invalidResult }
        let plan = RuleAssistantPlan(operation: operation, text: matchText, replacement: replacement)
        try plan.validate()
        return plan
    }
}

struct RuleAssistantError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
