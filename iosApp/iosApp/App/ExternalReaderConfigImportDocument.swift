import Foundation
import shared

/// Parsing a preview never imports images, registers fonts, or writes preferences.
struct ExternalReaderConfigImportDocument {
    struct Resource {
        let title: String
        let detail: String
    }

    let data: Data
    let name: String
    let resources: [Resource]

    static func parse(_ data: Data) throws -> Self {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= ReaderPresetTransferResources.archiveLimit else {
            throw ReaderPresetTransferResources.error("阅读配置为空或超过 64 MiB")
        }
        let entries: [String: String]
        if data.starts(with: [0x50, 0x4B]) {
            entries = try ReaderPresetArchive().unpack(base64Zip: data.base64EncodedString())
        } else {
            entries = ["readConfig.json": data.base64EncodedString()]
        }
        try Task.checkCancellation()
        guard let encoded = entries["readConfig.json"], let config = Data(base64Encoded: encoded),
            config.count <= 4 * 1024 * 1024, let text = String(data: config, encoding: .utf8),
            let object = try JSONSerialization.jsonObject(with: config) as? [String: Any]
        else { throw ReaderPresetTransferResources.error("缺少有效的 readConfig.json") }
        guard
            Set(object.keys).isDisjoint(with: [
                "books", "bookSources", "rssSources", "replaceRules", "preferences", "settings", "backupVersion",
                "schemaVersion", "bookSourceUrl", "sourceUrl", "pattern", "url", "themeName", "showRule", "rule",
            ])
        else { throw ReaderPresetTransferResources.error("文件不是单项阅读配置，请使用对应的规则或备份入口") }
        let codec = ReaderPresetTransferCodec()
        let preset = try codec.decode(jsonString: text)
        guard let row = try JSONSerialization.jsonObject(with: Data(try codec.encode(preset: preset).utf8)) as? [String: Any]
        else {
            throw ReaderPresetTransferResources.error("无法读取阅读配置")
        }
        var resources: [Resource] = []
        for (suffix, label) in [("", "日间背景"), ("Night", "夜间背景"), ("EInk", "墨水屏背景")] {
            let kind = (row["bgType" + suffix] as? NSNumber)?.intValue ?? 0
            let path = row["bgStr" + suffix] as? String ?? ""
            let detail: String
            if kind == 0 {
                detail = path
            } else if let item = ReaderBackgroundImageCatalog.item(forStoredPath: path) {
                detail = "内置图片：" + item.fileName
            } else {
                let name = resourceName(path)
                if let encoded = entries[name], let bytes = Data(base64Encoded: encoded) {
                    detail = name + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)
                } else if let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: path),
                    FileManager.default.fileExists(atPath: url.path)
                {
                    detail = "已有图片：" + url.lastPathComponent
                } else {
                    detail = "缺少图片：" + name
                }
            }
            resources.append(Resource(title: label, detail: detail))
        }
        let font = row["textFont"] as? String ?? ""
        if font.isEmpty {
            resources.append(Resource(title: "字体", detail: "默认字体"))
        } else if let encoded = entries[resourceName(font)], let bytes = Data(base64Encoded: encoded) {
            resources.append(
                Resource(
                    title: "字体",
                    detail: resourceName(font) + " · "
                        + ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)))
        } else {
            resources.append(Resource(title: "字体", detail: ReaderFontStore.shared.title(for: font) ?? "缺少字体，导入时恢复默认字体"))
        }
        try Task.checkCancellation()
        return Self(data: data, name: preset.name, resources: resources)
    }

    private static func resourceName(_ path: String) -> String {
        (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }
}
