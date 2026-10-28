import CoreImage
import CryptoKit
import ImageIO
import UIKit

/// Only stable, content-addressed files in this directory may become a global background.
actor ThemeBackgroundImageStore {
    static let shared = ThemeBackgroundImageStore()
    private static let prefix = "legado-theme-background:"
    private static let byteLimit = 32 * 1024 * 1024
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var cachedKey: String?
    private var cachedImage: UIImage?

    struct Imported: Sendable {
        let path: String
        let created: Bool
    }

    func importImage(from url: URL) throws -> Imported {
        try Task.checkCancellation()
        guard url.isFileURL else { throw Self.error("请选择本地图片文件") }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
            (properties.fileSize ?? 0) <= Self.byteLimit
        else { throw Self.error("图片文件无效或超过 32 MB") }
        let data = try read(url)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0, height > 0, width * height <= 100_000_000,
            let image = Self.thumbnail(source, maximumPixels: 3072)
        else { throw Self.error("无法读取图片，或图片尺寸过大") }
        try Task.checkCancellation()
        let normalized = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(normalized as CFMutableData, "public.png" as CFString, 1, nil)
        else {
            throw Self.error("无法保存背景图片")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), normalized.length <= Self.byteLimit else {
            throw Self.error("背景图片转换失败或超过 32 MB")
        }
        let output = normalized as Data
        let digest = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
        let name = digest + ".png"
        let directory = try Self.directory(create: true)
        let file = directory.appendingPathComponent(name, isDirectory: false)
        let exists = FileManager.default.fileExists(atPath: file.path)
        if exists {
            guard try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw Self.error("背景图片存储路径无效") }
        }
        try output.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return Imported(path: Self.prefix + name, created: !exists)
    }

    func removeIfUnreferenced(_ path: String?, referencedPaths: [String]) {
        guard let path, !referencedPaths.contains(path), let url = Self.fileURL(for: path) else { return }
        let latest = ThemeBackgroundChannel.allCases.compactMap { ThemeBackgroundConfiguration.read(channel: $0).imagePath }
        guard !latest.contains(path) else { return }
        try? FileManager.default.removeItem(at: url)
        cachedKey = nil
        cachedImage = nil
    }

    func image(configuration: ThemeBackgroundConfiguration, maximumPixels: Int) throws -> UIImage? {
        try Task.checkCancellation()
        guard let path = configuration.imagePath, let url = Self.fileURL(for: path) else { return nil }
        let pixels = min(3072, max(256, maximumPixels))
        let key = "\(path)|\(configuration.blurring)|\(pixels)"
        if cachedKey == key, let cachedImage { return cachedImage }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let decoded = Self.thumbnail(source, maximumPixels: pixels)
        else { throw Self.error("无法读取背景图片，请重新选择") }
        var image = decoded
        if configuration.blurring > 0 {
            let input = CIImage(cgImage: decoded)
            // Native blur retains ThemeConfig's 0...25 control without decoding the full source bitmap.
            let blurred = input.clampedToExtent().applyingFilter(
                "CIGaussianBlur", parameters: [kCIInputRadiusKey: configuration.blurring]
            )
            .cropped(to: input.extent)
            guard let output = context.createCGImage(blurred, from: input.extent) else {
                throw Self.error("背景图片模糊处理失败")
            }
            image = output
        }
        try Task.checkCancellation()
        let result = UIImage(cgImage: image).withRenderingMode(.alwaysOriginal)
        cachedKey = key
        cachedImage = result
        return result
    }

    nonisolated static func fileURL(for path: String) -> URL? {
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        let digest = name.dropLast(4)
        guard name.hasSuffix(".png"), digest.count == 64,
            digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            let directory = try? directory(create: false)
        else { return nil }
        let file = directory.appendingPathComponent(name, isDirectory: false)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= byteLimit,
            file.resolvingSymlinksInPath().deletingLastPathComponent() == directory
        else { return nil }
        return file
    }

    private nonisolated static func directory(create: Bool) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: create
        )
        .resolvingSymlinksInPath()
        let directory = support.appendingPathComponent("ThemeBackgrounds", isDirectory: true)
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
            directory.resolvingSymlinksInPath().deletingLastPathComponent() == support
        else { throw error("背景图片存储目录无效") }
        return directory
    }

    private func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        while let chunk = try handle.read(upToCount: min(65_536, Self.byteLimit - result.count + 1)), !chunk.isEmpty {
            try Task.checkCancellation()
            result.append(chunk)
            guard result.count <= Self.byteLimit else { throw Self.error("图片不能超过 32 MB") }
        }
        return result
    }

    private nonisolated static func thumbnail(_ source: CGImageSource, maximumPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func error(_ message: String) -> NSError {
        NSError(domain: "io.legado.theme.background", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
