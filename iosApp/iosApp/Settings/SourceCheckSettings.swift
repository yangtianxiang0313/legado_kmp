import Foundation
import shared

/// CheckSource.kt at Legado 5f5d314; the UI edits seconds, Android stores milliseconds.
struct SourceCheckSettings: Equatable {
    static let maximumTimeoutSeconds = Int64.max / 1_000

    var timeoutSeconds: Int64 = 180
    var checkSearch = true
    var checkDiscovery = true
    var checkInfo = true
    var checkCategory = true
    var checkContent = true

    var normalized: SourceCheckSettings {
        var value = self
        value.timeoutSeconds = min(max(1, timeoutSeconds), Self.maximumTimeoutSeconds)
        if !value.checkSearch && !value.checkDiscovery { value.checkSearch = true }
        value.checkCategory = value.checkInfo && value.checkCategory
        value.checkContent = value.checkCategory && value.checkContent
        return value
    }

    var summary: String {
        let value = normalized
        let items: [(Bool, String)] = [
            (value.checkSearch, "搜索"), (value.checkDiscovery, "发现"), (value.checkInfo, "详情"),
            (value.checkCategory, "目录"), (value.checkContent, "正文"),
        ]
        let titles = items.filter { $0.0 }.map { $0.1 }.joined(separator: " ")
        return "校验超时：\(value.timeoutSeconds)秒\n校验项目：\(titles)"
    }

    func makeConfig(keyword: String) -> shared.SourceCheckConfig {
        let value = normalized
        return shared.SourceCheckConfig(
            keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "我的",
            timeoutMs: value.timeoutSeconds * 1_000,
            checkSearch: value.checkSearch, checkDiscovery: value.checkDiscovery,
            checkInfo: value.checkInfo, checkCategory: value.checkCategory, checkContent: value.checkContent)
    }
}

final class SourceCheckSettingsStore {
    private let defaults: UserDefaults
    private let keywordKey = "checkSourceKeyword"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reading, including repairing inconsistent legacy values in memory, never writes defaults.
    func load() -> SourceCheckSettings {
        let raw = defaults.object(forKey: "checkSourceTimeout")
        let milliseconds: Int64?
        if let number = raw as? NSNumber {
            milliseconds = Int64(number.stringValue)
        } else if let string = raw as? String {
            milliseconds = Int64(string)
        } else {
            milliseconds = nil
        }
        let seconds = milliseconds.flatMap { $0 >= 1_000 ? $0 / 1_000 : nil } ?? 180
        return SourceCheckSettings(
            timeoutSeconds: seconds,
            checkSearch: bool(forKey: "checkSearch"), checkDiscovery: bool(forKey: "checkDiscovery"),
            checkInfo: bool(forKey: "checkInfo"), checkCategory: bool(forKey: "checkCategory"),
            checkContent: bool(forKey: "checkContent")
        ).normalized
    }

    func save(_ settings: SourceCheckSettings) {
        guard (1...SourceCheckSettings.maximumTimeoutSeconds).contains(settings.timeoutSeconds) else { return }
        let value = settings.normalized
        defaults.set(value.timeoutSeconds * 1_000, forKey: "checkSourceTimeout")
        defaults.set(value.checkSearch, forKey: "checkSearch")
        defaults.set(value.checkDiscovery, forKey: "checkDiscovery")
        defaults.set(value.checkInfo, forKey: "checkInfo")
        defaults.set(value.checkCategory, forKey: "checkCategory")
        defaults.set(value.checkContent, forKey: "checkContent")
    }

    var keyword: String {
        get { normalizedKeyword(defaults.string(forKey: keywordKey) ?? "我的") }
        set { defaults.set(normalizedKeyword(newValue), forKey: keywordKey) }
    }

    private func normalizedKeyword(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "我的"
    }

    private func bool(forKey key: String) -> Bool {
        guard let object = defaults.object(forKey: key) else { return true }
        if let string = object as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return true
            }
        }
        return (object as? NSNumber)?.boolValue ?? true
    }
}
