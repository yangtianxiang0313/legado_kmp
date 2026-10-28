import Foundation
import ImageIO
import UIKit

enum CoverConfigurationImageFiles {
    private static let directory = "covers/default-cover-configuration"
    private static let maximumFileSize = 32 * 1024 * 1024

    static func importImage(at url: URL) throws -> String {
        guard url.isFileURL else { throw imageError("请选择本地或文件提供器中的图片。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
            result = Result {
                try Task.checkCancellation()
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let count = values.fileSize, count > 0,
                    count <= maximumFileSize,
                    let source = CGImageSourceCreateWithURL(
                        readable as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                    CGImageSourceGetCount(source) > 0,
                    let bitmap = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1800,
                            kCGImageSourceShouldCacheImmediately: true,
                        ] as CFDictionary)
                else { throw imageError("请选择 32 MB 以内可读取的图片。") }
                try Task.checkCancellation()
                let manager = FileManager.default
                let root = try manager.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let folder = root.appendingPathComponent(directory, isDirectory: true)
                try manager.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = directory + "/" + UUID().uuidString + ".png"
                let destination = root.appendingPathComponent(path)
                guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil)
                else { throw imageError("无法保存封面底图。") }
                CGImageDestinationAddImage(writer, bitmap, nil)
                guard CGImageDestinationFinalize(writer) else {
                    try? manager.removeItem(at: destination)
                    throw imageError("封面底图保存失败，请重试。")
                }
                return path
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? imageError("无法读取所选图片。")
    }

    static func resolve(_ path: String) -> URL? {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        if path.hasPrefix(directory + "/") {
            let name = String(path.dropFirst(directory.count + 1))
            guard validOwnedName(name) else { return nil }
            let folder = support.appendingPathComponent(directory).standardizedFileURL.resolvingSymlinksInPath()
            let root = support.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard folder.path.hasPrefix(root) else { return nil }
            let result = folder.appendingPathComponent(name)
                .standardizedFileURL.resolvingSymlinksInPath()
            let base = folder.path + "/"
            return result.path.hasPrefix(base) ? result : nil
        }
        let url =
            URL(string: path).flatMap { $0.isFileURL ? $0 : nil }
            ?? (path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil)
        guard let url, url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
        // Existing app-local paths must survive simulator/container moves without reaching outside the sandbox.
        if let range = url.path.range(of: "/Library/Application Support/covers/") {
            let suffix = String(url.path[range.upperBound...])
            guard !suffix.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
            let rebound = support.appendingPathComponent("covers").appendingPathComponent(suffix)
                .standardizedFileURL.resolvingSymlinksInPath()
            let root = support.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return rebound.path.hasPrefix(root) ? rebound : nil
        }
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return normalized.path.hasPrefix(home) ? normalized : nil
    }

    static func removeOwnedImage(_ path: String) {
        guard path.hasPrefix(directory + "/"), let url = resolve(path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func loadImage(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1800,
                ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    private static func validOwnedName(_ name: String) -> Bool {
        name.hasSuffix(".png") && UUID(uuidString: String(name.dropLast(4))) != nil
    }

    private static func imageError(_ message: String) -> NSError {
        NSError(domain: "CoverConfiguration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
