import CryptoKit
import Foundation
import ImageIO
import shared

/// Android readConfig.zip carries one config and only the resources that it references.
enum ReaderPresetTransferResources {
    final class PreparedImport {
        let json: String
        private let imageLeases: [ReaderBackgroundTextFiles.ImportLease]
        private let fontLease: ReaderFontStore.ImportLease?
        private let lock = NSLock()
        private var settled = false

        init(json: String, imageLeases: [ReaderBackgroundTextFiles.ImportLease], fontLease: ReaderFontStore.ImportLease?) {
            self.json = json
            self.imageLeases = imageLeases
            self.fontLease = fontLease
        }

        // Only the real shared persistence result may commit, never a presentation/cancellation gate.
        func commitResources() {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            fontLease?.commit()
            for lease in imageLeases { lease.commit() }
            settled = true
        }

        func discardResources() throws {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return }
            var failure: Error?
            do { try fontLease?.rollback() } catch { failure = error }
            for lease in imageLeases {
                do { try lease.rollback() } catch { if failure == nil { failure = error } }
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
                            String.localizedStringWithFormat(
                                NSLocalizedString("reader.preset.consumer.rollback_failed", value: "%@\n导入资源回滚失败：%@", comment: ""),
                                originalError.localizedDescription, error.localizedDescription),
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
        guard data.count <= archiveLimit else {
            throw error(NSLocalizedString("reader.preset.consumer.file_too_large", value: "阅读配置文件过大", comment: ""))
        }
        let entries: [String: String]
        if data.starts(with: [0x50, 0x4B]) {
            entries = try ReaderPresetArchive().unpack(base64Zip: data.base64EncodedString())
        } else {
            // Keep previously exported KMP JSON usable as a platform compatibility input.
            entries = ["readConfig.json": data.base64EncodedString()]
        }
        guard let encoded = entries["readConfig.json"], let config = Data(base64Encoded: encoded),
            config.count <= 4 * 1024 * 1024, let text = String(data: config, encoding: .utf8)
        else {
            throw error(NSLocalizedString("reader.preset.consumer.config_missing", value: "缺少有效的 readConfig.json", comment: ""))
        }
        let codec = ReaderPresetTransferCodec()
        var row = try object(codec.encode(preset: codec.decode(jsonString: text)))
        var imageLeases: [ReaderBackgroundTextFiles.ImportLease] = []
        var importedImages: [String: String] = [:]
        var importedPaths: [String: String] = [:]
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
                if let storedPath = importedPaths[path] {
                    row[key] = storedPath
                    row["bgType" + suffix] = 2
                    continue
                }
                let image: Data
                let existingLease: ReaderBackgroundTextFiles.ImportLease?
                if path.hasPrefix("legado-background-file:"),
                    let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: path),
                    FileManager.default.fileExists(atPath: url.path)
                {
                    let lease = try ReaderBackgroundTextFiles.leaseImage(forStoredPath: path)
                    imageLeases.append(lease)
                    existingLease = lease
                    image = try ReaderBackgroundTextFiles.read(url, limit: resourceLimit)
                } else {
                    let name = resourceName(path)
                    guard let encoded = entries[name], let bytes = Data(base64Encoded: encoded) else {
                        throw error(
                            String.localizedStringWithFormat(
                                NSLocalizedString("reader.preset.consumer.background_missing", value: "配置缺少背景图片：%@", comment: ""), name))
                    }
                    image = bytes
                    existingLease = nil
                    try validateImage(image)
                }
                let digest = SHA256.hash(data: image).description
                let storedPath: String
                if let existing = importedImages[digest] {
                    storedPath = existing
                    if let existingLease {
                        try existingLease.rollback()
                        imageLeases.removeLast()
                    }
                } else {
                    if let existingLease {
                        storedPath = existingLease.storedPath
                    } else {
                        let lease = try ReaderBackgroundTextFiles.leaseImageImport(image)
                        imageLeases.append(lease)
                        storedPath = lease.storedPath
                        guard ReaderBackgroundImageCatalog.resourceURL(forStoredPath: storedPath) != nil else {
                            throw error(NSLocalizedString("reader.preset.consumer.background_save_failed", value: "无法保存背景图片", comment: ""))
                        }
                    }
                    importedImages[digest] = storedPath
                }
                importedPaths[path] = storedPath
                importedPaths[storedPath] = storedPath
                if let existingLease { importedPaths[existingLease.storedPath] = storedPath }
                row[key] = storedPath
                row["bgType" + suffix] = 2
            }
            row.removeValue(forKey: "backgroundImagePath")
            if let font = row["textFont"] as? String, !font.isEmpty {
                let name = resourceName(font)
                if let encoded = entries[name], let bytes = Data(base64Encoded: encoded) {
                    guard bytes.count <= resourceLimit, ["ttf", "otf"].contains((name as NSString).pathExtension.lowercased())
                    else {
                        throw error(NSLocalizedString("reader.preset.consumer.font_unsupported", value: "不支持的配置字体", comment: ""))
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
            return PreparedImport(json: json, imageLeases: imageLeases, fontLease: fontLease)
        } catch {
            throw PreparedImport(json: "", imageLeases: imageLeases, fontLease: fontLease).discardResources(after: error)
        }
    }

    static func prepareExport(json: String, fontStore: ReaderFontStore = .shared) throws -> Export {
        let codec = ReaderPresetTransferCodec()
        var row = try object(codec.encode(preset: codec.decode(jsonString: json)))
        var imageLeases: [ReaderBackgroundTextFiles.ImportLease] = []
        var leasedPaths: [String: String] = [:]
        defer {
            // Export only borrows resources; rollback must not commit another import's pending image.
            let borrowed = PreparedImport(json: "", imageLeases: imageLeases, fontLease: nil)
            do { try borrowed.discardResources() } catch {
                NSLog("ReaderPresetTransferResources export rollback: %@", error.localizedDescription)
            }
        }
        // Hold every owned background before reading or packaging any of them.
        for suffix in ["", "Night", "EInk"] {
            let kind = (row["bgType" + suffix] as? NSNumber)?.intValue ?? 0
            guard kind != 0, let path = row["bgStr" + suffix] as? String,
                ReaderBackgroundImageCatalog.item(forStoredPath: path) == nil,
                path.hasPrefix("legado-background-file:"), leasedPaths[path] == nil
            else { continue }
            let lease = try ReaderBackgroundTextFiles.leaseImage(forStoredPath: path)
            imageLeases.append(lease)
            leasedPaths[path] = lease.storedPath
        }
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
            guard let url = ReaderBackgroundImageCatalog.resourceURL(forStoredPath: leasedPaths[path] ?? path) else {
                throw error(NSLocalizedString("reader.preset.consumer.background_read_failed", value: "无法读取配置背景图片", comment: ""))
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
                    throw error(NSLocalizedString("reader.preset.consumer.background_extension_invalid", value: "背景图片扩展名无效", comment: ""))
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
                guard resource.data.count <= resourceLimit else {
                    throw error(NSLocalizedString("reader.preset.consumer.font_too_large", value: "配置字体文件过大", comment: ""))
                }
                let ext = (resource.name as NSString).pathExtension.lowercased()
                guard ["ttf", "otf"].contains(ext) else {
                    throw error(NSLocalizedString("reader.preset.consumer.font_unsupported", value: "不支持的配置字体", comment: ""))
                }
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
            throw error(NSLocalizedString("reader.preset.consumer.resources_too_large", value: "阅读配置资源总量过大", comment: ""))
        }
        entries["readConfig.json"] = config.base64EncodedString()
        let archive = try ReaderPresetArchive().pack(base64Entries: entries)
        guard let data = Data(base64Encoded: archive), data.count <= archiveLimit else {
            throw error(NSLocalizedString("reader.preset.consumer.archive_failed", value: "无法打包阅读配置", comment: ""))
        }
        let name = safeFileName(row["name"] as? String ?? "")
        return Export(fileName: name + ".zip", data: data)
    }

    private static func object(_ text: String) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw error(NSLocalizedString("reader.preset.consumer.object_required", value: "阅读配置必须是一个对象", comment: ""))
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
        else {
            throw error(NSLocalizedString("reader.preset.consumer.background_invalid", value: "配置背景图片无效或尺寸过大", comment: ""))
        }
    }

    static func error(_ text: String) -> NSError {
        NSError(domain: "io.legado.reader.configTransfer", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
