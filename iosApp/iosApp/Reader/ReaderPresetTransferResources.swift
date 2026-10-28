import CryptoKit
import Foundation
import ImageIO
import shared

/// Android readConfig.zip carries one config and only the resources that it references.
enum ReaderPresetTransferResources {
    final class PreparedImport {
        let json: String
        let createdImages: [URL]
        private let fontLease: ReaderFontStore.ImportLease?
        private let lock = NSLock()
        private var settled = false

        init(json: String, createdImages: [URL], fontLease: ReaderFontStore.ImportLease?) {
            self.json = json
            self.createdImages = createdImages
            self.fontLease = fontLease
        }

        // Only the real shared persistence result may commit, never a presentation/cancellation gate.
        func commitResources() {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            fontLease?.commit()
            settled = true
        }

        func discardResources() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            var failure: Error?
            do { try fontLease?.rollback() } catch { failure = error }
            for url in createdImages {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    let value = error as NSError
                    if value.domain != NSCocoaErrorDomain
                        || ![NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
                    {
                        if failure == nil { failure = error }
                    }
                }
            }
            if let failure { throw failure }
            settled = true
        }

        func discardResources(after originalError: Error) -> Error {
            do {
                try discardResources()
                return originalError
            } catch {
                if originalError is CancellationError {
                    NSLog("ReaderPresetTransferResources cancelled import rollback: %@", error.localizedDescription)
                    return originalError
                }
                return NSError(
                    domain: "io.legado.reader.configTransfer", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(originalError.localizedDescription)\n导入资源回滚失败：\(error.localizedDescription)",
                        NSUnderlyingErrorKey: originalError,
                    ])
            }
        }

        deinit {
            do { try discardResources() } catch {
                NSLog("ReaderPresetTransferResources rollback: %@", error.localizedDescription)
            }
        }
    }

    struct Export {
        let fileName: String
        let data: Data
    }

    static let archiveLimit = 64 * 1024 * 1024
    private static let resourceLimit = 32 * 1024 * 1024

    static func prepareImport(_ data: Data, fontStore: ReaderFontStore = .shared) throws -> PreparedImport {
        guard data.count <= archiveLimit else { throw error("阅读配置文件过大") }
        let entries: [String: String]
        if data.starts(with: [0x50, 0x4B]) {
            entries = try ReaderPresetArchive().unpack(base64Zip: data.base64EncodedString())
        } else {
            // Keep previously exported KMP JSON usable as a platform compatibility input.
            entries = ["readConfig.json": data.base64EncodedString()]
        }
        guard let encoded = entries["readConfig.json"], let config = Data(base64Encoded: encoded),
            config.count <= 4 * 1024 * 1024, let text = String(data: config, encoding: .utf8)
        else { throw error("缺少有效的 readConfig.json") }
        let codec = ReaderPresetTransferCodec()
        var row = try object(codec.encode(preset: codec.decode(jsonString: text)))
        var createdImages: [URL] = []
        var importedImages: [String: String] = [:]
        var fontLease: ReaderFontStore.ImportLease?
        do {
            for suffix in ["", "Night", "EInk"] {
                let key = "bgStr" + suffix
                let kind = (row["bgType" + suffix] as? NSNumber)?.intValue ?? 0
                guard kind != 0, let path = row[key] as? String, !path.isEmpty else { continue }
                if let builtin = ReaderBackgroundImageCatalog.item(forStoredPath: path) {
                    row[key] = builtin.storedPath
                    row["bgType" + suffix] = 1
                    continue
                }
                if path.hasPrefix("legado-background-file:"),
                    let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: path),
                    FileManager.default.fileExists(atPath: url.path)
                {
                    row["bgType" + suffix] = 2
                    continue
                }
                let name = resourceName(path)
                guard let encoded = entries[name], let image = Data(base64Encoded: encoded) else {
                    throw error("配置缺少背景图片：\(name)")
                }
                let digest = SHA256.hash(data: image).description
                let storedPath: String
                if let existing = importedImages[digest] {
                    storedPath = existing
                } else {
                    try validateImage(image)
                    storedPath = try ReaderBackgroundTextFiles.importImage(image)
                    guard let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: storedPath) else {
                        throw error("无法保存背景图片")
                    }
                    createdImages.append(url)
                    importedImages[digest] = storedPath
                }
                row[key] = storedPath
                row["bgType" + suffix] = 2
            }
            row.removeValue(forKey: "backgroundImagePath")
            if let font = row["textFont"] as? String, !font.isEmpty {
                let name = resourceName(font)
                if let encoded = entries[name], let bytes = Data(base64Encoded: encoded) {
                    guard bytes.count <= resourceLimit, ["ttf", "otf"].contains((name as NSString).pathExtension.lowercased())
                    else {
                        throw error("不支持的配置字体")
                    }
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                        UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let file = directory.appendingPathComponent(name)
                    try bytes.write(to: file, options: .atomic)
                    let lease = try fontStore.leaseFontImport(from: file)
                    fontLease = lease
                    row["textFont"] = try lease.selectionIdentifier(filename: name)
                } else if !font.hasPrefix("reader-font:") || fontStore.title(for: font) == nil {
                    // Android clears a font whose file is not carried by the archive.
                    row["textFont"] = ""
                } else {
                    fontLease = try fontStore.leaseFont(for: font)
                }
            }
            let json = try encode(row)
            _ = try codec.decode(jsonString: json)
            return PreparedImport(json: json, createdImages: createdImages, fontLease: fontLease)
        } catch {
            throw PreparedImport(json: "", createdImages: createdImages, fontLease: fontLease).discardResources(after: error)
        }
    }

    static func prepareExport(json: String, fontStore: ReaderFontStore = .shared) throws -> Export {
        let codec = ReaderPresetTransferCodec()
        var row = try object(codec.encode(preset: codec.decode(jsonString: json)))
        var entries: [String: String] = [:]
        var imageNames: [String: String] = [:]
        var total = 0
        for (suffix, label) in [("", "day"), ("Night", "night"), ("EInk", "eink")] {
            let key = "bgStr" + suffix
            let kind = (row["bgType" + suffix] as? NSNumber)?.intValue ?? 0
            guard kind != 0, let path = row[key] as? String, !path.isEmpty else { continue }
            if let builtin = ReaderBackgroundImageCatalog.item(forStoredPath: path) {
                row[key] = "bg/" + builtin.fileName
                row["bgType" + suffix] = 1
                continue
            }
            guard let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: path) else {
                throw error("无法读取配置背景图片")
            }
            let image = try ReaderBackgroundTextFiles.read(url, limit: resourceLimit)
            try validateImage(image)
            let digest = SHA256.hash(data: image).description
            let name: String
            if let previous = imageNames[digest] {
                name = previous
            } else {
                let ext = url.pathExtension.lowercased()
                guard !ext.isEmpty, ext.utf8.allSatisfy({ (48...57).contains($0) || (97...122).contains($0) }) else {
                    throw error("背景图片扩展名无效")
                }
                name = "background-\(label).\(ext)"
                entries[name] = image.base64EncodedString()
                imageNames[digest] = name
                total += image.count
            }
            row[key] = name
            row["bgType" + suffix] = 2
        }
        row.removeValue(forKey: "backgroundImagePath")
        if let font = row["textFont"] as? String, !font.isEmpty {
            if font.hasPrefix("reader-font:") {
                let resource = try fontStore.exportResource(for: font)
                guard resource.data.count <= resourceLimit else { throw error("配置字体文件过大") }
                let ext = (resource.name as NSString).pathExtension.lowercased()
                guard ["ttf", "otf"].contains(ext) else { throw error("不支持的配置字体") }
                let name = "font." + ext
                entries[name] = resource.data.base64EncodedString()
                row["textFont"] = name
                total += resource.data.count
            } else {
                // Platform-provided fonts are not owned portable resources.
                row["textFont"] = ""
            }
        }
        let config = Data(try encode(row).utf8)
        guard config.count <= 4 * 1024 * 1024, total + config.count < archiveLimit - 65_536 else {
            throw error("阅读配置资源总量过大")
        }
        entries["readConfig.json"] = config.base64EncodedString()
        let archive = try ReaderPresetArchive().pack(base64Entries: entries)
        guard let data = Data(base64Encoded: archive), data.count <= archiveLimit else {
            throw error("无法打包阅读配置")
        }
        let name = safeFileName(row["name"] as? String ?? "")
        return Export(fileName: name + ".zip", data: data)
    }

    private static func object(_ text: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw error("阅读配置必须是一个对象")
        }
        return value
    }

    private static func encode(_ row: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func resourceName(_ path: String) -> String {
        (path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
    }

    private static func safeFileName(_ text: String) -> String {
        let disallowed = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let value = text.unicodeScalars.map { disallowed.contains($0) ? "_" : String($0) }.joined()
        let trimmed = String(value.prefix(80)).trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "readConfig" : trimmed
    }

    private static func validateImage(_ data: Data) throws {
        guard data.count <= resourceLimit,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = props[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue > 0, height.doubleValue > 0,
            width.doubleValue <= 16_384, height.doubleValue <= 16_384,
            width.doubleValue * height.doubleValue <= 64_000_000
        else { throw error("配置背景图片无效或尺寸过大") }
    }

    static func error(_ text: String) -> NSError {
        NSError(domain: "io.legado.reader.configTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
