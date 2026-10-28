import Foundation

struct CacheExportOptions: Codable, Equatable {
    var chapterScope: String = ""
    var chaptersPerFile: Int = 0
    var charset: String = "UTF-8"
    var includeChapterTitle: Bool = true
    var useReplaceRules: Bool = true
    var fileNameScript: String = ""
    var splitFileNameScript: String = ""

    static let charsets = ["UTF-8", "UTF-16LE", "UTF-16BE", "GB18030", "GBK", "Big5"]
    static let maximumChapterScopeLength = 8_192
    static let maximumFileNameScriptLength = 16 * 1024

    static func supportedCharset(_ value: String) -> String {
        charsets.first { $0.caseInsensitiveCompare(value) == .orderedSame } ?? "UTF-8"
    }
}

struct CacheExportOptionsPreferences {
    private static let key = "legado.ios.cache.exportOptions.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CacheExportOptions {
        guard let data = defaults.data(forKey: Self.key),
            let saved = try? JSONDecoder().decode(SavedOptions.self, from: data)
        else { return CacheExportOptions() }
        return CacheExportOptions(
            charset: CacheExportOptions.supportedCharset(saved.charset),
            includeChapterTitle: saved.includeChapterTitle,
            useReplaceRules: saved.useReplaceRules,
            fileNameScript: Self.safeScript(saved.fileNameScript),
            splitFileNameScript: Self.safeScript(saved.splitFileNameScript))
    }

    func save(_ options: CacheExportOptions) {
        let saved = SavedOptions(
            charset: CacheExportOptions.supportedCharset(options.charset),
            includeChapterTitle: options.includeChapterTitle,
            useReplaceRules: options.useReplaceRules,
            fileNameScript: Self.safeScript(options.fileNameScript),
            splitFileNameScript: Self.safeScript(options.splitFileNameScript))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func safeScript(_ value: String) -> String {
        value.utf8.count <= CacheExportOptions.maximumFileNameScriptLength ? value : ""
    }

    // Per-book chapter selection is intentionally absent from the persisted schema.
    private struct SavedOptions: Codable {
        var charset: String
        var includeChapterTitle: Bool
        var useReplaceRules: Bool
        var fileNameScript: String
        var splitFileNameScript: String

        enum CodingKeys: String, CodingKey {
            case charset, includeChapterTitle, useReplaceRules, fileNameScript, splitFileNameScript
        }

        init(
            charset: String, includeChapterTitle: Bool, useReplaceRules: Bool,
            fileNameScript: String, splitFileNameScript: String
        ) {
            self.charset = charset
            self.includeChapterTitle = includeChapterTitle
            self.useReplaceRules = useReplaceRules
            self.fileNameScript = fileNameScript
            self.splitFileNameScript = splitFileNameScript
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            charset = (try? container.decode(String.self, forKey: .charset)) ?? "UTF-8"
            includeChapterTitle = (try? container.decode(Bool.self, forKey: .includeChapterTitle)) ?? true
            useReplaceRules = (try? container.decode(Bool.self, forKey: .useReplaceRules)) ?? true
            fileNameScript = (try? container.decode(String.self, forKey: .fileNameScript)) ?? ""
            splitFileNameScript = (try? container.decode(String.self, forKey: .splitFileNameScript)) ?? ""
        }
    }
}
