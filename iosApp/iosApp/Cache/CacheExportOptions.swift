import Foundation

enum CacheExportDestination: String, Codable, CaseIterable {
    case share, webDAV
}

struct CacheExportOptions: Codable, Equatable {
    var chapterScope: String = ""
    var chaptersPerFile: Int = 0
    var charset: String = "UTF-8"
    var includeChapterTitle: Bool = true
    var useReplaceRules: Bool = true
    var includeImages: Bool = false
    var useCustomEpubTemplate: Bool = false
    var epubTemplateBase64: String = ""
    var epubTemplateName: String = ""
    var fileNameScript: String = ""
    var splitFileNameScript: String = ""
    var destination: CacheExportDestination = .share

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
    private let templateStore: CacheExportTemplateStore

    init(defaults: UserDefaults = .standard, templateStore: CacheExportTemplateStore = CacheExportTemplateStore()) {
        self.defaults = defaults
        self.templateStore = templateStore
    }

    func load() -> CacheExportOptions {
        guard let data = defaults.data(forKey: Self.key),
            let saved = try? JSONDecoder().decode(SavedOptions.self, from: data)
        else { return CacheExportOptions() }
        var options = CacheExportOptions(
            charset: CacheExportOptions.supportedCharset(saved.charset),
            includeChapterTitle: saved.includeChapterTitle,
            useReplaceRules: saved.useReplaceRules,
            includeImages: saved.includeImages,
            useCustomEpubTemplate: saved.useCustomEpubTemplate,
            fileNameScript: Self.safeScript(saved.fileNameScript),
            splitFileNameScript: Self.safeScript(saved.splitFileNameScript),
            destination: saved.destination)
        if saved.useCustomEpubTemplate {
            // Keep the enabled flag on failure. The settings sheet must not silently choose the built-in template.
            if let snapshot = try? templateStore.load() {
                options.epubTemplateBase64 = snapshot.base64Zip
                options.epubTemplateName = snapshot.name
            }
        }
        return options
    }

    func save(_ options: CacheExportOptions) {
        let saved = SavedOptions(
            charset: CacheExportOptions.supportedCharset(options.charset),
            includeChapterTitle: options.includeChapterTitle,
            useReplaceRules: options.useReplaceRules,
            includeImages: options.includeImages,
            useCustomEpubTemplate: options.useCustomEpubTemplate,
            fileNameScript: Self.safeScript(options.fileNameScript),
            splitFileNameScript: Self.safeScript(options.splitFileNameScript),
            destination: options.destination)
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
        var includeImages: Bool
        var useCustomEpubTemplate: Bool
        var fileNameScript: String
        var splitFileNameScript: String
        var destination: CacheExportDestination

        enum CodingKeys: String, CodingKey {
            case charset, includeChapterTitle, useReplaceRules, includeImages
            case useCustomEpubTemplate
            case fileNameScript, splitFileNameScript, destination
        }

        init(
            charset: String, includeChapterTitle: Bool, useReplaceRules: Bool, includeImages: Bool,
            useCustomEpubTemplate: Bool,
            fileNameScript: String, splitFileNameScript: String, destination: CacheExportDestination
        ) {
            self.charset = charset
            self.includeChapterTitle = includeChapterTitle
            self.useReplaceRules = useReplaceRules
            self.includeImages = includeImages
            self.useCustomEpubTemplate = useCustomEpubTemplate
            self.fileNameScript = fileNameScript
            self.splitFileNameScript = splitFileNameScript
            self.destination = destination
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            charset = (try? container.decode(String.self, forKey: .charset)) ?? "UTF-8"
            includeChapterTitle = (try? container.decode(Bool.self, forKey: .includeChapterTitle)) ?? true
            useReplaceRules = (try? container.decode(Bool.self, forKey: .useReplaceRules)) ?? true
            includeImages = (try? container.decode(Bool.self, forKey: .includeImages)) ?? false
            useCustomEpubTemplate = (try? container.decode(Bool.self, forKey: .useCustomEpubTemplate)) ?? false
            fileNameScript = (try? container.decode(String.self, forKey: .fileNameScript)) ?? ""
            splitFileNameScript = (try? container.decode(String.self, forKey: .splitFileNameScript)) ?? ""
            destination = (try? container.decode(CacheExportDestination.self, forKey: .destination)) ?? .share
        }
    }
}
