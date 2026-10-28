import ImageIO
import UIKit

enum ReaderBackgroundImageCatalog {
    struct Item: Sendable {
        let id: String
        let title: String
        let fileName: String
        let storedPath: String

        fileprivate init(id: String, fileName: String) {
            self.id = id
            title = (fileName as NSString).deletingPathExtension
            self.fileName = fileName
            storedPath = ReaderBackgroundImageCatalog.builtinPrefix + id
        }
    }

    private static let builtinPrefix = "legado-background:"
    private static let importedPrefix = "legado-background-file:"

    // Preserve assets/bg filename order at Legado 5f5d314; IDs are persistence keys.
    static let items: [Item] = [
        Item(id: "afternoon-beach", fileName: "午后沙滩.jpg"),
        Item(id: "quiet-night", fileName: "宁静夜色.jpg"),
        Item(id: "ink-landscape", fileName: "山水墨影.jpg"),
        Item(id: "landscape", fileName: "山水画.jpg"),
        Item(id: "eye-care-green", fileName: "护眼漫绿.jpg"),
        Item(id: "new-parchment", fileName: "新羊皮纸.jpg"),
        Item(id: "bright-city", fileName: "明媚倾城.jpg"),
        Item(id: "palace-shadows", fileName: "深宫魅影.jpg"),
        Item(id: "fresh-moments", fileName: "清新时光.jpg"),
        Item(id: "parchment-1", fileName: "羊皮纸1.jpg"),
        Item(id: "parchment-2", fileName: "羊皮纸2.jpg"),
        Item(id: "parchment-3", fileName: "羊皮纸3.jpg"),
        Item(id: "parchment-4", fileName: "羊皮纸4.jpg"),
        Item(id: "bordered-canvas", fileName: "边彩画布.jpg"),
    ]

    static func item(forStoredPath path: String?) -> Item? {
        guard let path else { return nil }
        // Android asset aliases are exact whitelist matches, not relative paths to open.
        return items.first {
            path == $0.storedPath || path == $0.fileName
                || path == "bg/" + $0.fileName || path == "assets/bg/" + $0.fileName
        }
    }

    static func isBuiltin(path: String?) -> Bool {
        item(forStoredPath: path) != nil
    }

    static func resourceURL(forStoredPath path: String) -> URL? {
        if let item = item(forStoredPath: path) { return builtinURL(for: item) }
        if path.hasPrefix(importedPrefix) { return importedURL(forStoredPath: path) }
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Resolve identifiers on every load; never persist a bundle/container URL.
    static func image(forStoredPath path: String?) -> UIImage? {
        guard let path, !path.isEmpty else { return nil }

        if let item = item(forStoredPath: path) {
            guard let url = builtinURL(for: item) else { return nil }
            return UIImage(contentsOfFile: url.path)?.withRenderingMode(.alwaysOriginal)
        }

        if path.hasPrefix(importedPrefix) {
            guard let url = importedURL(forStoredPath: path) else { return nil }
            return UIImage(contentsOfFile: url.path)?.withRenderingMode(.alwaysOriginal)
        }

        guard (path as NSString).isAbsolutePath else { return nil }
        return UIImage(contentsOfFile: path)?.withRenderingMode(.alwaysOriginal)
    }

    static func thumbnail(for item: Item, maximumPixelSize: Int) -> UIImage? {
        guard maximumPixelSize > 0,
            let knownItem = self.item(forStoredPath: item.storedPath),
            let url = builtinURL(for: knownItem),
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        // Decode only the thumbnail, without retaining fourteen full-size page images.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image).withRenderingMode(.alwaysOriginal)
    }

    private static func builtinURL(for item: Item) -> URL? {
        Bundle.main.url(forResource: item.fileName, withExtension: nil, subdirectory: "ReaderBackgrounds")
    }

    private static func importedURL(forStoredPath path: String) -> URL? {
        let name = String(path.dropFirst(importedPrefix.count))
        guard !name.contains("/"), !name.contains("\\"), !name.contains("..") else { return nil }

        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let uuid = UUID(uuidString: String(parts[0])),
            uuid.uuidString.caseInsensitiveCompare(String(parts[0])) == .orderedSame,
            !parts[1].isEmpty,
            parts[1].utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            }),
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else { return nil }

        return directory.appendingPathComponent("ReaderBackgrounds", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}
